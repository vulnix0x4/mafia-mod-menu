--!nocheck
--[[
    MAFIA - persistent config profiles + auto-reinject (queue_on_teleport)

    Saves ESP/HUD/FOV/movement-speed preferences to disk via writefile/readfile
    and queues the loader across server teleports (lobby <-> round).

    API: _G.__mafiaConfig
        .Save()
        .Load()
        .Reset()
        .AutoReinject() / .SetAutoReinject(bool)
        .ArmTeleport()
        .Stop()
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local lp = Players.LocalPlayer

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaConfig
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local FOLDER = "mafia_toolkit"
local FILE = FOLDER .. "/profile.json"
local autoReinject = true
local teleportConn = nil

local function canIO()
    return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end

local function queueFn()
    return queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
end

local function loaderPayload()
    local base = (type(_G.__MAFIA_BASE) == "string" and _G.__MAFIA_BASE ~= "")
        and _G.__MAFIA_BASE
        or "http://127.0.0.1:8766/"
    if base:sub(-1) ~= "/" then base = base .. "/" end
    return string.format(
        'task.wait(1.5)\n_G.__MAFIA_BASE = %q\nloadstring(game:HttpGet(%q))()',
        base,
        base .. "lua/loaders/mafia_loader.lua"
    )
end

function API.ArmTeleport()
    if not autoReinject then return false, "auto-reinject off" end
    local q = queueFn()
    if type(q) ~= "function" then return false, "queue_on_teleport unavailable" end
    if _G.__mafiaTeleportArmed then return true, "already armed" end
    local ok, err = pcall(q, loaderPayload())
    if ok then
        _G.__mafiaTeleportArmed = true
        print("[MAFIA-CFG] auto-reinject armed for next teleport")
        return true, "armed"
    end
    return false, tostring(err)
end

local function collectState()
    local data = {
        version = API.Version,
        autoReinject = autoReinject,
    }
    local esp = _G.__mafiaESP
    if esp and type(esp.Options) == "function" then
        data.esp = esp.Options()
    end
    local move = _G.__mafiaMovement
    if move and type(move.Status) == "function" then
        local st = move.Status()
        data.movement = {
            multiplier = st.multiplier,
            flySpeed = st.flySpeed,
            scale = st.scale,
        }
    end
    local visuals = _G.__mafiaVisuals
    if visuals and type(visuals.FOV) == "function" then
        data.visuals = {
            fov = visuals.FOV(),
        }
    end
    local hud = _G.__mafiaHUD
    if hud and type(hud.Enabled) == "function" then
        data.hud = {
            enabled = hud.Enabled(),
        }
    end
    return data
end

local function applyState(data)
    if type(data) ~= "table" then return end
    if type(data.autoReinject) == "boolean" then
        autoReinject = data.autoReinject
    end
    local esp = _G.__mafiaESP
    if esp and type(data.esp) == "table" and type(esp.SetOption) == "function" then
        for k, v in pairs(data.esp) do
            pcall(esp.SetOption, k, v)
        end
    end
    local move = _G.__mafiaMovement
    if move and type(data.movement) == "table" then
        if data.movement.multiplier and type(move.SetMultiplier) == "function" then
            pcall(move.SetMultiplier, data.movement.multiplier)
        end
        if data.movement.flySpeed and type(move.SetFlySpeed) == "function" then
            pcall(move.SetFlySpeed, data.movement.flySpeed)
        end
    end
    local visuals = _G.__mafiaVisuals
    if visuals and type(data.visuals) == "table" then
        if data.visuals.fov and data.visuals.fov ~= 70 and type(visuals.SetFOV) == "function" then
            pcall(visuals.SetFOV, data.visuals.fov)
        end
    end
    local hud = _G.__mafiaHUD
    if hud and type(data.hud) == "table" and type(data.hud.enabled) == "boolean" and type(hud.Set) == "function" then
        pcall(hud.Set, data.hud.enabled)
    end
end

function API.Save()
    if not canIO() then return false, "filesystem API unavailable" end
    if type(makefolder) == "function" and (type(isfolder) ~= "function" or not isfolder(FOLDER)) then
        pcall(makefolder, FOLDER)
    end
    local okEnc, json = pcall(function() return HttpService:JSONEncode(collectState()) end)
    if not okEnc then return false, tostring(json) end
    local okWrite, err = pcall(writefile, FILE, json)
    if not okWrite then return false, tostring(err) end
    return true, FILE
end

function API.Load()
    if not canIO() then return false, "filesystem API unavailable" end
    local okExists, exists = pcall(isfile, FILE)
    if not okExists or not exists then return false, "no saved profile" end
    local okRead, raw = pcall(readfile, FILE)
    if not okRead or type(raw) ~= "string" or raw == "" then return false, "read failed" end
    local okDec, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not okDec or type(data) ~= "table" then return false, "invalid json" end
    applyState(data)
    return true, FILE
end

function API.Reset()
    autoReinject = true
    if type(delfile) == "function" and type(isfile) == "function" then
        pcall(function()
            if isfile(FILE) then delfile(FILE) end
        end)
    end
    return true
end

function API.AutoReinject()
    return autoReinject == true
end

function API.SetAutoReinject(on)
    autoReinject = on == true
    if autoReinject then
        API.ArmTeleport()
    end
    API.Save()
    return autoReinject
end

function API.Stop()
    if _G.__mafiaConfig ~= API then return end
    if teleportConn then
        pcall(function() teleportConn:Disconnect() end)
        teleportConn = nil
    end
    _G.__mafiaConfig = nil
end

_G.__mafiaConfig = API

if lp then
    local ok, conn = pcall(function()
        return lp.OnTeleport:Connect(function(state)
            if autoReinject and state == Enum.TeleportState.Started then
                API.ArmTeleport()
            end
        end)
    end)
    if ok then teleportConn = conn end
end

local loaded = API.Load()
if autoReinject then
    API.ArmTeleport()
end

print(string.format("[MAFIA-CFG] loaded - profile=%s autoReinject=%s",
    loaded and "restored" or "defaults", tostring(autoReinject)))
