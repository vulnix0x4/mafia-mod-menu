--!nocheck
--[[
    MAFIA - player ESP (read-only)

    Draws a local-only BillboardGui above every living player, using the
    disguise name the game already replicates. No remotes, no character edits,
    no server calls.

    API: _G.__mafiaESP
        .Set(bool)
        .Enabled()
        .Toggle()
        .SetOption(key, value)
        .Options() -> table copy
        .Count()   -> visible tag count
        .RefreshTeam() -> no-argument team self-query
        .IsTeammate(player)
        .Stop()
]]

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaESP
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local DEFAULTS = {
    enabled = true,
    showNames = true,
    showDistance = true,
    showHealth = true,
    showHighlight = true,
    showDead = false,
    showRoles = true,
    showForensics = true,
    maxDistance = 500,
    autoTeamScan = true,
}

local CONFIG = {}
for k, v in pairs(DEFAULTS) do CONFIG[k] = v end

local COLORS = {
    alive = Color3.fromRGB(140, 228, 172),
    downed = Color3.fromRGB(255, 186, 92),
    dead = Color3.fromRGB(232, 98, 112),
    suspect = Color3.fromRGB(255, 195, 95),
    killer = Color3.fromRGB(255, 42, 68),
    killerFill = Color3.fromRGB(255, 24, 52),
    teammate = Color3.fromRGB(255, 76, 96),
    teammateFill = Color3.fromRGB(255, 52, 76),
    stroke = Color3.fromRGB(10, 10, 14),
    fill = Color3.fromRGB(120, 210, 160),
}

local running = true
local entries = {}
local lastTeamRole = nil
local lastTeamScanAt = 0
local teamScanRetries = 0
local lastRoundDay = nil

local function playerGui()
    return lp and lp:FindFirstChild("PlayerGui") or nil
end

local pg = playerGui()
if pg then
    for _, child in ipairs(pg:GetChildren()) do
        if child.Name == "MafiaESP" then
            pcall(function() child:Destroy() end)
        end
    end
end
local gui = Instance.new("ScreenGui")
gui.Name = "MafiaESP"
gui.DisplayOrder = 40
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = pg

local folder = Instance.new("Folder")
folder.Name = "Tags"
folder.Parent = gui

local function stateApi()
    return _G.__mafiaState
end

local function removeEntry(key)
    local e = entries[key]
    if not e then return end
    entries[key] = nil
    if e.billboard then e.billboard:Destroy() end
    if e.highlight then e.highlight:Destroy() end
end

local function clearAll()
    for key in pairs(entries) do removeEntry(key) end
end

local function makeLabel(parent, name, y, size, color)
    local l = Instance.new("TextLabel")
    l.Name = name
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, 0, 0, y)
    l.Size = UDim2.new(1, 0, 0, size)
    l.Font = Enum.Font.GothamBold
    l.TextSize = 14
    l.TextColor3 = color
    l.TextStrokeTransparency = 0.35
    l.TextStrokeColor3 = COLORS.stroke
    l.TextXAlignment = Enum.TextXAlignment.Center
    l.TextTruncate = Enum.TextTruncate.AtEnd
    l.Text = ""
    l.Parent = parent
    return l
end

local function createEntry(key, entry)
    local head = entry.character:FindFirstChild("Head") or entry.root
    if not head then return nil end

    local bb = Instance.new("BillboardGui")
    bb.Name = "MafiaESPTag"
    bb.Size = UDim2.fromOffset(230, 40)
    bb.StudsOffset = Vector3.new(0, 2.7, 0)
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    bb.MaxDistance = CONFIG.maxDistance
    bb.Adornee = head
    bb.Parent = folder

    local nameLabel = makeLabel(bb, "Name", 0, 17, COLORS.alive)
    nameLabel.TextSize = 15

    local infoLabel = makeLabel(bb, "Info", 18, 13, Color3.fromRGB(220, 220, 230))
    infoLabel.Font = Enum.Font.GothamMedium
    infoLabel.TextSize = 11

    local highlight = nil
    if CONFIG.showHighlight then
        -- Parent under our PlayerGui folder (not the character in Workspace)
        -- so empBlackoutController cannot find and disable our ESP highlights
        -- during an EMP blackout.
        highlight = Instance.new("Highlight")
        highlight.Name = "MafiaESPHighlight"
        highlight.Adornee = entry.character
        highlight.FillColor = COLORS.fill
        highlight.FillTransparency = 0.84
        highlight.OutlineColor = COLORS.alive
        highlight.OutlineTransparency = 0.2
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Parent = folder
    end

    return {
        billboard = bb,
        nameLabel = nameLabel,
        infoLabel = infoLabel,
        highlight = highlight,
        adornee = head,
        character = entry.character,
    }
end

local function teammateIds()
    local set = {}
    local roles = _G.__mafiaRoles
    if not roles then return set end

    local ok, team = pcall(function() return roles.Team() end)
    if ok and type(team) == "table" then
        for _, member in ipairs(team) do
            if member.player then
                set[member.player.UserId] = true
            end
        end
    end

    -- Fallback for teammates the team query missed (for example a dead
    -- teammate): if we are Mafia/Witch, any confirmed Mafia/Witch reveal is
    -- also a teammate.
    local localRole = roles.CurrentRoleId and roles.CurrentRoleId() or nil
    if (localRole == "mafia" or localRole == "witch") and type(roles.Get) == "function" then
        for _, player in ipairs(Players:GetPlayers()) do
            local okRole, role = pcall(function() return roles.Get(player) end)
            if okRole and (role == "Mafia" or role == "Witch") then
                set[player.UserId] = true
            end
        end
    end

    return set
end

local function maybeAutoScan()
    if not CONFIG.autoTeamScan then return end
    local roles = _G.__mafiaRoles
    if not roles or type(roles.RefreshTeam) ~= "function" then return end

    local flow = _G.__mafiaFlowLog
    local day = flow and type(flow.Day) == "function" and flow.Day() or nil
    if day ~= lastRoundDay then
        lastRoundDay = day
        lastTeamRole = nil
        teamScanRetries = 0
    end

    local role = roles.CurrentRoleId and roles.CurrentRoleId() or nil
    if role ~= "mafia" and role ~= "witch" then
        lastTeamRole = role
        teamScanRetries = 0
        return
    end

    if role == lastTeamRole then
        -- The first query can land before the round fully assigns teams.
        -- Retry twice, eight seconds apart, only while the team is empty.
        if teamScanRetries < 2 and os.clock() - lastTeamScanAt > 8 then
            local ok, team = pcall(function() return roles.Team() end)
            if ok and type(team) == "table" and #team == 0 then
                teamScanRetries = teamScanRetries + 1
                lastTeamScanAt = os.clock()
                pcall(function() roles.RefreshTeam() end)
            end
        end
        return
    end

    -- One no-argument self-query per team role. The game client makes the
    -- same teamMembers call; it never targets another player.
    lastTeamRole = role
    teamScanRetries = 0
    lastTeamScanAt = os.clock()
    pcall(function() roles.RefreshTeam() end)
end

local function forensicsBadge(player)
    if not CONFIG.showForensics then return nil, nil end
    local lab = _G.__mafiaForensics
    if not lab or type(lab.Badge) ~= "function" then return nil, nil end
    local ok, badge, tier = pcall(lab.Badge, player)
    if ok and type(badge) == "string" and badge ~= "" then
        return badge, tier or "suspect"
    end
    return nil, nil
end

local function statusColor(entry, isTeammate, forensicsTier)
    if isTeammate then return COLORS.teammate end
    if forensicsTier == "confirmed" then return COLORS.killer end
    if entry.dead then return COLORS.dead end
    if forensicsTier == "suspect" then return COLORS.suspect end
    if entry.downed then return COLORS.downed end
    return COLORS.alive
end

local function infoText(entry, badge)
    local parts = {}
    if badge then
        parts[#parts + 1] = badge
    end
    if CONFIG.showRoles then
        local roles = _G.__mafiaRoles
        if roles and type(roles.Get) == "function" then
            local okRole, revealed = pcall(roles.Get, entry.player)
            if okRole and type(revealed) == "string" and revealed ~= "" then
                parts[#parts + 1] = "[" .. string.upper(revealed) .. "]"
            end
        end
    end
    if CONFIG.showHealth and not entry.dead then
        parts[#parts + 1] = string.format("%d hp", math.floor(entry.health + 0.5))
    end
    if CONFIG.showDistance and entry.distance then
        parts[#parts + 1] = string.format("%dm", math.floor(entry.distance + 0.5))
    end
    if entry.dead then
        parts[#parts + 1] = "DEAD"
    elseif entry.jailed then
        parts[#parts + 1] = "JAILED"
    elseif entry.downed then
        parts[#parts + 1] = "DOWNED"
    end
    if entry.isLocal then parts[#parts + 1] = "YOU" end
    return table.concat(parts, "  ·  ")
end

local function updateEntry(key, entry, teammates)
    local e = entries[key]

    if e and (e.character ~= entry.character or e.adornee == nil or e.adornee.Parent == nil) then
        removeEntry(key)
        e = nil
    end

    if not e then
        e = createEntry(key, entry)
        if not e then return end
        entries[key] = e
    end

    local isTeammate = teammates and teammates[entry.player.UserId] == true
    local badge, tier = nil, nil
    if not isTeammate then
        badge, tier = forensicsBadge(entry.player)
    end
    local color = statusColor(entry, isTeammate, tier)
    local showName = CONFIG.showNames
    local info = infoText(entry, badge)

    e.nameLabel.Text = showName and entry.disguise or ""
    e.nameLabel.TextColor3 = color
    e.nameLabel.Visible = showName and entry.disguise ~= ""
    e.infoLabel.Text = info
    e.infoLabel.TextColor3 = tier == "confirmed" and COLORS.killer or Color3.fromRGB(220, 220, 230)
    e.infoLabel.Visible = info ~= ""

    local offset = showName and 0 or -18
    e.billboard.Size = UDim2.fromOffset(230, showName and 40 or 22)
    e.nameLabel.Position = UDim2.new(0, 0, 0, offset)
    e.infoLabel.Position = UDim2.new(0, 0, 0, offset + 18)
    e.billboard.MaxDistance = CONFIG.maxDistance

    if e.highlight then
        if isTeammate then
            e.highlight.FillColor = COLORS.teammateFill
            e.highlight.FillTransparency = 0.84
            e.highlight.OutlineColor = COLORS.teammate
        elseif tier == "confirmed" then
            e.highlight.FillColor = COLORS.killerFill
            e.highlight.FillTransparency = 0.62
            e.highlight.OutlineColor = COLORS.killer
        elseif tier == "suspect" then
            e.highlight.FillColor = COLORS.suspect
            e.highlight.FillTransparency = 0.84
            e.highlight.OutlineColor = COLORS.suspect
        else
            e.highlight.FillColor = entry.downed and COLORS.downed or COLORS.fill
            e.highlight.FillTransparency = 0.84
            e.highlight.OutlineColor = color
        end
    end
end

local function refresh()
    if not CONFIG.enabled then
        clearAll()
        return
    end

    local state = stateApi()
    if not state then
        clearAll()
        return
    end

    maybeAutoScan()
    local teammates = teammateIds()

    local seen = {}
    for _, entry in ipairs(state.Players()) do
        if not entry.isLocal then
            local visible = (not entry.dead) or CONFIG.showDead
            if visible and entry.character and entry.root then
                seen[entry.player] = true
                updateEntry(entry.player, entry, teammates)
            end
        end
    end

    for key in pairs(entries) do
        if not seen[key] then removeEntry(key) end
    end
end

function API.Enabled()
    return CONFIG.enabled == true
end

function API.Set(on)
    CONFIG.enabled = on == true
    gui.Enabled = CONFIG.enabled
    if not CONFIG.enabled then
        clearAll()
    else
        pcall(refresh)
    end
    return true
end

function API.Toggle()
    return API.Set(not CONFIG.enabled)
end

function API.SetOption(key, value)
    if DEFAULTS[key] == nil then return false, "unknown option: " .. tostring(key) end
    CONFIG[key] = value
    if key == "enabled" then
        API.Set(value)
        return true
    end
    if key == "showHighlight" then clearAll() end
    if key == "autoTeamScan" and value == true then lastTeamRole = nil end
    if key == "maxDistance" then
        for _, e in pairs(entries) do e.billboard.MaxDistance = CONFIG.maxDistance end
    end
    if CONFIG.enabled then pcall(refresh) end
    return true
end

function API.Options()
    local out = {}
    for k, v in pairs(CONFIG) do out[k] = v end
    return out
end

function API.Count()
    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    return n
end

function API.RefreshTeam()
    local roles = _G.__mafiaRoles
    if not roles or type(roles.RefreshTeam) ~= "function" then
        return false, "roles module missing"
    end
    return roles.RefreshTeam()
end

function API.IsTeammate(player)
    if not player then return false end
    return teammateIds()[player.UserId] == true
end

function API.Stop()
    if _G.__mafiaESP ~= API then return end
    running = false
    clearAll()
    if gui then gui:Destroy() end
    _G.__mafiaESP = nil
end

_G.__mafiaESP = API

task.spawn(function()
    while running do
        pcall(refresh)
        task.wait(0.25)
    end
end)

print("[MAFIA-ESP] loaded - " .. (CONFIG.enabled and "on" or "off"))
