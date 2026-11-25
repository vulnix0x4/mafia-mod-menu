--!nocheck
--[[
    MAFIA - client-side match event feed (read-only)

    Listens to the game's own GameFlowLogRemote plus the low-volume game/chat
    service events the client already receives. Nothing is fired back.

    API: _G.__mafiaFlowLog
        .Lines()       -> array copy (oldest -> newest)
        .Last(n)       -> last n lines
        .Clear()
        .Stop()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaFlowLog
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local MAX_LINES = 220
local lines = _G.__mafiaFlowLogStore
if type(lines) ~= "table" then
    lines = {}
    _G.__mafiaFlowLogStore = lines
end
local connections = {}
local running = true

local function stripTags(text)
    return tostring(text):gsub("<[^>]->", "")
end

local function shallow(value, depth)
    if type(value) ~= "table" then return stripTags(value) end
    if depth <= 0 then return "{...}" end

    local numeric = true
    for key in pairs(value) do
        if type(key) ~= "number" then numeric = false break end
    end

    local parts, n = {}, 0
    if numeric then
        for i = 1, #value do
            n = n + 1
            if n > 10 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = shallow(value[i], depth - 1)
        end
        return table.concat(parts, " ")
    end

    for key, val in pairs(value) do
        n = n + 1
        if n > 10 then parts[#parts + 1] = "..." break end
        parts[#parts + 1] = tostring(key) .. "=" .. shallow(val, depth - 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function pack(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = shallow(select(i, ...), 2)
    end
    return table.concat(parts, " | ")
end

local function push(line)
    line = tostring(line)
    if line == "" then return end

    -- Drop the per-role controller spam; keep phase boundaries and events.
    if line:find("onGameStateChanged", 1, true)
        or line:find("onGamePhaseChangePreperation", 1, true)
        or line:find("getEvilAndGoodCount", 1, true) then
        return
    end

    lines[#lines + 1] = line
    while #lines > MAX_LINES do table.remove(lines, 1) end
end

local function format(label, ...)
    local args = { ... }
    if label == "[SYS]" and type(args[1]) == "table" then
        local t = args[1]
        if t[1] ~= nil and t[2] ~= nil then
            return stripTags(t[1]) .. " " .. stripTags(t[2])
        end
    end
    return pack(...)
end

local function hook(remote, label)
    if not running or not remote or not remote:IsA("RemoteEvent") then return end
    connections[#connections + 1] = remote.OnClientEvent:Connect(function(...)
        if not running then return end
        push(label .. " " .. format(label, ...))
    end)
end

local function hookRootWhenReady(name, label)
    local existing = ReplicatedStorage:FindFirstChild(name)
    if existing then
        hook(existing, label)
        return
    end
    task.spawn(function()
        local remote = ReplicatedStorage:WaitForChild(name, 60)
        if running and remote then hook(remote, label) end
    end)
end

local function hookServiceEventsWhenReady(serviceName, eventSpecs)
    local function attach(folder)
        for _, spec in ipairs(eventSpecs) do
            local existing = folder:FindFirstChild(spec.name)
            if existing then
                hook(existing, spec.label)
            else
                task.spawn(function()
                    local remote = folder:WaitForChild(spec.name, 60)
                    if running and remote then hook(remote, spec.label) end
                end)
            end
        end
    end

    local services = ReplicatedStorage:FindFirstChild("ServiceNetworks")
    local folder = services and services:FindFirstChild(serviceName)
    if folder then
        attach(folder)
        return
    end

    task.spawn(function()
        local nets = ReplicatedStorage:WaitForChild("ServiceNetworks", 60)
        if not running or not nets then return end
        local svc = nets:WaitForChild(serviceName, 60)
        if running and svc then attach(svc) end
    end)
end

hookRootWhenReady("GameFlowLogRemote", "[FLOW]")

local GAME_EVENTS = {}
for _, name in ipairs({
    "nightTransition", "lightsToggled", "talliedVotes", "mapVotesUpdate",
    "roundTypeVotesUpdate", "playBodyFoundCutscene", "playDeathCutscene",
    "endingCutscene", "selfRespawn", "aboutToTeleportToLobby", "skipVote",
}) do
    GAME_EVENTS[#GAME_EVENTS + 1] = { name = name, label = "[GAME] " .. name }
end
hookServiceEventsWhenReady("gameService", GAME_EVENTS)
hookServiceEventsWhenReady("chatService", {
    { name = "onSystemMessage", label = "[SYS]" },
})

function API.Lines()
    local out = {}
    for i, line in ipairs(lines) do out[i] = line end
    return out
end

function API.Last(n)
    n = tonumber(n) or 8
    local start = math.max(1, #lines - n + 1)
    local out = {}
    for i = start, #lines do out[#out + 1] = lines[i] end
    return out
end

function API.Clear()
    for i = #lines, 1, -1 do
        lines[i] = nil
    end
end

function API.Phase()
    for i = #lines, 1, -1 do
        local phase = lines[i]:match("phase '([^']+)' START")
        if phase then return phase end
    end
    return nil
end

function API.Day()
    for i = #lines, 1, -1 do
        local day = lines[i]:match("CYCLE start %(day (%d+)%)")
        if day then return tonumber(day) end
    end
    return nil
end

local DEATH_PATTERNS = {
    "shot by", "has been shot", "paid the ultimate price", "was killed",
    "playdeathcutscene", "playbodyfoundcutscene", " died",
}

function API.Deaths(n)
    n = tonumber(n) or 3
    local out = {}
    for i = #lines, 1, -1 do
        local line = lines[i]
        local lower = line:lower()
        for _, pattern in ipairs(DEATH_PATTERNS) do
            if lower:find(pattern, 1, true) then
                table.insert(out, 1, line)
                break
            end
        end
        if #out >= n then break end
    end
    return out
end

function API.Stop()
    if _G.__mafiaFlowLog ~= API then return end
    running = false
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    connections = {}
    _G.__mafiaFlowLog = nil
end

_G.__mafiaFlowLog = API

print("[MAFIA-FLOW] loaded - " .. #connections .. " listeners, " .. #lines .. " lines")
