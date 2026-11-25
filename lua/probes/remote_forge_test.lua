--!nocheck
--[[
    MAFIA - private-server remote validation probe

    This is a manual test harness, not part of the loader. It answers one
    question: do the game's own role/vote remotes accept calls that did not
    come from the normal UI flow?

    Safety gates (both required):
        game.PrivateServerId ~= ""          -- private server, or
        _G.__REMOTE_TEST_ALLOW_PUBLIC = true

        _G.__REMOTE_TEST_ARMED = true       -- explicit arming

    It never auto-targets. You choose a player by name or disguise:

        _G.__remoteForge.Status()
        _G.__remoteForge.Kill("<name>")      -- shoot
        _G.__remoteForge.Kill("<name>", "stab")
        _G.__remoteForge.Vote("<name>")
        _G.__remoteForge.SkipVote()
        _G.__remoteForge.Role()
        _G.__remoteForge.Intel()

    The exact wire shape was recovered from the game's own client code:
    the network wrapper serializes arguments as a table, so the raw calls are

        mafia.onShoot:InvokeServer({ targetPlayer })
        mafia.onStab:InvokeServer({ targetPlayer })
        gameService.votePlayer:FireServer({ targetPlayer })
        gameService.skipVote:FireServer({})

    Only use this on a server you control. It can get the account banned.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local lp = Players.LocalPlayer

local P = "[REMOTE-TEST]"
local API = {}

local function log(fmt, ...)
    print(P .. " " .. string.format(fmt, ...))
end

local function safeDump(value, depth)
    depth = depth or 0
    if depth > 4 then return "..." end
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for k, v in pairs(value) do
        parts[#parts + 1] = tostring(k) .. "=" .. safeDump(v, depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function invokeWithTimeout(remote, args, seconds)
    local done = false
    local ok, result = false, "timeout"
    task.spawn(function()
        local callOk, callResult = pcall(function() return remote:InvokeServer(args) end)
        ok = callOk
        result = callResult
        done = true
    end)
    local started = os.clock()
    while not done and os.clock() - started < (seconds or 2) do
        task.wait(0.05)
    end
    if not done then return false, "timeout" end
    return ok, result
end

local function serviceFolder(name)
    local networks = ReplicatedStorage:FindFirstChild("ServiceNetworks")
    return networks and networks:FindFirstChild(name) or nil
end

local function roleFolder(name)
    local networks = ReplicatedStorage:FindFirstChild("RoleNetworks")
    return networks and networks:FindFirstChild(name) or nil
end

local function remote(folder, name)
    local r = folder and folder:FindFirstChild(name)
    if not r then return nil end
    if not (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then return nil end
    return r
end

local function gameRemote(name)
    return remote(serviceFolder("gameService"), name)
end

local function mafiaRemote(name)
    return remote(roleFolder("mafia"), name)
end

local function witchRemote(name)
    return remote(roleFolder("witch"), name)
end

local function ensureServer()
    if game.PrivateServerId ~= "" then return true end
    if _G.__REMOTE_TEST_ALLOW_PUBLIC == true then return true end
    return false, "public server: set _G.__REMOTE_TEST_ALLOW_PUBLIC = true to override"
end

local function ensureArmed()
    if _G.__REMOTE_TEST_ARMED == true then return true end
    return false, "not armed: set _G.__REMOTE_TEST_ARMED = true first"
end

local function ensureReady()
    local ok, err = ensureServer()
    if not ok then return false, err end
    return ensureArmed()
end

local function roleName()
    local r = remote(serviceFolder("roleService"), "role")
    if not r then return nil end
    local ok, result = pcall(function() return r:InvokeServer() end)
    if not ok or type(result) ~= "table" then return nil end
    return result[1]
end

local function findTarget(query)
    if not query or query == "" then return nil, "empty target" end
    local needle = string.lower(tostring(query))
    for _, player in ipairs(Players:GetPlayers()) do
        local name = string.lower(player.Name)
        local display = string.lower(player.DisplayName or "")
        local disguise = string.lower(tostring(player:GetAttribute("DisguiseName") or ""))
        if name == needle or display == needle or disguise == needle then
            return player
        end
    end
    for _, player in ipairs(Players:GetPlayers()) do
        local name = string.lower(player.Name)
        local display = string.lower(player.DisplayName or "")
        local disguise = string.lower(tostring(player:GetAttribute("DisguiseName") or ""))
        if name:find(needle, 1, true) or display:find(needle, 1, true) or disguise:find(needle, 1, true) then
            return player
        end
    end
    return nil, "target not found: " .. tostring(query)
end

function API.Status()
    local phase = gameRemote("gamePhase")
    local canVote = gameRemote("canVote")
    local canSkip = gameRemote("canSkipVote")
    local out = {
        place = tostring(game.PlaceId),
        privateServer = game.PrivateServerId ~= "",
        armed = _G.__REMOTE_TEST_ARMED == true,
        role = roleName(),
        phase = phase and select(2, pcall(function() return phase:InvokeServer() end)) or nil,
        canVote = canVote and select(2, pcall(function() return canVote:InvokeServer() end)) or nil,
        canSkipVote = canSkip and select(2, pcall(function() return canSkip:InvokeServer() end)) or nil,
        players = {},
    }
    for _, player in ipairs(Players:GetPlayers()) do
        out.players[#out.players + 1] = {
            name = player.Name,
            disguise = player:GetAttribute("DisguiseName"),
            dead = player:GetAttribute("Dead"),
        }
    end
    log("status " .. safeDump(out))
    return out
end

function API.Intel()
    local night = gameRemote("nightTransition")
    local votes = gameRemote("talliedVotes")
    local out = {}
    if night then
        local ok, result = pcall(function() return night:InvokeServer() end)
        out.nightTransition = ok and result or tostring(result)
    end
    if votes then
        local ok, result = pcall(function() return votes:InvokeServer() end)
        out.talliedVotes = ok and result or tostring(result)
    end
    log("intel " .. safeDump(out))
    return out
end

function API.Role()
    local r = remote(serviceFolder("roleService"), "role")
    if not r then return nil, "role remote missing" end
    local ok, result = pcall(function() return r:InvokeServer() end)
    log("role " .. (ok and safeDump(result) or tostring(result)))
    return result
end

function API.Kill(query, mode)
    local ok, err = ensureReady()
    if not ok then return nil, err end
    if roleName() ~= "mafia" then return nil, "local role is not mafia" end

    local target, findErr = findTarget(query)
    if not target then return nil, findErr end
    if target == lp then return nil, "refusing self-target" end

    local name = mode == "stab" and "onStab" or "onShoot"
    local r = mafiaRemote(name)
    if not r then return nil, name .. " remote missing" end

    local invokeOk, result = pcall(function() return r:InvokeServer({ target }) end)
    log(string.format("kill mode=%s target=%s(%s) ok=%s result=%s",
        mode or "shoot", target.Name, tostring(target:GetAttribute("DisguiseName")),
        tostring(invokeOk), invokeOk and safeDump(result) or tostring(result)))
    return invokeOk, result
end

function API.Vote(query)
    local ok, err = ensureReady()
    if not ok then return nil, err end
    local target, findErr = findTarget(query)
    if not target then return nil, findErr end
    local r = gameRemote("votePlayer")
    if not r then return nil, "votePlayer remote missing" end
    local fireOk, fireErr = pcall(function() r:FireServer({ target }) end)
    log(string.format("vote target=%s(%s) ok=%s err=%s",
        target.Name, tostring(target:GetAttribute("DisguiseName")),
        tostring(fireOk), tostring(fireErr)))
    return fireOk, fireErr
end

function API.SkipVote()
    local ok, err = ensureReady()
    if not ok then return nil, err end
    local r = gameRemote("skipVote")
    if not r then return nil, "skipVote remote missing" end
    local fireOk, fireErr = pcall(function() r:FireServer({}) end)
    log("skipVote ok=" .. tostring(fireOk) .. " err=" .. tostring(fireErr))
    return fireOk, fireErr
end

local function witchEffectState(player)
    local out = {
        name = player.Name,
        disguise = player:GetAttribute("DisguiseName"),
    }
    for k, v in pairs(player:GetAttributes()) do
        local lk = string.lower(k)
        if lk:find("silenc", 1, true) or lk:find("mute", 1, true) or lk:find("witch", 1, true) then
            out[k] = tostring(v)
        end
    end
    local ch = player.Character
    if ch then
        for k, v in pairs(ch:GetAttributes()) do
            local lk = string.lower(k)
            if lk:find("silenc", 1, true) or lk:find("mute", 1, true) or lk:find("witch", 1, true) then
                out["char." .. k] = tostring(v)
            end
        end
    end
    local pg = player:FindFirstChild("PlayerGui")
    local timer = pg and pg:FindFirstChild("WitchTimer")
    if timer then out.WitchTimerEnabled = timer.Enabled end
    return out
end

function API.WitchStatus()
    local phase = gameRemote("gamePhase")
    local out = {
        role = roleName(),
        phase = phase and select(2, pcall(function() return phase:InvokeServer() end)) or nil,
        players = {},
    }
    local shared = ReplicatedStorage:FindFirstChild("shared")
    local configs = shared and shared:FindFirstChild("configurations")
    local roles = configs and configs:FindFirstChild("roles")
    if roles then
        local ok, cfg = pcall(function() return require(roles) end)
        if ok and type(cfg) == "table" and type(cfg.witch) == "table" then
            out.maxSilenceDistance = cfg.witch.maxSilenceDistance
        end
    end
    local myRoot = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    for _, player in ipairs(Players:GetPlayers()) do
        local ch = player.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        local row = witchEffectState(player)
        row.distance = myRoot and root and math.floor((root.Position - myRoot.Position).Magnitude + 0.5) or nil
        out.players[#out.players + 1] = row
    end
    log("witchStatus " .. safeDump(out))
    return out
end

local function castWitch(name, query)
    local ok, err = ensureReady()
    if not ok then return nil, err end
    if roleName() ~= "witch" then return nil, "local role is not witch" end
    local target, findErr = findTarget(query)
    if not target then return nil, findErr end
    if target == lp then return nil, "refusing self-target" end
    local r = witchRemote(name)
    if not r then return nil, name .. " remote missing" end
    local before = witchEffectState(target)
    local invokeOk, result = invokeWithTimeout(r, { target }, 2)
    task.wait(0.5)
    local after = witchEffectState(target)
    log(string.format("%s target=%s(%s) ok=%s result=%s before=%s after=%s",
        name, target.Name, tostring(target:GetAttribute("DisguiseName")),
        tostring(invokeOk), invokeOk and safeDump(result) or tostring(result),
        safeDump(before), safeDump(after)))
    return invokeOk, result
end

function API.Silence(query)
    return castWitch("onSilence", query)
end

function API.Bless(query)
    return castWitch("onBlessSixthSense", query)
end

function API.SilenceAll()
    if game.PrivateServerId == "" and _G.__REMOTE_TEST_ALLOW_PUBLIC ~= true then
        return nil, "mass silence requires a private server or _G.__REMOTE_TEST_ALLOW_PUBLIC = true"
    end
    if _G.__REMOTE_TEST_CONSENT ~= true then
        return nil, "mass silence requires _G.__REMOTE_TEST_CONSENT = true"
    end
    local ok, err = ensureArmed()
    if not ok then return nil, err end
    if roleName() ~= "witch" then return nil, "local role is not witch" end
    local r = witchRemote("onSilence")
    if not r then return nil, "onSilence remote missing" end

    local results = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp then
            local before = witchEffectState(player)
            local invokeOk, result = invokeWithTimeout(r, { player }, 2)
            task.wait(0.2)
            local after = witchEffectState(player)
            results[#results + 1] = {
                name = player.Name,
                disguise = player:GetAttribute("DisguiseName"),
                ok = invokeOk,
                result = invokeOk and safeDump(result) or tostring(result),
                before = before,
                after = after,
            }
            log(string.format("silenceAll %s(%s) ok=%s",
                player.Name, tostring(player:GetAttribute("DisguiseName")), tostring(invokeOk)))
        end
    end
    return results
end

_G.__remoteForge = API

log("loaded. set _G.__REMOTE_TEST_ARMED = true, then call _G.__remoteForge.Status()")
log("privateServer=" .. tostring(game.PrivateServerId ~= "") .. " place=" .. tostring(game.PlaceId))
