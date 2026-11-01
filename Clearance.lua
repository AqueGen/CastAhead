-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
-- Room for the nameplate addon's own aura icons.
--
-- Platynator, EllesmereUI Nameplates and Plater draw buffs (dispellable,
-- enrage), debuffs and crowd control beside their health bar, and our icons
-- sit beside the Blizzard plate - the same spot. The game fills their aura
-- rows itself and keeps what is in them Secret, so the only reliable input is
-- their configuration: where each row starts and how big one icon is. The
-- icons move out by one such icon, always, and never during a fight.

CastAheadClearance = {}
local M = CastAheadClearance

local function Overlaps(low, high, band)
    return low < band[2] and high > band[1]
end

-- rects: { left, right, bottom, top } in UIParent units around the plate
-- centre; band: what our first icon covers across the side.
function M.Push(rects, side, halfW, halfH, band)
    local push = 0
    for _, r in ipairs(rects) do
        local p = 0
        if side == "left" and r.left < -halfW and Overlaps(r.bottom, r.top, band) then
            p = -halfW - r.left
        elseif side == "right" and r.right > halfW and Overlaps(r.bottom, r.top, band) then
            p = r.right - halfW
        elseif side == "top" and r.top > halfH and Overlaps(r.left, r.right, band) then
            p = r.top - halfH
        elseif side == "bottom" and r.bottom < -halfH and Overlaps(r.left, r.right, band) then
            p = -halfH - r.bottom
        end
        if p > push then push = p end
    end
    return push
end

local function Readable(...)
    if not issecretvalue then return true end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return false end
    end
    return true
end

-- Their frame's units to ours.
local function Ratio(frame)
    local mine, base = frame:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if not Readable(mine, base) or not mine or not base or base == 0 then return nil end
    return mine / base
end

-- The rect of a w x h box whose `point` sits at (x, y).
local function Box(point, x, y, w, h)
    point = point and point:upper() or "CENTER"
    local cx = point:find("LEFT") and x + w / 2 or point:find("RIGHT") and x - w / 2 or x
    local cy = point:find("TOP") and y - h / 2 or point:find("BOTTOM") and y + h / 2 or y
    return { left = cx - w / 2, right = cx + w / 2, bottom = cy - h / 2, top = cy + h / 2 }
end

local function Scaled(rect, ratio, dy)
    return {
        left = rect.left * ratio, right = rect.right * ratio,
        bottom = (rect.bottom + dy) * ratio, top = (rect.top + dy) * ratio,
    }
end

M.Adapters = {}

-- Platynator keeps no handle to a unit's display outside its own files; the
-- display is a child of the nameplate with these fields
-- (Display/Nameplate.lua, Display/Initialize.lua).
local function PlatynatorDisplay(plate)
    for _, child in ipairs({ plate:GetChildren() }) do
        if type(child.aurasInfo) == "table" and child.BuffDisplay and child:IsShown() then
            return child
        end
    end
end

-- Each aura holder is one icon, 20 px times the widget's scale, anchored
-- around the display's centre the way Display/Widgets.lua ApplyAnchor does.
M.Adapters.platynator = {
    name = "Platynator",
    perUnit = true,
    loaded = function() return Platynator ~= nil end,
    rects = function(plate)
        local display = PlatynatorDisplay(plate)
        if not display then return nil end
        local ratio = Ratio(display)
        local _, _, _, _, dy = display:GetPoint(1)
        dy = dy or 0
        if not ratio or not Readable(dy) then return nil end
        local rects = {}
        for _, kind in ipairs({ "debuffs", "buffs", "crowdControl" }) do
            local info = display.aurasInfo[kind]
            if info then
                local anchor, scale = info.anchor, tonumber(info.scale)
                if type(anchor) ~= "table" or not scale then return nil end
                local w = 20 * scale
                local h = w * (tonumber(info.height) or 1)
                local box
                if #anchor >= 3 then
                    box = Box(anchor[1], anchor[2], anchor[3], w, h)
                elseif #anchor == 2 then
                    box = Box("CENTER", anchor[1], anchor[2], w, h)
                else
                    box = Box(anchor[1], 0, 0, w, h)
                end
                rects[#rects + 1] = Scaled(box, ratio, dy)
            end
        end
        return rects
    end,
}

-- EllesmereUI Nameplates exports its own getters, which already resolve slot
-- sizes and fallbacks; the rows hang off the health bar as in
-- EUI_Nameplates_AuraContainers.lua AnchorNPContainer.
local EUI_KINDS = {
    { slot = "debuffSlot", size = "GetDebuffIconSize" },
    { slot = "buffSlot", size = "GetBuffIconSize" },
    { slot = "ccSlot", size = "GetCCIconSize" },
}

local function EuiRow(ns, slot, size, w, hh, hy, xOff, yOff)
    local top = hy + hh / 2 + ((ns.GetDebuffYOffset and ns.GetDebuffYOffset()) or 2) + yOff
    if slot == "left" or slot == "right" then
        local gap = ns.GetSideAuraXOffset and ns.GetSideAuraXOffset() or 2
        local bottom = hy - hh / 2 + yOff
        local inner = w / 2 + gap
        if slot == "left" then
            return { left = -inner - size + xOff, right = -inner + xOff, bottom = bottom, top = bottom + size }
        end
        return { left = inner + xOff, right = inner + size + xOff, bottom = bottom, top = bottom + size }
    elseif slot == "top" then
        return { left = xOff - size / 2, right = xOff + size / 2, bottom = top, top = top + size }
    elseif slot == "bottom" then
        local below = hy - hh / 2 - 2 + yOff
        return { left = xOff - size / 2, right = xOff + size / 2, bottom = below - size, top = below }
    elseif slot == "topleft" then
        return { left = -w / 2 + xOff, right = -w / 2 + size + xOff, bottom = top, top = top + size }
    elseif slot == "topright" then
        return { left = w / 2 - size + xOff, right = w / 2 + xOff, bottom = top, top = top + size }
    end
end

M.Adapters.ellesmere = {
    name = "EllesmereUI Nameplates",
    perUnit = false,
    loaded = function() return EllesmereNameplates_NS ~= nil end,
    rects = function(_, unit)
        local ns = EllesmereNameplates_NS
        local eui = ns and ns.plates and ns.plates[unit]
        local health = eui and eui.health
        if not health or not ns.GetHealthBarWidth then return nil end
        local ratio = Ratio(health)
        local w, hh = ns.GetHealthBarWidth(), health:GetHeight()
        local _, _, _, _, hy = health:GetPoint(1)
        hy = hy or 0
        if not ratio or not Readable(w, hh, hy) or not w or not hh then return nil end
        local profile = ns.NP_GetProfile and ns.NP_GetProfile()
        local defaults = ns.NP_GetDefaults and ns.NP_GetDefaults() or {}
        local rects = {}
        for _, kind in ipairs(EUI_KINDS) do
            local slot = (profile and profile[kind.slot]) or defaults[kind.slot]
            local size = ns[kind.size] and ns[kind.size]()
            if slot and slot ~= "none" and size then
                local xOff, yOff = 0, 0
                if ns.GetAuraSlotOffsets then xOff, yOff = ns.GetAuraSlotOffsets(kind.slot) end
                local row = EuiRow(ns, slot, size, w, hh, hy, xOff or 0, yOff or 0)
                if row then rects[#rects + 1] = Scaled(row, ratio, 0) end
            end
        end
        return rects
    end,
}

-- Plater.SetAnchor's outer sides 1-8 (Plater.lua anchor_functions): the
-- point on the frame it attaches to, then the widget's own point, plain and
-- centred. Sides 9-17 sit inside the frame.
local PLATER_SIDES = {
    { "TOPLEFT", "BOTTOMLEFT", "BOTTOM" },
    { "LEFT", "RIGHT", "CENTER" },
    { "BOTTOMLEFT", "TOPLEFT", "TOP" },
    { "BOTTOM", "TOP", "TOP" },
    { "BOTTOMRIGHT", "TOPRIGHT", "TOP" },
    { "RIGHT", "LEFT", "CENTER" },
    { "TOPRIGHT", "BOTTOMRIGHT", "BOTTOM" },
    { "TOP", "BOTTOM", "BOTTOM" },
}

-- One w x h icon placed by `anchor` on a frame of size fw x fh centred at (fx, fy).
local function PlaterIcon(anchor, centred, w, h, fw, fh, fx, fy, dy)
    local side = type(anchor) == "table" and PLATER_SIDES[anchor.side]
    if not side then return nil end
    local rel = side[1]
    local x = fx + (rel:find("LEFT") and -fw / 2 or rel:find("RIGHT") and fw / 2 or 0) + (anchor.x or 0)
    local y = fy + (rel:find("TOP") and fh / 2 or rel:find("BOTTOM") and -fh / 2 or 0) + (anchor.y or 0) + (dy or 0)
    return Box(centred and side[3] or side[2], x, y, w, h)
end

M.Adapters.plater = {
    name = "Plater",
    perUnit = false,
    loaded = function() return Plater ~= nil end,
    rects = function(plate)
        local profile = Plater and Plater.db and Plater.db.profile
        local unitFrame = plate.unitFrame
        local healthBar = unitFrame and unitFrame.healthBar
        if not profile or not healthBar or profile.use_ui_parent then return nil end
        local config = profile.plate_config and profile.plate_config.enemynpc
        local size = config and config.health
        if type(size) ~= "table" or not size[1] or not size[2] then return nil end
        local barRatio, frameRatio = Ratio(healthBar), Ratio(unitFrame)
        local fw, fh = unitFrame:GetWidth(), unitFrame:GetHeight()
        if not barRatio or not frameRatio or not Readable(fw, fh) or not fw or not fh then return nil end
        local bx, by = profile.global_offset_x or 0, profile.global_offset_y or 0
        local dy = config.buff_frame_y_offset or 0
        local rects = {}
        local function Add(rect, ratio)
            if rect then rects[#rects + 1] = Scaled(rect, ratio, 0) end
        end
        Add(PlaterIcon(profile.aura_frame1_anchor, (profile.aura_grow_direction or 2) == 2,
            profile.aura_width or 26, profile.aura_height or 16, size[1], size[2], bx, by, dy), barRatio)
        if profile.buffs_on_aura2 then
            Add(PlaterIcon(profile.aura_frame2_anchor, (profile.aura2_grow_direction or 2) == 2,
                profile.aura_width2 or 26, profile.aura_height2 or 16, size[1], size[2], bx, by, dy), barRatio)
        end
        -- The extra icons (purge, enrage, defensives) hang off the unit frame,
        -- which covers the whole Blizzard plate, not the health bar.
        Add(PlaterIcon(profile.extra_icon_anchor, false,
            profile.extra_icon_width or 30, profile.extra_icon_height or 18, fw, fh, 0, 0), frameRatio)
        return rects
    end,
}

-- Which sides each addon draws auras on, from settings alone, for the hint.
-- Platynator picks a design per unit, so it can only say "can".
M.Adapters.platynator.sides = function() return nil end

local EUI_SIDE = { left = "left", right = "right", top = "top", topleft = "top", topright = "top", bottom = "bottom" }
M.Adapters.ellesmere.sides = function()
    local ns = EllesmereNameplates_NS
    local profile = ns.NP_GetProfile and ns.NP_GetProfile()
    local defaults = ns.NP_GetDefaults and ns.NP_GetDefaults() or {}
    local sides = {}
    for _, kind in ipairs(EUI_KINDS) do
        local side = EUI_SIDE[(profile and profile[kind.slot]) or defaults[kind.slot]]
        if side then sides[side] = true end
    end
    return sides
end

local PLATER_SIDE = { "top", "left", "bottom", "bottom", "bottom", "right", "top", "top" }
M.Adapters.plater.sides = function()
    local profile = Plater.db and Plater.db.profile
    if not profile then return {} end
    if profile.use_ui_parent then return {}, true end
    local sides = {}
    local anchors = { profile.aura_frame1_anchor, profile.extra_icon_anchor }
    if profile.buffs_on_aura2 then anchors[3] = profile.aura_frame2_anchor end
    for _, anchor in pairs(anchors) do
        local side = type(anchor) == "table" and PLATER_SIDE[anchor.side]
        if side then sides[side] = true end
    end
    return sides
end

local ORDER = { "platynator", "ellesmere", "plater" }

function M.Active()
    for _, key in ipairs(ORDER) do
        local adapter = M.Adapters[key]
        if adapter.loaded() then return adapter end
    end
end

local SIDES = { left = true, right = true, top = true, bottom = true }
local cache = setmetatable({}, { __mode = "k" })

-- Second result: whether the answer may be kept. We load before the
-- nameplate addons and see NAME_PLATE_UNIT_ADDED first, so their frame for
-- this unit may not exist yet; that miss is asked again on the next paint.
local function Measure(plate, unit, side, size, nudge)
    local adapter = M.Active()
    if not adapter then return 0, true end
    local okSize, w, h = pcall(CastAheadCore.MeasurePlate, plate)
    if not okSize or not w or not h then return 0, true end
    local ok, rects = pcall(adapter.rects, plate, unit)
    if not ok then return 0, true end
    if not rects then return 0, false end
    return M.Push(rects, side, w / 2, h / 2, { nudge - size / 2, nudge + size / 2 }), true
end

-- Outward push in UIParent pixels for our icons on `side` of this plate.
-- `nudge` is the player's shift across that side (NudgeY beside the plate,
-- NudgeX above or below it).
function M.ForPlate(plate, unit, side, size, nudge)
    if not plate or not unit or not SIDES[side] then return 0 end
    local hit = cache[plate]
    if hit and hit.side == side and hit.size == size and hit.nudge == nudge then return hit.push end
    local push, keep = Measure(plate, unit, side, size, nudge)
    if keep then cache[plate] = { side = side, size = size, nudge = nudge, push = push } end
    return push
end

-- One line for the Size and position panel, or nil when there is nothing to say.
function M.Hint(side)
    if not SIDES[side] then return nil end
    local adapter = M.Active()
    if not adapter then return nil end
    local ok, sides, unmeasured = pcall(adapter.sides)
    if not ok then return nil end
    if unmeasured then
        return adapter.name .. " draws its plates in a way we cannot measure. Icons are not moved for this setup."
    end
    local verb = sides == nil and "can draw" or sides[side] and "draws"
    if not verb then return nil end
    local text = adapter.name .. " " .. verb .. " auras on the " .. side .. " of its plates. "
    if CastAheadConfig.Enabled("auraClearance") then
        return text .. "Icons are moved out by one aura icon."
    end
    return text .. "Turn on Make room for nameplate auras, or pick another side."
end

function M.Invalidate(plate)
    if plate then
        cache[plate] = nil
    else
        for key in pairs(cache) do cache[key] = nil end
    end
end

-- Plates are recycled between units and Platynator picks a design per unit,
-- so a plate is measured again whenever it changes hands. The two hooks only
-- drop the cache when the other addon re-lays its plates after a settings
-- change.
if CreateFrame then
    local events = CreateFrame("Frame")
    events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    events:RegisterEvent("PLAYER_LOGIN")
    events:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_LOGIN" then
            if hooksecurefunc and Plater and type(Plater.UpdateAllPlates) == "function" then
                hooksecurefunc(Plater, "UpdateAllPlates", function() M.Invalidate() end)
            end
            local ns = EllesmereNameplates_NS
            if hooksecurefunc and ns and type(ns.NPC_ReloadAll) == "function" then
                hooksecurefunc(ns, "NPC_ReloadAll", function() M.Invalidate() end)
            end
            return
        end
        local plate = unit and C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
        if plate then M.Invalidate(plate) end
    end)
end
