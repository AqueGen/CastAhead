CastAheadWindow = {}
local W = CastAheadWindow

W.THEME = {
    bg = { 0.063, 0.075, 0.09, 0.99 },
    panel = { 0.082, 0.098, 0.125, 1 },
    border = { 0.235, 0.251, 0.282, 1 },
    control = { 0.36, 0.38, 0.43, 1 },
    line = { 0.125, 0.145, 0.176, 1 },
    gold = { 1, 0.82, 0 },
    text = { 0.9, 0.9, 0.9 },
    muted = { 0.66, 0.68, 0.72 },
    selected = { 0.165, 0.192, 0.251, 1 },
}
W.MIN_W, W.MIN_H = 460, 420
W.ICON = "Interface\\AddOns\\CastAhead\\Media\\icon"

local T = W.THEME
local DEFAULT_W, DEFAULT_H = 1200, 640
local TITLE_H, MENU_W, FOOTER_H = 26, 120, 20
local ENTRY_H, HEADER_H, GAP, PAD, SCROLLBAR_W = 20, 18, 4, 8, 24
local PER_ROW = 4
local GROUPS = { "Settings", "Dungeon", "Raid", "Feedback" }
local SCALE_STEPS = { 75, 100, 125, 150 }
local SCALE_MIN, SCALE_MAX, SCALE_DEFAULT = 75, 150, 100
local SIDE_HINT = "Shift + mouse wheel scrolls sideways"
local FLAT = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }
W.FLAT = FLAT

local RAID_DIFFICULTIES = { { 14, "Normal" }, { 15, "Heroic" }, { 16, "Mythic" } }
local RAID_DEFAULT = 15
-- Pages from older versions, so a saved page name still opens something.
local MOVED = { Bursts = "RaidGuide", RaidDefensives = "RaidGuide" }

local frame, titleBar, titleAnchor, scaleDrop, menu, content, grid, raidGrid, scroll, footerText, footerHint
local pages, order, headers, dungeonButtons, raidButtons = {}, {}, {}, {}, {}
local current, dungeon, picked, raidDifficulty, raidPicked

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
    b:SetBackdropBorderColor(unpack(primary and T.gold or T.control))
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

local NOTICE_W, NOTICE_PAD, NOTICE_ICON = 360, 14, 18
local DEFENSIVES_OFF = {
    text = "Defensive calls are now off by default, so they were switched off once for everyone, in dungeons and in raids.\n\nTurn them on in General - Features.",
    button = "Open settings", page = "General",
}
-- Shown once after an update, never on a new install. Only changes that
-- change how a run plays out go here; raise `id` for each new message.
W.NEWS = {
    id = 1,
    title = "What's new in CastAhead",
    text = "- The Casts page now sorts every cast by what you get in combat: called out loud, shown without sound, or hidden. Hover a cast to see why.\n\n"
        .. "- Click a cast to give it its own settings: star it as important, mute it, or give it its own sound or early warning.\n\n"
        .. "- \"My role only\" now hides tank busters and dispels you cannot use even with \"Important casts only\" off.",
    button = "Open Casts", page = "Casts",
}
local notice

local function BuildNotice()
    notice = CreateFrame("Frame", "CastAheadUpdateNotice", UIParent, "BackdropTemplate")
    notice:SetBackdrop(FLAT)
    notice:SetBackdropColor(unpack(T.bg))
    notice:SetBackdropBorderColor(unpack(T.border))
    notice:SetFrameStrata("FULLSCREEN_DIALOG")
    notice:SetPoint("CENTER")
    notice:SetMovable(true)
    notice:EnableMouse(true)
    notice:SetClampedToScreen(true)
    notice:RegisterForDrag("LeftButton")
    notice:SetScript("OnDragStart", notice.StartMoving)
    notice:SetScript("OnDragStop", notice.StopMovingOrSizing)
    table.insert(UISpecialFrames, "CastAheadUpdateNotice")

    local bar = CreateFrame("Frame", nil, notice)
    bar:SetPoint("TOPLEFT", notice, "TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", notice, "TOPRIGHT", -1, -1)
    bar:SetHeight(TITLE_H)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(unpack(T.panel))
    local line = bar:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
    line:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    line:SetHeight(1)
    line:SetColorTexture(unpack(T.line))
    local icon = bar:CreateTexture(nil, "OVERLAY")
    icon:SetSize(NOTICE_ICON, NOTICE_ICON)
    icon:SetPoint("LEFT", bar, "LEFT", NOTICE_PAD, 0)
    icon:SetTexture(W.ICON)
    notice.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    notice.title:SetPoint("LEFT", icon, "RIGHT", PAD, 0)
    notice.title:SetTextColor(unpack(T.gold))

    notice.body = notice:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    notice.body:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", NOTICE_PAD, -NOTICE_PAD)
    notice.body:SetWidth(NOTICE_W - 2 * NOTICE_PAD)
    notice.body:SetJustifyH("LEFT")
    notice.body:SetTextColor(unpack(T.text))

    notice.close = W.Button(notice, "Close", 80, false)
    notice.close:SetPoint("BOTTOMRIGHT", notice, "BOTTOMRIGHT", -NOTICE_PAD, NOTICE_PAD)
    notice.close:SetScript("OnClick", function() notice:Hide() end)
    notice.open = W.Button(notice, "", 110, true)
    notice.open:SetPoint("RIGHT", notice.close, "LEFT", -PAD, 0)
end

-- `message` = { title, text, button, page }; the button opens that page.
-- Without one it is the notice about defensive calls going off by default.
function W.ShowUpdateNotice(message)
    message = message or DEFENSIVES_OFF
    if not notice then BuildNotice() end
    notice.title:SetText(message.title or "CastAhead update")
    notice.body:SetText(message.text)
    notice.open:SetText(message.button)
    notice.open:SetScript("OnClick", function()
        notice:Hide()
        CastAheadUI.ShowTab(message.page)
    end)
    notice:SetSize(NOTICE_W, TITLE_H + 1 + 3 * NOTICE_PAD + ENTRY_H + math.ceil(notice.body:GetStringHeight()))
    notice:Show()
end

local SPEC_W, SPEC_MIN_W, SPEC_GAP, SPEC_BAR_H, CLASS_W, MAX_SPECS = 150, 60, 4, 28, 150, 4
local specBars = {}

local function Specs()
    local out = {}
    local class = CastAheadSaves and CastAheadSaves.ViewClassID()
    if class and class ~= CastAheadSaves.OwnClassID() and GetNumSpecializationsForClassID then
        for i = 1, GetNumSpecializationsForClassID(class) or 0 do
            local id, name, _, icon = GetSpecializationInfoForClassID(class, i)
            if id then out[#out + 1] = { id = id, name = name, icon = icon } end
        end
        return out
    end
    if not (GetNumSpecializations and GetSpecializationInfo) then return out end
    for i = 1, GetNumSpecializations() or 0 do
        local id, name, _, icon = GetSpecializationInfo(i)
        if id then out[#out + 1] = { id = id, name = name, icon = icon } end
    end
    return out
end

function W.PaintSpecBars()
    local viewing = CastAheadSaves and CastAheadSaves.ViewSpecID()
    local specs = Specs()
    for _, bar in ipairs(specBars) do
        if bar.pick and bar.pick.GenerateMenu then bar.pick:GenerateMenu() end
        local room = (bar.width() or 0) - bar.left - (#specs - 1) * SPEC_GAP
        local w = room > 0 and #specs > 0 and math.max(SPEC_MIN_W, math.min(SPEC_W, math.floor(room / #specs))) or SPEC_W
        for i, b in ipairs(bar) do
            local spec = specs[i]
            b:SetShown(spec ~= nil)
            if spec then
                b:SetWidth(w)
                b.label:SetWidth(w - 8)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", bar.parent, "TOPLEFT", bar.left + (i - 1) * (w + SPEC_GAP), -bar.y)
                b.specID = spec.id
                b:SetText(string.format("|T%s:14|t %s", spec.icon or "", spec.name or ""))
                local on = spec.id == viewing
                b:SetBackdropColor(unpack(on and T.selected or T.panel))
                b.label:SetTextColor(unpack(on and T.gold or T.text))
            end
        end
    end
end

local function ClassPick(parent, x, y, onPick)
    if not (GetNumClasses and C_CreatureInfo and C_CreatureInfo.GetClassInfo) then return nil end
    local pick = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    pick:SetSize(CLASS_W, ENTRY_H + 4)
    pick:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y + 2)
    pick:SetupMenu(function(_, root)
        for classID = 1, GetNumClasses() do
            local info = C_CreatureInfo.GetClassInfo(classID)
            if info then
                root:CreateRadio(info.className,
                    function() return CastAheadSaves.ViewClassID() == classID end,
                    function()
                        CastAheadSaves.SetViewClass(classID)
                        if onPick then onPick() end
                        W.PaintSpecBars()
                    end)
            end
        end
    end)
    return pick
end

function W.SpecBar(parent, x, y, onPick, roomFromParentLeft)
    if not CastAheadSaves then return 0 end
    local bar = { parent = parent, y = y, width = roomFromParentLeft or function() return parent:GetWidth() end }
    bar.pick = ClassPick(parent, x, y, onPick)
    bar.left = x + (bar.pick and CLASS_W + SPEC_GAP or 0)
    for i = 1, MAX_SPECS do
        local b = W.Button(parent, "", SPEC_W)
        b.label:SetWordWrap(false)
        b:SetScript("OnClick", function(self)
            CastAheadSaves.SetViewSpec(self.specID)
            if onPick then onPick() end
            W.PaintSpecBars()
        end)
        bar[i] = b
    end
    specBars[#specBars + 1] = bar
    W.PaintSpecBars()
    return SPEC_BAR_H
end

-- The scale is only ever the player's choice. A window too big for the screen is capped in
-- size instead: shrinking the scale to fit left the grip under a frame scaled below its
-- parent, and the next StartSizing ran away from the cursor.
function W.ApplyScale(target)
    target = target or frame
    if not target then return end
    local scale = CastAheadConfig.Number("uiScale", SCALE_DEFAULT, SCALE_MIN, SCALE_MAX) / 100
    target:SetScale(scale)
    local maxW, maxH = UIParent:GetWidth() / scale, UIParent:GetHeight() / scale
    if target.SetResizeBounds and target:IsResizable() then
        target:SetResizeBounds(W.MIN_W, W.MIN_H, maxW, maxH)
    end
    if target:GetWidth() > maxW or target:GetHeight() > maxH then
        target:SetSize(math.min(target:GetWidth(), maxW), math.min(target:GetHeight(), maxH))
    end
end

function W.Dungeon()
    if not picked then
        local _, _, _, _, _, _, _, here = GetInstanceInfo()
        local list = Dungeons()
        dungeon = (here and CastAheadData[here]) and here or (list[1] and list[1].id)
    end
    return dungeon
end

function W.RaidDifficulty()
    if not raidPicked then
        local _, kind, difficulty = GetInstanceInfo()
        raidDifficulty = RAID_DEFAULT
        for _, d in ipairs(RAID_DIFFICULTIES) do
            if kind == "raid" and difficulty == d[1] then raidDifficulty = difficulty end
        end
    end
    return raidDifficulty
end

local function PaintDungeons()
    for _, b in ipairs(raidButtons) do
        local on = b.difficultyID == raidDifficulty
        b:SetBackdropColor(unpack(on and T.selected or T.panel))
        b.label:SetTextColor(unpack(on and T.gold or T.text))
    end
    for _, b in ipairs(dungeonButtons) do
        local on = b.instanceID == dungeon
        b:SetBackdropColor(unpack(on and T.selected or T.panel))
        b.label:SetTextColor(unpack(on and T.gold or T.text))
    end
end

-- Up to PER_ROW buttons a row, fewer when the window is narrow, so a dungeon name keeps
-- room for itself; the grid grows a row and the page below follows its bottom edge.
local GRID_BUTTON_MIN = 140
local function LayoutGrid(width)
    local perRow = math.max(1, math.min(PER_ROW, math.floor((width + GAP) / (GRID_BUTTON_MIN + GAP))))
    local w = (width - (perRow - 1) * GAP) / perRow
    for _, set in ipairs({ { dungeonButtons, grid }, { raidButtons, raidGrid } }) do
        for i, b in ipairs(set[1]) do
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", set[2], "TOPLEFT", ((i - 1) % perRow) * (w + GAP),
                -math.floor((i - 1) / perRow) * (ENTRY_H + GAP))
        end
        local rows = math.max(math.ceil(#set[1] / perRow), 1)
        set[2]:SetHeight(rows * ENTRY_H + (rows - 1) * GAP)
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
    local b = W.Button(menu, page.label or page.name, MENU_W - 2 * PAD, false)
    b:SetBackdropBorderColor(unpack(T.border))
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
    titleText:SetText("CastAhead")

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
    raidGrid = CreateFrame("Frame", nil, content)
    raidGrid:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    raidGrid:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    raidGrid:SetHeight(ENTRY_H)
    for i, d in ipairs(RAID_DIFFICULTIES) do
        local b = W.Button(raidGrid, d[2], 1, false)
        b.difficultyID = d[1]
        b:SetScript("OnClick", function(self)
            raidDifficulty, raidPicked = self.difficultyID, true
            PaintDungeons()
            local page = pages[current]
            if page then page.refresh() end
        end)
        raidButtons[i] = b
    end
    content:SetScript("OnSizeChanged", function(_, width)
        LayoutGrid(width)
    end)

    scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    local function FitHosts(width)
        for _, p in ipairs(order) do
            if p.host then p.host:SetWidth(width) end
        end
    end
    scroll:SetScript("OnSizeChanged", function(_, width)
        FitHosts(width)
    end)

    local function Resized()
        LayoutGrid(content:GetWidth() or 0)
        FitHosts(scroll:GetWidth() or 0)
        W.ApplyScale()
    end

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
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        local s = Saved()
        s.width, s.height = frame:GetWidth(), frame:GetHeight()
        Resized()
    end)
    frame:SetClampedToScreen(true)

    function W.ResetSize()
        local s = Saved()
        s.width, s.height = nil, nil
        frame:SetSize(DEFAULT_W, DEFAULT_H)
        frame:ClearAllPoints()
        frame:SetPoint("CENTER")
        Resized()
    end

    if W.titleButtons then W.titleButtons(W.AddTitleButton) end
    W.AddTitleButton("Reset size", 80, false, W.ResetSize)
    W.ApplyScale()
end

function W.Register(name, group, build, refresh, before, ownBar, label)
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
    page.group, page.build, page.refresh, page.ownBar, page.label = group, build, refresh, ownBar, label
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
    local bar = not page.ownBar and (page.group == "Dungeon" and grid or page.group == "Raid" and raidGrid) or nil
    grid:SetShown(bar == grid)
    raidGrid:SetShown(bar == raidGrid)
    scroll:ClearAllPoints()
    if bar then
        scroll:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -PAD)
    else
        scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    end
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -SCROLLBAR_W, 0)
    LayoutGrid(content:GetWidth() or 0)
    W.Dungeon()
    W.RaidDifficulty()
    PaintDungeons()
    for _, p in ipairs(order) do
        if p.host and p ~= page then p.host:Hide() end
    end
    local hostWidth = math.max((content:GetWidth() or 0) - SCROLLBAR_W, 1)
    if not page.host then
        page.host = CreateFrame("Frame", nil, scroll)
        page.host:SetSize(hostWidth, 1)
        page.build(page.host)
    end
    page.host:SetWidth(hostWidth)
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
    if group ~= "Settings" then return FirstShown("Settings") end
end

function W.Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
        return
    end
    local savedName = CastAheadDB and CastAheadDB.window and CastAheadDB.window.page
    local saved = pages[MOVED[savedName] or savedName]
    local name = saved and (saved.shown and saved.name or FirstShown(saved.group))
        or current or FirstShown("Settings")
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

W.GROUPS = GROUPS

function W.Page(name)
    local page = pages[name]
    if page then return page.group, page.shown end
end

function W.Current() return current end
function W.Frame() return frame end
