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
