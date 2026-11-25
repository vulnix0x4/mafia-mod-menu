--!nocheck
--[[
    MAFIA - Crime Lab / Behavioral Forensics (read-only)

    Infers suspects purely from replicated client state:
      1. Rolling 6s position history -> flags anyone near a victim at death/downed
      2. Animation & weapon fingerprinting -> flags KnifeSwing / Glock / Body carry
      3. Alibi & solo tracker -> generates a 1-click Day discussion report

    API: _G.__mafiaForensics
        .Suspect(player)   -> { score, badge, reasons } or nil
        .Badge(player)     -> short ESP tag string or nil
        .Suspects()        -> sorted array of flagged players
        .Incidents(n)      -> recent forensics events
        .Report()          -> multi-line Crime Lab summary
        .ChatReport()      -> compact single-line Day chat summary
        .Reset()
        .Stop()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaForensics
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local running = true
local HISTORY_WINDOW = 6.0
local SAMPLE_INTERVAL = 0.25
local KILL_LOOKBACK = 3.5
local KILL_RADIUS = 6.5
local CROWD_RADIUS = 12.0
local CLOSE_RADIUS = 3.5
local MAX_INCIDENTS = 40

local history = {}      -- [userId] = { { t, pos }, ... }
local prevDown = {}     -- [userId] = boolean
local flags = {}        -- [userId] = { [tag] = { tag, detail, at, weight } }
local incidents = {}    -- { { t, text }, ... }
local soloTicks = {}    -- [userId] = number
local togetherTicks = {} -- [pairKey] = { a, b, ticks }
local lastDay = nil
local lastPhase = nil

-- Map known incriminating animation IDs from ReplicatedStorage
local WATCH_ANIMS = {
    ["KnifeSwing"] = { tag = "KNIFE", weight = 100 },
    ["Glock"] = { tag = "GUN", weight = 85 },
    ["Picking Up Body"] = { tag = "BODY", weight = 95 },
    ["Putting Body In Clos"] = { tag = "BODY", weight = 95 },
}

local animIdMap = {}
local function loadAnimIds()
    local assets = ReplicatedStorage:FindFirstChild("assets")
    local anims = assets and assets:FindFirstChild("animations")
    local p1 = anims and anims:FindFirstChild("player1")
    if not p1 then return end
    for name, meta in pairs(WATCH_ANIMS) do
        local obj = p1:FindFirstChild(name)
        if obj and obj:IsA("Animation") and obj.AnimationId ~= "" then
            local num = obj.AnimationId:match("%d+")
            if num then animIdMap[num] = meta end
            animIdMap[obj.AnimationId] = meta
        end
    end
end
pcall(loadAnimIds)

local WEAPON_KEYWORDS = {
    { needle = "knife", tag = "KNIFE", weight = 100 },
    { needle = "stab", tag = "KNIFE", weight = 100 },
    { needle = "glock", tag = "GUN", weight = 85 },
    { needle = "gun", tag = "GUN", weight = 80 },
    { needle = "minigun", tag = "GUN", weight = 85 },
}

local function displayOf(player)
    if not player then return "?" end
    local disguise = player:GetAttribute("DisguiseName")
    if type(disguise) == "string" and #disguise > 0 then return disguise end
    return player.DisplayName ~= "" and player.DisplayName or player.Name
end

local function isDown(player)
    if not player then return true end
    if player:GetAttribute("Dead") == true then return true end
    local ch = player.Character
    if not ch then return true end
    if ch:GetAttribute("Downed") == true or ch:GetAttribute("Ragdolled") == true then return true end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    return not hum or hum.Health <= 0
end

local function pushIncident(text)
    incidents[#incidents + 1] = { t = os.clock(), text = text }
    while #incidents > MAX_INCIDENTS do
        table.remove(incidents, 1)
    end
    print("[MAFIA-LAB] " .. text)
end

local function addFlag(player, tag, detail, weight)
    if not player then return false end
    local uid = player.UserId
    local bucket = flags[uid]
    if not bucket then
        bucket = {}
        flags[uid] = bucket
    end
    local existing = bucket[tag]
    if existing then
        -- Keep higher weight / fresher detail
        if (weight or 0) > (existing.weight or 0) then
            existing.weight = weight
            existing.detail = detail
        end
        existing.at = os.clock()
        return false
    end
    bucket[tag] = {
        tag = tag,
        detail = detail or tag,
        weight = weight or 50,
        at = os.clock(),
    }
    return true
end

local function recordSample(uid, pos, now)
    local buf = history[uid]
    if not buf then
        buf = {}
        history[uid] = buf
    end
    buf[#buf + 1] = { t = now, pos = pos }
    local cutoff = now - HISTORY_WINDOW
    while #buf > 0 and buf[1].t < cutoff do
        table.remove(buf, 1)
    end
end

local function minDistanceDuring(uidA, uidB, sinceT, fallbackPosA)
    local bufA = history[uidA]
    local bufB = history[uidB]
    if not bufB or #bufB == 0 then return math.huge end

    local best = math.huge
    if bufA and #bufA > 0 then
        for i = #bufA, 1, -1 do
            local a = bufA[i]
            if a.t < sinceT then break end
            for j = #bufB, 1, -1 do
                local b = bufB[j]
                if b.t < sinceT then break end
                if math.abs(a.t - b.t) <= 0.4 then
                    local d = (a.pos - b.pos).Magnitude
                    if d < best then best = d end
                end
            end
        end
    end

    if fallbackPosA then
        for j = #bufB, 1, -1 do
            local b = bufB[j]
            if b.t < sinceT then break end
            local d = (fallbackPosA - b.pos).Magnitude
            if d < best then best = d end
        end
    end

    return best
end

local function analyzeDeath(victim, now)
    local vName = displayOf(victim)
    local vCh = victim.Character
    local vHrp = vCh and vCh:FindFirstChild("HumanoidRootPart")
    local vPos = vHrp and vHrp.Position or nil
    local sinceT = now - KILL_LOOKBACK

    local nearby = {}
    local crowdCount = 0
    for _, other in ipairs(Players:GetPlayers()) do
        if other ~= victim and other ~= lp then
            local d = minDistanceDuring(victim.UserId, other.UserId, sinceT, vPos)
            if d <= CROWD_RADIUS then
                crowdCount = crowdCount + 1
            end
            if d <= KILL_RADIUS then
                nearby[#nearby + 1] = { player = other, name = displayOf(other), dist = d }
            end
        end
    end

    table.sort(nearby, function(a, b) return a.dist < b.dist end)

    if #nearby == 0 then
        pushIncident(string.format("%s downed — no one within %.1fm", vName, KILL_RADIUS))
        return
    end

    -- Crowd suppression: when 3+ players are clustered (e.g. Main), don't
    -- paint the whole room orange. Only flag the single closest person if
    -- they were right on top of the victim (<= 3.5m) and clearly closer than #2.
    if crowdCount >= 3 then
        local first = nearby[1]
        local second = nearby[2]
        if first.dist <= CLOSE_RADIUS and (not second or second.dist - first.dist >= 1.5) then
            local detail = string.format("%.1fm at %s's death", first.dist, vName)
            addFlag(first.player, "NEAR_KILL", detail, 65)
            pushIncident(string.format("%s downed in crowd (%d) — closest: %s (%.1fm)",
                vName, crowdCount, first.name, first.dist))
        else
            pushIncident(string.format("%s downed in crowd (%d nearby) — no single suspect",
                vName, crowdCount))
        end
        return
    end

    local parts = {}
    for i = 1, math.min(#nearby, 2) do
        local entry = nearby[i]
        local w = entry.dist <= CLOSE_RADIUS and 80 or 55
        local detail = string.format("%.1fm at %s's death", entry.dist, vName)
        addFlag(entry.player, "NEAR_KILL", detail, w)
        parts[#parts + 1] = string.format("%s (%.1fm)", entry.name, entry.dist)
    end
    pushIncident(string.format("%s downed — near: %s", vName, table.concat(parts, ", ")))
end

local function scanAnimationsAndTools(player)
    if player == lp then return end
    local ch = player.Character
    if not ch then return end

    local hum = ch:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if animator then
        local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
        if ok and type(tracks) == "table" then
            for _, track in ipairs(tracks) do
                local anim = track.Animation
                local aid = anim and anim.AnimationId or ""
                local num = aid:match("%d+")
                local hit = animIdMap[aid] or (num and animIdMap[num])
                if not hit and track.Name then
                    local lower = track.Name:lower()
                    if lower:find("knife", 1, true) or lower:find("stab", 1, true) then
                        hit = { tag = "KNIFE", weight = 100 }
                    elseif lower:find("glock", 1, true) then
                        hit = { tag = "GUN", weight = 85 }
                    elseif lower:find("picking up body", 1, true) or lower:find("putting body", 1, true) then
                        hit = { tag = "BODY", weight = 95 }
                    end
                end
                if hit then
                    if addFlag(player, hit.tag, "anim: " .. hit.tag, hit.weight) then
                        pushIncident(string.format("SEEN %s [%s]", displayOf(player), hit.tag))
                    end
                end
            end
        end
    end

    for _, child in ipairs(ch:GetChildren()) do
        if child:IsA("Tool") or child:IsA("Model") then
            local lower = child.Name:lower()
            if lower ~= "flashlight" then
                for _, kw in ipairs(WEAPON_KEYWORDS) do
                    if lower:find(kw.needle, 1, true) then
                        if addFlag(player, kw.tag, "held: " .. child.Name, kw.weight) then
                            pushIncident(string.format("SEEN %s holding %s", displayOf(player), child.Name))
                        end
                        break
                    end
                end
            end
        end
    end
end

local function tick()
    local now = os.clock()
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

    if next(animIdMap) == nil then
        pcall(loadAnimIds)
    end

    local alivePositions = {}

    for _, player in ipairs(Players:GetPlayers()) do
        local uid = player.UserId
        local down = isDown(player)
        local wasDown = prevDown[uid]

        if wasDown == false and down == true then
            analyzeDeath(player, now)
        end
        prevDown[uid] = down

        if not down then
            local ch = player.Character
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            if hrp then
                local pos = hrp.Position
                recordSample(uid, pos, now)
                alivePositions[#alivePositions + 1] = { player = player, uid = uid, pos = pos }
            end
            scanAnimationsAndTools(player)
        end
    end

    -- Track alibi pairs & solo roamers
    for i = 1, #alivePositions do
        local a = alivePositions[i]
        local hasNeighbor = false
        for j = 1, #alivePositions do
            if i ~= j then
                local b = alivePositions[j]
                local d = (a.pos - b.pos).Magnitude
                if d <= 24 then hasNeighbor = true end
                if j > i and d <= 18 then
                    local lo, hi = math.min(a.uid, b.uid), math.max(a.uid, b.uid)
                    local key = tostring(lo) .. ":" .. tostring(hi)
                    local entry = togetherTicks[key]
                    if not entry then
                        entry = { a = a.player, b = b.player, ticks = 0 }
                        togetherTicks[key] = entry
                    end
                    entry.ticks = entry.ticks + 1
                end
            end
        end
        if not hasNeighbor then
            soloTicks[a.uid] = (soloTicks[a.uid] or 0) + 1
        end
    end
end

function API.Suspect(player)
    if not player then return nil end
    local bucket = flags[player.UserId]
    if not bucket or next(bucket) == nil then return nil end

    local bestWeight = 0
    local tags, reasons = {}, {}
    for _, f in pairs(bucket) do
        if f.weight > bestWeight then bestWeight = f.weight end
        tags[#tags + 1] = f.tag
        reasons[#reasons + 1] = f.detail
    end
    table.sort(tags)

    local badge = nil
    local tier = "suspect"
    if bucket.KNIFE then
        badge = "KILLER · KNIFE"
        tier = "confirmed"
    elseif bucket.BODY then
        badge = "KILLER · BODY"
        tier = "confirmed"
    elseif bucket.GUN then
        badge = "KILLER · GUN"
        tier = "confirmed"
    elseif bucket.NEAR_KILL then
        badge = "SUSPECT (" .. bucket.NEAR_KILL.detail:gsub(" at .+$", "") .. ")"
        tier = "suspect"
    else
        badge = "FLAG: " .. table.concat(tags, "/")
    end

    return {
        player = player,
        name = displayOf(player),
        score = bestWeight,
        tier = tier,
        badge = badge,
        tags = tags,
        reasons = reasons,
    }
end

function API.Badge(player)
    local s = API.Suspect(player)
    if not s then return nil, nil end
    return s.badge, s.tier
end

function API.Suspects()
    local out = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp then
            local s = API.Suspect(player)
            if s then out[#out + 1] = s end
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name:lower() < b.name:lower()
    end)
    return out
end

function API.Incidents(n)
    n = tonumber(n) or 6
    local start = math.max(1, #incidents - n + 1)
    local out = {}
    for i = start, #incidents do
        out[#out + 1] = incidents[i].text
    end
    return out
end

function API.Report()
    local lines = {}
    local suspects = API.Suspects()
    if #suspects > 0 then
        lines[#lines + 1] = "=== SUSPECTS ==="
        for _, s in ipairs(suspects) do
            lines[#lines + 1] = string.format("- %s: %s (%s)", s.name, s.badge, table.concat(s.reasons, "; "))
        end
    else
        lines[#lines + 1] = "=== SUSPECTS: none flagged yet ==="
    end

    local recent = API.Incidents(5)
    if #recent > 0 then
        lines[#lines + 1] = "=== TIMELINE ==="
        for _, line in ipairs(recent) do
            lines[#lines + 1] = "- " .. line
        end
    end

    -- Top alibi pair
    local bestPair = nil
    for _, entry in pairs(togetherTicks) do
        if entry.ticks >= 16 and (not bestPair or entry.ticks > bestPair.ticks) then
            bestPair = entry
        end
    end
    if bestPair then
        lines[#lines + 1] = string.format("=== ALIBI ===\n- %s & %s stayed together (%.0fs)",
            displayOf(bestPair.a), displayOf(bestPair.b), bestPair.ticks * SAMPLE_INTERVAL)
    end

    return table.concat(lines, "\n")
end

function API.ChatReport()
    local parts = {}
    local suspects = API.Suspects()
    for i = 1, math.min(#suspects, 3) do
        local s = suspects[i]
        parts[#parts + 1] = string.format("%s [%s]", s.name, s.badge)
    end
    if #parts == 0 then
        return "No suspects flagged yet."
    end
    return "Crime Lab: " .. table.concat(parts, " | ")
end

function API.Reset()
    history = {}
    prevDown = {}
    flags = {}
    incidents = {}
    soloTicks = {}
    togetherTicks = {}
end

function API.Stop()
    if _G.__mafiaForensics ~= API then return end
    running = false
    API.Reset()
    _G.__mafiaForensics = nil
end

_G.__mafiaForensics = API

task.spawn(function()
    while running do
        pcall(tick)
        task.wait(SAMPLE_INTERVAL)
    end
end)

print("[MAFIA-LAB] loaded - crime lab active")
