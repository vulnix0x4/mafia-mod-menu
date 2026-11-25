--!nocheck
--[[
    MAFIA - passive role reveals

    The server does not publish a global role table. It *does* publish role
    information in a few legitimate places:

      gameService.revealRoles        role reveal event
      gameService.playDeathCutscene  death cutscene payload
      medalService.clip              kill / medal clips (public reveals)
      announcementService.show        public announcements
      endService.endCutscene          round-end cutscene

    Player chat is deliberately not parsed as a reveal: `chatService.onSystemMessage`
    relays ordinary chat, and "X is the mafia" is a claim, not proof.

    This module only *listens* to those events. It never calls FireServer and
    never invokes a remote on its own. `RefreshTeam()` is a manual, no-argument
    self-query (the same call the game client makes) and is only run when the
    user presses the button.

    Confirmed roles survive a module reload via
    _G.__mafiaRoleRevealStore. They are cleared at the start of a new round.

    API: _G.__mafiaRoles
        .Get(player)         -> confirmed role name or nil
        .GetEntry(player)    -> { role, source, at, name, disguise }
        .List()              -> ordered confirmed entries
        .Count()             -> number of confirmed roles
        .Team()              -> ordered teammates (from highlights / self-query)
        .ScanHighlights()    -> refresh team from game highlights (passive)
        .RefreshTeam()       -> manual no-argument teamMembers self-query
        .Raw()               -> recent raw reveal events
        .Reset()             -> clear confirms + raw feed
        .DisplayRole(id)     -> canonical display name
        .Faction(role)       -> Town / Mafia / Veil / Neutral
        .Stop()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"
API.LastTeamMessage = ""

local old = _G.__mafiaRoles
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local ROLE_LIST = {
    { id = "civilian", name = "Civilian", faction = "Town" },
    { id = "detective", name = "Detective", faction = "Town" },
    { id = "doctor", name = "Doctor", faction = "Town" },
    { id = "janitor", name = "Janitor", faction = "Town" },
    { id = "vigilante", name = "Vigilante", faction = "Town" },
    { id = "detainer", name = "Detainer", faction = "Town" },
    { id = "suppressor", name = "Suppressor", faction = "Town" },
    { id = "judge", name = "Judge", faction = "Town" },
    { id = "mafia", name = "Mafia", faction = "Mafia" },
    { id = "witch", name = "Witch", faction = "Mafia" },
    { id = "harbinger", name = "Harbinger", faction = "Veil" },
    { id = "mirage", name = "Mirage", faction = "Veil" },
    { id = "poisoner", name = "Poisoner", faction = "Veil" },
    { id = "saboteur", name = "Saboteur", faction = "Veil" },
    { id = "bodyguard", name = "Bodyguard", faction = "Neutral" },
    { id = "jester", name = "Jester", faction = "Neutral" },
    { id = "snowspirit", name = "Snow Spirit", faction = "Neutral" },
    { id = "phantom", name = "Phantom", faction = "Neutral" },
}

local BY_TOKEN = {}
local BY_NAME = {}
for _, role in ipairs(ROLE_LIST) do
    BY_NAME[role.name] = role
    BY_TOKEN[role.id] = role
    BY_TOKEN[role.name:lower():gsub("[%s_%-]+", "")] = role
end
BY_TOKEN["snowspirit"] = BY_NAME["Snow Spirit"]
BY_TOKEN["bodyguard"] = BY_NAME["Bodyguard"]

local TEXT_ALIASES = {
    { "snow spirit", "Snow Spirit" },
    { "bodyguard", "Bodyguard" },
    { "body guard", "Bodyguard" },
    { "suppressor", "Suppressor" },
    { "vigilante", "Vigilante" },
    { "detective", "Detective" },
    { "harbinger", "Harbinger" },
    { "poisoner", "Poisoner" },
    { "saboteur", "Saboteur" },
    { "detainer", "Detainer" },
    { "civilian", "Civilian" },
    { "janitor", "Janitor" },
    { "phantom", "Phantom" },
    { "jester", "Jester" },
    { "doctor", "Doctor" },
    { "mirage", "Mirage" },
    { "mafia", "Mafia" },
    { "witch", "Witch" },
    { "judge", "Judge" },
}

local store = _G.__mafiaRoleRevealStore
if type(store) ~= "table" then
    store = {}
    _G.__mafiaRoleRevealStore = store
end

local teamStore = _G.__mafiaRoleTeamStore
if type(teamStore) ~= "table" then
    teamStore = {}
    _G.__mafiaRoleTeamStore = teamStore
end

local rawStore = _G.__mafiaRoleRawStore
if type(rawStore) ~= "table" then
    rawStore = {}
    _G.__mafiaRoleRawStore = rawStore
end

local running = true
local connections = {}
local teamBusy = false
local lastDay = nil

local MAX_RAW = 60

local function isA(value, class)
    local ok, result = pcall(function() return value:IsA(class) end)
    return ok and result == true
end

local function getPlayerByUserId(userId)
    local ok, player = pcall(function() return Players:GetPlayerByUserId(userId) end)
    return ok and player or nil
end

local function getPlayerFromCharacter(character)
    local ok, player = pcall(function() return Players:GetPlayerFromCharacter(character) end)
    return ok and player or nil
end

local function pushRaw(source, text)
    rawStore[#rawStore + 1] = {
        source = source,
        text = text,
        at = os.time(),
    }
    while #rawStore > MAX_RAW do table.remove(rawStore, 1) end
end

local function ser(value, depth, seen)
    local t = type(value)
    if t == "string" then
        if #value > 140 then return value:sub(1, 137) .. "..." end
        return value
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(value)
    elseif t == "table" then
        if depth <= 0 then return "{...}" end
        seen = seen or {}
        if seen[value] then return "<cycle>" end
        seen[value] = true
        local parts, n = {}, 0
        for k, v in pairs(value) do
            n = n + 1
            if n > 16 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. ser(v, depth - 1, seen)
        end
        seen[value] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local ok, result = pcall(function() return value:GetFullName() end)
    return ok and result or tostring(value)
end

local function playerIndex()
    local index = {}
    for _, player in ipairs(Players:GetPlayers()) do
        index[player.Name:lower()] = player
        index[player.DisplayName:lower()] = player
        index[tostring(player.UserId)] = player
        local disguise = player:GetAttribute("DisguiseName")
        if type(disguise) == "string" and #disguise > 0 then
            index[disguise:lower()] = player
        end
        local character = player.Character
        if character then index[character.Name:lower()] = player end
    end
    return index
end

local function resolvePlayer(value, index)
    if isA(value, "Player") then return value end

    local characterPlayer = getPlayerFromCharacter(value)
    if characterPlayer then return characterPlayer end

    local parent = nil
    pcall(function() parent = value.Parent end)
    if parent then
        local parentPlayer = getPlayerFromCharacter(parent)
        if parentPlayer then return parentPlayer end
    end

    if type(value) == "number" then
        return getPlayerByUserId(value)
    end
    if type(value) == "string" then
        local direct = index[value:lower()]
        if direct then return direct end
        if value:match("^%d+$") then
            return getPlayerByUserId(tonumber(value))
        end
    end
    return nil
end

local function normalizeRole(value)
    if type(value) ~= "string" then return nil end
    local token = value:lower():gsub("[%s_%-]+", "")
    local role = BY_TOKEN[token]
    return role and role.name or nil
end

local function containsWord(text, word)
    if #word == 0 then return false end
    local init = 1
    while true do
        local s, e = text:find(word, init, true)
        if not s then return false end
        local before = s > 1 and text:sub(s - 1, s - 1) or ""
        local after = e < #text and text:sub(e + 1, e + 1) or ""
        if not before:match("%a") and not after:match("%a") then return true end
        init = e + 1
    end
end

local function displayOf(player)
    local disguise = player:GetAttribute("DisguiseName")
    if type(disguise) == "string" and #disguise > 0 then return disguise end
    return player.DisplayName ~= "" and player.DisplayName or player.Name
end

local function confirm(player, roleName, source)
    if not player or not roleName then return false end
    local key = player.UserId
    local previous = store[key]
    local changed = not previous or previous.role ~= roleName
    store[key] = {
        role = roleName,
        source = source or "reveal",
        at = os.time(),
        name = player.Name,
        disguise = displayOf(player),
    }
    if changed then
        print(string.format("[MAFIA-ROLES] %s (%s) = %s <- %s",
            player.Name, displayOf(player), roleName, source or "reveal"))
    end
    return changed
end

local ROLE_FIELDS = {
    role = true,
    rolename = true,
    revealedrole = true,
    assignedrole = true,
    newrole = true,
}

local PLAYER_FIELDS = {
    userid = true,
    playerid = true,
    player = true,
    target = true,
    victim = true,
    who = true,
    killer = true,
    shooter = true,
    bodyfinder = true,
    name = true,
}

local function scanPayload(payload, source)
    local index = playerIndex()
    local allPlayers, allRoles = {}, {}
    local seenPlayers, seenRoles, seenTables = {}, {}, {}
    local explicit = false

    local function addPlayer(player)
        if player and not seenPlayers[player] then
            seenPlayers[player] = true
            allPlayers[#allPlayers + 1] = player
        end
    end

    local function addRole(role)
        if role and not seenRoles[role] then
            seenRoles[role] = true
            allRoles[#allRoles + 1] = role
        end
    end

    local function visit(value, depth)
        if type(value) ~= "table" or depth > 4 then return end
        if seenTables[value] then return end
        seenTables[value] = true

        local roleField = nil
        local playerFields = {}

        for k, v in pairs(value) do
            if type(k) == "string" then
                local field = k:lower():gsub("[%s_%-]+", "")
                if ROLE_FIELDS[field] then
                    local role = normalizeRole(v)
                    if role then
                        roleField = role
                        addRole(role)
                    end
                end
                if PLAYER_FIELDS[field] then
                    local player = resolvePlayer(v, index)
                    if player then
                        playerFields[#playerFields + 1] = player
                        addPlayer(player)
                    end
                end
            end

            local keyPlayer = resolvePlayer(k, index)
            local valueRole = normalizeRole(v)
            if keyPlayer and valueRole then
                addPlayer(keyPlayer)
                addRole(valueRole)
                confirm(keyPlayer, valueRole, source)
                explicit = true
            end

            local keyRole = normalizeRole(k)
            local valuePlayer = resolvePlayer(v, index)
            if keyRole and valuePlayer then
                addPlayer(valuePlayer)
                addRole(keyRole)
                confirm(valuePlayer, keyRole, source)
                explicit = true
            end

            if type(v) == "table" then visit(v, depth + 1) end
        end

        if roleField then
            for _, player in ipairs(playerFields) do
                confirm(player, roleField, source)
                explicit = true
            end
        end
    end

    visit(payload, 0)

    if not explicit and #allPlayers == 1 and #allRoles == 1 then
        confirm(allPlayers[1], allRoles[1], source)
    end
end

local function scanText(text, source)
    if type(text) ~= "string" or #text < 4 or #text > 400 then return end
    local lower = text:lower()

    local playerHits = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local tokens = {
            player.Name:lower(),
            player.DisplayName:lower(),
        }
        local disguise = player:GetAttribute("DisguiseName")
        if type(disguise) == "string" and #disguise > 0 then
            tokens[#tokens + 1] = disguise:lower()
        end
        for _, token in ipairs(tokens) do
            if #token > 2 and containsWord(lower, token) then
                playerHits[player] = true
                break
            end
        end
    end

    for _, alias in ipairs(TEXT_ALIASES) do
        local phrase = alias[1]
        local roleName = alias[2]
        if containsWord(lower, phrase) then
            for player in pairs(playerHits) do
                local patterns = {
                    " was the " .. phrase,
                    " was a " .. phrase,
                    " is the " .. phrase,
                    " is a " .. phrase,
                    " revealed as " .. phrase,
                    " (" .. phrase .. ")",
                    " [" .. phrase .. "]",
                }
                local tokens = {
                    player.Name:lower(),
                    player.DisplayName:lower(),
                }
                local disguise = player:GetAttribute("DisguiseName")
                if type(disguise) == "string" and #disguise > 0 then
                    tokens[#tokens + 1] = disguise:lower()
                end
                local matched = false
                for _, token in ipairs(tokens) do
                    if #token > 2 and not matched then
                        for _, pattern in ipairs(patterns) do
                            if containsWord(lower, token .. pattern) then
                                confirm(player, roleName, source)
                                matched = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

local function handlePayload(source, payload)
    local text = ser(payload, 3)
    if #text > 0 then pushRaw(source, text) end
    scanPayload(payload, source)

    local function walkStrings(value, depth)
        if type(value) == "string" then
            scanText(value, source)
        elseif type(value) == "table" and depth <= 4 then
            for _, v in pairs(value) do walkStrings(v, depth + 1) end
        end
    end
    walkStrings(payload, 0)
end

local function hookEvent(event, source)
    if not running or not event or not event:IsA("RemoteEvent") then return end
    local ok = pcall(function()
        local connection = event.OnClientEvent:Connect(function(...)
            if not running then return end
            local payload = { ... }
            pcall(handlePayload, source, payload)
        end)
        connections[#connections + 1] = connection
    end)
    if ok then
        print("[MAFIA-ROLES] listening " .. source .. " (" .. event:GetFullName() .. ")")
    end
end

local function service(name, child)
    local networks = ReplicatedStorage:FindFirstChild("ServiceNetworks")
    local folder = networks and networks:FindFirstChild(name)
    return folder and folder:FindFirstChild(child) or nil
end

-- Services replicate in after a teleport. Wait for each one instead of assuming
-- it exists at module load, otherwise every reveal hook is silently skipped.
local function hookEventWhenReady(serviceName, eventName, source)
    task.spawn(function()
        local networks = ReplicatedStorage:WaitForChild("ServiceNetworks", 60)
        if not running or not networks then return end
        local folder = networks:WaitForChild(serviceName, 60)
        if not running or not folder then return end
        local event = folder:WaitForChild(eventName, 60)
        if running and event then hookEvent(event, source) end
    end)
end

hookEventWhenReady("gameService", "revealRoles", "reveal")
hookEventWhenReady("gameService", "playDeathCutscene", "death")
hookEventWhenReady("gameService", "playBodyFoundCutscene", "body")
hookEventWhenReady("gameService", "endingCutscene", "end")
hookEventWhenReady("medalService", "clip", "medal")
hookEventWhenReady("announcementService", "show", "announce")
hookEventWhenReady("endService", "endCutscene", "end")

-- Team detection -------------------------------------------------------------

local function markTeam(player, label, source)
    if not player then return false end
    local key = player.UserId
    local previous = teamStore[key]
    teamStore[key] = {
        label = label or "TEAM",
        name = player.Name,
        disguise = displayOf(player),
        source = source or "highlight",
        at = os.time(),
    }
    return not previous
end

function API.ScanHighlights()
    local found = 0
    for _, object in ipairs(Workspace:GetChildren()) do
        if isA(object, "Model") then
            local player = getPlayerFromCharacter(object)
            if player then
                for _, child in ipairs(object:GetChildren()) do
                    if child:IsA("Highlight") and child.Enabled and child.Name ~= "MafiaESPHighlight" then
                        -- Only explicit teammate highlights count as team info.
                        -- Game ability highlights (JesterApparition, managedHighlight,
                        -- target markers) are not teammates.
                        if child.Name:lower():find("teammate", 1, true) then
                            if markTeam(player, "TEAM", "highlight") then found = found + 1 end
                        end
                    end
                end
            end
        end
    end
    return found
end

local function collectPlayersFrom(payload, target)
    local index = playerIndex()
    local seen = {}
    local function visit(value, depth)
        if depth > 4 then return end
        if type(value) ~= "table" then
            local player = resolvePlayer(value, index)
            if player and not seen[player] then
                seen[player] = true
                target[#target + 1] = player
            end
            return
        end
        for k, v in pairs(value) do
            visit(k, depth + 1)
            visit(v, depth + 1)
        end
    end
    visit(payload, 0)
    return target
end

local function payloadHasText(payload, needle)
    local found = false
    local function visit(value, depth)
        if found or depth > 5 then return end
        if type(value) == "string" then
            if value:lower():find(needle, 1, true) then found = true end
        elseif type(value) == "table" then
            for _, v in pairs(value) do visit(v, depth + 1) end
        end
    end
    visit(payload, 0)
    return found
end

function API.CurrentRoleId()
    local state = _G.__mafiaState
    local role = nil
    if state then
        if type(state.ReadRole) == "function" then
            role = state.ReadRole()
        elseif type(state.Snapshot) == "function" then
            local snapshot = state.Snapshot()
            role = snapshot and snapshot.role
        end
    end
    local entry = role and BY_NAME[role]
    return entry and entry.id or nil
end

local function parseTeamCategories(payload)
    if type(payload) ~= "table" then return 0 end
    local count = 0
    for category, members in pairs(payload) do
        if type(category) == "string" and type(members) == "table" then
            local label = category:upper()
            for _, player in ipairs(collectPlayersFrom(members, {})) do
                markTeam(player, label, "roleTeam")
                count = count + 1
            end
        end
    end
    return count
end

function API.RefreshTeam()
    if teamBusy then return false, "team query already running" end
    local membersFn = service("teamService", "teamMembers")
    local highlightsFn = service("highlightsService", "highlights")
    local roleId = API.CurrentRoleId()
    local roleTeamFn = nil

    -- Only query the role network that matches the role you actually have.
    -- This is the same call the game's own role controller makes.
    if roleId == "mafia" or roleId == "witch" or roleId == "bodyguard" then
        local networks = ReplicatedStorage:FindFirstChild("RoleNetworks")
        local folder = networks and networks:FindFirstChild(roleId)
        -- Prefer teamMembers: getTeamMembers expects an argument in the live
        -- Mafia build and errors when called with none. teamMembers returns
        -- the same category table without arguments.
        local fn = folder and (folder:FindFirstChild("teamMembers") or folder:FindFirstChild("getTeamMembers"))
        if fn and fn:IsA("RemoteFunction") then
            roleTeamFn = fn
        end
    end

    if not membersFn and not highlightsFn and not roleTeamFn then
        API.LastTeamMessage = "team service missing"
        return false, API.LastTeamMessage
    end

    teamBusy = true
    task.spawn(function()
        local messages = {}
        local okAll = pcall(function()
            local roleCount = 0

            if roleTeamFn then
                local ok, result = pcall(function() return roleTeamFn:InvokeServer() end)
                if ok then
                    roleCount = parseTeamCategories(result)
                    if roleCount == 0 then
                        for _, player in ipairs(collectPlayersFrom(result, {})) do
                            markTeam(player, "TEAM", "roleTeam")
                            roleCount = roleCount + 1
                        end
                    end
                    messages[#messages + 1] = string.format("%s team: %d", roleId, roleCount)
                else
                    messages[#messages + 1] = roleId .. " team: error"
                end
            end

            -- The role-network call is authoritative for Mafia/Witch. Only fall
            -- back to the generic service queries when it returned nothing.
            if roleCount == 0 and membersFn then
                local ok, result = pcall(function() return membersFn:InvokeServer() end)
                if ok and type(result) == "table" then
                    local found = collectPlayersFrom(result, {})
                    for _, player in ipairs(found) do markTeam(player, "TEAM", "teamMembers") end
                    messages[#messages + 1] = string.format("teamMembers: %d", #found)
                else
                    messages[#messages + 1] = "teamMembers: error"
                end
            end

            if roleCount == 0 and highlightsFn then
                local ok, result = pcall(function() return highlightsFn:InvokeServer() end)
                if ok then
                    if payloadHasText(result, "teammate") then
                        local found = collectPlayersFrom(result, {})
                        for _, player in ipairs(found) do markTeam(player, "TEAM", "highlights") end
                        messages[#messages + 1] = string.format("highlights: %d team", #found)
                    else
                        messages[#messages + 1] = "highlights: no team tags"
                    end
                else
                    messages[#messages + 1] = "highlights: error"
                end
            end
        end)

        teamBusy = false
        if not running then return end
        API.LastTeamMessage = okAll and table.concat(messages, " · ") or "team query failed"
        print("[MAFIA-ROLES] team self-query: " .. API.LastTeamMessage)
    end)

    return true, "team query started"
end

function API.Team()
    local list, seen = {}, {}
    for key, entry in pairs(teamStore) do
        local player = getPlayerByUserId(tonumber(key) or -1)
        if player and not seen[player] then
            seen[player] = true
            list[#list + 1] = {
                player = player,
                name = player.Name,
                disguise = displayOf(player),
                label = entry.label,
                source = entry.source,
            }
        end
    end
    table.sort(list, function(a, b) return a.disguise:lower() < b.disguise:lower() end)
    return list
end

-- API -----------------------------------------------------------------------

function API.DisplayRole(role)
    if not role then return nil end
    local entry = BY_NAME[role]
    if entry then return entry.name end
    local token = role:lower():gsub("[%s_%-]+", "")
    entry = BY_TOKEN[token]
    return entry and entry.name or role
end

function API.Faction(role)
    if not role then return "Unknown" end
    local entry = BY_NAME[role]
    if entry then return entry.faction end
    local token = role:lower():gsub("[%s_%-]+", "")
    entry = BY_TOKEN[token]
    return entry and entry.faction or "Unknown"
end

function API.Roles()
    return ROLE_LIST
end

function API.Get(player)
    local entry = API.GetEntry(player)
    return entry and entry.role or nil
end

function API.GetEntry(player)
    if not player then return nil end
    return store[player.UserId]
end

function API.Count()
    local n = 0
    for _ in pairs(store) do n = n + 1 end
    return n
end

function API.List()
    local list = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local entry = store[player.UserId]
        if entry then
            list[#list + 1] = {
                player = player,
                name = player.Name,
                disguise = displayOf(player),
                role = entry.role,
                source = entry.source,
                at = entry.at,
            }
        end
    end
    table.sort(list, function(a, b) return a.disguise:lower() < b.disguise:lower() end)
    return list
end

function API.Raw()
    local out = {}
    for i, entry in ipairs(rawStore) do out[i] = entry end
    return out
end

-- Local-only: run a payload through the same parser. Used by diagnostics and
-- the offline mock; nothing is sent to the server.
function API.Ingest(source, ...)
    local payload = { ... }
    handlePayload(tostring(source or "manual"), payload)
    return API.Count()
end

function API.Reset()
    for key in pairs(store) do store[key] = nil end
    for key in pairs(teamStore) do teamStore[key] = nil end
    for i = #rawStore, 1, -1 do rawStore[i] = nil end
    API.LastTeamMessage = ""
end

function API.Stop()
    if _G.__mafiaRoles ~= API then return end
    running = false
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    connections = {}
    _G.__mafiaRoles = nil
end

_G.__mafiaRoles = API

local lastPhase = nil
task.spawn(function()
    while running do
        local flow = _G.__mafiaFlowLog
        if flow then
            local day = flow.Day()
            local phase = flow.Phase()
            if day and lastDay and day < lastDay then
                API.Reset()
            end
            if phase == "Lobby" and lastPhase ~= "Lobby" then
                API.Reset()
            end
            lastDay = day or lastDay
            lastPhase = phase
        end
        task.wait(1)
    end
end)

print(string.format("[MAFIA-ROLES] loaded - %d confirmed, %d team, %d raw events",
    API.Count(), #API.Team(), #rawStore))
