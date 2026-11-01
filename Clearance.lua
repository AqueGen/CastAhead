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
