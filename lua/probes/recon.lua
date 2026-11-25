--!nocheck
--[[
    MAFIA - one-shot reconnaissance dump

    Run once in the lobby and once during a live round:

        loadstring(game:HttpGet("http://127.0.0.1:8766/lua/probes/recon.lua"))()

    Prints, with the [MAFIA-RECON] prefix:

        - place / job / player identity and team
        - character state and attributes
        - ReplicatedStorage layout
        - Workspace top-level layout
        - every RemoteEvent / RemoteFunction / UnreliableRemoteEvent
        - PlayerGui screen hierarchy
        - player attributes and value objects
        - Teams

    Output is capped so a big map cannot flood the console. Copy the console
    to docs/recon-lobby.txt or docs/recon-round.txt after each run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local P = "[MAFIA-RECON]"
local MAX = 120

local function log(fmt, ...)
    print(P .. " " .. string.format(fmt, ...))
end

local function nameOf(inst)
    return inst.ClassName .. " " .. inst.Name
end

local function dumpChildren(container, label, limit)
    log("%s (%d):", label, #container:GetChildren())
    local n = 0
    for _, child in ipairs(container:GetChildren()) do
        n = n + 1
        if n > (limit or MAX) then
            log("  ... truncated")
            break
        end
        log("  %s", nameOf(child))
    end
end

log("place=%d job=%s players=%d", game.PlaceId, tostring(game.JobId), #Players:GetPlayers())

local lp = Players.LocalPlayer
if lp then
    local ch = lp.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    log("local=%s team=%s character=%s", lp.Name, lp.Team and lp.Team.Name or "none", ch and ch.Name or "none")
    if root then
        log("position=%.1f, %.1f, %.1f", root.Position.X, root.Position.Y, root.Position.Z)
    end
    if hum then
        log("humanoid health=%.0f state=%s", hum.Health, tostring(hum:GetState()))
    end

    log("player attributes:")
    for k, v in pairs(lp:GetAttributes()) do
        log("  %s = %s", tostring(k), tostring(v))
    end

    log("player value objects:")
    for _, child in ipairs(lp:GetChildren()) do
        if child:IsA("ValueBase") then
            log("  %s %s = %s", child.ClassName, child.Name, tostring(child.Value))
        end
    end

    log("leaderstats:")
    local stats = lp:FindFirstChild("leaderstats")
    if stats then
        for _, stat in ipairs(stats:GetChildren()) do
            if stat:IsA("ValueBase") then
                log("  %s = %s", stat.Name, tostring(stat.Value))
            end
        end
    end

    local pg = lp:FindFirstChild("PlayerGui")
    if pg then
        dumpChildren(pg, "PlayerGui", 40)
        for _, gui in ipairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") then
                dumpChildren(gui, "ScreenGui " .. gui.Name, 30)
            end
        end
    end
end

dumpChildren(ReplicatedStorage, "ReplicatedStorage")
dumpChildren(Workspace, "Workspace top level", 80)

log("remotes:")
local seen, total = {}, 0
local roots = { ReplicatedStorage, Workspace }
for _, root in ipairs(roots) do
    for _, inst in ipairs(root:GetDescendants()) do
        total = total + 1
        if total > 5000 then break end
        local cls = inst.ClassName
        if cls == "RemoteEvent" or cls == "RemoteFunction" or cls == "UnreliableRemoteEvent" then
            local key = inst:GetFullName()
            if not seen[key] then
                seen[key] = true
                log("  %s %s", cls, key)
            end
        end
    end
    if total > 5000 then break end
end
log("  scanned %d descendants", total)

log("teams:")
for _, team in ipairs(Teams:GetTeams()) do
    log("  %s (%d players)", team.Name, #team:GetPlayers())
end

log("done")
