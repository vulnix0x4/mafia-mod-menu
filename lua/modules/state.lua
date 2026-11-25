--!nocheck
--[[
    MAFIA - shared state reader (read-only)

    Everything here comes from replicated client state:
      RoleDisplay   -> your role
      Tips          -> phase, objective, action, warning
      NoirApp       -> corruption %, players remaining, role-specific status
      Players       -> names, disguises, health, Dead attribute, positions

    No remotes are invoked and nothing in the game is modified.

    API: _G.__mafiaState
        .Snapshot()        -> table  (role/faction/phase/objective/corruption/...)
        .Players()         -> array  (sorted alive-first, then distance)
        .AlivePlayers()    -> array
        .FactionForRole(r) -> string
        .RoleInfo(r)       -> table
        .Stop()
]]

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaState
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local FACTIONS = {
    Civilian = "Town",
    Detective = "Town",
    Doctor = "Town",
    Janitor = "Town",
    Vigilante = "Town",
    Detainer = "Town",
    Suppressor = "Town",
    Judge = "Town",

    Mafia = "Mafia",
    Witch = "Mafia",

    Harbinger = "Veil",
    Mirage = "Veil",
    Poisoner = "Veil",
    Saboteur = "Veil",

    Bodyguard = "Neutral",
    Jester = "Neutral",
    ["Snow Spirit"] = "Neutral",
    Phantom = "Neutral",
}

local ROLE_INFO = {
    Civilian = { short = "No abilities. Survive, read the room, vote correctly." },
    Detective = { short = "Track handprints and footprints at night; see where players died." },
    Doctor = { short = "Heal players attacked by the Mafia and cleanse Veil effects." },
    Janitor = { short = "Clean Saboteur and Poisoner messes; unlock doors to cut corruption." },
    Vigilante = { short = "Shoot one player during voting. If they are innocent, you die too." },
    Detainer = { short = "Jail one player through the next night and talk to them privately." },
    Suppressor = { short = "Remove one player's right to vote for the coming vote." },
    Judge = { short = "Break tied votes and see who voted for whom." },

    Mafia = { short = "Kill one player each night. Reach parity with the town." },
    Witch = { short = "Silence a player for the next day and vote." },

    Harbinger = { short = "Guess roles to fill the corruption bar: +20% correct, -10% wrong." },
    Mirage = { short = "Haunt a target repeatedly; every terror stage feeds corruption." },
    Poisoner = { short = "Poison the crowd. Deaths from your gas feed the corruption bar." },
    Saboteur = { short = "Lock doors to feed corruption. Stay hidden while doing it." },

    Bodyguard = { short = "Protect your assigned target; take the shot meant for them." },
    Jester = { short = "Get voted out, then kill one player at night to win." },
    ["Snow Spirit"] = { short = "Freeze one player per night, removing their ability and vote." },
    Phantom = { short = "Revive or finish wounded players; use invisibility to escape." },
}

function API.FactionForRole(role)
    return FACTIONS[role] or "Unknown"
end

function API.RoleInfo(role)
    return ROLE_INFO[role] or { short = "Role data not mapped yet." }
end

local function playerGui()
    return lp and lp:FindFirstChild("PlayerGui")
end

local function findGui(name)
    local pg = playerGui()
    return pg and pg:FindFirstChild(name) or nil
end

local function readRole()
    local rd = findGui("RoleDisplay")
    if not rd then return nil end
    local label = rd:FindFirstChild("Wrapper", true)
    if label and label:IsA("TextLabel") then
        local role = label.Text:match("Your role is:%s*(.+)$")
        if role then
            role = role:gsub("^%s+", ""):gsub("%s+$", "")
            if role ~= "" then return role end
        end
    end
    return nil
end

local function readTips()
    local out = {}
    local tips = findGui("Tips")
    if not tips then return out end

    for _, d in ipairs(tips:GetDescendants()) do
        if d:IsA("TextLabel") then
            if d.Name == "Title" then
                out.title = d.Text
            elseif d.Name == "Objective" then
                out.objective = d.Text
            elseif d.Name == "Action" then
                out.action = d.Text
            elseif d.Name == "Warning" then
                out.warning = d.Text
            end
        end
    end

    if out.title then
        local phase = out.title:match("^%s*([^—%-]+)")
        if phase then
            out.phase = phase:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end

    local transition = findGui("nextNightTransition")
    out.transition = transition ~= nil and transition.Enabled == true
    return out
end

local function readNoirApp()
    local noir = findGui("NoirApp")
    if not noir then return nil, nil end
    local corruption, playersLeft = nil, nil
    for _, d in ipairs(noir:GetDescendants()) do
        if d:IsA("TextLabel") then
            local text = d.Text
            if corruption == nil then
                local pct = text:match("CORRUPTION%s*(%d+)%%")
                if pct then corruption = tonumber(pct) end
            end
            if playersLeft == nil then
                local n = text:match("PLAYERS REMAINING:%s*(%d+)")
                if n then playersLeft = tonumber(n) end
            end
            if corruption ~= nil and playersLeft ~= nil then
                break
            end
        end
    end
    return corruption, playersLeft
end

function API.ReadRole()
    return readRole()
end

local function readVoteTarget()
    local ui = findGui("UI")
    local vote = ui and ui:FindFirstChild("mafiavote")
    if not vote or not vote.Visible then return nil end
    local nameLabel = vote:FindFirstChild("PlayerName")
    if nameLabel and nameLabel:IsA("TextLabel") then
        local target = nameLabel.Text:gsub("^%s+", ""):gsub("%s+$", "")
        if target ~= "" and target ~= "PLAYER" then
            return target
        end
    end
    return nil
end

local function localRoot()
    local ch = lp and lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

function API.Players()
    local list = {}
    local myRoot = localRoot()
    for _, p in ipairs(Players:GetPlayers()) do
        local ch = p.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        local deadAttr = p:GetAttribute("Dead")
        local dead = deadAttr == true or (hum ~= nil and hum.Health <= 0)

        local distance = nil
        if myRoot and root and p ~= lp then
            distance = (root.Position - myRoot.Position).Magnitude
        elseif p == lp then
            distance = 0
        end

        local parentName = ch and ch.Parent and ch.Parent.Name or ""
        local jailed = parentName == "jail" or parentName == "detain" or parentName == "detainerJail"

        list[#list + 1] = {
            player = p,
            name = p.Name,
            display = p.DisplayName,
            disguise = p:GetAttribute("DisguiseName") or (ch and ch.Name) or p.DisplayName,
            health = hum and hum.Health or 0,
            dead = dead,
            deadAttr = deadAttr == true,
            downed = ch ~= nil and ch:GetAttribute("Downed") == true,
            ragdolled = ch ~= nil and ch:GetAttribute("Ragdolled") == true,
            jailed = jailed,
            root = root,
            character = ch,
            distance = distance,
            isLocal = p == lp,
        }
    end

    table.sort(list, function(a, b)
        if a.dead ~= b.dead then return not a.dead end
        local ad = a.distance or math.huge
        local bd = b.distance or math.huge
        if ad ~= bd then return ad < bd end
        return a.name:lower() < b.name:lower()
    end)

    return list
end

function API.AlivePlayers()
    local out = {}
    for _, entry in ipairs(API.Players()) do
        if not entry.dead and entry.character and entry.root then
            out[#out + 1] = entry
        end
    end
    return out
end

function API.Snapshot()
    local role = readRole()
    local tips = readTips()
    local players = API.Players()
    local alive = 0
    for _, entry in ipairs(players) do
        if not entry.dead then alive = alive + 1 end
    end

    local faction = role and API.FactionForRole(role) or "Unknown"
    local info = role and API.RoleInfo(role) or nil
    local corruption, left = readNoirApp()

    local actionText = tips.action or ""
    local actionLower = actionText:lower()
    local powerState = nil
    if actionLower:find("cannot use your power yet", 1, true) then
        powerState = "locked"
    elseif actionLower:find("never used it", 1, true) or actionLower:find("had a power", 1, true) then
        powerState = "missed"
    elseif actionLower:find("press t", 1, true) or actionLower:find("use your power", 1, true) then
        powerState = "ready"
    end

    return {
        role = role,
        faction = faction,
        roleShort = info and info.short or "",
        inRound = role ~= nil,
        phase = tips.phase,
        phaseTitle = tips.title,
        objective = tips.objective,
        action = tips.action,
        warning = tips.warning,
        powerState = powerState,
        transition = tips.transition == true,
        corruption = corruption,
        voteTarget = readVoteTarget(),
        playersLeft = left or alive,
        alive = alive,
        total = #players,
        dead = lp ~= nil and lp:GetAttribute("Dead") == true,
        placeId = game.PlaceId,
        gameId = game.GameId,
        updatedAt = os.clock(),
    }
end

function API.Stop()
    if _G.__mafiaState == API then
        _G.__mafiaState = nil
    end
end

_G.__mafiaState = API

local initialRole = readRole()
print("[MAFIA-STATE] loaded - role=" .. tostring(initialRole) .. " faction=" .. tostring(API.FactionForRole(initialRole or "")))
