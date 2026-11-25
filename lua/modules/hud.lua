--!nocheck
--[[
    MAFIA - compact status HUD (read-only)

    Bottom-left strip: role + faction, phase, players remaining and corruption.
    Reads _G.__mafiaState; makes no remote calls.

    API: _G.__mafiaHUD
        .Set(bool)
        .Enabled()
        .Toggle()
        .Stop()
]]

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaHUD
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local FACTION_COLORS = {
    Town = Color3.fromRGB(92, 176, 255),
    Mafia = Color3.fromRGB(235, 92, 104),
    Veil = Color3.fromRGB(178, 126, 245),
    Neutral = Color3.fromRGB(240, 190, 92),
    Unknown = Color3.fromRGB(150, 150, 165),
}

local enabled = true
local running = true

local pg = lp and lp:FindFirstChild("PlayerGui")
if pg then
    for _, child in ipairs(pg:GetChildren()) do
        if child.Name == "MafiaHUD" then
            pcall(function() child:Destroy() end)
        end
    end
end
local gui = Instance.new("ScreenGui")
gui.Name = "MafiaHUD"
gui.DisplayOrder = 35
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = pg

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0, 1)
panel.Position = UDim2.new(0, 16, 1, -16)
panel.Size = UDim2.fromOffset(280, 62)
panel.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(52, 52, 66)
stroke.Transparency = 0.25
stroke.Thickness = 1
stroke.Parent = panel

local accent = Instance.new("Frame")
accent.Name = "Accent"
accent.Position = UDim2.new(0, 0, 0, 10)
accent.Size = UDim2.new(0, 2, 1, -20)
accent.BackgroundColor3 = FACTION_COLORS.Unknown
accent.BorderSizePixel = 0
accent.Parent = panel

local roleLabel = Instance.new("TextLabel")
roleLabel.Name = "Role"
roleLabel.BackgroundTransparency = 1
roleLabel.Position = UDim2.new(0, 12, 0, 7)
roleLabel.Size = UDim2.new(1, -24, 0, 18)
roleLabel.Font = Enum.Font.GothamBold
roleLabel.TextSize = 14
roleLabel.TextXAlignment = Enum.TextXAlignment.Left
roleLabel.TextTruncate = Enum.TextTruncate.AtEnd
roleLabel.TextColor3 = Color3.fromRGB(238, 238, 245)
roleLabel.Text = "MAFIA // waiting for role"
roleLabel.Parent = panel

local phaseLabel = Instance.new("TextLabel")
phaseLabel.Name = "Phase"
phaseLabel.BackgroundTransparency = 1
phaseLabel.Position = UDim2.new(0, 12, 0, 25)
phaseLabel.Size = UDim2.new(1, -24, 0, 15)
phaseLabel.Font = Enum.Font.GothamMedium
phaseLabel.TextSize = 10
phaseLabel.TextXAlignment = Enum.TextXAlignment.Left
phaseLabel.TextTruncate = Enum.TextTruncate.AtEnd
phaseLabel.TextColor3 = Color3.fromRGB(170, 170, 185)
phaseLabel.Text = "lobby"
phaseLabel.Parent = panel

local infoLabel = Instance.new("TextLabel")
infoLabel.Name = "Info"
infoLabel.BackgroundTransparency = 1
infoLabel.Position = UDim2.new(0, 12, 0, 41)
infoLabel.Size = UDim2.new(1, -24, 0, 14)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 10
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.TextTruncate = Enum.TextTruncate.AtEnd
infoLabel.TextColor3 = Color3.fromRGB(120, 120, 138)
infoLabel.Text = "read-only"
infoLabel.Parent = panel

local function refresh()
    local state = _G.__mafiaState
    if not state then
        roleLabel.Text = "MAFIA // state module missing"
        phaseLabel.Text = "reload the suite"
        infoLabel.Text = "no remotes fired"
        return
    end

    local s = state.Snapshot()
    local color = FACTION_COLORS[s.faction] or FACTION_COLORS.Unknown

    if s.role then
        roleLabel.Text = string.upper(s.role) .. "  ·  " .. string.upper(s.faction)
        roleLabel.TextColor3 = color
        accent.BackgroundColor3 = color
    else
        roleLabel.Text = "MAFIA // no role yet"
        roleLabel.TextColor3 = Color3.fromRGB(238, 238, 245)
        accent.BackgroundColor3 = FACTION_COLORS.Unknown
    end

    local flow = _G.__mafiaFlowLog
    local phase = (flow and flow.Phase()) or s.phase or (s.inRound and "unknown phase" or "lobby")
    if s.dead then phase = "DEAD  ·  " .. phase end
    if s.transition then phase = "TRANSITION  ·  " .. phase end
    phaseLabel.Text = string.upper(phase)

    local parts = { string.format("%d alive", s.playersLeft or s.alive or 0) }
    local day = flow and flow.Day()
    if day then
        parts[#parts + 1] = "day " .. tostring(day)
    end
    if s.role == "Harbinger" and s.powerState then
        parts[#parts + 1] = "power " .. s.powerState
    end
    if s.voteTarget then
        parts[#parts + 1] = "vote " .. s.voteTarget
    end
    if s.corruption ~= nil then
        parts[#parts + 1] = string.format("corruption %d%%", s.corruption)
    end
    if s.total and s.total > 0 then
        parts[#parts + 1] = string.format("%d in server", s.total)
    end
    infoLabel.Text = table.concat(parts, "  ·  ")
end

function API.Enabled()
    return enabled
end

function API.Set(on)
    enabled = on == true
    gui.Enabled = enabled
    return true
end

function API.Toggle()
    return API.Set(not enabled)
end

function API.Stop()
    if _G.__mafiaHUD ~= API then return end
    running = false
    if gui then gui:Destroy() end
    _G.__mafiaHUD = nil
end

_G.__mafiaHUD = API

task.spawn(function()
    while running do
        pcall(refresh)
        task.wait(0.5)
    end
end)

print("[MAFIA-HUD] loaded - " .. (enabled and "on" or "off"))
