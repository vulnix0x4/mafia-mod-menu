--!nocheck
--[[
    MAFIA - menu (v0.3.0)

    Redesigned Obsidian Noir UI with Movement as the primary tab, 2-column
    action/toggle grids for zero-scroll access, crisp typography, and full
    keyboard shortcuts.

    API: _G.__mafiaMenu
        .Open() / .Close() / .Set(bool) / .Toggle() / .Enabled()
        .SetTab("move" | "esp" | "visuals" | "system")
        .Center() / .Stop()
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local lp = Players.LocalPlayer

local API = {}
API.ID = tostring(os.clock()) .. "-" .. tostring(math.random(100000, 999999))
API.Version = "0.3.0"

local old = _G.__mafiaMenu
if old and old.ID ~= API.ID and type(old.Stop) == "function" then
    pcall(old.Stop)
end

local T = {
    bg = Color3.fromRGB(11, 12, 16),
    sidebar = Color3.fromRGB(16, 18, 24),
    header = Color3.fromRGB(15, 17, 23),
    card = Color3.fromRGB(22, 25, 34),
    cardHover = Color3.fromRGB(30, 34, 46),
    cardActive = Color3.fromRGB(34, 24, 33),
    border = Color3.fromRGB(40, 44, 58),
    borderHover = Color3.fromRGB(64, 70, 92),
    text = Color3.fromRGB(242, 244, 250),
    dim = Color3.fromRGB(160, 166, 186),
    faint = Color3.fromRGB(102, 108, 128),
    accent = Color3.fromRGB(232, 59, 90),
    accentDark = Color3.fromRGB(56, 22, 32),
    violet = Color3.fromRGB(138, 108, 255),
    green = Color3.fromRGB(94, 224, 154),
    amber = Color3.fromRGB(248, 186, 86),
    blue = Color3.fromRGB(92, 174, 255),
    red = Color3.fromRGB(240, 78, 98),
    off = Color3.fromRGB(38, 42, 54),
}

local FACTION_COLORS = {
    Town = T.blue,
    Mafia = T.red,
    Veil = T.violet,
    Neutral = T.amber,
    Unknown = T.dim,
}

local WIDTH, HEIGHT = 680, 476
local SIDEBAR, HEADER = 158, 48
local TW_FAST = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TW_MED = TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local running = true
local open = true
local minimized = false
local activeTab = "move"
local connections = {}
local pages = {}
local navItems = {}
local pageRefreshers = {}
local windowTween, shadowTween = nil, nil

local notify, toggleMinimize, centerWindow, minButton

local PAGE_META = {
    move = { title = "Movement", sub = "Kill macro, panic escape, flight & speed" },
    esp = { title = "ESP", sub = "Player tags, teammates & Crime Lab flags" },
    visuals = { title = "Visuals", sub = "EMP-proof fullbright & camera FOV" },
    system = { title = "System", sub = "Crime Lab feed, match log & profile" },
}

local TAB_ALIASES = {
    status = "move",
    players = "esp",
    claims = "esp",
    roles = "esp",
}

local function connect(signal, fn)
    local c = signal:Connect(fn)
    connections[#connections + 1] = c
    return c
end

local function make(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        inst[k] = v
    end
    if parent then inst.Parent = parent end
    return inst
end

local function corner(inst, r)
    return make("UICorner", { CornerRadius = UDim.new(0, r or 8) }, inst)
end

local function stroke(inst, color, trans, thick)
    return make("UIStroke", {
        Color = color or T.border,
        Transparency = trans == nil and 0.35 or trans,
        Thickness = thick or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
end

local function label(parent, props)
    props.BackgroundTransparency = 1
    props.BorderSizePixel = 0
    props.Font = props.Font or Enum.Font.Gotham
    return make("TextLabel", props, parent)
end

local function tween(inst, info, props)
    local tw = TweenService:Create(inst, info, props)
    tw:Play()
    return tw
end

-- module getters -------------------------------------------------------------

local function espApi() return _G.__mafiaESP end
local function moveApi() return _G.__mafiaMovement end
local function visApi() return _G.__mafiaVisuals end

local function espOpt(key)
    local api = espApi()
    return api and api.Options()[key] or false
end

local function setEspOpt(key, val)
    local api = espApi()
    if not api then error("ESP module missing") end
    api.SetOption(key, val)
end

-- shell ----------------------------------------------------------------------

local pg = lp and lp:FindFirstChild("PlayerGui")
if pg then
    for _, child in ipairs(pg:GetChildren()) do
        if child.Name == "MafiaMenu" then
            pcall(function() child:Destroy() end)
        end
    end
end

local gui = make("ScreenGui", {
    Name = "MafiaMenu",
    DisplayOrder = 100,
    IgnoreGuiInset = false,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, pg)

local shadow = make("Frame", {
    Name = "Shadow",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(1, -(WIDTH / 2 + 18), 0, HEIGHT / 2 + 24),
    Size = UDim2.fromOffset(WIDTH + 16, HEIGHT + 16),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.45,
    BorderSizePixel = 0,
    ZIndex = 0,
}, gui)
corner(shadow, 18)

local window = make("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(1, -(WIDTH / 2 + 18), 0, HEIGHT / 2 + 18),
    Size = UDim2.fromOffset(WIDTH, HEIGHT),
    BackgroundColor3 = T.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
    ZIndex = 2,
}, gui)
corner(window, 13)
stroke(window, T.border, 0.2, 1)

-- Subtle top accent bar
local topAccent = make("Frame", {
    Size = UDim2.new(1, 0, 0, 2),
    BackgroundColor3 = T.accent,
    BorderSizePixel = 0,
    ZIndex = 10,
}, window)
make("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, T.accent),
        ColorSequenceKeypoint.new(0.55, T.violet),
        ColorSequenceKeypoint.new(1, T.accent),
    }),
}, topAccent)

-- Header
local header = make("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, HEADER),
    BackgroundColor3 = T.header,
    BorderSizePixel = 0,
    ZIndex = 3,
}, window)

make("Frame", {
    Position = UDim2.new(0, 0, 1, -1),
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = T.border,
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    ZIndex = 4,
}, header)

local brandDot = make("Frame", {
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 16, 0.5, 0),
    Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = T.accent,
    BorderSizePixel = 0,
    ZIndex = 5,
}, header)
corner(brandDot, 4)

label(header, {
    Position = UDim2.new(0, 32, 0, 0),
    Size = UDim2.new(0, 86, 1, 0),
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.text,
    Text = "MAFIA",
    ZIndex = 5,
})

local verPill = make("Frame", {
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 96, 0.5, 0),
    Size = UDim2.fromOffset(42, 18),
    BackgroundColor3 = T.accentDark,
    BorderSizePixel = 0,
    ZIndex = 5,
}, header)
corner(verPill, 5)
label(verPill, {
    Size = UDim2.new(1, 0, 1, 0),
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextColor3 = T.accent,
    Text = "v" .. API.Version,
    ZIndex = 6,
})

local pageTitle = label(header, {
    Position = UDim2.new(0, SIDEBAR + 18, 0, 7),
    Size = UDim2.new(0, 260, 0, 18),
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.text,
    Text = "Movement",
    ZIndex = 5,
})

local pageSub = label(header, {
    Position = UDim2.new(0, SIDEBAR + 18, 0, 26),
    Size = UDim2.new(0, 320, 0, 14),
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.faint,
    Text = "Kill macro, panic escape, flight & speed",
    ZIndex = 5,
})

local dragArea = make("TextButton", {
    Name = "DragArea",
    Size = UDim2.new(1, -110, 1, 0),
    BackgroundTransparency = 1,
    AutoButtonColor = false,
    Text = "",
    ZIndex = 4,
}, header)

local function winBtn(txt, rightOffset, cb, danger)
    local b = make("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, rightOffset, 0.5, 0),
        Size = UDim2.fromOffset(24, 24),
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = T.dim,
        Text = txt,
        ZIndex = 6,
    }, header)
    corner(b, 6)
    stroke(b, T.border, 0.5, 1)
    connect(b.MouseEnter, function()
        tween(b, TW_FAST, {
            BackgroundColor3 = danger and T.red or T.cardHover,
            TextColor3 = Color3.new(1, 1, 1),
        })
    end)
    connect(b.MouseLeave, function()
        tween(b, TW_FAST, { BackgroundColor3 = T.card, TextColor3 = T.dim })
    end)
    connect(b.MouseButton1Click, cb)
    return b
end

winBtn("×", -14, function() API.Set(false) end, true)
minButton = winBtn("–", -44, function() toggleMinimize() end)
winBtn("⌂", -74, function() centerWindow(); notify("Window recentered") end)

-- Sidebar --------------------------------------------------------------------

local sidebar = make("Frame", {
    Name = "Sidebar",
    Position = UDim2.new(0, 0, 0, HEADER),
    Size = UDim2.new(0, SIDEBAR, 1, -HEADER),
    BackgroundColor3 = T.sidebar,
    BorderSizePixel = 0,
    ZIndex = 3,
}, window)

make("Frame", {
    Position = UDim2.new(1, -1, 0, 0),
    Size = UDim2.new(0, 1, 1, 0),
    BackgroundColor3 = T.border,
    BackgroundTransparency = 0.45,
    BorderSizePixel = 0,
    ZIndex = 4,
}, sidebar)

local navList = make("Frame", {
    Position = UDim2.new(0, 10, 0, 12),
    Size = UDim2.new(1, -20, 0, 220),
    BackgroundTransparency = 1,
    ZIndex = 4,
}, sidebar)
make("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, navList)

local navOrder = 0
local function navButton(id, icon, title, desc)
    navOrder = navOrder + 1
    local btn = make("TextButton", {
        Name = id,
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = T.card,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = navOrder,
        ZIndex = 5,
    }, navList)
    corner(btn, 9)
    local st = stroke(btn, T.border, 1, 1)

    local bar = make("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.fromOffset(3, 22),
        BackgroundColor3 = T.accent,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 6,
    }, btn)
    corner(bar, 2)

    local ico = label(btn, {
        Position = UDim2.new(0, 12, 0, 0),
        Size = UDim2.new(0, 20, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = T.faint,
        Text = icon,
        ZIndex = 6,
    })

    local tl = label(btn, {
        Position = UDim2.new(0, 34, 0, 6),
        Size = UDim2.new(1, -40, 0, 16),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = T.dim,
        Text = title,
        ZIndex = 6,
    })

    local dl = label(btn, {
        Position = UDim2.new(0, 34, 0, 23),
        Size = UDim2.new(1, -40, 0, 13),
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = T.faint,
        Text = desc,
        ZIndex = 6,
    })

    local function paint(active)
        tween(btn, TW_FAST, { BackgroundTransparency = active and 0 or 1 })
        tween(st, TW_FAST, { Transparency = active and 0.35 or 1 })
        tween(bar, TW_FAST, { BackgroundTransparency = active and 0 or 1 })
        tween(tl, TW_FAST, { TextColor3 = active and T.text or T.dim })
        tween(dl, TW_FAST, { TextColor3 = active and T.dim or T.faint })
        tween(ico, TW_FAST, { TextColor3 = active and T.accent or T.faint })
    end

    connect(btn.MouseEnter, function()
        if activeTab ~= id then
            tween(btn, TW_FAST, { BackgroundTransparency = 0.55 })
        end
    end)
    connect(btn.MouseLeave, function()
        if activeTab ~= id then
            tween(btn, TW_FAST, { BackgroundTransparency = 1 })
        end
    end)
    connect(btn.MouseButton1Click, function() API.SetTab(id) end)

    navItems[id] = { paint = paint }
    paint(id == activeTab)
end

navButton("move", "⚡", "Movement", "Kill · Fly · Speed")
navButton("esp", "◎", "ESP", "Tags · Crime Lab")
navButton("visuals", "☀", "Visuals", "Fullbright · FOV")
navButton("system", "⌘", "System", "Logs · Profile")

-- Compact Live Status Card in Sidebar
local liveCard = make("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 10, 1, -12),
    Size = UDim2.new(1, -20, 0, 86),
    BackgroundColor3 = T.card,
    BorderSizePixel = 0,
    ZIndex = 4,
}, sidebar)
corner(liveCard, 10)
stroke(liveCard, T.border, 0.4, 1)

local liveDot = make("Frame", {
    Position = UDim2.new(0, 10, 0, 11),
    Size = UDim2.fromOffset(6, 6),
    BackgroundColor3 = T.green,
    BorderSizePixel = 0,
    ZIndex = 5,
}, liveCard)
corner(liveDot, 3)

local livePhase = label(liveCard, {
    Position = UDim2.new(0, 22, 0, 6),
    Size = UDim2.new(1, -28, 0, 16),
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.green,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "LOBBY",
    ZIndex = 5,
})

local liveRole = label(liveCard, {
    Position = UDim2.new(0, 10, 0, 28),
    Size = UDim2.new(1, -20, 0, 16),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.text,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Text = "No Role",
    ZIndex = 5,
})

local liveAlive = label(liveCard, {
    Position = UDim2.new(0, 10, 0, 48),
    Size = UDim2.new(1, -20, 0, 14),
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.dim,
    Text = "Alive 0 / 0",
    ZIndex = 5,
})

label(liveCard, {
    Position = UDim2.new(0, 10, 0, 65),
    Size = UDim2.new(1, -20, 0, 13),
    Font = Enum.Font.Gotham,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.faint,
    Text = "RightShift: toggle UI",
    ZIndex = 5,
})

-- Content Host ---------------------------------------------------------------

local pageHost = make("Frame", {
    Name = "PageHost",
    Position = UDim2.new(0, SIDEBAR, 0, HEADER),
    Size = UDim2.new(1, -SIDEBAR, 1, -HEADER),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    ZIndex = 3,
}, window)

-- Toast ----------------------------------------------------------------------

local toast = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, SIDEBAR / 2, 1, -12),
    Size = UDim2.new(0, 340, 0, 30),
    BackgroundColor3 = T.card,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 30,
}, window)
corner(toast, 8)
local toastStroke = stroke(toast, T.accent, 0.25, 1)
local toastDot = make("Frame", {
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 12, 0.5, 0),
    Size = UDim2.fromOffset(6, 6),
    BackgroundColor3 = T.accent,
    BorderSizePixel = 0,
    ZIndex = 31,
}, toast)
corner(toastDot, 3)
local toastLabel = label(toast, {
    Position = UDim2.new(0, 26, 0, 0),
    Size = UDim2.new(1, -36, 1, 0),
    Font = Enum.Font.GothamMedium,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.text,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 31,
})

local toastSerial = 0
notify = function(msg, isError)
    toastSerial = toastSerial + 1
    local serial = toastSerial
    toastLabel.Text = tostring(msg)
    toastLabel.TextColor3 = isError and T.red or T.text
    toastStroke.Color = isError and T.red or T.accent
    toastDot.BackgroundColor3 = isError and T.red or T.accent
    toast.Visible = true
    toast.Position = UDim2.new(0.5, SIDEBAR / 2, 1, 4)
    tween(toast, TW_FAST, { Position = UDim2.new(0.5, SIDEBAR / 2, 1, -12) })
    task.delay(2.2, function()
        if not running or toastSerial ~= serial then return end
        tween(toast, TW_FAST, { Position = UDim2.new(0.5, SIDEBAR / 2, 1, 4) })
        task.delay(0.16, function()
            if running and toastSerial == serial then toast.Visible = false end
        end)
    end)
end

-- Window motion --------------------------------------------------------------

local function syncShadow()
    shadow.Position = UDim2.new(
        window.Position.X.Scale, window.Position.X.Offset,
        window.Position.Y.Scale, window.Position.Y.Offset + 6
    )
    shadow.Size = UDim2.new(
        window.Size.X.Scale, window.Size.X.Offset + 16,
        window.Size.Y.Scale, window.Size.Y.Offset + 16
    )
end

centerWindow = function()
    window.Position = UDim2.new(0.5, 0, 0.5, 0)
    syncShadow()
end

local function clampWindow(fw, fh)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    local sx = fw or window.AbsoluteSize.X
    local sy = fh or window.AbsoluteSize.Y
    if sx <= 0 or sy <= 0 then return end
    local hw, hh = sx / 2, sy / 2
    local x = vp.X * window.Position.X.Scale + window.Position.X.Offset
    local y = vp.Y * window.Position.Y.Scale + window.Position.Y.Offset
    x = math.clamp(x, hw, math.max(hw, vp.X - hw))
    y = math.clamp(y, hh, math.max(hh, vp.Y - hh))
    window.Position = UDim2.fromOffset(x, y)
    syncShadow()
end

toggleMinimize = function()
    minimized = not minimized
    sidebar.Visible = not minimized
    pageHost.Visible = not minimized
    minButton.Text = minimized and "+" or "–"
    local th = minimized and HEADER or HEIGHT
    if windowTween then pcall(function() windowTween:Cancel() end) end
    if shadowTween then pcall(function() shadowTween:Cancel() end) end
    windowTween = tween(window, TW_MED, { Size = UDim2.fromOffset(WIDTH, th) })
    shadowTween = tween(shadow, TW_MED, {
        Size = UDim2.fromOffset(WIDTH + 16, th + 16),
        Position = UDim2.new(window.Position.X.Scale, window.Position.X.Offset, window.Position.Y.Scale, window.Position.Y.Offset + 6),
    })
    task.delay(0.22, function() if running then clampWindow() end end)
end

-- Component Builders ---------------------------------------------------------

local orderSeq = 0
local function nextOrder()
    orderSeq = orderSeq + 1
    return orderSeq
end

local function newPage(id)
    orderSeq = 0
    local page = make("ScrollingFrame", {
        Name = id,
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = T.borderHover,
        ScrollBarImageTransparency = 0.2,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false,
        ZIndex = 4,
    }, pageHost)
    make("UIListLayout", {
        Padding = UDim.new(0, 10),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, page)
    make("UIPadding", {
        PaddingLeft = UDim.new(0, 16),
        PaddingRight = UDim.new(0, 16),
        PaddingTop = UDim.new(0, 14),
        PaddingBottom = UDim.new(0, 18),
    }, page)
    pageRefreshers[id] = {}
    pages[id] = page
    return page
end

local function section(page, text)
    local row = make("Frame", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        ZIndex = 4,
    }, page)
    label(row, {
        Size = UDim2.new(1, 0, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = T.faint,
        Text = string.upper(text),
        ZIndex = 5,
    })
end

local function makeRowContainer(page, height)
    return make("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        ZIndex = 4,
    }, page)
end

local function attachHover(hit, frame, st, baseColor)
    connect(hit.MouseEnter, function()
        tween(frame, TW_FAST, { BackgroundColor3 = T.cardHover })
        if st then tween(st, TW_FAST, { Transparency = 0.1 }) end
    end)
    connect(hit.MouseLeave, function()
        tween(frame, TW_FAST, { BackgroundColor3 = baseColor or T.card })
        if st then tween(st, TW_FAST, { Transparency = 0.35 }) end
    end)
end

local function keyPill(parent, keyText, color)
    local pill = make("Frame", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -10, 0, 10),
        Size = UDim2.fromOffset(math.max(24, #keyText * 7 + 12), 18),
        BackgroundColor3 = T.off,
        BorderSizePixel = 0,
        ZIndex = 6,
    }, parent)
    corner(pill, 5)
    label(pill, {
        Size = UDim2.new(1, 0, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = color or T.dim,
        Text = keyText,
        ZIndex = 7,
    })
    return pill
end

-- Big 2-column Hero Action Buttons (Role Combo / Panic Locker)
local function actionPair(page, leftSpec, rightSpec)
    local wrap = makeRowContainer(page, 64)
    local specs = {
        { spec = leftSpec, pos = UDim2.new(0, 0, 0, 0), size = UDim2.new(0.5, -5, 1, 0) },
        { spec = rightSpec, pos = UDim2.new(0.5, 5, 0, 0), size = UDim2.new(0.5, -5, 1, 0) },
    }
    local refs = {}
    for idx, item in ipairs(specs) do
        local s = item.spec
        local accentCol = s.color or T.accent
        local bgCol = s.bg or T.card
        local f = make("Frame", {
            Position = item.pos,
            Size = item.size,
            BackgroundColor3 = bgCol,
            BorderSizePixel = 0,
            ZIndex = 5,
        }, wrap)
        corner(f, 10)
        local st = stroke(f, accentCol, 0.35, 1)

        local stripe = make("Frame", {
            Position = UDim2.new(0, 0, 0, 10),
            Size = UDim2.new(0, 3, 1, -20),
            BackgroundColor3 = accentCol,
            BorderSizePixel = 0,
            ZIndex = 6,
        }, f)
        corner(stripe, 2)

        local tl = label(f, {
            Position = UDim2.new(0, 14, 0, 10),
            Size = UDim2.new(1, -56, 0, 20),
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = T.text,
            Text = s.title,
            ZIndex = 6,
        })

        local sl = label(f, {
            Position = UDim2.new(0, 14, 0, 33),
            Size = UDim2.new(1, -24, 0, 22),
            Font = Enum.Font.Gotham,
            TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextColor3 = T.dim,
            Text = s.sub or "",
            ZIndex = 6,
        })

        local kp = s.key and keyPill(f, s.key, accentCol) or nil

        local hit = make("TextButton", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            ZIndex = 8,
        }, f)
        attachHover(hit, f, st, bgCol)
        connect(hit.MouseButton1Click, function()
            local ok, err = pcall(s.onClick)
            if not ok then notify(tostring(err), true) end
        end)
        refs[idx] = { frame = f, stroke = st, stripe = stripe, title = tl, sub = sl, pill = kp }
    end
    return refs[1], refs[2]
end

-- Compact 2-column Toggle Tile Grid
local function toggleGrid(page, items)
    local cols = 2
    local tileH = 50
    local gap = 8
    local rows = math.ceil(#items / cols)
    local totalH = rows * tileH + math.max(0, rows - 1) * gap
    local wrap = makeRowContainer(page, totalH)

    for idx, item in ipairs(items) do
        local col = (idx - 1) % cols
        local row = math.floor((idx - 1) / cols)
        local f = make("Frame", {
            Position = UDim2.new(col == 0 and 0 or 0.5, col == 0 and 0 or 4, 0, row * (tileH + gap)),
            Size = UDim2.new(0.5, -4, 0, tileH),
            BackgroundColor3 = T.card,
            BorderSizePixel = 0,
            ZIndex = 5,
        }, wrap)
        corner(f, 9)
        local st = stroke(f, T.border, 0.4, 1)

        local titleLbl = label(f, {
            Position = UDim2.new(0, 12, 0, 8),
            Size = UDim2.new(1, -66, 0, 17),
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = T.dim,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = item.title,
            ZIndex = 6,
        })

        local subLbl = label(f, {
            Position = UDim2.new(0, 12, 0, 26),
            Size = UDim2.new(1, -66, 0, 14),
            Font = Enum.Font.Gotham,
            TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = T.faint,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = item.key and ("Hotkey: " .. item.key) or (item.sub or ""),
            ZIndex = 6,
        })

        -- Pill switch
        local track = make("Frame", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -12, 0.5, 0),
            Size = UDim2.fromOffset(38, 20),
            BackgroundColor3 = T.off,
            BorderSizePixel = 0,
            ZIndex = 6,
        }, f)
        corner(track, 10)
        local knob = make("Frame", {
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 3, 0.5, 0),
            Size = UDim2.fromOffset(14, 14),
            BackgroundColor3 = Color3.fromRGB(190, 196, 212),
            BorderSizePixel = 0,
            ZIndex = 7,
        }, track)
        corner(knob, 7)

        local state = false
        local function paint(on)
            state = on == true
            tween(track, TW_FAST, { BackgroundColor3 = state and T.accent or T.off })
            tween(knob, TW_FAST, {
                Position = state and UDim2.new(0, 21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
                BackgroundColor3 = state and Color3.new(1, 1, 1) or Color3.fromRGB(190, 196, 212),
            })
            tween(st, TW_FAST, { Color = state and T.accent or T.border, Transparency = state and 0.35 or 0.45 })
            titleLbl.TextColor3 = state and T.text or T.dim
            subLbl.TextColor3 = state and T.dim or T.faint
        end

        local hit = make("TextButton", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            ZIndex = 8,
        }, f)

        connect(hit.MouseEnter, function() tween(f, TW_FAST, { BackgroundColor3 = T.cardHover }) end)
        connect(hit.MouseLeave, function() tween(f, TW_FAST, { BackgroundColor3 = T.card }) end)

        connect(hit.MouseButton1Click, function()
            local nextState = not state
            if item.set then
                local ok, res, err = pcall(item.set, nextState)
                if not ok then
                    notify(tostring(res or "failed"), true)
                    return
                elseif res == false and err ~= nil then
                    notify(tostring(err), true)
                    return
                end
            end
            paint(nextState)
        end)

        local function refresh()
            if item.get then
                local ok, val = pcall(item.get)
                if ok and val ~= nil then paint(val) end
            end
        end

        table.insert(pageRefreshers[page.Name], refresh)
        refresh()
    end
end

-- Compact 2-column Button Pair
local function buttonPair(page, leftSpec, rightSpec)
    local wrap = makeRowContainer(page, 40)
    local specs = {
        { spec = leftSpec, pos = UDim2.new(0, 0, 0, 0), size = UDim2.new(0.5, -4, 1, 0) },
        { spec = rightSpec, pos = UDim2.new(0.5, 4, 0, 0), size = UDim2.new(0.5, -4, 1, 0) },
    }
    for _, item in ipairs(specs) do
        local s = item.spec
        if s then
            local f = make("Frame", {
                Position = item.pos,
                Size = item.size,
                BackgroundColor3 = s.danger and T.accentDark or T.card,
                BorderSizePixel = 0,
                ZIndex = 5,
            }, wrap)
            corner(f, 8)
            local st = stroke(f, s.danger and T.red or T.border, 0.4, 1)

            label(f, {
                Position = UDim2.new(0, 12, 0, 0),
                Size = UDim2.new(1, -24, 1, 0),
                Font = Enum.Font.GothamBold,
                TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Center,
                TextColor3 = s.danger and T.red or T.text,
                Text = s.title,
                ZIndex = 6,
            })

            local hit = make("TextButton", {
                Size = UDim2.new(1, 0, 1, 0),
                BackgroundTransparency = 1,
                AutoButtonColor = false,
                Text = "",
                ZIndex = 8,
            }, f)
            attachHover(hit, f, st, s.danger and T.accentDark or T.card)
            connect(hit.MouseButton1Click, function()
                local ok, err = pcall(s.onClick)
                if not ok then notify(tostring(err), true) end
            end)
        end
    end
end

-- Full-width Slider Card
local function sliderCard(page, title, subtitle, getter, setter, minV, maxV, stepV, fmt)
    local f = make("Frame", {
        Size = UDim2.new(1, 0, 0, 58),
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        ZIndex = 5,
    }, page)
    corner(f, 9)
    local st = stroke(f, T.border, 0.4, 1)

    label(f, {
        Position = UDim2.new(0, 14, 0, 7),
        Size = UDim2.new(1, -90, 0, 16),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = T.text,
        Text = title,
        ZIndex = 6,
    })

    label(f, {
        Position = UDim2.new(0, 14, 0, 23),
        Size = UDim2.new(1, -90, 0, 13),
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = T.faint,
        Text = subtitle or "",
        ZIndex = 6,
    })

    local valPill = make("Frame", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 9),
        Size = UDim2.fromOffset(58, 20),
        BackgroundColor3 = T.off,
        BorderSizePixel = 0,
        ZIndex = 6,
    }, f)
    corner(valPill, 6)
    local valLbl = label(valPill, {
        Size = UDim2.new(1, 0, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = T.text,
        Text = "",
        ZIndex = 7,
    })

    local track = make("Frame", {
        Position = UDim2.new(0, 14, 0, 43),
        Size = UDim2.new(1, -28, 0, 5),
        BackgroundColor3 = T.off,
        BorderSizePixel = 0,
        ZIndex = 6,
    }, f)
    corner(track, 3)

    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = T.accent,
        BorderSizePixel = 0,
        ZIndex = 7,
    }, track)
    corner(fill, 3)

    local knob = make("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.fromOffset(13, 13),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 8,
    }, track)
    corner(knob, 7)
    stroke(knob, T.accent, 0.1, 2)

    local hit = make("TextButton", {
        Position = UDim2.new(0, 8, 0, 32),
        Size = UDim2.new(1, -16, 0, 24),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        ZIndex = 9,
    }, f)

    local dragging = false
    local lastVal = nil
    local fillTw, knobTw = nil, nil

    local function paint(v, instant)
        v = math.clamp(tonumber(v) or minV, minV, maxV)
        if lastVal == v then return end
        lastVal = v
        local r = (v - minV) / math.max(maxV - minV, 0.0001)
        valLbl.Text = fmt and fmt(v) or tostring(v)
        local ns = UDim2.new(r, 0, 1, 0)
        local np = UDim2.new(r, 0, 0.5, 0)
        if instant then
            if fillTw then fillTw:Cancel() end
            if knobTw then knobTw:Cancel() end
            fill.Size = ns
            knob.Position = np
        else
            fillTw = tween(fill, TW_FAST, { Size = ns })
            knobTw = tween(knob, TW_FAST, { Position = np })
        end
    end

    local function commit(x)
        local rel = (x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1)
        local raw = minV + math.clamp(rel, 0, 1) * (maxV - minV)
        if stepV and stepV > 0 then
            raw = minV + math.floor((raw - minV) / stepV + 0.5) * stepV
        end
        raw = math.clamp(raw, minV, maxV)
        if setter then
            local ok, err = pcall(setter, raw)
            if not ok then notify(tostring(err), true); return end
        end
        paint(raw, true)
    end

    connect(hit.MouseButton1Down, function(x) dragging = true; commit(x) end)
    connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            commit(input.Position.X)
        end
    end)
    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    attachHover(hit, f, st, T.card)

    local function refresh()
        if dragging then return end
        local v = getter and getter() or minV
        paint(v, false)
    end
    table.insert(pageRefreshers[page.Name], refresh)
    refresh()
end

-- Master Hero Toggle Card (used on ESP & Visuals)
local function heroToggle(page, title, sub, getter, setter, key)
    local f = make("Frame", {
        Size = UDim2.new(1, 0, 0, 68),
        BackgroundColor3 = T.card,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        ZIndex = 5,
    }, page)
    corner(f, 10)
    local st = stroke(f, T.border, 0.3, 1)

    local tl = label(f, {
        Position = UDim2.new(0, 16, 0, 12),
        Size = UDim2.new(1, -130, 0, 20),
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = T.text,
        Text = title,
        ZIndex = 6,
    })

    local sl = label(f, {
        Position = UDim2.new(0, 16, 0, 36),
        Size = UDim2.new(1, -130, 0, 16),
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextColor3 = T.dim,
        Text = sub,
        ZIndex = 6,
    })

    if key then
        local kp = keyPill(f, key, T.dim)
        kp.AnchorPoint = Vector2.new(1, 0.5)
        kp.Position = UDim2.new(1, -76, 0.5, 0)
    end

    local track = make("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -16, 0.5, 0),
        Size = UDim2.fromOffset(48, 24),
        BackgroundColor3 = T.off,
        BorderSizePixel = 0,
        ZIndex = 6,
    }, f)
    corner(track, 12)
    local knob = make("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = Color3.fromRGB(190, 196, 212),
        BorderSizePixel = 0,
        ZIndex = 7,
    }, track)
    corner(knob, 9)

    local state = false
    local function paint(on)
        state = on == true
        tween(track, TW_FAST, { BackgroundColor3 = state and T.accent or T.off })
        tween(knob, TW_FAST, {
            Position = state and UDim2.new(0, 27, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
            BackgroundColor3 = state and Color3.new(1, 1, 1) or Color3.fromRGB(190, 196, 212),
        })
        tween(st, TW_FAST, { Color = state and T.accent or T.border, Transparency = state and 0.3 or 0.4 })
        tl.TextColor3 = state and T.text or T.dim
    end

    local hit = make("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        ZIndex = 8,
    }, f)
    attachHover(hit, f, st, T.card)
    connect(hit.MouseButton1Click, function()
        local ns = not state
        if setter then
            local ok, res, err = pcall(setter, ns)
            if not ok then notify(tostring(res or "failed"), true); return
            elseif res == false and err ~= nil then notify(tostring(err), true); return end
        end
        paint(ns)
    end)

    local function refresh()
        if getter then
            local ok, v = pcall(getter)
            if ok and v ~= nil then paint(v) end
        end
    end
    table.insert(pageRefreshers[page.Name], refresh)
    refresh()
    return { sub = sl }
end

-- ============================================================================
-- PAGE 1: MOVEMENT (PRIMARY)
-- ============================================================================

local movePage = newPage("move")

section(movePage, "quick actions")

local roleComboCard = actionPair(movePage, {
    title = "Role Combo",
    sub = "Auto-adapts to Mafia / Doc / Poison / Witch / etc.",
    key = "K",
    color = T.red,
    bg = T.cardActive,
    onClick = function()
        local api = moveApi()
        if not api then return notify("Movement module missing", true) end
        local ok, info = (api.RoleCombo or api.KillFarthest)()
        notify(ok and tostring(info) or tostring(info), not ok)
    end,
}, {
    title = "Panic Locker",
    sub = "Instant escape to nearest empty locker",
    key = "HOME",
    color = T.amber,
    bg = T.card,
    onClick = function()
        local api = moveApi()
        if not api then return notify("Movement module missing", true) end
        local ok, info = api.PanicLocker()
        notify(ok and ("Panic → " .. tostring(info)) or tostring(info), not ok)
    end,
})

local ROLE_COLOR_MAP = {
    red = T.red,
    blue = T.blue,
    violet = T.violet,
    amber = T.amber,
}

table.insert(pageRefreshers.move, function()
    local a = moveApi()
    if not a or type(a.RoleActionInfo) ~= "function" then return end
    local info = a.RoleActionInfo()
    local col = ROLE_COLOR_MAP[info.color] or T.accent
    roleComboCard.title.Text = info.title
    roleComboCard.sub.Text = info.sub
    roleComboCard.stroke.Color = col
    roleComboCard.stripe.BackgroundColor3 = col
end)

-- Kill target picker (Auto isolated or pick specific username)
local pickerWrap = make("Frame", {
    Size = UDim2.new(1, 0, 0, 38),
    BackgroundColor3 = T.card,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    LayoutOrder = nextOrder(),
    ZIndex = 5,
}, movePage)
corner(pickerWrap, 9)
local pickerStroke = stroke(pickerWrap, T.border, 0.4, 1)

local pickerExpanded = false

local pickerHeader = make("Frame", {
    Size = UDim2.new(1, 0, 0, 38),
    BackgroundTransparency = 1,
    ZIndex = 6,
}, pickerWrap)

label(pickerHeader, {
    Position = UDim2.new(0, 12, 0, 0),
    Size = UDim2.new(0, 56, 1, 0),
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.faint,
    Text = "TARGET",
    ZIndex = 7,
})

local targetLbl = label(pickerHeader, {
    Position = UDim2.new(0, 68, 0, 0),
    Size = UDim2.new(1, -158, 1, 0),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextColor3 = T.text,
    Text = "Auto (most isolated)",
    ZIndex = 7,
})

local pickerToggleBtn = make("TextButton", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -54, 0.5, 0),
    Size = UDim2.fromOffset(48, 22),
    BackgroundColor3 = T.off,
    BorderSizePixel = 0,
    AutoButtonColor = false,
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    TextColor3 = T.dim,
    Text = "PICK ▾",
    ZIndex = 8,
}, pickerHeader)
corner(pickerToggleBtn, 6)

local autoBtn = make("TextButton", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -8, 0.5, 0),
    Size = UDim2.fromOffset(42, 22),
    BackgroundColor3 = T.off,
    BorderSizePixel = 0,
    AutoButtonColor = false,
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextColor3 = T.dim,
    Text = "AUTO",
    ZIndex = 8,
}, pickerHeader)
corner(autoBtn, 6)

local pickerScroll = make("ScrollingFrame", {
    Position = UDim2.new(0, 8, 0, 40),
    Size = UDim2.new(1, -16, 0, 126),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = T.borderHover,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    Visible = false,
    ZIndex = 7,
}, pickerWrap)
make("UIListLayout", {
    Padding = UDim.new(0, 4),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, pickerScroll)

local function refreshKillTargetLabel()
    local a = moveApi()
    local t = a and type(a.KillTarget) == "function" and a.KillTarget() or nil
    if t then
        targetLbl.Text = string.format("%s  (@%s)", t.disguise, t.name)
        targetLbl.TextColor3 = T.red
        pickerStroke.Color = T.red
    else
        targetLbl.Text = "Auto (most isolated)"
        targetLbl.TextColor3 = T.text
        pickerStroke.Color = T.border
    end
end

local function rebuildPickerList()
    for _, child in ipairs(pickerScroll:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    local a = moveApi()
    local list = a and type(a.KillCandidates) == "function" and a.KillCandidates() or {}
    if #list == 0 then
        local empty = make("TextButton", {
            Size = UDim2.new(1, 0, 0, 26),
            BackgroundColor3 = T.sidebar,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            TextColor3 = T.faint,
            Text = "No alive non-mafia targets",
            ZIndex = 8,
        }, pickerScroll)
        corner(empty, 6)
        return
    end
    local cur = a.KillTarget()
    for i, entry in ipairs(list) do
        local isSel = cur and cur.userId == entry.userId
        local rowBtn = make("TextButton", {
            Size = UDim2.new(1, 0, 0, 26),
            BackgroundColor3 = isSel and T.cardActive or T.sidebar,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = isSel and T.red or T.text,
            Text = string.format("  %s  (@%s)  ·  %.0fm", entry.disguise, entry.name, entry.dist),
            LayoutOrder = i,
            ZIndex = 8,
        }, pickerScroll)
        corner(rowBtn, 6)
        connect(rowBtn.MouseButton1Click, function()
            local ok, msg = a.SetKillTarget(entry.userId)
            notify(ok and ("Kill target → " .. tostring(msg)) or tostring(msg), not ok)
            pickerExpanded = false
            pickerScroll.Visible = false
            pickerToggleBtn.Text = "PICK ▾"
            tween(pickerWrap, TW_FAST, { Size = UDim2.new(1, 0, 0, 38) })
            refreshKillTargetLabel()
        end)
    end
end

connect(pickerToggleBtn.MouseButton1Click, function()
    pickerExpanded = not pickerExpanded
    pickerToggleBtn.Text = pickerExpanded and "HIDE ▴" or "PICK ▾"
    if pickerExpanded then
        rebuildPickerList()
        pickerScroll.Visible = true
        tween(pickerWrap, TW_FAST, { Size = UDim2.new(1, 0, 0, 174) })
    else
        pickerScroll.Visible = false
        tween(pickerWrap, TW_FAST, { Size = UDim2.new(1, 0, 0, 38) })
    end
end)

connect(autoBtn.MouseButton1Click, function()
    local a = moveApi()
    if a and type(a.SetKillTarget) == "function" then
        a.SetKillTarget(nil)
        notify("Kill target → Auto (most isolated)")
        refreshKillTargetLabel()
        if pickerExpanded then rebuildPickerList() end
    end
end)

table.insert(pageRefreshers.move, refreshKillTargetLabel)

section(movePage, "locomotion")

toggleGrid(movePage, {
    {
        title = "Noclip",
        key = "V",
        get = function() local a = moveApi(); return a and a.Noclip() or false end,
        set = function(v) local a = moveApi(); if not a then error("missing") end; a.SetNoclip(v) end,
    },
    {
        title = "Fly / Ghost",
        key = "X",
        get = function() local a = moveApi(); return a and a.Fly() or false end,
        set = function(v) local a = moveApi(); if not a then error("missing") end; a.SetFly(v) end,
    },
    {
        title = "Speed Boost",
        key = "Q",
        get = function() local a = moveApi(); return a and a.Speed() or false end,
        set = function(v) local a = moveApi(); if not a then error("missing") end; a.SetSpeed(v) end,
    },
    {
        title = "Fullbright",
        key = "Y",
        get = function() local a = visApi(); return a and a.Fullbright() or false end,
        set = function(v) local a = visApi(); if not a then error("missing") end; a.SetFullbright(v) end,
    },
})

sliderCard(movePage, "Speed Multiplier", "Walk speed while Speed Boost is active",
    function() local a = moveApi(); return a and a.Multiplier() or 5 end,
    function(v) local a = moveApi(); if a then a.SetMultiplier(v) end end,
    1, 5, 0.25, function(v) return string.format("%.2fx", v) end)

sliderCard(movePage, "Fly Speed", "Base flight speed (hold Shift for 3x)",
    function() local a = moveApi(); return a and a.FlySpeed() or 50 end,
    function(v) local a = moveApi(); if a then a.SetFlySpeed(v) end end,
    15, 200, 5, function(v) return string.format("%d", v) end)

section(movePage, "teleport")

buttonPair(movePage, {
    title = "TP Nearest Player",
    onClick = function()
        local a = moveApi()
        if not a then return notify("Movement module missing", true) end
        local ok, name = a.TeleportToNearestPlayer()
        notify(ok and ("TP → " .. tostring(name)) or tostring(name), not ok)
    end,
}, {
    title = "TP to Cursor",
    onClick = function()
        local a = moveApi()
        if not a then return notify("Movement module missing", true) end
        local ok, err = a.TeleportToCursor()
        notify(ok and "Teleported to cursor" or tostring(err), not ok)
    end,
})

section(movePage, "character & fun")

toggleGrid(movePage, {
    {
        title = "Spinbot",
        sub = "Continuous rotation",
        get = function() local a = moveApi(); return a and a.Spin() or false end,
        set = function(v) local a = moveApi(); if a then a.SetSpin(v) end end,
    },
    {
        title = "Ragdoll Self",
        sub = "Force ragdoll state",
        get = function() local a = moveApi(); return a and a.Ragdoll() or false end,
        set = function(v) local a = moveApi(); if a then a.SetRagdoll(v) end end,
    },
    {
        title = "Emote Spam",
        sub = "Cycle animations",
        get = function() local a = moveApi(); return a and a.EmoteSpam() or false end,
        set = function(v) local a = moveApi(); if a then a.SetEmoteSpam(v) end end,
    },
})

sliderCard(movePage, "Character Scale", "1.0x is normal body & head size",
    function() local a = moveApi(); return a and a.Scale() or 1 end,
    function(v) local a = moveApi(); if a then a.SetScale(v) end end,
    0.5, 2.0, 0.1, function(v) return string.format("%.1fx", v) end)

buttonPair(movePage, {
    title = "Reset All Movement",
    danger = true,
    onClick = function()
        local a = moveApi()
        if not a then return notify("Movement module missing", true) end
        a.SetScale(1); a.SetRagdoll(false); a.SetSpin(false)
        a.SetEmoteSpam(false); a.SetFly(false); a.SetNoclip(false); a.SetSpeed(false)
        notify("Movement restored")
    end,
}, {
    title = "Repair Black Screen",
    onClick = function()
        local a = visApi()
        if not a then return notify("Visuals module missing", true) end
        a.Repair()
        notify("Lighting repaired")
    end,
})

-- ============================================================================
-- PAGE 2: ESP
-- ============================================================================

local espPage = newPage("esp")

local espHero = heroToggle(espPage, "Player ESP", "0 tracked · 500m · 0 team",
    function() local a = espApi(); return a and a.Enabled() or false end,
    function(v) local a = espApi(); if not a then error("ESP missing") end; a.Set(v) end,
    "F4")

section(espPage, "display options")

toggleGrid(espPage, {
    { title = "Disguise Names", sub = "Tag title", get = function() return espOpt("showNames") end, set = function(v) setEspOpt("showNames", v) end },
    { title = "Highlights", sub = "Through walls", get = function() return espOpt("showHighlight") end, set = function(v) setEspOpt("showHighlight", v) end },
    { title = "Distance", sub = "Meters away", get = function() return espOpt("showDistance") end, set = function(v) setEspOpt("showDistance", v) end },
    { title = "Health", sub = "Humanoid HP", get = function() return espOpt("showHealth") end, set = function(v) setEspOpt("showHealth", v) end },
    { title = "Crime Lab Badges", sub = "Red killer / suspect", get = function() return espOpt("showForensics") end, set = function(v) setEspOpt("showForensics", v) end },
    { title = "Revealed Roles", sub = "Death/medal reveals", get = function() return espOpt("showRoles") end, set = function(v) setEspOpt("showRoles", v) end },
    { title = "Show Dead", sub = "Tag bodies", get = function() return espOpt("showDead") end, set = function(v) setEspOpt("showDead", v) end },
    { title = "Auto Team Scan", sub = "Color Mafia red", get = function() return espOpt("autoTeamScan") end, set = function(v) setEspOpt("autoTeamScan", v) end },
})

sliderCard(espPage, "Max Distance", "Tags hide beyond this range",
    function() local a = espApi(); return a and a.Options().maxDistance or 500 end,
    function(v) setEspOpt("maxDistance", v) end,
    100, 1000, 50, function(v) return string.format("%dm", v) end)

buttonPair(espPage, {
    title = "Refresh Teammates",
    onClick = function()
        local a = espApi()
        if not a then return notify("ESP missing", true) end
        local ok, msg = a.RefreshTeam()
        notify(ok and "Team scan started" or tostring(msg), not ok)
    end,
}, {
    title = "Copy Crime Lab Report",
    onClick = function()
        local lab = _G.__mafiaForensics
        if not lab then return notify("Crime Lab missing", true) end
        local txt = lab.ChatReport()
        if type(setclipboard) == "function" then pcall(setclipboard, txt); notify("Copied: " .. txt:sub(1, 44))
        else print("[MAFIA-LAB] " .. lab.Report()); notify("Printed report to console") end
    end,
})

table.insert(pageRefreshers.esp, function()
    local a = espApi()
    local count = a and a.Count() or 0
    local max = a and a.Options().maxDistance or 500
    local team = _G.__mafiaRoles and _G.__mafiaRoles.Team() or {}
    espHero.sub.Text = string.format("%d tracked  ·  %dm  ·  %d teammates", count, max, #team)
end)

-- ============================================================================
-- PAGE 3: VISUALS
-- ============================================================================

local visualsPage = newPage("visuals")

local fbHero = heroToggle(visualsPage, "Fullbright (EMP-Proof)", "Suspends EMP blackout & mutes post-effects",
    function() local a = visApi(); return a and a.Fullbright() or false end,
    function(v) local a = visApi(); if not a then error("Visuals missing") end; a.SetFullbright(v) end,
    "Y")

section(visualsPage, "camera & recovery")

sliderCard(visualsPage, "Field of View", "70 is default; higher is wider",
    function() local a = visApi(); return a and a.FOV() or 70 end,
    function(v) local a = visApi(); if a then a.SetFOV(v) end end,
    50, 120, 5, function(v) return string.format("%d°", v) end)

buttonPair(visualsPage, {
    title = "Reset FOV (70°)",
    onClick = function()
        local a = visApi()
        if not a then return notify("Visuals missing", true) end
        a.ResetFOV()
        notify("FOV reset to 70°")
    end,
}, {
    title = "Repair Black Screen",
    onClick = function()
        local a = visApi()
        if not a then return notify("Visuals missing", true) end
        a.Repair()
        notify("Lighting repaired")
    end,
})

table.insert(pageRefreshers.visuals, function()
    local a = visApi()
    local on = a and a.Fullbright() or false
    fbHero.sub.Text = on and "Active · EMP exposure suspended, effects muted" or "Bright lighting, no fog, EMP screens suppressed"
end)

-- ============================================================================
-- PAGE 4: SYSTEM
-- ============================================================================

local systemPage = newPage("system")

section(systemPage, "crime lab")

local labBox = make("Frame", {
    Size = UDim2.new(1, 0, 0, 108),
    BackgroundColor3 = T.card,
    BorderSizePixel = 0,
    LayoutOrder = nextOrder(),
    ZIndex = 5,
}, systemPage)
corner(labBox, 9)
stroke(labBox, T.border, 0.4, 1)

local labLabel = label(labBox, {
    Position = UDim2.new(0, 12, 0, 10),
    Size = UDim2.new(1, -24, 1, -20),
    Font = Enum.Font.Code,
    TextSize = 10,
    TextWrapped = true,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.amber,
    Text = "Watching player positions, deaths & animations...",
    ZIndex = 6,
})

local function refreshLab()
    local lab = _G.__mafiaForensics
    if not lab then labLabel.Text = "forensics module missing"; return end
    local lines = {}
    for _, s in ipairs(lab.Suspects()) do
        lines[#lines + 1] = string.format("%s [%s] (%s)", s.name, s.badge, table.concat(s.reasons, ", "))
        if #lines >= 4 then break end
    end
    for _, inc in ipairs(lab.Incidents(2)) do
        lines[#lines + 1] = "• " .. inc
    end
    labLabel.Text = #lines == 0 and "Watching player positions, deaths & animations..." or table.concat(lines, "\n")
end
table.insert(pageRefreshers.system, refreshLab)

buttonPair(systemPage, {
    title = "Copy Day Alibi Report",
    onClick = function()
        local lab = _G.__mafiaForensics
        if not lab then return notify("Crime Lab missing", true) end
        local txt = lab.ChatReport()
        if type(setclipboard) == "function" then pcall(setclipboard, txt); notify("Copied: " .. txt:sub(1, 44))
        else print("[MAFIA-LAB] " .. lab.Report()); notify("Printed report to console") end
    end,
}, {
    title = "Reset Crime Lab",
    onClick = function()
        local lab = _G.__mafiaForensics
        if lab then lab.Reset() end
        refreshLab()
        notify("Crime Lab cleared")
    end,
})

section(systemPage, "match log")

local logBox = make("Frame", {
    Size = UDim2.new(1, 0, 0, 104),
    BackgroundColor3 = T.card,
    BorderSizePixel = 0,
    LayoutOrder = nextOrder(),
    ZIndex = 5,
}, systemPage)
corner(logBox, 9)
stroke(logBox, T.border, 0.4, 1)

local logLabel = label(logBox, {
    Position = UDim2.new(0, 12, 0, 10),
    Size = UDim2.new(1, -24, 1, -20),
    Font = Enum.Font.Code,
    TextSize = 9,
    TextWrapped = true,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = T.dim,
    Text = "Waiting for game events...",
    ZIndex = 6,
})

local function refreshFlow()
    local api = _G.__mafiaFlowLog
    if not api then logLabel.Text = "flowlog module missing"; return end
    local last = api.Last(6)
    if #last == 0 then logLabel.Text = "Waiting for game events..."; return end
    local out = {}
    for i, line in ipairs(last) do out[i] = line:sub(1, 120) end
    logLabel.Text = table.concat(out, "\n")
end
table.insert(pageRefreshers.system, refreshFlow)

buttonPair(systemPage, {
    title = "Copy Match Log",
    onClick = function()
        local api = _G.__mafiaFlowLog
        if not api then return notify("Flow log missing", true) end
        local text = table.concat(api.Lines(), "\n")
        if text == "" then return notify("No events yet", true) end
        if type(setclipboard) == "function" then pcall(setclipboard, text); notify("Match log copied")
        else print("[MAFIA-FLOW] " .. text); notify("Printed to console") end
    end,
}, {
    title = "Clear Match Log",
    onClick = function()
        local api = _G.__mafiaFlowLog
        if api then api.Clear() end
        refreshFlow()
        notify("Match log cleared")
    end,
})

section(systemPage, "profile & session")

toggleGrid(systemPage, {
    {
        title = "Status HUD",
        sub = "Bottom-left strip",
        get = function() local a = _G.__mafiaHUD; return a and a.Enabled() or false end,
        set = function(v) local a = _G.__mafiaHUD; if a then a.Set(v) end end,
    },
    {
        title = "Auto-Reinject",
        sub = "Across teleports",
        get = function() local c = _G.__mafiaConfig; return c and c.AutoReinject() or false end,
        set = function(v) local c = _G.__mafiaConfig; if c then c.SetAutoReinject(v) end end,
    },
})

buttonPair(systemPage, {
    title = "Save Profile",
    onClick = function()
        local c = _G.__mafiaConfig
        if not c then return notify("Config module missing", true) end
        local ok, msg = c.Save()
        notify(ok and "Profile saved" or tostring(msg), not ok)
    end,
}, {
    title = "Unload All Tools",
    danger = true,
    onClick = function()
        for _, name in ipairs({
            "__mafiaESP", "__mafiaHUD", "__mafiaVisuals", "__mafiaMovement",
            "__mafiaForensics", "__mafiaFlowLog", "__mafiaClaims", "__mafiaRoles",
            "__mafiaConfig", "__mafiaState", "__mafiaCore", "__mafiaMenu",
        }) do
            local api = _G[name]
            if api and type(api.Stop) == "function" then pcall(api.Stop) end
        end
    end,
})

-- Live Refresh & Navigation --------------------------------------------------

local function phaseColor(phase)
    local p = string.lower(tostring(phase or ""))
    if p:find("night", 1, true) then return T.violet end
    if p:find("day", 1, true) then return T.amber end
    if p:find("discussion", 1, true) then return T.blue end
    if p:find("voting", 1, true) then return T.red end
    if p:find("lobby", 1, true) then return T.faint end
    return T.green
end

local function refreshSidebar()
    local state = _G.__mafiaState
    local flow = _G.__mafiaFlowLog
    local s = state and state.Snapshot and state.Snapshot() or nil
    local phase = (flow and flow.Phase()) or (s and s.phase) or (s and s.inRound and "ROUND" or "LOBBY")
    local alive = s and (s.playersLeft or s.alive) or 0
    local total = s and s.total or 0
    local role = s and s.role or "No Role"
    local faction = s and s.faction or "Unknown"

    local pc = phaseColor(phase)
    livePhase.Text = string.upper(tostring(phase))
    livePhase.TextColor3 = pc
    liveDot.BackgroundColor3 = pc
    liveRole.Text = tostring(role)
    liveRole.TextColor3 = FACTION_COLORS[faction] or T.text
    liveAlive.Text = string.format("Alive %d / %d", alive, total)
end

local function refreshActive()
    for _, fn in ipairs(pageRefreshers[activeTab] or {}) do
        pcall(fn)
    end
end

function API.SetTab(id)
    id = TAB_ALIASES[id] or id
    if not pages[id] then return false end
    activeTab = id
    for tabId, page in pairs(pages) do
        page.Visible = tabId == activeTab
        if page.Visible then
            page.Position = UDim2.new(0, 8, 0, 0)
            tween(page, TW_MED, { Position = UDim2.new(0, 0, 0, 0) })
            page.CanvasPosition = Vector2.new(0, 0)
        end
    end
    for tabId, item in pairs(navItems) do
        item.paint(tabId == activeTab)
    end
    local meta = PAGE_META[id]
    pageTitle.Text = meta.title
    pageSub.Text = meta.sub
    refreshActive()
    refreshSidebar()
    return true
end

function API.Open()
    open = true
    window.Visible = true
    shadow.Visible = true
    local th = minimized and HEADER or HEIGHT
    window.Size = UDim2.fromOffset(WIDTH - 10, th - 10)
    syncShadow()
    clampWindow(WIDTH - 10, th - 10)
    if windowTween then pcall(function() windowTween:Cancel() end) end
    if shadowTween then pcall(function() shadowTween:Cancel() end) end
    windowTween = tween(window, TW_MED, { Size = UDim2.fromOffset(WIDTH, th) })
    shadowTween = tween(shadow, TW_MED, {
        Size = UDim2.fromOffset(WIDTH + 16, th + 16),
        Position = UDim2.new(window.Position.X.Scale, window.Position.X.Offset, window.Position.Y.Scale, window.Position.Y.Offset + 6),
    })
    refreshSidebar()
    refreshActive()
    return true
end

function API.Close()
    open = false
    local th = minimized and HEADER or HEIGHT
    if windowTween then pcall(function() windowTween:Cancel() end) end
    if shadowTween then pcall(function() shadowTween:Cancel() end) end
    windowTween = tween(window, TW_FAST, { Size = UDim2.fromOffset(WIDTH - 10, th - 10) })
    shadowTween = tween(shadow, TW_FAST, {
        Size = UDim2.fromOffset(WIDTH + 6, th + 6),
        Position = UDim2.new(window.Position.X.Scale, window.Position.X.Offset, window.Position.Y.Scale, window.Position.Y.Offset + 6),
    })
    task.delay(0.12, function()
        if not running or open then return end
        window.Visible = false
        shadow.Visible = false
        window.Size = UDim2.fromOffset(WIDTH, th)
        syncShadow()
    end)
    return true
end

function API.Set(on) return on and API.Open() or API.Close() end
function API.Toggle() return open and API.Close() or API.Open() end
function API.Enabled() return open end
function API.Center() centerWindow(); return true end

function API.Stop()
    if _G.__mafiaMenu ~= API then return end
    running = false
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    if gui then gui:Destroy() end
    _G.__mafiaMenu = nil
end

-- Hotkeys --------------------------------------------------------------------

connect(UserInputService.InputBegan, function(input)
    if UserInputService:GetFocusedTextBox() then return end
    local kc = input.KeyCode
    if kc == Enum.KeyCode.RightShift then
        API.Toggle()
    elseif kc == Enum.KeyCode.PageUp then
        centerWindow(); API.Open(); notify("Window recentered")
    elseif kc == Enum.KeyCode.End then
        API.Close()
    elseif kc == Enum.KeyCode.F4 then
        local a = espApi()
        if a then a.Toggle(); notify("ESP " .. (a.Enabled() and "on" or "off")); refreshActive() end
    elseif kc == Enum.KeyCode.Q then
        local a = moveApi()
        if a and not a.Fly() then a.ToggleSpeed(); notify("Speed " .. (a.Speed() and "on" or "off")); refreshActive() end
    elseif kc == Enum.KeyCode.X then
        local a = moveApi()
        if a then
            local ok, err = pcall(function() a.ToggleFly() end)
            notify(ok and ("Fly " .. (a.Fly() and "on" or "off")) or tostring(err), not ok)
            refreshActive()
        end
    elseif kc == Enum.KeyCode.V then
        local a = moveApi()
        if a then a.ToggleNoclip(); notify("Noclip " .. (a.Noclip() and "on" or "off")); refreshActive() end
    elseif kc == Enum.KeyCode.Y then
        local a = visApi()
        if a then a.ToggleFullbright(); notify("Fullbright " .. (a.Fullbright() and "on" or "off")); refreshActive() end
    elseif kc == Enum.KeyCode.K then
        local a = moveApi()
        if a and type(a.RoleCombo) == "function" then
            local okCall, ok, info = pcall(a.RoleCombo)
            if not okCall then
                notify(tostring(ok), true)
            else
                notify(tostring(info), not ok)
            end
        end
    elseif kc == Enum.KeyCode.Home then
        local a = moveApi()
        if a and type(a.PanicLocker) == "function" then
            local okCall, ok, info = pcall(a.PanicLocker)
            if not okCall then
                notify(tostring(ok), true)
            else
                notify(ok and ("Panic → " .. tostring(info)) or tostring(info), not ok)
            end
            refreshActive()
        end
    end
end)

-- Dragging -------------------------------------------------------------------

local dragging, dragStart, dragOrigin = false, nil, nil
connect(dragArea.InputBegan, function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    dragging = true
    dragStart = input.Position
    dragOrigin = window.Position
    if windowTween then pcall(function() windowTween:Cancel() end) end
    if shadowTween then pcall(function() shadowTween:Cancel() end) end
end)

connect(UserInputService.InputChanged, function(input)
    if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    local dx = input.Position.X - dragStart.X
    local dy = input.Position.Y - dragStart.Y
    local cam = Workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or nil
    if vp then
        local ox = vp.X * dragOrigin.X.Scale + dragOrigin.X.Offset
        local oy = vp.Y * dragOrigin.Y.Scale + dragOrigin.Y.Offset
        local hw, hh = window.AbsoluteSize.X / 2, window.AbsoluteSize.Y / 2
        window.Position = UDim2.fromOffset(
            math.clamp(ox + dx, hw, math.max(hw, vp.X - hw)),
            math.clamp(oy + dy, hh, math.max(hh, vp.Y - hh))
        )
    else
        window.Position = UDim2.new(dragOrigin.X.Scale, dragOrigin.X.Offset + dx, dragOrigin.Y.Scale, dragOrigin.Y.Offset + dy)
    end
    syncShadow()
end)

connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

-- Boot -----------------------------------------------------------------------

_G.__mafiaMenu = API
API.SetTab("move")
API.Open()

task.spawn(function()
    while running do
        if open and not minimized then
            pcall(refreshSidebar)
            pcall(refreshActive)
        end
        task.wait(0.4)
    end
end)

print("[MAFIA-MENU] loaded v" .. API.Version .. " - Movement primary, RightShift toggles")
