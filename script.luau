--!strict
-- Place this LocalScript in StarterPlayer.StarterPlayerScripts

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
    ShowTeammates = true,
    EnemyColor = Color3.fromRGB(255, 65, 65),
    FriendlyColor = Color3.fromRGB(0, 180, 255),
    OutlineColor = Color3.fromRGB(255, 255, 255),
    FillTransparency = 0.55,
    OutlineTransparency = 0.1,
    ToggleKey = Enum.KeyCode.RightShift,
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

local espHolder = Camera:FindFirstChild("ESPHolder") :: Folder?
if not espHolder then
    espHolder = Instance.new("Folder")
    espHolder.Name = "ESPHolder"
    espHolder.Parent = Camera
end

---------------------------------------------------------------------
-- 1. Custom Character Compatibility Resolvers
---------------------------------------------------------------------
local function isTeammate(player: Player): boolean
    if not Settings.TeamCheckEnabled then return false end
    if #Teams:GetTeams() == 0 then return false end
    return player.Team ~= nil and player.Team == LocalPlayer.Team
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
    local activeColor = teammate and Settings.FriendlyColor or Settings.EnemyColor
    
    local isVisible = true
    if Settings.TeamCheckEnabled and teammate and not Settings.ShowTeammates then
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
    local initialColor = teammate and Settings.FriendlyColor or Settings.EnemyColor
    local isVisible = true
    if Settings.TeamCheckEnabled and teammate and not Settings.ShowTeammates then
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
    highlight.Parent = espHolder

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
    panel.Size = UDim2.new(0, 240, 0, 260)
    panel.Position = UDim2.new(0, 28, 0.5, -130)
    panel.BackgroundColor3 = Color3.fromRGB(14, 16, 20)
    panel.BackgroundTransparency = 0.12
    panel.BorderSizePixel = 0
    panel.Active = true
    panel.ClipsDescendants = true
    panel.Parent = screenGui

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 10)
    panelCorner.Parent = panel

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(42, 52, 68)
    panelStroke.Thickness = 1.2
    panelStroke.Transparency = 0.2
    panelStroke.Parent = panel

    -- Header / Drag Bar
    local dragBar = Instance.new("Frame")
    dragBar.Name = "DragBar"
    dragBar.Size = UDim2.new(1, 0, 0, 34)
    dragBar.BackgroundTransparency = 1
    dragBar.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -64, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = "TACTICAL RADAR"
    title.TextColor3 = Color3.fromRGB(185, 210, 240)
    title.TextSize = 11
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = dragBar

    local shortcutHint = Instance.new("TextLabel")
    shortcutHint.Size = UDim2.new(0, 48, 0, 16)
    shortcutHint.Position = UDim2.new(1, -58, 0.5, -8)
    shortcutHint.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
    shortcutHint.BorderSizePixel = 0
    shortcutHint.Font = Enum.Font.GothamBold
    shortcutHint.Text = "R-SHIFT"
    shortcutHint.TextColor3 = Color3.fromRGB(120, 135, 160)
    shortcutHint.TextSize = 8
    shortcutHint.Parent = dragBar

    local hintCorner = Instance.new("UICorner")
    hintCorner.CornerRadius = UDim.new(0, 4)
    hintCorner.Parent = shortcutHint

    -- Tabs Navigation Bar
    local navBar = Instance.new("Frame")
    navBar.Name = "NavBar"
    navBar.Size = UDim2.new(1, -20, 0, 26)
    navBar.Position = UDim2.new(0, 10, 0, 36)
    navBar.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
    navBar.BorderSizePixel = 0
    navBar.Parent = panel

    local navCorner = Instance.new("UICorner")
    navCorner.CornerRadius = UDim.new(0, 6)
    navCorner.Parent = navBar

    local tabButtons: { [string]: TextButton } = {}
    local tabPages: { [string]: Frame } = {}

    local tabNames = { "Visuals", "Colors", "Misc" }
    local activeTab = "Visuals"

    for i, tabName in ipairs(tabNames) do
        local page = Instance.new("Frame")
        page.Name = tabName .. "_Page"
        page.Size = UDim2.new(1, -20, 1, -74)
        page.Position = UDim2.new(0, 10, 0, 68)
        page.BackgroundTransparency = 1
        page.Visible = (tabName == activeTab)
        page.Parent = panel
        tabPages[tabName] = page

        local btn = Instance.new("TextButton")
        btn.Name = tabName .. "_TabBtn"
        btn.Size = UDim2.new(1 / #tabNames, 0, 1, 0)
        btn.Position = UDim2.new((i - 1) / #tabNames, 0, 0, 0)
        btn.BackgroundTransparency = (tabName == activeTab) and 0 or 1
        btn.BackgroundColor3 = Color3.fromRGB(30, 42, 58)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold
        btn.Text = tabName
        btn.TextColor3 = (tabName == activeTab) and Color3.fromRGB(0, 190, 255) or Color3.fromRGB(130, 140, 155)
        btn.TextSize = 10
        btn.Parent = navBar

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 5)
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
                b.TextColor3 = selected and Color3.fromRGB(0, 190, 255) or Color3.fromRGB(130, 140, 155)
            end
        end)
    end

    -- Helper: Toggle Button Maker
    local function createToggleButton(parentPage: Frame, name: string, yPos: number, initialState: boolean, callback: (boolean) -> ())
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Size = UDim2.new(1, 0, 0, 28)
        btn.Position = UDim2.new(0, 0, 0, yPos)
        btn.BackgroundColor3 = initialState and Color3.fromRGB(22, 38, 54) or Color3.fromRGB(22, 25, 32)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamMedium
        btn.Text = ""
        btn.AutoButtonColor = false
        btn.Parent = parentPage

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 6)
        btnCorner.Parent = btn

        local btnStroke = Instance.new("UIStroke")
        btnStroke.Color = initialState and Color3.fromRGB(0, 160, 255) or Color3.fromRGB(45, 50, 60)
        btnStroke.Thickness = 1
        btnStroke.Parent = btn

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.65, 0, 1, 0)
        label.Position = UDim2.new(0, 10, 0, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.Text = name
        label.TextColor3 = Color3.fromRGB(215, 220, 230)
        label.TextSize = 10
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = btn

        local status = Instance.new("TextLabel")
        status.Size = UDim2.new(0.3, -10, 1, 0)
        status.Position = UDim2.new(0.7, 0, 0, 0)
        status.BackgroundTransparency = 1
        status.Font = Enum.Font.GothamBold
        status.Text = initialState and "ON" or "OFF"
        status.TextColor3 = initialState and Color3.fromRGB(0, 190, 255) or Color3.fromRGB(120, 125, 135)
        status.TextSize = 9
        status.TextXAlignment = Enum.TextXAlignment.Right
        status.Parent = btn

        local state = initialState
        btn.MouseButton1Click:Connect(function()
            state = not state
            callback(state)

            local targetBg = state and Color3.fromRGB(22, 38, 54) or Color3.fromRGB(22, 25, 32)
            local targetStroke = state and Color3.fromRGB(0, 160, 255) or Color3.fromRGB(45, 50, 60)
            local targetText = state and Color3.fromRGB(0, 190, 255) or Color3.fromRGB(120, 125, 135)

            TweenService:Create(btn, TweenInfo.new(0.2), { BackgroundColor3 = targetBg }):Play()
            TweenService:Create(btnStroke, TweenInfo.new(0.2), { Color = targetStroke }):Play()
            status.Text = state and "ON" or "OFF"
            status.TextColor3 = targetText
        end)
    end

    -- Helper: Smooth Color Slider Maker
    local function createColorSlider(parentPage: Frame, titleText: string, yPos: number, initialColor: Color3, onColorChanged: (Color3) -> ())
        local container = Instance.new("Frame")
        container.Size = UDim2.new(1, 0, 0, 36)
        container.Position = UDim2.new(0, 0, 0, yPos)
        container.BackgroundTransparency = 1
        container.Parent = parentPage

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.7, 0, 0, 12)
        label.Position = UDim2.new(0, 0, 0, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.Text = titleText
        label.TextColor3 = Color3.fromRGB(160, 175, 195)
        label.TextSize = 9
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = container

        local preview = Instance.new("Frame")
        preview.Size = UDim2.new(0, 12, 0, 12)
        preview.Position = UDim2.new(1, -12, 0, 0)
        preview.BackgroundColor3 = initialColor
        preview.BorderSizePixel = 0
        preview.Parent = container

        local prevCorner = Instance.new("UICorner")
        prevCorner.CornerRadius = UDim.new(1, 0)
        prevCorner.Parent = preview

        local track = Instance.new("TextButton")
        track.Name = "Track"
        track.Size = UDim2.new(1, 0, 0, 8)
        track.Position = UDim2.new(0, 0, 0, 20)
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
        knob.Size = UDim2.new(0, 12, 0, 12)
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
        knobStroke.Thickness = 1.2
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

    createToggleButton(tabPages["Misc"], "Show Teammates", 38, Settings.ShowTeammates, function(enabled)
        Settings.ShowTeammates = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    -----------------------------------------------------------------
    -- Draggable Panel
    -----------------------------------------------------------------
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
    -- Right-Shift Minimize / Restore Toggle
    -----------------------------------------------------------------
    local uiVisible = true
    local isAnimating = false

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Settings.ToggleKey and not isAnimating then
            isAnimating = true
            uiVisible = not uiVisible

            if uiVisible then
                panel.Visible = true
                local openTween = TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    BackgroundTransparency = 0.12,
                    Size = UDim2.new(0, 240, 0, 260)
                })
                openTween:Play()
                openTween.Completed:Connect(function() isAnimating = false end)
            else
                local closeTween = TweenService:Create(panel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                    BackgroundTransparency = 1,
                    Size = UDim2.new(0, 240, 0, 0)
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

RunService.Heartbeat:Connect(function()
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
        local isAllowed = Settings.BoxesEnabled and (not Settings.TeamCheckEnabled or Settings.ShowTeammates or not teammate)

        if data.Box2D and isAllowed and data.CharModel and data.CharModel.Parent then
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
