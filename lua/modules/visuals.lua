--!nocheck
--[[
    MAFIA - client-side visual options (off by default)

    Fullbright and camera FOV. Local only: no remotes, no replication.

    API: _G.__mafiaVisuals
        .Fullbright() / .SetFullbright(bool) / .ToggleFullbright()
        .FOV() / .SetFOV(n) / .ResetFOV()
        .Stop()
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local function getNightVisionController()
    local client = ReplicatedStorage:FindFirstChild("client")
    local controllers = client and client:FindFirstChild("controllers")
    local mod = controllers and controllers:FindFirstChild("nightVisionController")
    if not mod then return nil end
    local ok, ctrl = pcall(require, mod)
    if ok and type(ctrl) == "table" and type(ctrl.setExposureSuspended) == "function" then
        return ctrl
    end
    return nil
end

local nvController = getNightVisionController()

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.2.0"

local old = _G.__mafiaVisuals
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local CONFIG = {
    fullbright = false,
    fov = 70,
}

local running = true
local saved = nil
local savedEffects = {}
local savedAtmospheres = {}
local savedOverlays = {}
local savedScreens = {}
local renderConnection = nil
local renderBound = false
local heartbeatConnection = nil
local applying = false
local propertyConnections = {}
local effectConnections = {}
local darkSince = nil
local fovTouched = false

local RENDER_BIND_NAME = "MafiaFullbrightCore"
local OUR_GUIS = { MafiaMenu = true, MafiaESP = true, MafiaHUD = true }
local SCREEN_GUARDS = {
    "Emp",
    "EmpAfterimage",
    "EmpInk",
    "SovietEmpWhiteout",
    "Vignette",
    "Fade",
    "nextNightTransition",
    "TeleportScreen",
}
local TRANSIENT_GUIS = {}
for _, name in ipairs(SCREEN_GUARDS) do TRANSIENT_GUIS[name] = true end

local function camera()
    return Workspace.CurrentCamera
end

local function saveLighting()
    if saved then return end
    saved = {
        Brightness = Lighting.Brightness,
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        ClockTime = Lighting.ClockTime,
        FogEnd = Lighting.FogEnd,
        FogStart = Lighting.FogStart,
        FogColor = Lighting.FogColor,
        GlobalShadows = Lighting.GlobalShadows,
        ExposureCompensation = Lighting.ExposureCompensation,
        EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
        EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
        GeographicLatitude = Lighting.GeographicLatitude,
    }
end

local EFFECT_CLASSES = {
    BlurEffect = true,
    BloomEffect = true,
    SunRaysEffect = true,
    DepthOfFieldEffect = true,
    ColorCorrectionEffect = true,
}

local function muteEffect(effect)
    if savedEffects[effect] == nil then
        savedEffects[effect] = effect.Enabled
    end
    pcall(function() effect.Enabled = false end)
end

local function muteEffects()
    for _, effect in ipairs(Lighting:GetDescendants()) do
        if EFFECT_CLASSES[effect.ClassName] then
            muteEffect(effect)
        elseif effect:IsA("Atmosphere") then
            if savedAtmospheres[effect] == nil then
                savedAtmospheres[effect] = {
                    Density = effect.Density,
                    Haze = effect.Haze,
                    Glare = effect.Glare,
                }
            end
            pcall(function()
                effect.Density = 0
                effect.Haze = 0
                effect.Glare = 0
            end)
        end
    end

    -- Some game builds parent EMP colour grading under the camera instead of
    -- Lighting. Catch those too; the effect table is keyed by instance so
    -- restoreEffects() handles both locations.
    local cam = camera()
    if cam then
        for _, effect in ipairs(cam:GetDescendants()) do
            if EFFECT_CLASSES[effect.ClassName] then
                muteEffect(effect)
            end
        end
    end
end

local function restoreEffects()
    for effect, enabled in pairs(savedEffects) do
        if effect and effect.Parent then
            -- Blur/DoF are the "can't see" EMP effects. Never restore them to
            -- true: if the game wants them later it enables them itself.
            if effect:IsA("BlurEffect") or effect:IsA("DepthOfFieldEffect") then
                enabled = false
            end
            pcall(function() effect.Enabled = enabled end)
        end
    end
    savedEffects = {}

    for atmosphere, values in pairs(savedAtmospheres) do
        if atmosphere and atmosphere.Parent then
            pcall(function()
                atmosphere.Density = values.Density
                atmosphere.Haze = values.Haze
                atmosphere.Glare = values.Glare
            end)
        end
    end
    savedAtmospheres = {}
end

local function hideOverlay(inst, hideVisible)
    if not inst or not inst:IsA("GuiObject") then return end
    local savedEntry = savedOverlays[inst]
    if not savedEntry then
        local image = nil
        if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
            image = inst.ImageTransparency
        end
        savedEntry = {
            image = image,
            background = inst.BackgroundTransparency,
            visible = hideVisible and inst.Visible or nil,
        }
        savedOverlays[inst] = savedEntry
    end
    pcall(function() inst.BackgroundTransparency = 1 end)
    if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
        pcall(function() inst.ImageTransparency = 1 end)
    end
    if hideVisible then
        pcall(function() inst.Visible = false end)
    end
end

-- Cheap per-frame guard: disable the known EMP/fade screens and hide the
-- full-screen fade/grain frames. Runs every render frame, so their animation
-- tweens cannot win the race.
local function guardKnownScreens()
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end

    for _, name in ipairs(SCREEN_GUARDS) do
        local gui = pg:FindFirstChild(name)
        if gui and gui:IsA("ScreenGui") then
            if savedScreens[gui] == nil then
                savedScreens[gui] = gui.Enabled
            end
            if gui.Enabled then
                pcall(function() gui.Enabled = false end)
            end
        end
    end

    local ui = pg:FindFirstChild("UI")
    if ui then
        for _, name in ipairs({"Fade", "Grain"}) do
            local d = ui:FindFirstChild(name)
            if d then hideOverlay(d, true) end
        end
    end
end

-- Generic guard: any full-screen, nearly opaque GuiObject in any enabled
-- ScreenGui is a blackout layer. Catches EMP/fade screens the game adds later
-- and ones we have not named yet.
local function sweepFullscreenOverlays()
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
    local cam = camera()
    if not pg then return end
    local vp = (cam and cam.ViewportSize) or Vector2.new(1920, 1080)

    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Enabled and not OUR_GUIS[gui.Name] then
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("GuiObject") and d.Visible then
                    local abs = d.AbsoluteSize
                    if abs and abs.X >= vp.X * 0.75 and abs.Y >= vp.Y * 0.75 then
                        local bg = d.BackgroundTransparency
                        local img = nil
                        if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                            img = d.ImageTransparency
                        end
                        if (bg and bg <= 0.25) or (img and img <= 0.25) then
                            hideOverlay(d, true)
                        end
                    end
                end
            end
        end
    end
end

local function muteEmpOverlays()
    guardKnownScreens()
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    for _, name in ipairs(SCREEN_GUARDS) do
        local gui = pg:FindFirstChild(name)
        if gui then
            for _, d in ipairs(gui:GetDescendants()) do
                hideOverlay(d)
            end
        end
    end
    sweepFullscreenOverlays()
end

local function insideTransient(inst)
    local node = inst
    while node do
        if node:IsA("ScreenGui") and TRANSIENT_GUIS[node.Name] then return true end
        node = node.Parent
    end
    return false
end

local function restoreEmpOverlays()
    -- Never re-enable the EMP/fade screens on toggle-off. If the game still
    -- needs one, it enables it itself; re-enabling a captured blackout frame
    -- is what left the screen permanently black after an EMP.
    for screen in pairs(savedScreens) do
        if screen and screen.Parent then
            pcall(function() screen.Enabled = false end)
        end
    end
    savedScreens = {}

    for overlay, values in pairs(savedOverlays) do
        if overlay and overlay.Parent then
            local skip = insideTransient(overlay)
            -- Do not restore a fully opaque full-screen layer either; that is
            -- a blackout, not gameplay UI.
            if not skip and values.background ~= nil and values.background <= 0.25 then
                skip = true
            end
            if not skip and values.image ~= nil and values.image <= 0.25 then
                skip = true
            end
            if not skip then
                pcall(function()
                    if values.background ~= nil then
                        overlay.BackgroundTransparency = values.background
                    end
                    if values.image ~= nil then
                        overlay.ImageTransparency = values.image
                    end
                    if values.visible ~= nil then
                        overlay.Visible = values.visible
                    end
                end)
            end
        end
    end
    savedOverlays = {}
end

local CORE = {
    Brightness = function() return 2 end,
    Ambient = function() return Color3.fromRGB(190, 190, 190) end,
    OutdoorAmbient = function() return Color3.fromRGB(190, 190, 190) end,
    ClockTime = function() return 14 end,
    FogEnd = function() return 100000 end,
    FogStart = function() return 0 end,
    FogColor = function() return Color3.fromRGB(255, 255, 255) end,
    GlobalShadows = function() return false end,
    ExposureCompensation = function() return 0 end,
    EnvironmentDiffuseScale = function() return 1 end,
    EnvironmentSpecularScale = function() return 1 end,
    GeographicLatitude = function() return 40 end,
}

local function applyCore()
    applying = true
    for key, value in pairs(CORE) do
        pcall(function() Lighting[key] = value() end)
    end
    applying = false
end

-- The game's EMP writes Lighting on a connection or loop that runs after our
-- render callbacks. A property-changed handler fires synchronously with that
-- write, in every phase, so we can undo it before the frame is drawn.
local function startPropertyGuard()
    if #propertyConnections > 0 then return end
    for key in pairs(CORE) do
        local ok = pcall(function()
            local conn = Lighting:GetPropertyChangedSignal(key):Connect(function()
                if applying or not CONFIG.fullbright then return end
                applying = true
                pcall(function() Lighting[key] = CORE[key]() end)
                applying = false
            end)
            table.insert(propertyConnections, conn)
        end)
        if not ok then
            -- Mock/unsupported environment: render loops still cover it.
        end
    end
end

local function stopPropertyGuard()
    for _, conn in ipairs(propertyConnections) do
        pcall(function() conn:Disconnect() end)
    end
    propertyConnections = {}
end

local function startEffectGuard()
    if #effectConnections > 0 then return end
    local function watchContainer(container)
        if not container then return end
        local ok, conn = pcall(function()
            return container.DescendantAdded:Connect(function(desc)
                if not CONFIG.fullbright then return end
                if EFFECT_CLASSES[desc.ClassName] then
                    muteEffect(desc)
                elseif desc:IsA("Atmosphere") then
                    pcall(muteEffects)
                end
            end)
        end)
        if ok and conn then
            table.insert(effectConnections, conn)
        end
    end
    watchContainer(Lighting)
    watchContainer(camera())
end

local function stopEffectGuard()
    for _, conn in ipairs(effectConnections) do
        pcall(function() conn:Disconnect() end)
    end
    effectConnections = {}
end

local function setNvSuspended(suspended)
    if not nvController then
        nvController = getNightVisionController()
    end
    if nvController and type(nvController.setExposureSuspended) == "function" then
        pcall(nvController.setExposureSuspended, suspended == true)
    end
end

local function applyFullbright()
    saveLighting()
    setNvSuspended(true)
    applyCore()
    muteEffects()
    muteEmpOverlays()
end

local function startRenderLoop()
    if renderConnection then return end

    setNvSuspended(true)
    startPropertyGuard()
    startEffectGuard()

    renderConnection = RunService.RenderStepped:Connect(function()
        if CONFIG.fullbright then
            pcall(applyCore)
            pcall(guardKnownScreens)
        end
    end)

    -- Run at Last + 10 so we execute after SovietEmp (Last + 5) and any
    -- game-owned render callbacks, preventing exposure/whiteout overrides.
    pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND_NAME) end)
    renderBound = pcall(function()
        RunService:BindToRenderStep(RENDER_BIND_NAME, Enum.RenderPriority.Last.Value + 10, function()
            if CONFIG.fullbright then
                pcall(applyCore)
                pcall(guardKnownScreens)
            end
        end)
    end)

    heartbeatConnection = RunService.Heartbeat:Connect(function()
        if CONFIG.fullbright then
            pcall(applyCore)
        end
    end)
end

local function stopRenderLoop()
    stopPropertyGuard()
    stopEffectGuard()
    setNvSuspended(false)
    if renderConnection then
        pcall(function() renderConnection:Disconnect() end)
        renderConnection = nil
    end
    if heartbeatConnection then
        pcall(function() heartbeatConnection:Disconnect() end)
        heartbeatConnection = nil
    end
    if renderBound then
        pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND_NAME) end)
    end
    renderBound = false
end

local function restoreLighting()
    restoreEffects()
    restoreEmpOverlays()
    if not saved then return end
    for key, value in pairs(saved) do
        -- The saved exposure may have been captured during an EMP (-10). If
        -- restored as-is the screen stays black forever, so never restore a
        -- negative exposure.
        if key == "ExposureCompensation" and value < 0 then
            value = 0
        end
        pcall(function() Lighting[key] = value end)
    end
    saved = nil
end

-- Manual unstick for the "screen stays black after EMP" case. Stops the
-- guard, discards the captured values, and applies safe visible defaults.
function API.Repair()
    CONFIG.fullbright = false
    stopRenderLoop()
    -- Restore colour-grading/bloom (blur and DoF are forced off), and disable
    -- the EMP/fade screens instead of restoring their black values.
    restoreEffects()
    restoreEmpOverlays()
    saved = nil
    darkSince = nil

    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _, name in ipairs(SCREEN_GUARDS) do
            local gui = pg:FindFirstChild(name)
            if gui and gui:IsA("ScreenGui") then
                pcall(function() gui.Enabled = false end)
            end
        end
        local ui = pg:FindFirstChild("UI")
        if ui then
            for _, name in ipairs({ "Fade", "Grain" }) do
                local d = ui:FindFirstChild(name)
                if d and d:IsA("GuiObject") then
                    pcall(function()
                        d.Visible = false
                        d.BackgroundTransparency = 1
                    end)
                end
            end
        end
    end

    local function clearDarkEffects(container)
        if not container then return end
        for _, effect in ipairs(container:GetDescendants()) do
            if effect:IsA("BlurEffect") or effect:IsA("DepthOfFieldEffect") then
                pcall(function() effect.Enabled = false end)
            elseif effect:IsA("ColorCorrectionEffect") and effect.Brightness < -0.2 then
                pcall(function() effect.Enabled = false end)
            end
        end
    end

    clearDarkEffects(Lighting)
    clearDarkEffects(camera())

    pcall(function()
        Lighting.ExposureCompensation = 0
        Lighting.Brightness = 1.5
        Lighting.Ambient = Color3.fromRGB(140, 140, 150)
        Lighting.OutdoorAmbient = Color3.fromRGB(140, 140, 150)
        Lighting.ClockTime = 14
        Lighting.FogEnd = 100000
        Lighting.FogStart = 0
        Lighting.FogColor = Color3.fromRGB(200, 200, 210)
        Lighting.GlobalShadows = true
        Lighting.EnvironmentDiffuseScale = 0.8
        Lighting.EnvironmentSpecularScale = 0.8
        Lighting.GeographicLatitude = 40
    end)

    print("[MAFIA-VISUALS] repaired lighting (fullbright off, safe defaults)")
    return true
end

local function applyFOV()
    local cam = camera()
    if cam then
        pcall(function() cam.FieldOfView = CONFIG.fov end)
    end
end

function API.Fullbright()
    return CONFIG.fullbright == true
end

function API.SetFullbright(on)
    CONFIG.fullbright = on == true
    if CONFIG.fullbright then
        startRenderLoop()
        applyFullbright()
    else
        stopRenderLoop()
        restoreLighting()
    end
    return true
end

function API.ToggleFullbright()
    return API.SetFullbright(not CONFIG.fullbright)
end

function API.FOV()
    return CONFIG.fov
end

function API.SetFOV(value)
    local n = tonumber(value) or CONFIG.fov
    CONFIG.fov = math.clamp(n, 50, 120)
    fovTouched = true
    applyFOV()
    return CONFIG.fov
end

function API.ResetFOV()
    CONFIG.fov = 70
    fovTouched = false
    applyFOV()
    return CONFIG.fov
end

function API.Stop()
    if _G.__mafiaVisuals ~= API then return end
    running = false
    CONFIG.fullbright = false
    stopRenderLoop()
    restoreLighting()
    if fovTouched then
        CONFIG.fov = 70
        applyFOV()
    end
    _G.__mafiaVisuals = nil
end

_G.__mafiaVisuals = API

task.spawn(function()
    while running do
        if CONFIG.fullbright then
            pcall(applyFullbright)
            darkSince = nil
        else
            -- Post-EMP safety: the game sometimes leaves exposure at -10 long
            -- after the EMP ends, which reads as a permanently black screen.
            local exposure = Lighting.ExposureCompensation or 0
            if exposure <= -2 then
                darkSince = darkSince or os.clock()
                if os.clock() - darkSince > 12 then
                    pcall(function() Lighting.ExposureCompensation = 0 end)
                    pcall(function() Lighting.Brightness = math.max(Lighting.Brightness, 0.6) end)
                    print("[MAFIA-VISUALS] cleared stale negative exposure (12s)")
                    darkSince = nil
                end
            else
                darkSince = nil
            end
        end
        if CONFIG.fov ~= 70 then
            pcall(applyFOV)
        end
        task.wait(0.25)
    end
end)

print("[MAFIA-VISUALS] loaded - fullbright=" .. tostring(CONFIG.fullbright) .. " fov=" .. tostring(CONFIG.fov))
