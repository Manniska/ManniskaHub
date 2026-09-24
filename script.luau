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
    BoxesEnabled = true,
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
    Box: SelectionBox?,
    BoxAdorneePart: BasePart?,
    Tag: BillboardGui?,
    Label: TextLabel?,
    TargetAnchor: BasePart?,
    CharModel: Model?,
    DeathConn: RBXScriptConnection?,
}

local trackedPlayers: { [Player]: TrackedData } = {}
local localAnchor: BasePart? = nil

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

-- Works for custom models WITHOUT a Humanoid (monsters, custom rigs, machines)
local function isCharacterAlive(character: Model?): boolean
    if not character or not character.Parent or not character:IsDescendantOf(workspace) then
        return false
    end
    -- Check if Humanoid exists; if it does NOT, we verify the model has live physical parts
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid and humanoid.Health <= 0 then
        return false
    end
    return true
end

-- Deep search for anchor BasePart across custom nested folders/submodels
local function getModelAnchor(character: Model?): BasePart?
    if not character or not character.Parent then return nil end
    if character.PrimaryPart and character.PrimaryPart:IsDescendantOf(workspace) then
        return character.PrimaryPart
    end

    -- Priority names for custom rigs
    local commonNames = { "HumanoidRootPart", "Root", "Torso", "UpperTorso", "Core", "Chest", "Main", "Head" }
    for _, name in ipairs(commonNames) do
        local part = character:FindFirstChild(name, true)
        if part and part:IsA("BasePart") and part:IsDescendantOf(workspace) then
            return part
        end
    end

    -- Fallback: Largest BasePart in the hierarchy
    local largestPart: BasePart? = nil
    local largestVolume = 0
    for _, desc in ipairs(character:GetDescendants()) do
        if desc:IsA("BasePart") and desc:IsDescendantOf(workspace) and desc.Transparency < 1 then
            local vol = desc.Size.X * desc.Size.Y * desc.Size.Z
            if vol > largestVolume then
                largestVolume = vol
                largestPart = desc
            end
        end
    end

    return largestPart or character:FindFirstChildWhichIsA("BasePart", true)
end

-- Custom Bounding Box calculator fallback (safe against non-standard/skinned custom models)
local function getCustomBoundingBox(character: Model): (CFrame, Vector3)
    local ok, cf, sz = pcall(function()
        return character:GetBoundingBox()
    end)
    if ok and cf and sz and sz.Magnitude > 0 then
        return cf, sz
    end

    -- Manual fallback if engine BoundingBox fails on custom mesh rigs
    local anchor = getModelAnchor(character)
    if anchor then
        return anchor.CFrame, anchor.Size + Vector3.new(2, 3, 2)
    end
    return CFrame.new(), Vector3.new(4, 5, 4)
end

---------------------------------------------------------------------
-- 2. Visual Effects Management
---------------------------------------------------------------------
local function cleanPlayer(player: Player)
    local data = trackedPlayers[player]
    if data then
        if data.DeathConn then
            data.DeathConn:Disconnect()
            data.DeathConn = nil
        end
        if data.Highlight then data.Highlight:Destroy() end
        if data.Box then data.Box:Destroy() end
        if data.BoxAdorneePart then data.BoxAdorneePart:Destroy() end
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

    if data.Box then
        data.Box.Visible = Settings.BoxesEnabled and isVisible
        data.Box.Color3 = activeColor
        data.Box.SurfaceColor3 = activeColor
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

    -- Wait asynchronously for custom mesh/rig parts to replicate
    local anchor: BasePart? = nil
    local tries = 0
    while tries < 40 do
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

    -- 1. Native Highlight
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

    -- 2. Box ESP (Works with custom sizes)
    local cf, sz = getCustomBoundingBox(character)
    local boxPart = Instance.new("Part")
    boxPart.Name = "BoxPart_" .. player.Name
    boxPart.Transparency = 1
    boxPart.CanCollide = false
    boxPart.CanTouch = false
    boxPart.CanQuery = false
    boxPart.Anchored = true
    boxPart.Size = sz
    boxPart.CFrame = cf
    boxPart.Parent = espHolder

    local selectionBox = Instance.new("SelectionBox")
    selectionBox.Name = "Box_" .. player.Name
    selectionBox.Adornee = boxPart
    selectionBox.Color3 = initialColor
    selectionBox.LineThickness = 0.03
    selectionBox.SurfaceTransparency = 0.88
    selectionBox.SurfaceColor3 = initialColor
    selectionBox.Visible = Settings.BoxesEnabled and isVisible
    selectionBox.Parent = espHolder

    -- 3. Compact Name & Distance Pill
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "Tag_" .. player.Name
    billboard.Adornee = anchor
    billboard.Size = UDim2.new(0, 95, 0, 18)
    billboard.StudsOffset = Vector3.new(0, (sz.Y * 0.5) + 1.2, 0) -- Dynamically placed above custom heights
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

    -- Death & Cleanup hooks
    local deathConn: RBXScriptConnection? = nil
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        deathConn = humanoid.Died:Connect(function()
            cleanPlayer(player)
        end)
    end

    character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            cleanPlayer(player)
        end
    end)

    trackedPlayers[player] = {
        Highlight = highlight,
        Box = selectionBox,
        BoxAdorneePart = boxPart,
        Tag = billboard,
        Label = compactLabel,
        TargetAnchor = anchor,
        CharModel = character,
        DeathConn = deathConn,
    }
end

---------------------------------------------------------------------
-- 3. Local Player Anchor (Sync on custom death/respawn)
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
-- 4. Sleek Draggable HUD Controller
---------------------------------------------------------------------
local function buildModernUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TacticalRadarHUD"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = PlayerGui

    local panel = Instance.new("Frame")
    panel.Name = "ControlPanel"
    panel.Size = UDim2.new(0, 220, 0, 320)
    panel.Position = UDim2.new(0, 24, 0.5, -160)
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
    panelStroke.Color = Color3.fromRGB(40, 50, 65)
    panelStroke.Thickness = 1.2
    panelStroke.Transparency = 0.2
    panelStroke.Parent = panel

    local dragBar = Instance.new("Frame")
    dragBar.Name = "DragBar"
    dragBar.Size = UDim2.new(1, 0, 0, 34)
    dragBar.BackgroundTransparency = 1
    dragBar.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -60, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = "TACTICAL RADAR"
    title.TextColor3 = Color3.fromRGB(180, 205, 235)
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

    local function createToggleButton(name: string, yPos: number, initialState: boolean, callback: (boolean) -> ())
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Size = UDim2.new(1, -20, 0, 26)
        btn.Position = UDim2.new(0, 10, 0, yPos)
        btn.BackgroundColor3 = initialState and Color3.fromRGB(22, 38, 54) or Color3.fromRGB(22, 25, 32)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamMedium
        btn.Text = ""
        btn.AutoButtonColor = false
        btn.Parent = panel

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

    local function createColorSlider(titleText: string, yPos: number, initialColor: Color3, onColorChanged: (Color3) -> ())
        local container = Instance.new("Frame")
        container.Size = UDim2.new(1, -20, 0, 32)
        container.Position = UDim2.new(0, 10, 0, yPos)
        container.BackgroundTransparency = 1
        container.Parent = panel

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
        preview.Size = UDim2.new(0, 10, 0, 10)
        preview.Position = UDim2.new(1, -10, 0, 1)
        preview.BackgroundColor3 = initialColor
        preview.BorderSizePixel = 0
        preview.Parent = container

        local prevCorner = Instance.new("UICorner")
        prevCorner.CornerRadius = UDim.new(1, 0)
        prevCorner.Parent = preview

        local track = Instance.new("TextButton")
        track.Name = "Track"
        track.Size = UDim2.new(1, 0, 0, 8)
        track.Position = UDim2.new(0, 0, 0, 18)
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

    -- Toggle Buttons Layout
    createToggleButton("Highlights", 38, Settings.HighlightsEnabled, function(enabled)
        Settings.HighlightsEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    createToggleButton("Box ESP", 68, Settings.BoxesEnabled, function(enabled)
        Settings.BoxesEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    createToggleButton("Compact Tags", 98, Settings.NametagsEnabled, function(enabled)
        Settings.NametagsEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    createToggleButton("Team Check", 128, Settings.TeamCheckEnabled, function(enabled)
        Settings.TeamCheckEnabled = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    createToggleButton("Show Teammates", 158, Settings.ShowTeammates, function(enabled)
        Settings.ShowTeammates = enabled
        for player in pairs(trackedPlayers) do updatePlayerVisuals(player) end
    end)

    -- Color Sliders
    createColorSlider("Target / Enemy Color", 196, Settings.EnemyColor, function(newColor)
        Settings.EnemyColor = newColor
        for player in pairs(trackedPlayers) do
            if not isTeammate(player) then updatePlayerVisuals(player) end
        end
    end)

    createColorSlider("Teammate Color", 238, Settings.FriendlyColor, function(newColor)
        Settings.FriendlyColor = newColor
        for player in pairs(trackedPlayers) do
            if isTeammate(player) then updatePlayerVisuals(player) end
        end
    end)

    -- Draggable Header Logic
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

    -- Right Shift Toggle Animation
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
                    Size = UDim2.new(0, 220, 0, 320)
                })
                openTween:Play()
                openTween.Completed:Connect(function() isAnimating = false end)
            else
                local closeTween = TweenService:Create(panel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                    BackgroundTransparency = 1,
                    Size = UDim2.new(0, 220, 0, 0)
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
-- 5. Heartbeat Watchdog, Box CFrame & Distance Loop
---------------------------------------------------------------------
local lastWatchdogCheck = 0

RunService.Heartbeat:Connect(function()
    local now = os.clock()

    -- 1. Refresh local player anchor if missing or destroyed
    if not localAnchor or not localAnchor.Parent or not localAnchor:IsDescendantOf(workspace) then
        refreshLocalAnchor()
    end

    -- 2. Periodic recovery check: handles late custom model replication
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

    -- 3. Live 3D Box CFrame sync & distance tag formatting
    for player, data in pairs(trackedPlayers) do
        if data.CharModel and data.CharModel.Parent and data.BoxAdorneePart then
            local cf, sz = getCustomBoundingBox(data.CharModel)
            data.BoxAdorneePart.CFrame = cf
            data.BoxAdorneePart.Size = sz
        end

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

-- Initialize HUD
buildModernUI()
