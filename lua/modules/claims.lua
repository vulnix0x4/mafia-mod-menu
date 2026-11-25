--!nocheck
--[[
    MAFIA - local role claims (no game data)

    A notebook for the user: assign a suspected role to each player. Nothing
    is sent to the server and nothing is read from the game's hidden roles.

    Data survives a module reload via _G.__mafiaClaimsStore.

    API: _G.__mafiaClaims
        .Roles()        -> ordered role list
        .Get(player)    -> claimed role or nil
        .Set(player, role)
        .Cycle(player, dir)  -- dir 1 / -1
        .Clear(player)
        .ClearAll()
        .Faction(role)
        .Stop()
]]

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaClaims
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local ROLES = {
    { name = "Civilian", faction = "Town" },
    { name = "Detective", faction = "Town" },
    { name = "Doctor", faction = "Town" },
    { name = "Janitor", faction = "Town" },
    { name = "Vigilante", faction = "Town" },
    { name = "Detainer", faction = "Town" },
    { name = "Suppressor", faction = "Town" },
    { name = "Judge", faction = "Town" },
    { name = "Mafia", faction = "Mafia" },
    { name = "Witch", faction = "Mafia" },
    { name = "Harbinger", faction = "Veil" },
    { name = "Mirage", faction = "Veil" },
    { name = "Poisoner", faction = "Veil" },
    { name = "Saboteur", faction = "Veil" },
    { name = "Bodyguard", faction = "Neutral" },
    { name = "Jester", faction = "Neutral" },
    { name = "Snow Spirit", faction = "Neutral" },
    { name = "Phantom", faction = "Neutral" },
}

local BY_NAME = {}
for i, role in ipairs(ROLES) do BY_NAME[role.name] = i end

local store = _G.__mafiaClaimsStore
if type(store) ~= "table" then
    store = {}
    _G.__mafiaClaimsStore = store
end

local function playerKey(player)
    return player.UserId or player.Name or tostring(player)
end

function API.Roles()
    return ROLES
end

function API.Get(player)
    if not player then return nil end
    return store[playerKey(player)]
end

function API.Set(player, role)
    if not player then return false, "no player" end
    if role == nil or role == "" then
        store[playerKey(player)] = nil
        return true
    end
    role = tostring(role)
    if not BY_NAME[role] then
        return false, "unknown role: " .. role
    end
    store[playerKey(player)] = role
    return true
end

function API.Cycle(player, dir)
    if not player then return nil end
    local key = playerKey(player)
    local current = store[key]
    local index = current and BY_NAME[current] or 0
    if not current then
        index = (dir or 1) < 0 and (#ROLES + 1) or 0
    end
    index = ((index - 1 + (dir or 1)) % #ROLES) + 1
    store[key] = ROLES[index].name
    return ROLES[index].name
end

function API.Clear(player)
    if player then store[playerKey(player)] = nil end
end

function API.ClearAll()
    for key in pairs(store) do store[key] = nil end
end

function API.Faction(role)
    local index = role and BY_NAME[role]
    return index and ROLES[index].faction or "Unknown"
end

function API.Stop()
    if _G.__mafiaClaims == API then
        _G.__mafiaClaims = nil
    end
end

_G.__mafiaClaims = API

local savedCount = 0
for _ in pairs(store) do savedCount = savedCount + 1 end
print("[MAFIA-CLAIMS] loaded - " .. #ROLES .. " roles, " .. savedCount .. " saved claims")
