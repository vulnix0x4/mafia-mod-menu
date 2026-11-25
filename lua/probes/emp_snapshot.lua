--!nocheck
--[[
    MAFIA - EMP snapshot probe

    Run while the screen is dark from an EMP:

        loadstring(game:HttpGet("http://127.0.0.1:8766/lua/probes/emp_snapshot.lua"))()

    Prints the lighting state, post-effects, and every large visible GuiObject
    with non-trivial transparency. Read-only.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local camera = game:GetService("Workspace").CurrentCamera
local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
local vp = camera and camera.ViewportSize or Vector2.new(1920, 1080)

local P = "[EMPSNAP]"
local function log(fmt, ...) print(P .. " " .. string.format(fmt, ...)) end

log("viewport=%s", tostring(vp))
log("brightness=%s exposure=%s ambient=%s outdoor=%s clock=%s fog=%s shadows=%s",
    tostring(Lighting.Brightness), tostring(Lighting.ExposureCompensation),
    tostring(Lighting.Ambient), tostring(Lighting.OutdoorAmbient),
    tostring(Lighting.ClockTime), tostring(Lighting.FogEnd),
    tostring(Lighting.GlobalShadows))

for _, d in ipairs(Lighting:GetDescendants()) do
    local cls = d.ClassName
    if cls == "BlurEffect" or cls == "BloomEffect" or cls == "SunRaysEffect"
        or cls == "DepthOfFieldEffect" or cls == "ColorCorrectionEffect" then
        local extra = ""
        if cls == "ColorCorrectionEffect" then
            extra = string.format(" b=%s c=%s s=%s tint=%s",
                tostring(d.Brightness), tostring(d.Contrast),
                tostring(d.Saturation), tostring(d.TintColor))
        end
        log("effect %s %s enabled=%s%s", cls, d:GetFullName(), tostring(d.Enabled), extra)
    elseif cls == "Atmosphere" then
        log("atmosphere %s density=%s haze=%s glare=%s",
            d:GetFullName(), tostring(d.Density), tostring(d.Haze), tostring(d.Glare))
    end
end

if not pg then
    log("no PlayerGui")
    return
end

local count = 0
for _, gui in ipairs(pg:GetChildren()) do
    if gui:IsA("ScreenGui") and gui.Name ~= "MafiaMenu" and gui.Name ~= "MafiaESP"
        and gui.Name ~= "MafiaHUD" then
        for _, d in ipairs(gui:GetDescendants()) do
            if d:IsA("GuiObject") and d.Visible then
                local abs = d.AbsoluteSize
                local big = abs.X >= vp.X * 0.8 and abs.Y >= vp.Y * 0.8
                if big then
                    local bg = d.BackgroundTransparency
                    local img = nil
                    if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                        img = d.ImageTransparency
                    end
                    local interesting = (bg ~= nil and bg < 0.95)
                        or (img ~= nil and img < 0.95)
                    if interesting then
                        count = count + 1
                        if count <= 120 then
                            log("gui %s %s abs=%s bgT=%s bg=%s imgT=%s image=%s z=%s",
                                d.ClassName, d:GetFullName(), tostring(abs),
                                tostring(bg), tostring(d.BackgroundColor3),
                                tostring(img), tostring(d:IsA("ImageLabel") and d.Image or ""),
                                tostring(d.ZIndex))
                        end
                    end
                end
            end
        end
    end
end
log("large-transparent guis=%d", count)
