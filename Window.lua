CastAheadWindow = {}
local W = CastAheadWindow

W.THEME = {
    bg = { 0.063, 0.075, 0.09, 0.97 },
    panel = { 0.082, 0.098, 0.125, 1 },
    border = { 0.235, 0.251, 0.282, 1 },
    line = { 0.125, 0.145, 0.176, 1 },
    gold = { 1, 0.82, 0 },
    text = { 0.9, 0.9, 0.9 },
    muted = { 0.545, 0.576, 0.627 },
    selected = { 0.165, 0.192, 0.251, 1 },
}
W.MIN_W, W.MIN_H = 600, 420

local T = W.THEME
local DEFAULT_W, DEFAULT_H = 900, 560
local TITLE_H, MENU_W, FOOTER_H = 26, 120, 20
local ENTRY_H, HEADER_H, GAP, PAD, SCROLLBAR_W = 20, 18, 4, 8, 24
local PER_ROW = 4
local GROUPS = { "Settings", "Dungeon" }
local SCALE_STEPS = { 75, 100, 125, 150 }
local SCALE_MIN, SCALE_MAX, SCALE_DEFAULT = 75, 150, 100
local SIDE_HINT = "Shift + mouse wheel scrolls sideways"
local FLAT = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }

local frame, titleBar, titleAnchor, scaleDrop, menu, content, grid, scroll, footerText, footerHint
local sizing = false
local pages, order, headers, dungeonButtons = {}, {}, {}, {}
local current, dungeon, picked

local function Saved()
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.window = CastAheadDB.window or {}
    return CastAheadDB.window
end

local function Dungeons()
    local list = {}
    for id, data in pairs(CastAheadData) do
        list[#list + 1] = { id = id, name = data.name or tostring(id) }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function W.Button(parent, text, width, primary)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, ENTRY_H)
    b:SetBackdrop(FLAT)
    b:SetBackdropColor(unpack(T.panel))
    b:SetBackdropBorderColor(unpack(primary and T.gold or T.border))
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("CENTER")
    b.label:SetTextColor(unpack(primary and T.gold or T.text))
    b:SetFontString(b.label)
    b:SetText(text)
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.06)
    return b
end

function W.ApplyScale(target)
    target = target or frame
    if not target then return end
    local wanted = CastAheadConfig.Number("uiScale", SCALE_DEFAULT, SCALE_MIN, SCALE_MAX) / 100
    local fits = math.min(UIParent:GetWidth() / target:GetWidth(), UIParent:GetHeight() / target:GetHeight())
    target:SetScale(math.min(wanted, fits))
end

function W.Dungeon()
    if not picked then
        local _, _, _, _, _, _, _, here = GetInstanceInfo()
        local list = Dungeons()
        dungeon = (here and CastAheadData[here]) and here or (list[1] and list[1].id)
    end
    return dungeon
end

local function PaintDungeons()
    for _, b in ipairs(dungeonButtons) do
        local on = b.instanceID == dungeon
        b:SetBackdropColor(unpack(on and T.selected or T.panel))
        b.label:SetTextColor(unpack(on and T.gold or T.text))
    end
end

local function LayoutGrid(width)
    local w = (width - (PER_ROW - 1) * GAP) / PER_ROW
    for i, b in ipairs(dungeonButtons) do
        b:SetWidth(w)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", grid, "TOPLEFT", ((i - 1) % PER_ROW) * (w + GAP),
            -math.floor((i - 1) / PER_ROW) * (ENTRY_H + GAP))
    end
end

local function PaintMenu()
    for _, p in ipairs(order) do
        if p.entry then
            local on = p.name == current
            p.entry:SetBackdropColor(unpack(on and T.selected or T.panel))
            p.entry.label:SetTextColor(unpack(on and T.gold or T.text))
            p.entry.bar:SetShown(on)
        end
    end
end

local function Entry(page)
    if page.entry then return end
    local b = W.Button(menu, page.name, MENU_W - 2 * PAD, false)
    b.label:ClearAllPoints()
    b.label:SetPoint("LEFT", b, "LEFT", PAD, 0)
    b.bar = b:CreateTexture(nil, "OVERLAY")
    b.bar:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.bar:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    b.bar:SetWidth(2)
    b.bar:SetColorTexture(unpack(T.gold))
    b:SetScript("OnClick", function() W.Show(page.name) end)
    page.entry = b
end

local function LayoutMenu()
    local y = -PAD
    for _, group in ipairs(GROUPS) do
        local any = false
        for _, p in ipairs(order) do
            if p.group == group and p.shown then any = true end
        end
        headers[group]:SetShown(any)
        if any then
            headers[group]:ClearAllPoints()
            headers[group]:SetPoint("TOPLEFT", menu, "TOPLEFT", PAD, y)
            y = y - HEADER_H
        end
        for _, p in ipairs(order) do
            if p.group == group then
                p.entry:SetShown(p.shown)
                if p.shown then
                    p.entry:ClearAllPoints()
                    p.entry:SetPoint("TOPLEFT", menu, "TOPLEFT", PAD, y)
                    y = y - ENTRY_H - GAP
                end
            end
        end
        if any then y = y - PAD end
    end
end

function W.AddTitleButton(text, width, primary, onClick)
    local b = W.Button(titleBar, text, width, primary)
    b:SetPoint("RIGHT", titleAnchor, "LEFT", -GAP, 0)
    b:SetScript("OnClick", onClick)
    titleAnchor = b
    scaleDrop:ClearAllPoints()
    scaleDrop:SetPoint("RIGHT", b, "LEFT", -PAD, 0)
    return b
end

local function Build()
    frame = CreateFrame("Frame", "CastAheadMainWindow", UIParent, "BackdropTemplate")
    frame:SetBackdrop(FLAT)
    frame:SetBackdropColor(unpack(T.bg))
    frame:SetBackdropBorderColor(unpack(T.border))
    local saved = CastAheadDB and CastAheadDB.window
    if saved and saved.width and saved.height then
        frame:SetSize(math.max(saved.width, W.MIN_W), math.max(saved.height, W.MIN_H))
    else
        frame:SetSize(DEFAULT_W, DEFAULT_H)
    end
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame:SetResizable(true)
    frame:SetResizeBounds(W.MIN_W, W.MIN_H)
    table.insert(UISpecialFrames, "CastAheadMainWindow")

    titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    titleBar:SetHeight(TITLE_H)
    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(unpack(T.panel))
    local titleLine = titleBar:CreateTexture(nil, "ARTWORK")
    titleLine:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    titleLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    titleLine:SetHeight(1)
    titleLine:SetColorTexture(unpack(T.line))
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", titleBar, "LEFT", PAD + 2, 0)
    titleText:SetTextColor(unpack(T.gold))
    titleText:SetText("Cast Ahead")

    local close = W.Button(titleBar, "X", ENTRY_H, false)
    close:SetPoint("RIGHT", titleBar, "RIGHT", -(TITLE_H - ENTRY_H) / 2, 0)
    close:SetScript("OnClick", function() frame:Hide() end)
    titleAnchor = close

    scaleDrop = CreateFrame("DropdownButton", nil, titleBar, "WowStyle1DropdownTemplate")
    scaleDrop:SetSize(80, ENTRY_H)
    scaleDrop:SetPoint("RIGHT", close, "LEFT", -PAD, 0)
    local scaleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    scaleText:SetPoint("RIGHT", scaleDrop, "LEFT", -6, 0)
    scaleText:SetTextColor(unpack(T.muted))
    scaleText:SetText("Scale")
    local function Scale() return CastAheadConfig.Number("uiScale", SCALE_DEFAULT, SCALE_MIN, SCALE_MAX) end
    scaleDrop:SetupMenu(function(_, root)
        for _, value in ipairs(SCALE_STEPS) do
            root:CreateRadio(value .. "%", function() return Scale() == value end, function()
                CastAheadConfig.Set("uiScale", value ~= SCALE_DEFAULT and value or nil)
                W.ApplyScale()
            end)
        end
    end)

    menu = CreateFrame("Frame", nil, frame)
    menu:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -1)
    menu:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, FOOTER_H)
    menu:SetWidth(MENU_W)
    local menuBg = menu:CreateTexture(nil, "BACKGROUND")
    menuBg:SetAllPoints()
    menuBg:SetColorTexture(unpack(T.panel))
    for _, group in ipairs(GROUPS) do
        headers[group] = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        headers[group]:SetTextColor(unpack(T.gold))
        headers[group]:SetText(group)
    end
    for _, p in ipairs(order) do Entry(p) end
    LayoutMenu()

    local footerLine = frame:CreateTexture(nil, "ARTWORK")
    footerLine:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, FOOTER_H)
    footerLine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, FOOTER_H)
    footerLine:SetHeight(1)
    footerLine:SetColorTexture(unpack(T.line))
    local madeIn = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    madeIn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PAD + 16), 5)
    madeIn:SetText("|cFF0057B7Made|r |cFFFFD700in Ukraine|r")
    footerHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerHint:SetPoint("BOTTOMRIGHT", madeIn, "BOTTOMLEFT", -2 * PAD, 0)
    footerHint:SetTextColor(unpack(T.muted))
    footerText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 5)
    footerText:SetPoint("RIGHT", footerHint, "LEFT", -2 * PAD, 0)
    footerText:SetJustifyH("LEFT")
    footerText:SetWordWrap(false)

    content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", menu, "TOPRIGHT", PAD, -PAD)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOTER_H + PAD)

    grid = CreateFrame("Frame", nil, content)
    grid:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    grid:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    local list = Dungeons()
    local rows = math.max(math.ceil(#list / PER_ROW), 1)
    grid:SetHeight(rows * ENTRY_H + (rows - 1) * GAP)
    for i, d in ipairs(list) do
        local b = W.Button(grid, d.name, 1, false)
        b.instanceID = d.id
        b:SetScript("OnClick", function(self)
            dungeon, picked = self.instanceID, true
            PaintDungeons()
            local page = pages[current]
            if page then page.refresh() end
        end)
        dungeonButtons[i] = b
    end
    content:SetScript("OnSizeChanged", function(_, width)
        if not sizing then LayoutGrid(width) end
    end)

    scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    local function FitHosts(width)
        for _, p in ipairs(order) do
            if p.host then p.host:SetWidth(width) end
        end
    end
    scroll:SetScript("OnSizeChanged", function(_, width)
        if not sizing then FitHosts(width) end
    end)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        local left, top = frame:GetLeft(), frame:GetTop()
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        sizing = true
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        sizing = false
        LayoutGrid(content:GetWidth() or 0)
        FitHosts(scroll:GetWidth() or 0)
        local s = Saved()
        s.width, s.height = frame:GetWidth(), frame:GetHeight()
        W.ApplyScale()
    end)

    if W.titleButtons then W.titleButtons(W.AddTitleButton) end
    W.ApplyScale()
end

function W.Register(name, group, build, refresh, before)
    local page = pages[name]
    if not page then
        page = { name = name, shown = true }
        pages[name] = page
        local at = #order + 1
        for i, p in ipairs(order) do
            if p.name == before then at = i end
        end
        table.insert(order, at, page)
    end
    page.group, page.build, page.refresh = group, build, refresh
    if menu then
        Entry(page)
        LayoutMenu()
        PaintMenu()
    end
end

function W.Show(name)
    local page = pages[name]
    if not page then return end
    if not frame then Build() end
    frame:Show()
    current = name
    local dungeonPage = page.group == "Dungeon"
    grid:SetShown(dungeonPage)
    scroll:ClearAllPoints()
    if dungeonPage then
        scroll:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -PAD)
    else
        scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    end
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -SCROLLBAR_W, 0)
    LayoutGrid(content:GetWidth() or 0)
    W.Dungeon()
    PaintDungeons()
    for _, p in ipairs(order) do
        if p.host and p ~= page then p.host:Hide() end
    end
    if not page.host then
        page.host = CreateFrame("Frame", nil, scroll)
        page.host:SetSize(scroll:GetWidth() or 1, 1)
        page.build(page.host)
    end
    scroll:SetScrollChild(page.host)
    page.host:Show()
    PaintMenu()
    Saved().page = name
    W.SetFooter("")
    W.SetFooterHint("")
    page.refresh()
end

local function FirstShown(group)
    for _, p in ipairs(order) do
        if p.group == group and p.shown then return p.name end
    end
end

function W.Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
        return
    end
    local saved = pages[CastAheadDB and CastAheadDB.window and CastAheadDB.window.page]
    local name = saved and (saved.shown and saved.name or FirstShown(saved.group))
        or current or (order[1] and order[1].name)
    if name then W.Show(name) end
end

function W.SetMenuShown(name, shown)
    local page = pages[name]
    if not page then return end
    page.shown = shown and true or false
    if menu then LayoutMenu() end
    if page.shown or current ~= name then return end
    local fallback = FirstShown(page.group)
    if not fallback then return end
    if frame and frame:IsShown() then
        W.Show(fallback)
    else
        current = fallback
        Saved().page = fallback
    end
end

function W.SetFooter(text)
    if footerText then footerText:SetText(text) end
end

function W.SetFooterHint(text)
    if footerHint then footerHint:SetText(text) end
end

function W.SideHint(side, child)
    if side:IsVisible() then
        W.SetFooterHint(child:GetWidth() > side:GetWidth() + 0.5 and SIDE_HINT or "")
    end
end

function W.SideScroll(host, top)
    local side = CreateFrame("ScrollFrame", nil, host)
    side:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -top)
    side:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -top)
    side:SetHeight(1)
    local child = CreateFrame("Frame", nil, side)
    child:SetSize(1, 1)
    side:SetScrollChild(child)
    side:EnableMouseWheel(true)
    side:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            local range = self:GetHorizontalScrollRange()
            self:SetHorizontalScroll(math.max(0, math.min(range, self:GetHorizontalScroll() - delta * 60)))
        else
            local outer = host:GetParent()
            outer:GetScript("OnMouseWheel")(outer, delta)
        end
    end)
    side:SetScript("OnSizeChanged", function(self) W.SideHint(self, child) end)
    return side, child
end

function W.Current() return current end
function W.Frame() return frame end
