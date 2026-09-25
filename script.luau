--!strict
-- TacticalRadar v2.5.0 - Enhanced ESP & Aim Assist Suite
-- Scoped execution to prevent register limit errors
do
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local TweenService = game:GetService("TweenService")
    local UserInputService = game:GetService("UserInputService")
    local Teams = game:GetService("Teams")

    local LocalPlayer = Players.LocalPlayer
    local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
    local Camera = workspace.CurrentCamera or workspace:WaitForChild("Camera")

    -- State settings
    local Settings = {
        HighlightsEnabled = true,
        BoxesEnabled = true,          -- 2D Screen-space Box ESP
        NametagsEnabled = true,
        TeamCheckEnabled = true,
        TeamColorEnabled = true,      -- Toggles whether teammates get team color or have no ESP
        EnemyColor = Color3.fromRGB(255, 65, 65),
        FriendlyColor = Color3.fromRGB(0, 180, 255),
        OutlineColor = Color3.fromRGB(255, 255, 255),
        FillTransparency = 0.55,
        OutlineTransparency = 0.1,
        ToggleKey = Enum.KeyCode.RightShift,
        -- Aim Assist Settings
        AimAssistEnabled = false,
        AimAssistFOV = 150,
        AimAssistSmoothness = 0.15,
        AimAssistBone = "Head",       -- "Head", "Chest", "Neck"
        AimAssistKey = Enum.KeyCode.RightControl,
        AimAssistFOVCircleEnabled = true,
        -- Silent Aim Settings
        SilentAimEnabled = false,
        SilentAimFOV = 150,
        SilentAimSmoothness = 0.2,
        SilentAimBone = "Head",
        SilentAimKey = Enum.KeyCode.RightControl,
    }

type TrackedData = {
    Highlight: Highlight?,
    Box2D: Frame?,
    BoxStroke: UIStroke?,
    Tag: BillboardGui?,
    Label: TextLabel?,
    TargetAnchor: BasePart?,
    CharModel: Model?,
    DeathConn: RBXScriptConnection?,
}

local isRunning = true
local trackedPlayers: { [Player]: TrackedData } = {}
local localAnchor: BasePart? = nil

-- Dedicated ScreenGui for HUD & 2D Screen-Space Boxes
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TacticalRadarHUD"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = PlayerGui

local boxContainer = Instance.new("Folder")
boxContainer.Name = "2D_Boxes"
boxContainer.Parent = screenGui

local highlightHolder = Instance.new("Folder")
highlightHolder.Name = "HighlightHolder"
highlightHolder.Parent = PlayerGui

-- FOV Circle for Aim Assist
local fovCircle = Instance.new("Frame")
fovCircle.Name = "FOV_Circle"
fovCircle.Size = UDim2.new(0, 0, 0, 0)
fovCircle.Position = UDim2.new(0.5, 0, 0.5, 0)
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.BackgroundColor3 = Color3.fromRGB(0, 190, 255)
fovCircle.BackgroundTransparency = 0.85
fovCircle.BorderSizePixel = 2
fovCircle.BorderColor3 = Color3.fromRGB(0, 190, 255)
fovCircle.Parent = screenGui

local fovCorner = Instance.new("UICorner")
fovCorner.CornerRadius = UDim.new(0.5, 0)
fovCorner.Parent = fovCircle

local fovStroke = Instance.new("UIStroke")
fovStroke.Color = Color3.fromRGB(0, 190, 255)
fovStroke.Thickness = 2
fovStroke.Transparency = 0.3
fovStroke.Parent = fovCircle

---------------------------------------------------------------------
-- 1. Custom Character Compatibility Resolvers
---------------------------------------------------------------------
local function isTeammate(player: Player): boolean
    if not Settings.TeamCheckEnabled then return false end
    if player == LocalPlayer then return true end

    -- Strict Team Object Check (most reliable across Roblox games)
    if player.Team and LocalPlayer.Team then
        if player.Team == LocalPlayer.Team then
            return true
        end
    end

    return false
end

local function isCharacterAlive(character: Model?): boolean
    if not character or not character.Parent or not character:IsDescendantOf(workspace) then
        return false
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid and humanoid.Health <= 0 then
        return false
    end
    return true
end

local function getModelAnchor(character: Model?): BasePart?
    if not character or not character.Parent then return nil end
    if character.PrimaryPart and character.PrimaryPart:IsDescendantOf(workspace) then
        return character.PrimaryPart
    end

    local commonNames = { "HumanoidRootPart", "Root", "Torso", "UpperTorso", "Core", "Chest", "Main", "Head" }
    for _, name in ipairs(commonNames) do
        local part = character:FindFirstChild(name, true)
        if part and part:IsA("BasePart") and part:IsDescendantOf(workspace) then
            return part
        end
    end

    local largestPart: BasePart? = nil
    local largestVol = 0
    for _, desc in ipairs(character:GetDescendants()) do
        if desc:IsA("BasePart") and desc:IsDescendantOf(workspace) and desc.Transparency < 1 then
            local vol = desc.Size.X * desc.Size.Y * desc.Size.Z
            if vol > largestVol then
                largestVol = vol
                largestPart = desc
            end
        end
    end

    return largestPart or character:FindFirstChildWhichIsA("BasePart", true)
end

local function getCustomBoundingBox(character: Model): (CFrame, Vector3)
    local ok, cf, sz = pcall(function()
        return character:GetBoundingBox()
    end)
    if ok and cf and sz and sz.Magnitude > 0 then
        return cf, sz
    end

    local anchor = getModelAnchor(character)
    if anchor then
        return anchor.CFrame, anchor.Size + Vector3.new(2, 3, 2)
    end
    return CFrame.new(), Vector3.new(4, 5, 4)
end

---------------------------------------------------------------------
-- 2. Visuals Setup & Destruction
---------------------------------------------------------------------
local function cleanPlayer(player: Player)
    local data = trackedPlayers[player]
    if data then
        if data.DeathConn then
            data.DeathConn:Disconnect()
            data.DeathConn = nil
        end
        if data.Highlight then data.Highlight:Destroy() end
        if data.Box2D then data.Box2D:Destroy() end
        if data.Tag then data.Tag:Destroy() end
        trackedPlayers[player] = nil
    end
end

local function updatePlayerVisuals(player: Player)
    local data = trackedPlayers[player]
    if not data then return end

    local teammate = isTeammate(player)
    local activeColor = (teammate and Settings.TeamColorEnabled) and Settings.FriendlyColor or Settings.EnemyColor

    local isVisible = true
    if Settings.TeamCheckEnabled and teammate and not Settings.TeamColorEnabled then
        isVisible = false
    end

    if data.Highlight then
        data.Highlight.Enabled = Settings.HighlightsEnabled and isVisible
        data.Highlight.FillColor = activeColor
    end

    if data.Box2D and data.BoxStroke then
        data.Box2D.Visible = Settings.BoxesEnabled and isVisible
        data.BoxStroke.Color = activeColor
    end

    if data.Tag then
        data.Tag.Enabled = Settings.NametagsEnabled and isVisible
    end
    if data.Label then
        data.Label.TextColor3 = activeColor
    end
end

local function setupCharacterDisplay(player: Player, character: Model)
    if player == LocalPlayer then return end
    cleanPlayer(player)

    local anchor: BasePart? = nil
    local tries = 0
    while tries < 35 do
        if not character.Parent or not character:IsDescendantOf(workspace) or not isCharacterAlive(character) then
            return
        end
        anchor = getModelAnchor(character)
        if anchor then break end
        tries += 1
        task.wait(0.1)
    end

    if not anchor or not character.Parent then return end

    local teammate = isTeammate(player)
    local initialColor = (teammate and Settings.TeamColorEnabled) and Settings.FriendlyColor or Settings.EnemyColor
    local isVisible = true
    if Settings.TeamCheckEnabled and teammate and not Settings.TeamColorEnabled then
        isVisible = false
    end

    -- 1. Native Silhouette Highlight
    local highlight = Instance.new("Highlight")
    highlight.Name = "HL_" .. player.Name
    highlight.Adornee = character
    highlight.FillColor = initialColor
    highlight.OutlineColor = Settings.OutlineColor
    highlight.FillTransparency = Settings.FillTransparency
    highlight.OutlineTransparency = Settings.OutlineTransparency
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = Settings.HighlightsEnabled and isVisible
    highlight.Parent = highlightHolder

    -- 2. True 2D Screen-Space Box ESP (Visible Through All Walls)
    local boxFrame = Instance.new("Frame")
    boxFrame.Name = "2DBox_" .. player.Name
    boxFrame.BackgroundTransparency = 1
    boxFrame.BorderSizePixel = 0
    boxFrame.Visible = Settings.BoxesEnabled and isVisible
    boxFrame.Parent = boxContainer

    local boxStroke = Instance.new("UIStroke")
    boxStroke.Color = initialColor
    boxStroke.Thickness = 1.2
    boxStroke.Transparency = 0.1
    boxStroke.Parent = boxFrame

    -- 3. Compact Name & Distance Pill
    local _, sz = getCustomBoundingBox(character)
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "Tag_" .. player.Name
    billboard.Adornee = anchor
    billboard.Size = UDim2.new(0, 95, 0, 18)
    billboard.StudsOffset = Vector3.new(0, (sz.Y * 0.5) + 1.2, 0)
    billboard.AlwaysOnTop = true
    billboard.ResetOnSpawn = false
    billboard.Enabled = Settings.NametagsEnabled and isVisible

    local pillFrame = Instance.new("Frame")
    pillFrame.Size = UDim2.new(1, 0, 1, 0)
    pillFrame.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
    pillFrame.BackgroundTransparency = 0.35
    pillFrame.BorderSizePixel = 0
    pillFrame.Parent = billboard

    local pillCorner = Instance.new("UICorner")
    pillCorner.CornerRadius = UDim.new(0, 4)
    pillCorner.Parent = pillFrame

    local pillStroke = Instance.new("UIStroke")
    pillStroke.Color = Color3.fromRGB(45, 55, 70)
    pillStroke.Thickness = 1
    pillStroke.Transparency = 0.5
    pillStroke.Parent = pillFrame

    local compactLabel = Instance.new("TextLabel")
    compactLabel.Size = UDim2.new(1, -6, 1, 0)
    compactLabel.Position = UDim2.new(0, 3, 0, 0)
    compactLabel.BackgroundTransparency = 1
    compactLabel.Font = Enum.Font.GothamMedium
    compactLabel.Text = string.format("%s • ...", player.DisplayName)
    compactLabel.TextColor3 = initialColor
    compactLabel.TextSize = 9
    compactLabel.TextTruncate = Enum.TextTruncate.AtEnd
    compactLabel.Parent = pillFrame

    billboard.Parent = PlayerGui

    -- Cleanup on death
    local deathConn: RBXScriptConnection? = nil
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        deathConn = humanoid.Died:Connect(function()
            cleanPlayer(player)
        end)
    end

    character.AncestryChanged:Connect(function(_, parent)
        if not parent then cleanPlayer(player) end
    end)

    trackedPlayers[player] = {
        Highlight = highlight,
        Box2D = boxFrame,
        BoxStroke = boxStroke,
        Tag = billboard,
        Label = compactLabel,
        TargetAnchor = anchor,
        CharModel = character,
        DeathConn = deathConn,
    }
end

---------------------------------------------------------------------
-- 3. Local Player Anchor Sync
---------------------------------------------------------------------
local function refreshLocalAnchor()
    local char = LocalPlayer.Character
    if not isCharacterAlive(char) then
        localAnchor = nil
        return
    end
    localAnchor = getModelAnchor(char)
end

LocalPlayer.CharacterAdded:Connect(function(char)
    localAnchor = nil
    task.spawn(function()
        local tries = 0
        while tries < 40 and not localAnchor do
            localAnchor = getModelAnchor(char)
            if localAnchor then break end
            tries += 1
            task.wait(0.1)
        end
    end)
end)

LocalPlayer.CharacterRemoving:Connect(function()
    localAnchor = nil
end)

if LocalPlayer.Character then
    refreshLocalAnchor()
end

---------------------------------------------------------------------
-- 4. Sleek Modern Tabbed UI (Visuals / Colors / Misc)
---------------------------------------------------------------------
local function buildModernUI()
    local panel = Instance.new("Frame")
    panel.Name = "ControlPanel"
    panel.Size = UDim2.new(0, 640, 0, 480)
    panel.Position = UDim2.new(0.5, -320, 0.5, -240)
    panel.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
    panel.BackgroundTransparency = 0.05
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.ClipsDescendants = true
    panel.Parent = screenGui

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 12)
    panelCorner.Parent = panel

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(50, 60, 75)
    panelStroke.Thickness = 1.5
    panelStroke.Transparency = 0.15
    panelStroke.Parent = panel

    -- Header / Drag Bar
    local dragBar = Instance.new("Frame")
    dragBar.Name = "DragBar"
    dragBar.Size = UDim2.new(1, 0, 0, 40)
    dragBar.BackgroundColor3 = Color3.fromRGB(22, 25, 30)
    dragBar.BorderSizePixel = 0
    dragBar.Parent = panel

    local dragBarCorner = Instance.new("UICorner")
    dragBarCorner.CornerRadius = UDim.new(0, 12)
    dragBarCorner.CornerRadius = UDim.new(0, 0)
    dragBarCorner.Parent = dragBar

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -100, 1, 0)
    title.Position = UDim2.new(0, 16, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = "TACTICAL RADAR"
    title.TextColor3 = Color3.fromRGB(200, 220, 245)
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = dragBar

    local shortcutHint = Instance.new("TextLabel")
    shortcutHint.Size = UDim2.new(0, 60, 0, 20)
    shortcutHint.Position = UDim2.new(1, -76, 0.5, -10)
    shortcutHint.BackgroundColor3 = Color3.fromRGB(28, 32, 40)
    shortcutHint.BorderSizePixel = 0
    shortcutHint.Font = Enum.Font.GothamBold
    shortcutHint.Text = "R-SHIFT"
    shortcutHint.TextColor3 = Color3.fromRGB(140, 160, 185)
    shortcutHint.TextSize = 9
    shortcutHint.Parent = dragBar

    local hintCorner = Instance.new("UICorner")
    hintCorner.CornerRadius = UDim.new(0, 5)
    hintCorner.Parent = shortcutHint

    -- Tabs Navigation Bar
    local navBar = Instance.new("Frame")
    navBar.Name = "NavBar"
    navBar.Size = UDim2.new(1, -24, 0, 32)
    navBar.Position = UDim2.new(0, 12, 0, 48)
    navBar.BackgroundColor3 = Color3.fromRGB(24, 28, 35)
    navBar.BorderSizePixel = 0
    navBar.Parent = panel

    local navCorner = Instance.new("UICorner")
    navCorner.CornerRadius = UDim.new(0, 8)
    navCorner.Parent = navBar

    local tabButtons: { [string]: TextButton } = {}
    local tabPages: { [string]: Frame } = {}

    local tabNames = { "Visuals", "Colors", "Aim Assist", "Misc", "Settings" }
    local activeTab = "Visuals"

    for i, tabName in ipairs(tabNames) do
        local page = Instance.new("Frame")
        page.Name = tabName .. "_Page"
        page.Size = UDim2.new(1, -24, 1, -80)
        page.Position = UDim2.new(0, 12, 0, 88)
        page.BackgroundTransparency = 1
        page.Visible = (tabName == activeTab)
        page.Parent = panel
        tabPages[tabName] = page

        local btn = Instance.new("TextButton")
        btn.Name = tabName .. "_TabBtn"
        btn.Size = UDim2.new(1 / #tabNames, 0, 1, 0)
        btn.Position = UDim2.new((i - 1) / #tabNames, 0, 0, 0)
        btn.BackgroundTransparency = (tabName == activeTab) and 0 or 1
        btn.BackgroundColor3 = (tabName == activeTab) and Color3.fromRGB(0, 160, 255) or Color3.fromRGB(28, 32, 40)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.Text = tabName
        btn.TextColor3 = (tabName == activeTab) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(140, 155, 175)
        btn.TextSize = 11
        btn.Parent = navBar

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = btn

        tabButtons[tabName] = btn

        btn.MouseButton1Click:Connect(function()
            activeTab = tabName
            for name, p in pairs(tabPages) do
                p.Visible = (name == tabName)
            end
            for name, b in pairs(tabButtons) do
                local selected = (name == tabName)
                b.BackgroundTransparency = selected and 0 or 1
                b.BackgroundColor3 = selected and Color3.fromRGB(0, 160, 255) or Color3.fromRGB(28, 32, 40)
                b.TextColor3 = selected and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(140, 155, 175)
            end
        end)
    end

    -- Helper: Toggle Button Maker
    local function createToggleButton(parentPage: Frame, name: string, yPos: number, initialState: boolean, callback: (boolean) -> ())
        local container = Instance.new("Frame")
        container.Size = UDim2.new(1, 0, 0, 36)
        container.Position = UDim2.new(0, 0, 0, yPos)
        container.BackgroundTransparency = 1
        container.Parent = parentPage

        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Size = UDim2.new(1, 0, 1, 0)
        btn.BackgroundColor3 = initialState and Color3.fromRGB(25, 35, 48) or Color3.fromRGB(22, 25, 32)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamMedium
        btn.Text = ""
        btn.AutoButtonColor = false
        btn.Parent = container

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 8)
        btnCorner.Parent = btn

        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = initialState and Color3.fromRGB(0, 160, 255) or Color3.fromRGB(40, 48, 60)
        btnStroke.Thickness = 1.5
        btnStroke.Parent = btn

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.5, 0, 1, 0)
        label.Position = UDim2.new(0, 16, 0, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.Text = name
        label.TextColor3 = Color3.fromRGB(220, 225, 235)
        label.TextSize = 11
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = btn

        local status = Instance.new("TextLabel")
        status.Size = UDim2.new(0.3, -16, 1, 0)
        status.Position = UDim2.new(0.7, 0, 0, 0)
        status.BackgroundTransparency = 1
        status.Font = Enum.Font.GothamBold
        status.Text = initialState and "ON" or "OFF"
        status.TextColor3 = initialState and Color3.fromRGB(0, 190, 255) or Color3.fromRGB(130, 140, 155)
        status.TextSize = 10
        status.TextXAlignment = Enum.TextXAlignment.Right
        status.Parent = btn

        local state = initialState
        btn.MouseButton1Click:Connect(function()
            state = not state
            callback(state)

            local targetBg = state and Color3.fromRGB(25, 35, 48) or Color3.fromRGB(22, 25, 32)
            local targetStroke = state and Color3.fromRGB(0, 160, 255) or Color3.fromRGB(40, 48, 60)
            local targetText = state and Color3.fromRGB(0, 190, 255) or Color3.fromRGB(130, 140, 155)

            TweenService:Create(btn, TweenInfo.new(0.2), { BackgroundColor3 = targetBg }):Play()
            TweenService:Create(btnStroke, TweenInfo.new(0.2), { Color = targetStroke }):Play()
            status.Text = state and "ON" or "OFF"
            status.TextColor3 = targetText
        end)
    end

    -- Helper: Keybind Binder Maker
    local function createKeybindButton(parentPage: Frame, titleText: string, yPos: number, currentKey: Enum.KeyCode, onKeyChanged: (Enum.KeyCode) -> ())
        local container = Instance.new("Frame")
        container.Size = UDim2.new(1, 0, 0, 40)
        container.Position = UDim2.new(0, 0, 0, yPos)
        container.BackgroundTransparency = 1
        container.Parent = parentPage

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.45, 0, 1, 0)
        label.Position = UDim2.new(0, 16, 0, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.Text = titleText
        label.TextColor3 = Color3.fromRGB(180, 195, 215)
        label.TextSize = 11
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = container

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.45, 0, 1, 0)
        btn.Position = UDim2.new(0.55, 0, 0, 0)
        btn.BackgroundColor3 = Color3.fromRGB(25, 30, 40)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.Text = currentKey.Name
        btn.TextColor3 = Color3.fromRGB(0, 190, 255)
        btn.TextSize = 10
        btn.AutoButtonColor = false
        btn.Parent = container

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = btn

        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = Color3.fromRGB(50, 65, 85)
        btnStroke.Thickness = 1.5
        btnStroke.Parent = btn

        local listening = false
        btn.MouseButton1Click:Connect(function()
            if listening then return end
            listening = true
            btn.Text = "..."
            btn.TextColor3 = Color3.fromRGB(255, 200, 0)

            local conn
            conn = UserInputService.InputBegan:Connect(function(input, gp)
                if input.UserInputType == Enum.UserInputType.Keyboard then
                    local newKey = input.KeyCode
                    onKeyChanged(newKey)
                    btn.Text = newKey.Name
                    btn.TextColor3 = Color3.fromRGB(0, 190, 255)
                    listening = false
                    conn:Disconnect()
                end
            end)
        end)
    end

    -- Helper: Action Button Maker (for Terminate Script)
    local function createActionButton(parentPage: Frame, titleText: string, yPos: number, buttonColor: Color3, callback: () -> ())
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 36)
        btn.Position = UDim2.new(0, 0, 0, yPos)
        btn.BackgroundColor3 = buttonColor
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.Text = titleText
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.TextSize = 11
        btn.AutoButtonColor = false
        btn.Parent = parentPage

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 8)
        btnCorner.Parent = btn

        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = Color3.fromRGB(255, 255, 255)
        btnStroke.Transparency = 0.6
        btnStroke.Thickness = 1.5
        btnStroke.Parent = btn

        btn.MouseButton1Click:Connect(callback)
    end
    local function createColorSlider(parentPage: Frame, titleText: string, yPos: number, initialColor: Color3, onColorChanged: (Color3) -> ())
        local container = Instance.new("Frame")
        container.Size = UDim2.new(1, 0, 0, 44)
        container.Position = UDim2.new(0, 0, 0, yPos)
        container.BackgroundTransparency = 1
        container.Parent = parentPage

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.65, 0, 0, 14)
        label.Position = UDim2.new(0, 16, 0, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.Text = titleText
        label.TextColor3 = Color3.fromRGB(170, 185, 205)
        label.TextSize = 10
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = container

        local preview = Instance.new("Frame")
        preview.Size = UDim2.new(0, 14, 0, 14)
        preview.Position = UDim2.new(1, -18, 0, 0)
        preview.BackgroundColor3 = initialColor
        preview.BorderSizePixel = 0
        preview.Parent = container

        local prevCorner = Instance.new("UICorner")
        prevCorner.CornerRadius = UDim.new(1, 0)
        prevCorner.Parent = preview

        local track = Instance.new("TextButton")
        track.Name = "Track"
        track.Size = UDim2.new(1, -32, 0, 8)
        track.Position = UDim2.new(0, 16, 0, 20)
        track.Text = ""
        track.AutoButtonColor = false
        track.BorderSizePixel = 0
        track.BackgroundColor3 = Color3.new(1, 1, 1)
        track.Parent = container

        local trackCorner = Instance.new("UICorner")
        trackCorner.CornerRadius = UDim.new(1, 0)
        trackCorner.Parent = track

        local gradient = Instance.new("UIGradient")
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
            ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
            ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
            ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
            ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
            ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
            ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
        })
        gradient.Parent = track

        local knob = Instance.new("Frame")
        knob.Size = UDim2.new(0, 14, 0, 14)
        knob.AnchorPoint = Vector2.new(0.5, 0.5)
        local initialHue, _, _ = initialColor:ToHSV()
        knob.Position = UDim2.new(initialHue, 0, 0.5, 0)
        knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        knob.BorderSizePixel = 0
        knob.Parent = track

        local knobCorner = Instance.new("UICorner")
        knobCorner.CornerRadius = UDim.new(1, 0)
        knobCorner.Parent = knob

        local knobStroke = Instance.new("UIStroke")
        knobStroke.Color = Color3.fromRGB(20, 20, 20)
        knobStroke.Thickness = 1.5
        knobStroke.Parent = knob

        local isSliding = false
        local function updateColorFromInput(inputX: number)
            local relX = math.clamp((inputX - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
            knob.Position = UDim2.new(relX, 0, 0.5, 0)
            local newColor = Color3.fromHSV(relX, 0.85, 1)
            preview.BackgroundColor3 = newColor
            onColorChanged(newColor)
        end

        track.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isSliding = true
                updateColorFromInput(input.Position.X)
            end
        end)

        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isSliding = false
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if isSliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                updateColorFromInput(input.Position.X)
            end
        end)
    end

    -----------------------------------------------------------------
    -- Tab 1: Visuals Controls
    -----------------------------------------------------------------
    createToggleButton(tabPages["Visuals"], "Highlights", 4, Settings.HighlightsEnabled, function(enabled)
        Settings.HighlightsEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    createToggleButton(tabPages["Visuals"], "2D Box ESP", 38, Settings.BoxesEnabled, function(enabled)
        Settings.BoxesEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    createToggleButton(tabPages["Visuals"], "Compact Tags", 72, Settings.NametagsEnabled, function(enabled)
        Settings.NametagsEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    -----------------------------------------------------------------
    -- Tab 2: Colors Controls
    -----------------------------------------------------------------
    createColorSlider(tabPages["Colors"], "Target / Enemy Color", 10, Settings.EnemyColor, function(newColor)
        Settings.EnemyColor = newColor
        for player in pairs(trackedPlayers) do
            if not isTeammate(player) then updatePlayerVisuals(player) end
        end
    end)

    createColorSlider(tabPages["Colors"], "Teammate Color", 58, Settings.FriendlyColor, function(newColor)
        Settings.FriendlyColor = newColor
        for player in pairs(trackedPlayers) do
            if isTeammate(player) then updatePlayerVisuals(player) end
        end
    end)

    -----------------------------------------------------------------
    -- Tab 3: Misc Controls
    -----------------------------------------------------------------
    createToggleButton(tabPages["Misc"], "Team Check", 4, Settings.TeamCheckEnabled, function(enabled)
        Settings.TeamCheckEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    createToggleButton(tabPages["Misc"], "Team Color", 38, Settings.TeamColorEnabled, function(enabled)
        Settings.TeamColorEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    -----------------------------------------------------------------
    -- Tab 4: Settings Controls
    -----------------------------------------------------------------
    createKeybindButton(tabPages["Settings"], "Minimize Key", 4, Settings.ToggleKey, function(newKey)
        Settings.ToggleKey = newKey
        shortcutHint.Text = newKey.Name
    end)

    createActionButton(tabPages["Settings"], "Terminate Script", 42, Color3.fromRGB(180, 40, 40), function()
        isRunning = false
        for player in pairs(trackedPlayers) do
            cleanPlayer(player)
        end
        if screenGui then
            screenGui:Destroy()
        end
    end)

    -----------------------------------------------------------------
    -- Tab 3: Aim Assist Controls
    -----------------------------------------------------------------
    createToggleButton(tabPages["Aim Assist"], "Enable Aim Assist", 4, Settings.AimAssistEnabled, function(enabled)
        Settings.AimAssistEnabled = enabled
    end)

    createToggleButton(tabPages["Aim Assist"], "Show FOV Circle", 40, Settings.AimAssistFOVCircleEnabled, function(enabled)
        Settings.AimAssistFOVCircleEnabled = enabled
    end)

    createSlider(tabPages["Aim Assist"], "FOV Radius", 88, Settings.AimAssistFOV, 50, 300, "", function(value)
        Settings.AimAssistFOV = value
    end)

    createSlider(tabPages["Aim Assist"], "Smoothness", 136, math.floor(Settings.AimAssistSmoothness * 100), 1, 100, "%", function(value)
        Settings.AimAssistSmoothness = value / 100
    end)

    createBoneSelector(tabPages["Aim Assist"], "Target Bone", 184, Settings.AimAssistBone, {"Head", "Neck", "Chest"}, function(bone)
        Settings.AimAssistBone = bone
    end)

    createKeybindButton(tabPages["Aim Assist"], "Aim Key", 228, Settings.AimAssistKey, function(newKey)
        Settings.AimAssistKey = newKey
    end)

    -----------------------------------------------------------------
    -- Silent Aim Controls
    -----------------------------------------------------------------
    createToggleButton(tabPages["Aim Assist"], "Enable Silent Aim", 272, Settings.SilentAimEnabled, function(enabled)
        Settings.SilentAimEnabled = enabled
    end)

    createSlider(tabPages["Aim Assist"], "Silent FOV Radius", 320, Settings.SilentAimFOV, 50, 300, "", function(value)
        Settings.SilentAimFOV = value
    end)

    createSlider(tabPages["Aim Assist"], "Silent Smoothness", 368, math.floor(Settings.SilentAimSmoothness * 100), 1, 100, "%", function(value)
        Settings.SilentAimSmoothness = value / 100
    end)

    createBoneSelector(tabPages["Aim Assist"], "Silent Target Bone", 416, Settings.SilentAimBone, {"Head", "Neck", "Chest"}, function(bone)
        Settings.SilentAimBone = bone
    end)

    createKeybindButton(tabPages["Aim Assist"], "Silent Aim Key", 460, Settings.SilentAimKey, function(newKey)
        Settings.SilentAimKey = newKey
    end)

    local isDragging = false
    local dragStartPos = Vector2.zero
    local panelStartPos = UDim2.new()

    dragBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = true
            dragStartPos = Vector2.new(input.Position.X, input.Position.Y)
            panelStartPos = panel.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then isDragging = false end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStartPos
            local targetPos = UDim2.new(
                panelStartPos.X.Scale,
                panelStartPos.X.Offset + delta.X,
                panelStartPos.Y.Scale,
                panelStartPos.Y.Offset + delta.Y
            )
            TweenService:Create(panel, TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Position = targetPos }):Play()
        end
    end)

    -----------------------------------------------------------------
    -- Minimize / Restore Toggle
    -----------------------------------------------------------------
    local uiVisible = true
    local isAnimating = false
    local panelOriginalSize = panel.Size
    local panelOriginalTransparency = panel.BackgroundTransparency

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Settings.ToggleKey and not isAnimating then
            isAnimating = true
            uiVisible = not uiVisible

            if uiVisible then
                panel.Visible = true
                local openTween = TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    BackgroundTransparency = panelOriginalTransparency,
                    Size = panelOriginalSize
                })
                openTween:Play()
                openTween.Completed:Connect(function() isAnimating = false end)
            else
                local closeTween = TweenService:Create(panel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                    BackgroundTransparency = 1,
                    Size = UDim2.new(0, 0, 0, 40)
                })
                closeTween:Play()
                closeTween.Completed:Connect(function()
                    panel.Visible = false
                    isAnimating = false
                end)
            end
        end
    end)
end

---------------------------------------------------------------------
-- 5. Heartbeat 2D Box Projection & Distance Loop
---------------------------------------------------------------------
local lastWatchdogCheck = 0

local heartbeatConn
heartbeatConn = RunService.Heartbeat:Connect(function()
    if not isRunning then
        heartbeatConn:Disconnect()
        return
    end
    local now = os.clock()

    -- 1. Refresh local anchor
    if not localAnchor or not localAnchor.Parent or not localAnchor:IsDescendantOf(workspace) then
        refreshLocalAnchor()
    end

    -- 2. Periodic recovery check for late-spawning custom characters
    if now - lastWatchdogCheck > 0.4 then
        lastWatchdogCheck = now
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                local char = player.Character
                if isCharacterAlive(char) then
                    local data = trackedPlayers[player]
                    if not data or not data.Highlight or data.Highlight.Adornee ~= char or not data.TargetAnchor or not data.TargetAnchor.Parent then
                        setupCharacterDisplay(player, char :: Model)
                    end
                else
                    if trackedPlayers[player] then
                        cleanPlayer(player)
                    end
                end
            end
        end
    end

    -- 3. Live 2D Box projection & distance tags
    for player, data in pairs(trackedPlayers) do
        local teammate = isTeammate(player)
        local isAllowed = Settings.BoxesEnabled and (not Settings.TeamCheckEnabled or Settings.TeamColorEnabled or not teammate)

        -- Check if character is alive (instant check)
        local charAlive = false
        if data.CharModel and data.CharModel.Parent then
            local humanoid = data.CharModel:FindFirstChildOfClass("Humanoid") or data.CharModel:FindFirstChildWhichIsA("Humanoid", true)
            if humanoid then
                charAlive = humanoid.Health > 0
            end
        end

        if data.Box2D and isAllowed and charAlive then
            local cf, sz = getCustomBoundingBox(data.CharModel)
            local half = sz * 0.5

            -- 8 bounding box corners in world space
            local corners = {
                cf:PointToWorldSpace(Vector3.new(-half.X,  half.Y, -half.Z)),
                cf:PointToWorldSpace(Vector3.new( half.X,  half.Y, -half.Z)),
                cf:PointToWorldSpace(Vector3.new(-half.X, -half.Y, -half.Z)),
                cf:PointToWorldSpace(Vector3.new( half.X, -half.Y, -half.Z)),
                cf:PointToWorldSpace(Vector3.new(-half.X,  half.Y,  half.Z)),
                cf:PointToWorldSpace(Vector3.new( half.X,  half.Y,  half.Z)),
                cf:PointToWorldSpace(Vector3.new(-half.X, -half.Y,  half.Z)),
                cf:PointToWorldSpace(Vector3.new( half.X, -half.Y,  half.Z)),
            }

            local minX, minY = math.huge, math.huge
            local maxX, maxY = -math.huge, -math.huge
            local anyOnScreen = false

            for _, corner in ipairs(corners) do
                local screenPos, onScreen = Camera:WorldToViewportPoint(corner)
                if screenPos.Z > 0 then
                    anyOnScreen = true
                    if screenPos.X < minX then minX = screenPos.X end
                    if screenPos.X > maxX then maxX = screenPos.X end
                    if screenPos.Y < minY then minY = screenPos.Y end
                    if screenPos.Y > maxY then maxY = screenPos.Y end
                end
            end

            if anyOnScreen and minX < math.huge then
                data.Box2D.Visible = true
                data.Box2D.Position = UDim2.new(0, minX, 0, minY)
                data.Box2D.Size = UDim2.new(0, math.max(6, maxX - minX), 0, math.max(6, maxY - minY))
            else
                data.Box2D.Visible = false
            end
        elseif data.Box2D then
            data.Box2D.Visible = false
        end

        -- Update compact distance tags
        if data.Label and data.TargetAnchor and data.TargetAnchor.Parent then
            if localAnchor and localAnchor.Parent then
                local dist = (localAnchor.Position - data.TargetAnchor.Position).Magnitude
                data.Label.Text = string.format("%s • %dm", player.DisplayName, math.floor(dist))
            else
                data.Label.Text = string.format("%s • --", player.DisplayName)
            end
        end
    end

    -- 4. Aim Assist System
    if Settings.AimAssistEnabled then
        local isAimKeyDown = UserInputService:IsKeyDown(Settings.AimAssistKey)

        if isAimKeyDown then
            local closestTarget = nil
            local closestDistance = math.huge

            for player, data in pairs(trackedPlayers) do
                local teammate = isTeammate(player)
                local isAllowed = Settings.TeamCheckEnabled and not Settings.TeamColorEnabled and teammate
                if isAllowed then continue end

                if data.CharModel and data.CharModel.Parent then
                    local targetPart: BasePart?
                    local boneName = Settings.AimAssistBone

                    -- Custom character model support: try multiple bone names
                    if boneName == "Head" then
                        targetPart = data.CharModel:FindFirstChild("Head") or data.CharModel:FindFirstChild("Head1") or data.CharModel:FindFirstChild("Head2")
                    elseif boneName == "Neck" then
                        targetPart = data.CharModel:FindFirstChild("Neck") or data.CharModel:FindFirstChild("UpperTorso") or data.CharModel:FindFirstChild("Chest")
                    elseif boneName == "Chest" then
                        targetPart = data.CharModel:FindFirstChild("UpperTorso") or data.CharModel:FindFirstChild("Torso") or data.CharModel:FindFirstChild("Chest") or data.CharModel:FindFirstChild("HumanoidRootPart")
                    end

                    -- Fallback: use TargetAnchor if no bone found
                    if not targetPart and data.TargetAnchor and data.TargetAnchor.Parent then
                        targetPart = data.TargetAnchor
                    end

                    if targetPart and targetPart:IsA("BasePart") then
                        local screenPos, onScreen = Camera:WorldToViewportPoint(targetPart.Position)
                        if onScreen then
                            local centerX, centerY = Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2
                            local dx = screenPos.X - centerX
                            local dy = screenPos.Y - centerY
                            local distance = math.sqrt(dx * dx + dy * dy)

                            if distance < Settings.AimAssistFOV and distance < closestDistance then
                                closestDistance = distance
                                closestTarget = targetPart
                            end
                        end
                    end
                end
            end

            if closestTarget then
                local targetCFrame = closestTarget.CFrame
                local aimDelta = (targetCFrame * CFrame.new(0, 0, -10) - Camera.CFrame.p).Unit * Settings.AimAssistSmoothness

                UserInputService.SendMouseMovement(
                    math.floor(aimDelta.X * 100),
                    math.floor(aimDelta.Y * 100)
                )
            end
        end

        -- Update FOV Circle (always visible when FOV circle toggle is enabled)
        if Settings.AimAssistFOVCircleEnabled then
            fovCircle.Visible = true
            fovCircle.Size = UDim2.new(0, Settings.AimAssistFOV * 2, 0, Settings.AimAssistFOV * 2)
            fovCircle.BackgroundTransparency = isAimKeyDown and 0.5 or 0.8
            fovCircle.BorderSizePixel = isAimKeyDown and 3 or 2
            fovCircle.BorderColor3 = isAimKeyDown and Color3.fromRGB(0, 255, 100) or Color3.fromRGB(0, 190, 255)
        else
            fovCircle.Visible = false
        end
    else
        fovCircle.Visible = false
    end

    -- 5. Silent Aim System
    if Settings.SilentAimEnabled then
        local isSilentAimKeyDown = UserInputService:IsKeyDown(Settings.SilentAimKey)

        if isSilentAimKeyDown and UserInputService:IsMouseButton1Down() then
            local closestTarget = nil
            local closestDistance = math.huge

            for player, data in pairs(trackedPlayers) do
                local teammate = isTeammate(player)
                local isAllowed = Settings.TeamCheckEnabled and not Settings.TeamColorEnabled and teammate
                if isAllowed then continue end

                if data.CharModel and data.CharModel.Parent then
                    local targetPart: BasePart?
                    local boneName = Settings.SilentAimBone

                    if boneName == "Head" then
                        targetPart = data.CharModel:FindFirstChild("Head")
                    elseif boneName == "Neck" then
                        targetPart = data.CharModel:FindFirstChild("Neck") or data.CharModel:FindFirstChild("UpperTorso")
                    elseif boneName == "Chest" then
                        targetPart = data.CharModel:FindFirstChild("UpperTorso") or data.CharModel:FindFirstChild("Torso") or data.CharModel:FindFirstChild("HumanoidRootPart")
                    end

                    if targetPart and targetPart:IsA("BasePart") then
                        local screenPos, onScreen = Camera:WorldToViewportPoint(targetPart.Position)
                        if onScreen then
                            local centerX, centerY = Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2
                            local dx = screenPos.X - centerX
                            local dy = screenPos.Y - centerY
                            local distance = math.sqrt(dx * dx + dy * dy)

                            if distance < Settings.SilentAimFOV and distance < closestDistance then
                                closestDistance = distance
                                closestTarget = targetPart
                            end
                        end
                    end
                end
            end

            if closestTarget then
                local weapon = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
                if weapon and weapon:IsA("Tool") then
                    -- Get weapon handle position
                    local handle = weapon:FindFirstChild("Handle")
                    local weaponPosition = handle and handle.Position or Camera.CFrame.p

                    -- Calculate direction to target
                    local targetPosition = closestTarget.Position
                    local direction = (targetPosition - weaponPosition).Unit

                    -- Modify mouse location for games that use it
                    local mouse = LocalPlayer:GetMouse()
                    mouse.X = Camera.ViewportSize.X / 2
                    mouse.Y = Camera.ViewportSize.Y / 2

                    -- Set weapon attribute if it exists
                    if weapon:GetAttribute("MouseLocation") then
                        weapon:SetAttribute("MouseLocation", targetPosition)
                    end

                    -- Set local player attribute if it exists
                    if LocalPlayer.Character:GetAttribute("MouseLocation") then
                        LocalPlayer.Character:SetAttribute("MouseLocation", targetPosition)
                    end

                    -- Modify weapon firing if it has a fire event
                    if weapon.FireServer then
                        -- Hook the fire event to redirect bullets
                        local originalFireServer = weapon.FireServer
                        -- This is a placeholder - actual implementation depends on the game
                    end
                end
            end
        end
    end
end)

---------------------------------------------------------------------
-- 6. Player Lifecycle Listeners
---------------------------------------------------------------------
local function hookPlayer(player: Player)
    if player == LocalPlayer then return end

    player.CharacterAdded:Connect(function(char)
        cleanPlayer(player)
        setupCharacterDisplay(player, char)
    end)

    player.CharacterRemoving:Connect(function()
        cleanPlayer(player)
    end)

    player:GetPropertyChangedSignal("Team"):Connect(function()
        updatePlayerVisuals(player)
    end)

    if player.Character and isCharacterAlive(player.Character) then
        setupCharacterDisplay(player, player.Character)
    end
end

for _, player in ipairs(Players:GetPlayers()) do
    hookPlayer(player)
end

Players.PlayerAdded:Connect(hookPlayer)
Players.PlayerRemoving:Connect(cleanPlayer)

LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
    for player in pairs(trackedPlayers) do
        updatePlayerVisuals(player)
    end
end)

-- Initialize Modern Tabbed UI
buildModernUI()
end
