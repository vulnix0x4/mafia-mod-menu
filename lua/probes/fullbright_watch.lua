--!nocheck
--[[
    MAFIA - fullbright / EMP watcher

    Run while fullbright is on, ideally right before a round reaches night:

        loadstring(game:HttpGet("http://127.0.0.1:8766/lua/probes/fullbright_watch.lua"))()

    The probe:

      * loads the suite if it is not already loaded,
      * forces fullbright on,
      * logs the moment a known EMP/fade/transition screen is enabled,
      * logs any Lighting value, post-effect, Atmosphere, or full-screen
        overlay that survives the fullbright guard,
      * records compact snapshots so the exact dark layer can be identified.

    It never calls a remote and never changes another player. Stop it with:

        _G.__fbWatch.Stop()
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local P = "[FBWATCH]"
local MAX_EVENTS = 80
local KNOWN = {
    Emp = true,
    EmpAfterimage = true,
    EmpInk = true,
    Vignette = true,
    Fade = true,
    nextNightTransition = true,
    TeleportScreen = true,
    Death = true,
    UI = true,
}

local TARGETS = {
    Brightness = 2,
    Ambient = Color3.fromRGB(190, 190, 190),
    OutdoorAmbient = Color3.fromRGB(190, 190, 190),
    ClockTime = 14,
    FogEnd = 100000,
    FogStart = 0,
    FogColor = Color3.fromRGB(255, 255, 255),
    GlobalShadows = false,
    ExposureCompensation = 0,
    EnvironmentDiffuseScale = 1,
    EnvironmentSpecularScale = 1,
    GeographicLatitude = 40,
}

local function log(fmt, ...)
    print(P .. " " .. string.format(fmt, ...))
end

local function path(inst)
    local parts = {}
    while inst and inst ~= game do
        table.insert(parts, 1, inst.Name)
        inst = inst.Parent
    end
    return table.concat(parts, ".")
end

local function num(v)
    return string.format("%.3f", v)
end

local function color(v)
    return string.format("%.3f,%.3f,%.3f", v.R, v.G, v.B)
end

local function lum(v)
    return 0.299 * v.R + 0.587 * v.G + 0.114 * v.B
end

local function valueText(v)
    if typeof(v) == "Color3" then return color(v) end
    if typeof(v) == "Vector2" then return string.format("%.0f,%.0f", v.X, v.Y) end
    return tostring(v)
end

local function fullbright()
    local api = _G.__mafiaVisuals
    return api and type(api.Fullbright) == "function" and api.Fullbright() == true
end

local W = {
    running = true,
    events = {},
    lastIssue = "",
    lastIssueAt = 0,
    lastSnapshotAt = 0,
    conns = {},
}

local function remember(tag, detail)
    local row = { t = os.clock(), tag = tag, detail = detail }
    table.insert(W.events, row)
    if #W.events > MAX_EVENTS then table.remove(W.events, 1) end
end

local function effectRows()
    local out = {}
    for _, e in ipairs(Lighting:GetDescendants()) do
        if e:IsA("PostEffect") then
            local row = {
                path = path(e),
                class = e.ClassName,
                enabled = e.Enabled,
            }
            if e:IsA("ColorCorrectionEffect") then
                row.brightness = e.Brightness
                row.contrast = e.Contrast
                row.saturation = e.Saturation
                row.tint = color(e.TintColor)
            elseif e:IsA("BlurEffect") then
                row.size = e.Size
            elseif e:IsA("DepthOfFieldEffect") then
                row.far = e.FarIntensity
                row.near = e.NearIntensity
                row.focus = e.FocusDistance
            end
            table.insert(out, row)
        elseif e:IsA("Atmosphere") then
            table.insert(out, {
                path = path(e),
                class = "Atmosphere",
                density = e.Density,
                haze = e.Haze,
                glare = e.Glare,
                color = color(e.Color),
                decay = color(e.Decay),
            })
        elseif e:IsA("Sky") then
            table.insert(out, {
                path = path(e),
                class = "Sky",
                starCount = e.StarCount,
                sunAngularSize = e.SunAngularSize,
                moonAngularSize = e.MoonAngularSize,
                celestialBodiesShown = e.CelestialBodiesShown,
            })
        end
    end

    local cam = Workspace.CurrentCamera
    if cam then
        for _, e in ipairs(cam:GetDescendants()) do
            if e:IsA("PostEffect") then
                table.insert(out, {
                    path = path(e),
                    class = "CAMERA:" .. e.ClassName,
                    enabled = e.Enabled,
                })
            end
        end
    end

    return out
end

local function guiRows(onlyKnown)
    local out = {}
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
    local cam = Workspace.CurrentCamera
    if not pg or not cam then return out end
    local vp = cam.ViewportSize

    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") then
            local known = KNOWN[gui.Name] == true
            if gui.Enabled and (not onlyKnown or known) then
                local row = {
                    name = gui.Name,
                    enabled = gui.Enabled,
                    order = gui.DisplayOrder,
                    overlays = {},
                }
                for _, d in ipairs(gui:GetDescendants()) do
                    if d:IsA("GuiObject") and d.Visible then
                        local abs = d.AbsoluteSize
                        local big = abs and abs.X >= vp.X * 0.5 and abs.Y >= vp.Y * 0.5
                        local img = nil
                        if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                            img = d.ImageTransparency
                        end
                        local interesting = (d.BackgroundTransparency and d.BackgroundTransparency <= 0.6)
                            or (img and img <= 0.6)
                        if big and interesting and #row.overlays < 24 then
                            local overlay = {
                                path = path(d),
                                class = d.ClassName,
                                bg = d.BackgroundTransparency,
                                img = img,
                                abs = tostring(abs),
                                pos = tostring(d.AbsolutePosition),
                                z = d.ZIndex,
                            }
                            local gradient = d:FindFirstChildOfClass("UIGradient")
                            if gradient then
                                local points = {}
                                for _, k in ipairs(gradient.Transparency.Keypoints) do
                                    table.insert(points, string.format("%.2f:%.2f", k.Time, k.Value))
                                end
                                overlay.gradient = table.concat(points, ",")
                            end
                            table.insert(row.overlays, overlay)
                        end
                    end
                end
                if #row.overlays > 0 or known then
                    table.insert(out, row)
                end
            end
        end
    end

    return out
end

local function snapshot(tag)
    local lighting = {}
    for key in pairs(TARGETS) do
        local ok, v = pcall(function() return Lighting[key] end)
        if ok then lighting[key] = valueText(v) end
    end

    local out = {
        tag = tag,
        t = os.clock(),
        place = tostring(game.PlaceId),
        fullbright = fullbright(),
        lighting = lighting,
        effects = effectRows(),
        screens = guiRows(true),
    }

    local encoded = HttpService:JSONEncode(out)
    -- Keep a single console line readable; the JSON is still one line.
    log("SNAP " .. encoded)
    remember(tag, encoded)
end

local function collectIssues()
    local out = {}
    if not fullbright() then return out end

    for key, target in pairs(TARGETS) do
        local ok, v = pcall(function() return Lighting[key] end)
        if ok then
            if typeof(target) == "number" then
                if math.abs(v - target) > 0.01 then
                    table.insert(out, key .. "=" .. num(v))
                end
            elseif typeof(target) == "Color3" then
                if math.abs(v.R - target.R) > 0.01
                    or math.abs(v.G - target.G) > 0.01
                    or math.abs(v.B - target.B) > 0.01 then
                    table.insert(out, key .. "=" .. color(v))
                end
            end
        end
    end

    for _, e in ipairs(effectRows()) do
        if e.enabled == true then
            table.insert(out, "effect:" .. e.class .. ":" .. e.path)
        end
        if e.class == "Atmosphere" and (e.density > 0.01 or e.haze > 0.01 or e.glare > 0.01) then
            table.insert(out, "atmosphere:" .. e.path .. " d=" .. num(e.density))
        end
    end

    for _, screen in ipairs(guiRows(true)) do
        if KNOWN[screen.name] then
            table.insert(out, "screen:" .. screen.name)
        end
        for _, overlay in ipairs(screen.overlays) do
            table.insert(out, "overlay:" .. screen.name .. "/" .. overlay.path)
        end
    end

    return out
end

local function logEvent(tag)
    remember(tag, "")
    log(string.format(
        "EVENT %s t=%.2f fb=%s exposure=%s bright=%s clock=%s ambient=%s",
        tag,
        os.clock(),
        tostring(fullbright()),
        tostring(Lighting.ExposureCompensation),
        tostring(Lighting.Brightness),
        tostring(Lighting.ClockTime),
        color(Lighting.Ambient)
    ))
end

W.Snapshot = function(tag)
    snapshot(tag or "manual")
end

W.Events = function()
    return W.events
end

W.Stop = function()
    W.running = false
    for _, c in ipairs(W.conns) do
        pcall(function() c:Disconnect() end)
    end
    W.conns = {}
    if _G.__fbWatch == W then _G.__fbWatch = nil end
    log("stopped")
end

if _G.__fbWatch and type(_G.__fbWatch.Stop) == "function" then
    pcall(_G.__fbWatch.Stop)
end

if not _G.__mafiaVisuals then
    log("suite not loaded; loading from 8766")
    pcall(function()
        loadstring(game:HttpGet("http://127.0.0.1:8766/lua/loaders/mafia_loader.lua"))()
    end)
    task.wait(1)
end

_G.__fbWatch = W

local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
if pg then
    for _, name in ipairs({
        "Emp",
        "EmpAfterimage",
        "EmpInk",
        "Vignette",
        "Fade",
        "nextNightTransition",
        "TeleportScreen",
        "Death",
        "UI",
    }) do
        local gui = pg:FindFirstChild(name)
        if gui then
            local conn = gui:GetPropertyChangedSignal("Enabled"):Connect(function()
                logEvent("screen " .. name .. " enabled=" .. tostring(gui.Enabled))
                if gui.Enabled then
                    snapshot("enabled:" .. name)
                end
            end)
            table.insert(W.conns, conn)
        end
    end
end

for _, key in ipairs({
    "ExposureCompensation",
    "Brightness",
    "ClockTime",
    "Ambient",
    "OutdoorAmbient",
    "FogEnd",
    "FogStart",
    "GlobalShadows",
    "EnvironmentDiffuseScale",
    "EnvironmentSpecularScale",
    "GeographicLatitude",
}) do
    local ok = pcall(function()
        local conn = Lighting:GetPropertyChangedSignal(key):Connect(function()
            if not fullbright() then return end
            local ok2, v = pcall(function() return Lighting[key] end)
            if not ok2 then return end
            local dark = false
            if key == "ExposureCompensation" then dark = v <= -1
            elseif key == "Brightness" then dark = v <= 0.8
            elseif key == "ClockTime" then dark = v <= 6
            elseif key == "Ambient" or key == "OutdoorAmbient" then dark = lum(v) < 0.25
            elseif key == "FogEnd" then dark = v < 1000
            elseif key == "FogStart" then dark = v > 100
            elseif key == "GlobalShadows" then dark = v == true
            elseif key == "EnvironmentDiffuseScale" or key == "EnvironmentSpecularScale" then dark = v < 0.5
            end
            if dark then
                logEvent("write " .. key .. "=" .. valueText(v))
            end
        end)
        table.insert(W.conns, conn)
    end)
end

log(string.format(
    "armed place=%s fullbright=%s exposure=%s bright=%s clock=%s",
    tostring(game.PlaceId),
    tostring(fullbright()),
    tostring(Lighting.ExposureCompensation),
    tostring(Lighting.Brightness),
    tostring(Lighting.ClockTime)
))

if _G.__mafiaVisuals and type(_G.__mafiaVisuals.SetFullbright) == "function" then
    _G.__mafiaVisuals.SetFullbright(true)
    log("fullbright forced on=" .. tostring(fullbright()))
end

task.spawn(function()
    while W.running do
        local issues = collectIssues()
        local key = table.concat(issues, "|")
        local now = os.clock()
        if #issues > 0 then
            if key ~= W.lastIssue or now - W.lastIssueAt > 2 then
                W.lastIssue = key
                W.lastIssueAt = now
                log("ISSUE " .. key)
                if now - W.lastSnapshotAt > 2 then
                    W.lastSnapshotAt = now
                    snapshot("issue")
                end
            end
        elseif W.lastIssue ~= "" then
            W.lastIssue = ""
            log("OK recovered t=" .. string.format("%.2f", now))
        end
        task.wait(0.1)
    end
end)
