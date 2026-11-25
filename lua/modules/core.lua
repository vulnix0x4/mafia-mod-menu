--!nocheck
--[[
    MAFIA - core module

    Smallest possible foundation: identifies the experience, owns a version,
    and provides shared logging. No hooks, no loops, no game mutation.

    API: _G.__mafiaCore
        .Version   string
        .PlaceId   number
        .IsMafia() boolean      -- true when running in the target place
        .Log(...)  void         -- prints with the [MAFIA] prefix
]]

local PLACE_ID = 113232329524315
local LIVE_PLACE_ID = 83705601973004
local UNIVERSE_ID = 7497471789
local VERSION = "0.2.0"
local ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))

local old = _G.__mafiaCore
if old and old.ID ~= ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    print("[MAFIA] " .. table.concat(parts, " "))
end

local Core = {
    ID = ID,
    Version = VERSION,
    PlaceId = PLACE_ID,
}

function Core.IsMafia()
    return game.PlaceId == PLACE_ID
        or game.PlaceId == LIVE_PLACE_ID
        or game.GameId == UNIVERSE_ID
end

function Core.Log(...)
    log(...)
end

function Core.Stop()
    if _G.__mafiaCore == Core then
        _G.__mafiaCore = nil
    end
end

_G.__mafiaCore = Core

log("loaded - v" .. VERSION .. " (place " .. tostring(game.PlaceId) .. ", universe " .. tostring(game.GameId) .. ")")
if not Core.IsMafia() then
    warn("[MAFIA] not in the target universe (expected place " .. tostring(PLACE_ID) .. " or " .. tostring(LIVE_PLACE_ID) .. ") - tools will stay passive")
end
