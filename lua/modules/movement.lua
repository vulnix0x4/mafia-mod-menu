--!nocheck
--[[
    MAFIA - client-side movement (off by default)

    Noclip, speed, the game's own fly/ghost controller, teleport, spinbot,
    self-ragdoll, animation spam and character scale. These change only your
    local character; the server may validate movement, so treat them as
    experimental. Nothing is enabled until the user toggles it.

    API: _G.__mafiaMovement
        .Noclip() / .SetNoclip(bool) / .ToggleNoclip()
        .Speed()  / .SetSpeed(bool)  / .ToggleSpeed()
        .Multiplier() / .SetMultiplier(n)
        .Fly() / .SetFly(bool) / .ToggleFly()
        .TeleportToNearestPlayer() / .TeleportToPlayer(query) / .TeleportToCursor()
        .Spin() / .SetSpin(bool) / .ToggleSpin()
        .Ragdoll() / .SetRagdoll(bool) / .ToggleRagdoll()
        .EmoteSpam() / .SetEmoteSpam(bool) / .ToggleEmoteSpam()
        .Scale() / .SetScale(n)
        .Status()
        .Stop()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local VirtualInputManager = nil
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)
local lp = Players.LocalPlayer

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaMovement
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

-- The game's noclipController has the right movement feel, but calling its
-- setEnabled() from an executor context fails on an internal require. Keep a
-- reference only to clear any half-enabled state, then use our own anchored
-- CFrame flight below.
local noclipController = nil
local controllers = ReplicatedStorage:FindFirstChild("client")
    and ReplicatedStorage.client:FindFirstChild("controllers")
if controllers then
    local module = controllers:FindFirstChild("noclipController")
    if module then
        local ok, result = pcall(require, module)
        if ok and type(result) == "table" and type(result.setEnabled) == "function" then
            noclipController = result
            pcall(function() noclipController.setEnabled(false) end)
        end
    end
end

local playerAnimations = ReplicatedStorage:FindFirstChild("assets")
    and ReplicatedStorage.assets:FindFirstChild("animations")
    and ReplicatedStorage.assets.animations:FindFirstChild("player1")

local CONFIG = {
    noclip = false,
    speed = false,
    multiplier = 5.0,
    fly = false,
    flySpeed = 50,
    spin = false,
    spinSpeed = 720,
    ragdoll = false,
    emoteSpam = false,
    scale = 1.0,
}

local running = true
local savedParts = {}
local trackedCharacter = nil
local baseWalk = nil
local baseScale = nil
local baseAutoRotate = nil
local spinConn = nil
local emoteGen = 0
local currentEmote = nil
local flyConn = nil
local flyBaseAnchored = nil
local killBusy = false
local selectedKillUserId = nil

local EMOTE_NAMES = {
    "KnifeSwing",
    "Glock",
    "Falling From Gunshot",
    "Falling From Stab",
    "Wounded Idle",
    "Wounded Crawling",
    "FlashlightToggle",
    "Opening Door",
    "Closing Door",
    "Picking Up Body",
    "Putting Body In Clos",
    "Idle",
    "Walk",
}

local function character()
    return lp and lp.Character or nil
end

local function humanoid()
    local ch = character()
    return ch and ch:FindFirstChildOfClass("Humanoid") or nil
end

local function root()
    local ch = character()
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function applyScale()
    local ch = character()
    if not ch or not baseScale then return end
    pcall(function() ch:ScaleTo(baseScale * CONFIG.scale) end)
end

local function restoreScale()
    local ch = character()
    if not ch or not baseScale then return end
    pcall(function() ch:ScaleTo(baseScale) end)
end

local function applyRagdoll()
    local hum = humanoid()
    if not hum then return end
    hum:ChangeState(Enum.HumanoidStateType.Ragdoll)
    hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
    hum.PlatformStand = true
end

local function restoreRagdoll()
    local hum = humanoid()
    if not hum then return end
    hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
    hum.PlatformStand = false
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
end

local function captureCharacter()
    local ch = character()
    if ch == trackedCharacter then return end
    trackedCharacter = ch
    if flyConn then flyBaseAnchored = false end
    savedParts = {}
    baseWalk = nil
    baseScale = nil
    baseAutoRotate = nil

    local hum = humanoid()
    if hum then
        baseWalk = hum.WalkSpeed
        local okScale, sc = pcall(function() return ch:GetScale() end)
        baseScale = okScale and sc or 1
        baseAutoRotate = hum.AutoRotate
        if CONFIG.spin or CONFIG.fly then hum.AutoRotate = false end
        if CONFIG.scale ~= 1 then applyScale() end
        if CONFIG.ragdoll then applyRagdoll() end
    end
end

local function applyNoclip()
    local ch = character()
    if not ch then return end
    for _, part in ipairs(ch:GetDescendants()) do
        if part:IsA("BasePart") then
            if savedParts[part] == nil then
                savedParts[part] = part.CanCollide
            end
            part.CanCollide = false
        end
    end
end

local function restoreNoclip()
    for part, value in pairs(savedParts) do
        if part and part.Parent then
            pcall(function() part.CanCollide = value end)
        end
    end
    savedParts = {}
end

local function applySpeed()
    local hum = humanoid()
    if not hum then return end
    if baseWalk == nil then baseWalk = hum.WalkSpeed end
    hum.WalkSpeed = baseWalk * CONFIG.multiplier
end

local function restoreSpeed()
    local hum = humanoid()
    if hum and baseWalk ~= nil then
        pcall(function() hum.WalkSpeed = baseWalk end)
    end
    baseWalk = nil
end

local function flyMoveVector()
    local override = _G.__MAFIA_FLY_TEST_VECTOR
    if typeof(override) == "Vector3" then return override end
    local x, z = 0, 0
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then z = z - 1 end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then z = z + 1 end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then x = x - 1 end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then x = x + 1 end
    local move = Vector3.new(x, 0, z)
    if move.Magnitude > 0 then
        local camera = Workspace.CurrentCamera
        if camera then
            local look = camera.CFrame.LookVector
            local right = camera.CFrame.RightVector
            local forward = Vector3.new(look.X, 0, look.Z)
            local side = Vector3.new(right.X, 0, right.Z)
            if forward.Magnitude > 0 and side.Magnitude > 0 then
                move = (forward.Unit * -z + side.Unit * x).Unit
            end
        end
    end
    return move
end

local function startFly()
    local hum = humanoid()
    local hrp = root()
    if not hum or not hrp then return false, "no character" end
    if flyConn then return true end
    flyBaseAnchored = hrp.Anchored
    if baseAutoRotate == nil then baseAutoRotate = hum.AutoRotate end
    hum.AutoRotate = false
    hrp.Anchored = true
    flyConn = RunService.RenderStepped:Connect(function(dt)
        if not CONFIG.fly then return end
        local h = humanoid()
        local r = root()
        if not h or not r then return end
        if not r.Anchored then r.Anchored = true end
        if UserInputService:GetFocusedTextBox() then return end
        local move = flyMoveVector()
        local up = 0
        if UserInputService:IsKeyDown(Enum.KeyCode.Space)
            or UserInputService:IsKeyDown(Enum.KeyCode.E) then
            up = up + 1
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.C)
            or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
            or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
            up = up - 1
        end
        local dir = move + Vector3.new(0, up, 0)
        if dir.Magnitude > 1 then dir = dir.Unit end
        local speed = CONFIG.flySpeed
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
            speed = speed * 3
        end
        local delta = dir * speed * dt
        if delta.Magnitude > 0 then
            local yaw = 0
            local camera = Workspace.CurrentCamera
            if camera then
                local _, cameraYaw = camera.CFrame:ToEulerAnglesYXZ()
                yaw = cameraYaw
            end
            r.CFrame = CFrame.new(r.Position + delta) * CFrame.Angles(0, yaw, 0)
        end
    end)
    return true
end

local function stopFly()
    if flyConn then
        flyConn:Disconnect()
        flyConn = nil
    end
    local hum = humanoid()
    local hrp = root()
    if hrp then
        pcall(function()
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
        if flyBaseAnchored ~= nil then
            hrp.Anchored = flyBaseAnchored
        end
    end
    if hum and not CONFIG.spin and baseAutoRotate ~= nil then
        hum.AutoRotate = baseAutoRotate
    end
    flyBaseAnchored = nil
end

local function setRootCFrame(cf)
    local hum = humanoid()
    local hrp = root()
    if not hum or not hrp then return false, "no character" end
    hum.Sit = false
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    hrp.CFrame = cf
    return true
end

local function startSpin()
    if spinConn then return end
    local hum = humanoid()
    if hum then
        if baseAutoRotate == nil then baseAutoRotate = hum.AutoRotate end
        hum.AutoRotate = false
    end
    spinConn = RunService.RenderStepped:Connect(function(dt)
        if not CONFIG.spin then return end
        local hrp = root()
        if hrp then
            hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(CONFIG.spinSpeed) * dt, 0)
        end
    end)
end

local function stopSpin()
    if spinConn then
        spinConn:Disconnect()
        spinConn = nil
    end
    local hum = humanoid()
    if hum and not CONFIG.fly and baseAutoRotate ~= nil then
        hum.AutoRotate = baseAutoRotate
    end
end

local function stopCurrentEmote()
    if currentEmote then
        pcall(function() currentEmote:Stop() end)
        currentEmote = nil
    end
end

local function startEmoteSpam()
    emoteGen = emoteGen + 1
    local myGen = emoteGen
    task.spawn(function()
        while CONFIG.emoteSpam and running and emoteGen == myGen do
            local hum = humanoid()
            local animator = hum and hum:FindFirstChildOfClass("Animator")
            if animator and playerAnimations then
                local name = EMOTE_NAMES[math.random(1, #EMOTE_NAMES)]
                local asset = playerAnimations:FindFirstChild(name)
                if asset then
                    local ok, track = pcall(function() return animator:LoadAnimation(asset) end)
                    if ok and track then
                        stopCurrentEmote()
                        track.Looped = false
                        track:Play()
                        currentEmote = track
                    end
                end
            end
            task.wait(0.7)
        end
        if emoteGen == myGen then
            stopCurrentEmote()
        end
    end)
end

function API.Noclip()
    return CONFIG.noclip == true
end

function API.SetNoclip(on)
    CONFIG.noclip = on == true
    if CONFIG.noclip then
        applyNoclip()
    else
        restoreNoclip()
    end
    return true
end

function API.ToggleNoclip()
    return API.SetNoclip(not CONFIG.noclip)
end

function API.Speed()
    return CONFIG.speed == true
end

function API.SetSpeed(on)
    CONFIG.speed = on == true
    if CONFIG.speed then
        applySpeed()
    else
        restoreSpeed()
    end
    return true
end

function API.ToggleSpeed()
    return API.SetSpeed(not CONFIG.speed)
end

function API.Multiplier()
    return CONFIG.multiplier
end

function API.SetMultiplier(value)
    local n = tonumber(value) or CONFIG.multiplier
    CONFIG.multiplier = math.clamp(n, 1, 5)
    if CONFIG.speed then applySpeed() end
    return CONFIG.multiplier
end

function API.Fly()
    return CONFIG.fly == true
end

function API.SetFly(on)
    CONFIG.fly = on == true
    if CONFIG.fly then
        if CONFIG.ragdoll then
            API.SetRagdoll(false)
        end
        local ok, err = startFly()
        if not ok then
            CONFIG.fly = false
            error(err)
        end
    else
        stopFly()
    end
    return CONFIG.fly
end

function API.ToggleFly()
    return API.SetFly(not CONFIG.fly)
end

function API.FlySpeed()
    return CONFIG.flySpeed
end

function API.SetFlySpeed(value)
    local n = tonumber(value) or CONFIG.flySpeed
    CONFIG.flySpeed = math.clamp(n, 15, 200)
    return CONFIG.flySpeed
end

function API.TeleportToNearestPlayer()
    local myRoot = root()
    if not myRoot then return false, "no character" end
    local best, bestDist, bestName = nil, nil, nil
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and player:GetAttribute("Dead") ~= true and player.Character then
            local hum = player.Character:FindFirstChildOfClass("Humanoid")
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")
            if hum and hum.Health > 0 and hrp then
                local dist = (hrp.Position - myRoot.Position).Magnitude
                if not bestDist or dist < bestDist then
                    best, bestDist = hrp, dist
                    bestName = player:GetAttribute("DisguiseName") or player.Name
                end
            end
        end
    end
    if not best then return false, "no alive players" end
    local ok, err = setRootCFrame(CFrame.new(best.Position + Vector3.new(0, 0, 3)))
    return ok, ok and bestName or err
end

function API.TeleportToPlayer(query)
    if not query or query == "" then
        return API.TeleportToNearestPlayer()
    end
    local needle = string.lower(tostring(query))
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and player:GetAttribute("Dead") ~= true then
            local name = string.lower(player.Name)
            local rawDisguise = player:GetAttribute("DisguiseName")
            local disguise = type(rawDisguise) == "string" and string.lower(rawDisguise) or ""
            if name:find(needle, 1, true) or (disguise ~= "" and disguise:find(needle, 1, true)) then
                local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                if hum and hum.Health > 0 and hrp then
                    local ok, err = setRootCFrame(CFrame.new(hrp.Position + Vector3.new(0, 0, 3)))
                    return ok, ok and (rawDisguise or player.Name) or err
                end
            end
        end
    end
    return false, "target not found"
end

function API.TeleportToCursor()
    local ch = character()
    if not ch then return false, "no character" end
    local camera = Workspace.CurrentCamera
    if not camera then return false, "no camera" end
    local mouse = UserInputService:GetMouseLocation()
    local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { ch }
    local result = Workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
    local pos = result and result.Position or (ray.Origin + ray.Direction * 200)
    local ok, err = setRootCFrame(CFrame.new(pos + Vector3.new(0, 3, 0)))
    return ok, err
end

local function tapKey(keyCode)
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.05)
            VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
        end)
    end
end

local function getController(name)
    local client = ReplicatedStorage:FindFirstChild("client")
    local ctrls = client and client:FindFirstChild("controllers")
    local mod = ctrls and ctrls:FindFirstChild(name)
    if not mod then return nil end
    local ok, ctrl = pcall(require, mod)
    return ok and type(ctrl) == "table" and ctrl or nil
end

local function triggerEmp()
    local empCtrl = getController("empController")
    if empCtrl and type(empCtrl.requestDetonate) == "function" then
        pcall(empCtrl.requestDetonate)
    end
    local inputCtrl = getController("inputController")
    local roleCtrl = getController("roleController")
    local role = roleCtrl and type(roleCtrl.getCurrentRole) == "function" and roleCtrl.getCurrentRole() or "mafia"
    if inputCtrl and type(inputCtrl.triggerAction) == "function" then
        pcall(inputCtrl.triggerAction, "roles", role, "emp")
    end
    tapKey(Enum.KeyCode.G)
end

local function getRoleModule(roleId)
    local client = ReplicatedStorage:FindFirstChild("client")
    local ctrls = client and client:FindFirstChild("controllers")
    local rc = ctrls and ctrls:FindFirstChild("roleController")
    local roles = rc and rc:FindFirstChild("roles")
    local mod = roles and roles:FindFirstChild(roleId)
    if not mod then return nil end
    local ok, ctrl = pcall(require, mod)
    return ok and type(ctrl) == "table" and ctrl or nil
end

local function currentRoleId()
    local roleCtrl = getController("roleController")
    if roleCtrl and type(roleCtrl.getCurrentRole) == "function" then
        local ok, r = pcall(roleCtrl.getCurrentRole)
        if ok and type(r) == "string" and r ~= "" then return r:lower() end
    end
    local rolesApi = _G.__mafiaRoles
    if rolesApi and type(rolesApi.CurrentRoleId) == "function" then
        local ok, r = pcall(rolesApi.CurrentRoleId)
        if ok and type(r) == "string" and r ~= "" then return r:lower() end
    end
    return nil
end

local function triggerRoleAction(roleId, actionName, fallbackKey)
    local inputCtrl = getController("inputController")
    if inputCtrl and type(inputCtrl.triggerAction) == "function" then
        pcall(inputCtrl.triggerAction, "roles", roleId, actionName)
    end
    if fallbackKey then tapKey(fallbackKey) end
end

local function triggerKnife(targetChar)
    local mafiaRole = getRoleModule("mafia")
    if mafiaRole and targetChar and type(mafiaRole.setTargetCharacter) == "function" then
        pcall(mafiaRole.setTargetCharacter, targetChar, true)
    end
    triggerRoleAction("mafia", "stab", Enum.KeyCode.R)
end

local function isBlackoutActive()
    local client = ReplicatedStorage:FindFirstChild("client")
    local mods = client and client:FindFirstChild("modules")
    local mod = mods and mods:FindFirstChild("empBlackoutBus")
    if not mod then return false end
    local ok, bus = pcall(require, mod)
    if ok and type(bus) == "table" and type(bus.get) == "function" then
        local ok2, val = pcall(bus.get)
        return ok2 and val == true
    end
    return false
end

local function isTargetDown(player)
    if not player or not player.Parent then return true end
    if player:GetAttribute("Dead") == true then return true end
    local ch = player.Character
    if not ch or not ch.Parent then return true end
    if ch:GetAttribute("Downed") == true or ch:GetAttribute("Ragdolled") == true then return true end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return true end
    return false
end

local function isMafiaTeammate(player)
    if not player then return false end
    local esp = _G.__mafiaESP
    if esp and type(esp.IsTeammate) == "function" then
        local ok, res = pcall(esp.IsTeammate, player)
        if ok and res == true then return true end
    end
    local roles = _G.__mafiaRoles
    if roles then
        if type(roles.Team) == "function" then
            local ok, team = pcall(roles.Team)
            if ok and type(team) == "table" then
                for _, m in ipairs(team) do
                    if m.player == player or (m.player and m.player.UserId == player.UserId) then
                        return true
                    end
                end
            end
        end
        if type(roles.Get) == "function" then
            local ok, role = pcall(roles.Get, player)
            if ok and (role == "Mafia" or role == "Witch") then
                return true
            end
        end
    end
    local ch = player.Character
    if ch then
        for _, child in ipairs(ch:GetChildren()) do
            if child:IsA("Highlight") and child.Enabled and child.Name:lower():find("teammate", 1, true) then
                return true
            end
        end
    end
    return false
end

local function findIsolatedTarget(originPos)
    local roles = _G.__mafiaRoles
    if roles and type(roles.ScanHighlights) == "function" then
        pcall(roles.ScanHighlights)
    end

    local candidates = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and not isTargetDown(player) then
            local isTeam = isMafiaTeammate(player)
            local ch = player.Character
            local parentName = ch and ch.Parent and ch.Parent.Name or ""
            local jailed = parentName == "jail" or parentName == "detain" or parentName == "detainerJail"
            if not isTeam and not jailed and ch then
                local hrp = ch:FindFirstChild("HumanoidRootPart")
                if hrp then
                    candidates[#candidates + 1] = {
                        player = player,
                        hrp = hrp,
                        pos = hrp.Position,
                        myDist = (hrp.Position - originPos).Magnitude,
                    }
                end
            end
        end
    end

    if #candidates == 0 then return nil, nil, 0, 0 end

    local best, bestScore = nil, -1
    for i = 1, #candidates do
        local c = candidates[i]
        local nearestWitness = 999
        for j = 1, #candidates do
            if i ~= j then
                local d = (c.pos - candidates[j].pos).Magnitude
                if d < nearestWitness then nearestWitness = d end
            end
        end
        -- Strongly prefer isolated targets (far from any witness), then far from us
        local score = math.min(nearestWitness, 120) * 2.5 + math.min(c.myDist, 200) * 0.6
        c.witnessDist = nearestWitness
        if score > bestScore then
            best, bestScore = c, score
        end
    end

    return best.player, best.hrp, best.myDist, best.witnessDist
end

function API.KillBusy()
    return killBusy == true
end

function API.KillCandidates()
    local roles = _G.__mafiaRoles
    if roles and type(roles.ScanHighlights) == "function" then
        pcall(roles.ScanHighlights)
    end
    local myRoot = root()
    local myPos = myRoot and myRoot.Position or nil
    local out = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and not isTargetDown(player) and not isMafiaTeammate(player) then
            local ch = player.Character
            local parentName = ch and ch.Parent and ch.Parent.Name or ""
            local jailed = parentName == "jail" or parentName == "detain" or parentName == "detainerJail"
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            if not jailed and hrp then
                local disguise = player:GetAttribute("DisguiseName")
                local disp = (type(disguise) == "string" and #disguise > 0) and disguise or player.DisplayName
                out[#out + 1] = {
                    player = player,
                    userId = player.UserId,
                    name = player.Name,
                    disguise = disp,
                    dist = myPos and (hrp.Position - myPos).Magnitude or 0,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.disguise:lower() < b.disguise:lower() end)
    return out
end

function API.KillTarget()
    if not selectedKillUserId then return nil end
    local ok, p = pcall(function() return Players:GetPlayerByUserId(selectedKillUserId) end)
    if not ok or not p or isTargetDown(p) or isMafiaTeammate(p) then
        selectedKillUserId = nil
        return nil
    end
    local disguise = p:GetAttribute("DisguiseName")
    local disp = (type(disguise) == "string" and #disguise > 0) and disguise or p.DisplayName
    return {
        player = p,
        userId = p.UserId,
        name = p.Name,
        disguise = disp,
    }
end

function API.SetKillTarget(playerOrId)
    if playerOrId == nil then
        selectedKillUserId = nil
        return true, "Auto (most isolated)"
    end
    if type(playerOrId) == "number" then
        selectedKillUserId = playerOrId
    elseif typeof(playerOrId) == "Instance" and playerOrId:IsA("Player") then
        selectedKillUserId = playerOrId.UserId
    elseif type(playerOrId) == "table" and playerOrId.userId then
        selectedKillUserId = playerOrId.userId
    else
        selectedKillUserId = nil
        return false, "invalid target"
    end
    local info = API.KillTarget()
    if not info then
        selectedKillUserId = nil
        return false, "target unavailable"
    end
    return true, info.disguise .. " (@" .. info.name .. ")"
end

function API.KillFarthest()
    if killBusy then return false, "kill already running" end
    local myRoot = root()
    if not myRoot then return false, "no character" end

    local originCF = myRoot.CFrame
    local cam = Workspace.CurrentCamera
    local originCamCF = cam and cam.CFrame or nil

    local targetPlayer, targetHrp, dist, witnessDist = nil, nil, 0, 999
    local locked = API.KillTarget()
    if locked and locked.player and locked.player.Character then
        local hrp = locked.player.Character:FindFirstChild("HumanoidRootPart")
        if hrp then
            targetPlayer = locked.player
            targetHrp = hrp
            dist = (hrp.Position - originCF.Position).Magnitude
            witnessDist = -1
        end
    end

    if not targetPlayer then
        targetPlayer, targetHrp, dist, witnessDist = findIsolatedTarget(originCF.Position)
    end
    if not targetPlayer or not targetHrp then
        return false, "no alive target"
    end

    local targetName = targetPlayer:GetAttribute("DisguiseName") or targetPlayer.Name
    killBusy = true

    task.spawn(function()
        local STICK_BIND = "MafiaKillStick"
        local killed = false
        local ok, err = pcall(function()
            local function snapToTarget()
                local ch = targetPlayer.Character
                local thrp = ch and ch:FindFirstChild("HumanoidRootPart")
                if not thrp or not thrp.Parent then return false end
                local tcf = thrp.CFrame
                -- Stand 2.8 studs behind them (tight knife range without
                -- clipping inside their character) and aim level at their torso.
                local flatLook = Vector3.new(tcf.LookVector.X, 0, tcf.LookVector.Z)
                if flatLook.Magnitude < 0.01 then flatLook = Vector3.new(0, 0, -1) else flatLook = flatLook.Unit end
                local standPos = tcf.Position - flatLook * 2.8
                setRootCFrame(CFrame.lookAt(standPos, Vector3.new(tcf.Position.X, standPos.Y, tcf.Position.Z)))
                local c = Workspace.CurrentCamera
                if c then
                    local torso = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso") or thrp
                    local eyePos = standPos + Vector3.new(0, 1.4, 0)
                    local aimPos = Vector3.new(torso.Position.X, torso.Position.Y, torso.Position.Z)
                    c.CFrame = CFrame.lookAt(eyePos, aimPos)
                end
                return true
            end

            -- 1. EMP before TP (double-tap so it reliably fires)
            triggerEmp()
            task.wait(0.12)
            if not isBlackoutActive() then
                triggerEmp()
                task.wait(0.12)
            end

            -- 2. Bind at Camera + 1 so our camera aim runs AFTER Roblox's camera
            --    controller and BEFORE roles.mafia's RenderStepped target check.
            snapToTarget()
            pcall(RunService.UnbindFromRenderStep, RunService, STICK_BIND)
            RunService:BindToRenderStep(STICK_BIND, Enum.RenderPriority.Camera.Value + 1, function()
                if not running or not killBusy then return end
                if isTargetDown(targetPlayer) then return end
                pcall(snapToTarget)
            end)

            task.wait(0.18)

            -- 3. Knife loop until confirmed down/dead or 2.5s timeout
            local deadline = os.clock() + 2.5
            local lastEmpTry = os.clock()
            while running and os.clock() < deadline do
                if isTargetDown(targetPlayer) then
                    killed = true
                    break
                end
                triggerKnife(targetPlayer.Character)
                if not isBlackoutActive() and os.clock() - lastEmpTry > 0.35 then
                    lastEmpTry = os.clock()
                    triggerEmp()
                end
                task.wait(0.22)
            end

            pcall(RunService.UnbindFromRenderStep, RunService, STICK_BIND)

            -- 4. Keep EMPing (double) to cover the return
            triggerEmp()
            task.wait(0.12)
            triggerEmp()
            task.wait(0.08)

            -- 5. TP back to original position & camera
            setRootCFrame(originCF)
            if originCamCF and Workspace.CurrentCamera then
                Workspace.CurrentCamera.CFrame = originCamCF
            end
        end)

        pcall(RunService.UnbindFromRenderStep, RunService, STICK_BIND)
        killBusy = false

        if ok then
            print(string.format("[MAFIA-MOVE] kill %s -> %s (%.0fm, witnesses %.0fm)",
                killed and "CONFIRMED" or "timeout", tostring(targetName), dist, witnessDist))
        else
            warn("[MAFIA-MOVE] kill failed: " .. tostring(err))
        end
    end)

    local witLabel = witnessDist < 0 and "locked" or (witnessDist >= 900 and "solo" or string.format("%.0fm from witness", witnessDist))
    return true, string.format("%s (%.0fm · %s)", tostring(targetName), dist, witLabel)
end

-- Role-Adaptive Combo (K) ----------------------------------------------------

local ROLE_ACTION_META = {
    mafia = { title = "Kill", sub = "EMP → isolated target → knife → return", color = "red" },
    doctor = { title = "Auto-Heal", sub = "TP downed/poisoned → heal → return", color = "blue" },
    poisoner = { title = "Poison Crowd", sub = "TP biggest cluster → drop gas → return", color = "violet" },
    witch = { title = "Silence", sub = "EMP → TP target → silence → return", color = "red" },
    snowspirit = { title = "Freeze", sub = "TP target → freeze → return", color = "blue" },
    mirage = { title = "Haunt", sub = "TP target → haunt → return", color = "violet" },
    phantom = { title = "Spare Downed", sub = "TP downed → spare → return", color = "amber" },
}

function API.RoleActionInfo()
    local r = currentRoleId()
    local meta = r and ROLE_ACTION_META[r] or nil
    if meta then
        return { role = r, title = meta.title, sub = meta.sub, color = meta.color, supported = true }
    end
    return {
        role = r or "none",
        title = "Role Combo",
        sub = r and ("No night combo for " .. r) or "Waiting for night role (Mafia/Doc/Poison/Witch/etc.)",
        color = "red",
        supported = false,
    }
end

local function findDoctorTarget(originPos)
    local hlCtrl = getController("highlightsController")
    local bestP, bestCh, bestDist, bestPriority = nil, nil, math.huge, -1
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and p:GetAttribute("Dead") ~= true and p.Character then
            local ch = p.Character
            if ch:GetAttribute("Dead") ~= true then
                local isDowned = ch:GetAttribute("Downed") == true
                local isPoisoned = hlCtrl and type(hlCtrl.hasType) == "function" and pcall(hlCtrl.hasType, ch, "poisoned") and hlCtrl.hasType(ch, "poisoned")
                local isScared = hlCtrl and type(hlCtrl.hasType) == "function" and pcall(hlCtrl.hasType, ch, "scared") and hlCtrl.hasType(ch, "scared")
                local prio = isDowned and 2 or ((isPoisoned or isScared) and 1 or 0)
                if prio > 0 then
                    local hrp = ch:FindFirstChild("HumanoidRootPart") or ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso")
                    if hrp then
                        local d = (hrp.Position - originPos).Magnitude
                        if prio > bestPriority or (prio == bestPriority and d < bestDist) then
                            bestP, bestCh, bestDist, bestPriority = p, ch, d, prio
                        end
                    end
                end
            end
        end
    end
    return bestP, bestCh, bestDist
end

local function findBestCluster(originPos)
    local alive = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and not isTargetDown(p) and p.Character then
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                alive[#alive + 1] = { player = p, pos = hrp.Position }
            end
        end
    end
    if #alive == 0 then return nil, 0 end
    local bestPos, bestCount, bestDist = nil, -1, -1
    for i = 1, #alive do
        local count = 0
        for j = 1, #alive do
            if (alive[i].pos - alive[j].pos).Magnitude <= 14 then
                count = count + 1
            end
        end
        local d = (alive[i].pos - originPos).Magnitude
        if count > bestCount or (count == bestCount and d > bestDist) then
            bestPos, bestCount, bestDist = alive[i].pos, count, d
        end
    end
    return bestPos, bestCount
end

local function runDoctorCombo()
    local myRoot = root()
    if not myRoot then return false, "no character" end
    local originCF = myRoot.CFrame
    local cam = Workspace.CurrentCamera
    local originCamCF = cam and cam.CFrame or nil

    local targetP, targetCh, dist = findDoctorTarget(originCF.Position)
    if not targetP or not targetCh then
        return false, "no downed/poisoned player"
    end
    local targetName = targetP:GetAttribute("DisguiseName") or targetP.Name
    killBusy = true

    task.spawn(function()
        local STICK = "MafiaDocStick"
        local ok, err = pcall(function()
            local docMod = getRoleModule("doctor")
            local function snapGround()
                local ch = targetP.Character
                if not ch or not ch.Parent then return false end
                local body = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso") or ch:FindFirstChild("HumanoidRootPart")
                if not body then return false end
                local bPos = body.Position
                -- Stand 2.5 studs beside the downed player and aim DOWN at their ground torso
                local standPos = Vector3.new(bPos.X + 2.5, bPos.Y + 1.5, bPos.Z)
                setRootCFrame(CFrame.lookAt(standPos, Vector3.new(bPos.X, standPos.Y, bPos.Z)))
                local c = Workspace.CurrentCamera
                if c then
                    c.CFrame = CFrame.lookAt(standPos + Vector3.new(0, 1.4, 0), bPos)
                end
                if docMod and type(docMod.setTargetCharacter) == "function" then
                    pcall(docMod.setTargetCharacter, ch)
                end
                return true
            end

            snapGround()
            pcall(RunService.UnbindFromRenderStep, RunService, STICK)
            RunService:BindToRenderStep(STICK, Enum.RenderPriority.Camera.Value + 1, function()
                if not running or not killBusy then return end
                pcall(snapGround)
            end)

            task.wait(0.12)
            triggerRoleAction("doctor", "heal", Enum.KeyCode.R)
            task.wait(0.22)
            if targetP.Character and targetP.Character:GetAttribute("Downed") == true then
                triggerRoleAction("doctor", "heal", Enum.KeyCode.R)
                task.wait(0.18)
            end

            pcall(RunService.UnbindFromRenderStep, RunService, STICK)
            setRootCFrame(originCF)
            if originCamCF and Workspace.CurrentCamera then
                Workspace.CurrentCamera.CFrame = originCamCF
            end
        end)
        pcall(RunService.UnbindFromRenderStep, RunService, STICK)
        killBusy = false
        if ok then
            print(string.format("[MAFIA-MOVE] doctor heal -> %s (%.0fm)", tostring(targetName), dist))
        else
            warn("[MAFIA-MOVE] doctor heal failed: " .. tostring(err))
        end
    end)

    return true, string.format("Heal %s (%.0fm)", tostring(targetName), dist)
end

local function runPoisonerCombo()
    local myRoot = root()
    if not myRoot then return false, "no character" end
    local originCF = myRoot.CFrame
    local clusterPos, count = findBestCluster(originCF.Position)
    if not clusterPos then return false, "no alive players" end

    killBusy = true
    task.spawn(function()
        local ok, err = pcall(function()
            setRootCFrame(CFrame.new(clusterPos + Vector3.new(0, 0.5, 0)))
            task.wait(0.12)
            triggerRoleAction("poisoner", "use", Enum.KeyCode.R)
            task.wait(0.22)
            setRootCFrame(originCF)
        end)
        killBusy = false
        if ok then
            print(string.format("[MAFIA-MOVE] poisoner gas -> cluster of %d", count))
        else
            warn("[MAFIA-MOVE] poisoner failed: " .. tostring(err))
        end
    end)

    return true, string.format("Poison crowd (%d players)", count)
end

local function runTargetedRoleCombo(roleId, actionName, targetArg, useEmp)
    local myRoot = root()
    if not myRoot then return false, "no character" end
    local originCF = myRoot.CFrame
    local cam = Workspace.CurrentCamera
    local originCamCF = cam and cam.CFrame or nil

    local targetPlayer, targetHrp, dist = nil, nil, 0
    local locked = API.KillTarget()
    if locked and locked.player and locked.player.Character then
        local hrp = locked.player.Character:FindFirstChild("HumanoidRootPart")
        if hrp then
            targetPlayer, targetHrp, dist = locked.player, hrp, (hrp.Position - originCF.Position).Magnitude
        end
    end
    if not targetPlayer then
        targetPlayer, targetHrp, dist = findIsolatedTarget(originCF.Position)
    end
    if not targetPlayer or not targetHrp then
        return false, "no alive target"
    end
    local targetName = targetPlayer:GetAttribute("DisguiseName") or targetPlayer.Name
    killBusy = true

    task.spawn(function()
        local STICK = "MafiaRoleStick"
        local ok, err = pcall(function()
            local roleMod = getRoleModule(roleId)
            local function snap()
                local ch = targetPlayer.Character
                local thrp = ch and ch:FindFirstChild("HumanoidRootPart")
                if not thrp or not thrp.Parent then return false end
                local tcf = thrp.CFrame
                local flat = Vector3.new(tcf.LookVector.X, 0, tcf.LookVector.Z)
                flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
                local standPos = tcf.Position - flat * 2.8
                setRootCFrame(CFrame.lookAt(standPos, Vector3.new(tcf.Position.X, standPos.Y, tcf.Position.Z)))
                local c = Workspace.CurrentCamera
                if c then
                    local torso = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso") or thrp
                    c.CFrame = CFrame.lookAt(standPos + Vector3.new(0, 1.4, 0), torso.Position)
                end
                if roleMod and type(roleMod.setTargetCharacter) == "function" then
                    if targetArg ~= nil then
                        pcall(roleMod.setTargetCharacter, ch, targetArg)
                    else
                        pcall(roleMod.setTargetCharacter, ch)
                    end
                end
                return true
            end

            if useEmp then
                triggerEmp()
                task.wait(0.1)
            end

            snap()
            pcall(RunService.UnbindFromRenderStep, RunService, STICK)
            RunService:BindToRenderStep(STICK, Enum.RenderPriority.Camera.Value + 1, function()
                if not running or not killBusy then return end
                pcall(snap)
            end)

            task.wait(0.12)
            triggerRoleAction(roleId, actionName, Enum.KeyCode.R)
            task.wait(0.22)

            pcall(RunService.UnbindFromRenderStep, RunService, STICK)
            if useEmp then
                triggerEmp()
                task.wait(0.08)
            end
            setRootCFrame(originCF)
            if originCamCF and Workspace.CurrentCamera then
                Workspace.CurrentCamera.CFrame = originCamCF
            end
        end)
        pcall(RunService.UnbindFromRenderStep, RunService, STICK)
        killBusy = false
        if ok then
            print(string.format("[MAFIA-MOVE] %s %s -> %s (%.0fm)", roleId, actionName, tostring(targetName), dist))
        else
            warn("[MAFIA-MOVE] role combo failed: " .. tostring(err))
        end
    end)

    return true, string.format("%s → %s (%.0fm)", actionName:upper(), tostring(targetName), dist)
end

local function runPhantomCombo()
    local myRoot = root()
    if not myRoot then return false, "no character" end
    local originCF = myRoot.CFrame
    local cam = Workspace.CurrentCamera
    local originCamCF = cam and cam.CFrame or nil

    local targetP, targetCh, dist = findDoctorTarget(originCF.Position)
    if not targetP or not targetCh then return false, "no downed player" end
    local targetName = targetP:GetAttribute("DisguiseName") or targetP.Name
    killBusy = true

    task.spawn(function()
        local STICK = "MafiaPhantomStick"
        local ok, err = pcall(function()
            local pMod = getRoleModule("phantom")
            local function snap()
                local ch = targetP.Character
                if not ch or not ch.Parent then return false end
                local body = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso") or ch:FindFirstChild("HumanoidRootPart")
                if not body then return false end
                local bPos = body.Position
                local standPos = Vector3.new(bPos.X + 2.5, bPos.Y + 1.5, bPos.Z)
                setRootCFrame(CFrame.lookAt(standPos, Vector3.new(bPos.X, standPos.Y, bPos.Z)))
                local c = Workspace.CurrentCamera
                if c then c.CFrame = CFrame.lookAt(standPos + Vector3.new(0, 1.4, 0), bPos) end
                if pMod and type(pMod.setTargetCharacter) == "function" then
                    pcall(pMod.setTargetCharacter, ch)
                end
                return true
            end

            snap()
            pcall(RunService.UnbindFromRenderStep, RunService, STICK)
            RunService:BindToRenderStep(STICK, Enum.RenderPriority.Camera.Value + 1, function()
                if not running or not killBusy then return end
                pcall(snap)
            end)
            task.wait(0.14)
            triggerRoleAction("phantom", "save", Enum.KeyCode.R)
            task.wait(0.22)
            pcall(RunService.UnbindFromRenderStep, RunService, STICK)
            setRootCFrame(originCF)
            if originCamCF and Workspace.CurrentCamera then Workspace.CurrentCamera.CFrame = originCamCF end
        end)
        pcall(RunService.UnbindFromRenderStep, RunService, STICK)
        killBusy = false
        if not ok then warn("[MAFIA-MOVE] phantom failed: " .. tostring(err)) end
    end)

    return true, string.format("Spare %s (%.0fm)", tostring(targetName), dist)
end

function API.RoleCombo()
    if killBusy then return false, "combo already running" end
    local r = currentRoleId()
    if r == "mafia" then
        return API.KillFarthest()
    elseif r == "doctor" then
        return runDoctorCombo()
    elseif r == "poisoner" then
        return runPoisonerCombo()
    elseif r == "witch" then
        return runTargetedRoleCombo("witch", "silence", "silence", true)
    elseif r == "snowspirit" then
        return runTargetedRoleCombo("snowspirit", "freeze", nil, false)
    elseif r == "mirage" then
        return runTargetedRoleCombo("mirage", "haunt", nil, false)
    elseif r == "phantom" then
        return runPhantomCombo()
    else
        return false, r and ("no night combo for " .. r) or "not in a supported role"
    end
end

local function lockerStandCFrame(locker)
    local base = locker:FindFirstChild("Base") or locker:FindFirstChild("blockingPart")
    local basePos = nil
    if base and base:IsA("BasePart") then
        basePos = base.Position
    elseif locker:IsA("Model") then
        local ok, piv = pcall(function() return locker:GetPivot() end)
        if ok then basePos = piv.Position end
    elseif locker:IsA("BasePart") then
        basePos = locker.Position
    end
    if not basePos then return nil, nil end

    -- Find the door side so we stand cleanly in front of the closet (never inside blockingPart)
    local doorPos = nil
    local doorL = locker:FindFirstChild("DoorL")
    local doorR = locker:FindFirstChild("DoorR")
    local door = locker:FindFirstChild("Door")
    local function partPos(inst)
        if not inst then return nil end
        if inst:IsA("BasePart") then return inst.Position end
        if inst:IsA("Model") then
            local ok, piv = pcall(function() return inst:GetPivot() end)
            return ok and piv.Position or nil
        end
        return nil
    end
    local pL, pR, pD = partPos(doorL), partPos(doorR), partPos(door)
    if pL and pR then
        doorPos = (pL + pR) * 0.5
    elseif pD then
        doorPos = pD
    end

    local frontDir = nil
    if doorPos then
        local delta = Vector3.new(doorPos.X - basePos.X, 0, doorPos.Z - basePos.Z)
        if delta.Magnitude > 0.1 then frontDir = delta.Unit end
    end
    if not frontDir then
        if base and base:IsA("BasePart") then
            local lv = Vector3.new(base.CFrame.LookVector.X, 0, base.CFrame.LookVector.Z)
            frontDir = lv.Magnitude > 0.1 and lv.Unit or Vector3.new(0, 0, 1)
        else
            frontDir = Vector3.new(0, 0, 1)
        end
    end

    local anchor = doorPos or basePos
    local standPos = Vector3.new(anchor.X, basePos.Y, anchor.Z) + frontDir * 3.0
    local lookAt = Vector3.new(basePos.X, standPos.Y, basePos.Z)
    return CFrame.lookAt(standPos, lookAt), basePos
end

function API.PanicLocker()
    local myRoot = root()
    if not myRoot then return false, "no character" end

    -- Stop active movement states cleanly
    if CONFIG.fly then pcall(API.SetFly, false) end
    if CONFIG.spin then pcall(API.SetSpin, false) end
    if CONFIG.ragdoll then pcall(API.SetRagdoll, false) end
    if CONFIG.emoteSpam then pcall(API.SetEmoteSpam, false) end
    if CONFIG.speed then pcall(API.SetSpeed, false) end

    local lockers = CollectionService:GetTagged("Locker")
    local myPos = myRoot.Position
    local bestStandCF, bestBasePos, bestDist = nil, nil, math.huge

    for _, locker in ipairs(lockers) do
        local standCF, basePos = lockerStandCFrame(locker)
        if standCF and basePos then
            local occupied = false
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= lp and not isTargetDown(p) and p.Character then
                    local hrp = p.Character:FindFirstChild("HumanoidRootPart")
                    if hrp and (hrp.Position - basePos).Magnitude < 6 then
                        occupied = true
                        break
                    end
                end
            end
            if not occupied then
                local d = (basePos - myPos).Magnitude
                if d < bestDist then
                    bestStandCF, bestBasePos, bestDist = standCF, basePos, d
                end
            end
        end
    end

    if not bestStandCF then
        return false, "no empty locker"
    end

    local ok, err = setRootCFrame(bestStandCF)
    if not ok then return false, err end

    -- Aim camera at the closet and trigger the game's interact action (E)
    -- so hidingSpotController puts you inside cleanly without wall-clipping.
    task.spawn(function()
        local cam = Workspace.CurrentCamera
        if cam and bestBasePos then
            local eyePos = bestStandCF.Position + Vector3.new(0, 1.4, 0)
            pcall(function() cam.CFrame = CFrame.lookAt(eyePos, bestBasePos) end)
        end
        task.wait(0.15)
        local inputCtrl = getController("inputController")
        if inputCtrl and type(inputCtrl.triggerAction) == "function" then
            pcall(inputCtrl.triggerAction, "universal", "general", "interact")
        end
        tapKey(Enum.KeyCode.E)
    end)

    return true, string.format("Locker (%.0fm)", bestDist)
end

function API.Spin()
    return CONFIG.spin == true
end

function API.SetSpin(on)
    CONFIG.spin = on == true
    if CONFIG.spin then
        startSpin()
    else
        stopSpin()
    end
    return CONFIG.spin
end

function API.ToggleSpin()
    return API.SetSpin(not CONFIG.spin)
end

function API.Ragdoll()
    return CONFIG.ragdoll == true
end

function API.SetRagdoll(on)
    CONFIG.ragdoll = on == true
    if CONFIG.ragdoll then
        if CONFIG.fly then API.SetFly(false) end
        applyRagdoll()
    else
        restoreRagdoll()
    end
    return CONFIG.ragdoll
end

function API.ToggleRagdoll()
    return API.SetRagdoll(not CONFIG.ragdoll)
end

function API.EmoteSpam()
    return CONFIG.emoteSpam == true
end

function API.SetEmoteSpam(on)
    CONFIG.emoteSpam = on == true
    if CONFIG.emoteSpam then
        startEmoteSpam()
    else
        emoteGen = emoteGen + 1
        stopCurrentEmote()
    end
    return CONFIG.emoteSpam
end

function API.ToggleEmoteSpam()
    return API.SetEmoteSpam(not CONFIG.emoteSpam)
end

function API.Scale()
    return CONFIG.scale
end

function API.SetScale(value)
    local n = tonumber(value) or CONFIG.scale
    CONFIG.scale = math.clamp(n, 0.5, 2)
    applyScale()
    return CONFIG.scale
end

function API.Status()
    local out = {}
    for k, v in pairs(CONFIG) do out[k] = v end
    out.hasFlyController = true
    return out
end

function API.Stop()
    if _G.__mafiaMovement ~= API then return end
    running = false
    CONFIG.noclip = false
    CONFIG.speed = false
    CONFIG.fly = false
    CONFIG.spin = false
    CONFIG.ragdoll = false
    CONFIG.emoteSpam = false
    stopFly()
    if noclipController then
        pcall(function() noclipController.setEnabled(false) end)
    end
    stopSpin()
    stopCurrentEmote()
    restoreNoclip()
    restoreSpeed()
    restoreRagdoll()
    restoreScale()
    CONFIG.scale = 1.0
    _G.__mafiaMovement = nil
end

_G.__mafiaMovement = API

task.spawn(function()
    while running do
        local ok = pcall(function()
            captureCharacter()
            if CONFIG.noclip then applyNoclip() end
            if CONFIG.speed then applySpeed() end
            if CONFIG.fly and not flyConn then
                startFly()
            end
            if CONFIG.ragdoll then
                local hum = humanoid()
                if hum and hum:GetState() ~= Enum.HumanoidStateType.Ragdoll then
                    applyRagdoll()
                end
            end
        end)
        if not ok then
            -- A transient character change should not kill the loop.
        end
        task.wait(0.2)
    end
end)

local s = API.Status()
print(string.format("[MAFIA-MOVE] loaded - noclip=%s speed=%s x%.2f fly=%s spin=%s ragdoll=%s emote=%s scale=%.1f",
    tostring(s.noclip), tostring(s.speed), s.multiplier,
    tostring(s.fly), tostring(s.spin), tostring(s.ragdoll),
    tostring(s.emoteSpam), s.scale))
