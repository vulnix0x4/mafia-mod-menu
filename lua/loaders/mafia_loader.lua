--!nocheck
--[[
    MAFIA - suite loader

    One paste loads the whole menu straight from the local static server:

        loadstring(game:HttpGet("http://127.0.0.1:8766/lua/loaders/mafia_loader.lua"))()

    Order matters: modules publish their _G APIs, and menu.lua goes last so it
    can see all of them on its first refresh.

    Current modules:

        core.lua     -> _G.__mafiaCore      (place guard, logging, version)
        state.lua    -> _G.__mafiaState     (role/phase/player reader, read-only)
        flowlog.lua  -> _G.__mafiaFlowLog   (client event feed, read-only)
        claims.lua   -> _G.__mafiaClaims    (local role-claim notes)
        roles.lua    -> _G.__mafiaRoles     (passive role reveals + team tags)
        movement.lua -> _G.__mafiaMovement  (noclip/speed/fly/teleport, off by default)
        visuals.lua  -> _G.__mafiaVisuals   (fullbright/FOV, off by default)
        esp.lua      -> _G.__mafiaESP       (local name tags + highlight)
        hud.lua      -> _G.__mafiaHUD       (compact status strip)
        menu.lua     -> _G.__mafiaMenu      (GUI, last)

    Add new files to MODULES in load order. Re-running this file is safe as
    long as each module tears down its previous instance.
]]

local BASE = (type(_G.__MAFIA_BASE) == "string" and _G.__MAFIA_BASE ~= "")
    and _G.__MAFIA_BASE
    or "http://127.0.0.1:8766/"
if BASE:sub(-1) ~= "/" then BASE = BASE .. "/" end

local MODULES = {
    "lua/modules/core.lua",
    "lua/modules/state.lua",
    "lua/modules/flowlog.lua",
    "lua/modules/claims.lua",
    "lua/modules/roles.lua",
    "lua/modules/forensics.lua",
    "lua/modules/movement.lua",
    "lua/modules/visuals.lua",
    "lua/modules/esp.lua",
    "lua/modules/hud.lua",
    "lua/modules/config.lua",
    "lua/menu.lua",
}

local function fetchHttp(url)
    local reqUrl = url .. "?t=" .. tostring(os.time())

    local ok, body = pcall(function() return game:HttpGet(reqUrl) end)
    if ok and type(body) == "string" and #body > 0 then
        return body
    end

    local reqFn = request or http_request or (syn and syn.request) or (http and http.request)
    if type(reqFn) == "function" then
        local ok2, res = pcall(reqFn, { Url = reqUrl, Method = "GET" })
        if ok2 and type(res) == "table" and type(res.Body) == "string" and #res.Body > 0 then
            return res.Body
        end
    end

    return nil, tostring(body)
end

local loaded, failed = 0, 0

for _, name in ipairs(MODULES) do
    local src, fetchErr = fetchHttp(BASE .. name)

    if not src then
        failed = failed + 1
        warn(string.format("[MAFIA-LOADER] %s: fetch failed (%s) - is the server on 8766 running?", name, fetchErr))
    else
        local fn, compileErr = loadstring(src, "=" .. name)
        if not fn then
            failed = failed + 1
            warn(string.format("[MAFIA-LOADER] %s: compile failed (%s)", name, tostring(compileErr)))
        else
            local ok, runErr = pcall(fn)
            if ok then
                loaded = loaded + 1
            else
                failed = failed + 1
                warn(string.format("[MAFIA-LOADER] %s: runtime error (%s)", name, tostring(runErr)))

                -- A failed menu build must not leave a half-finished window
                -- covering the screen with no drag/close handlers.
                if name == "lua/menu.lua" then
                    local Players = game:GetService("Players")
                    local lp = Players.LocalPlayer
                    local pg = lp and lp:FindFirstChild("PlayerGui")
                    if pg then
                        for _, gui in ipairs(pg:GetChildren()) do
                            if gui.Name == "MafiaMenu" then
                                pcall(function() gui:Destroy() end)
                            end
                        end
                    end
                end
            end
        end
    end
end

print(string.format("[MAFIA-LOADER] %d loaded, %d failed", loaded, failed))
