-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
-- Standalone check for Clearance.lua: lua test_clearance.lua

local failures = 0
local function check(ok, msg)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

dofile("Clearance.lua")

do
    local P = CastAheadClearance.Push
    local band = { -13, 13 }
    check(P({}, "left", 60, 6, band) == 0, "no rects, no push")
    check(P({ { left = -84, right = -60, bottom = -12, top = 12 } }, "left", 60, 6, band) == 24,
        "one 24px icon left of the plate pushes 24")
    check(P({ { left = -84, right = -60, bottom = -12, top = 12 }, { left = -90, right = -62, bottom = -14, top = 14 } },
        "left", 60, 6, band) == 30, "max over groups, not the sum")
    check(P({ { left = -50, right = -26, bottom = -12, top = 12 } }, "left", 60, 6, band) == 0,
        "an icon inside the plate width does not push")
    check(P({ { left = -84, right = -60, bottom = 20, top = 44 } }, "left", 60, 6, band) == 0,
        "a corner icon above our band does not count for left")
    check(P({ { left = -84, right = -60, bottom = 20, top = 44 } }, "top", 60, 6, { -13, 13 }) == 0,
        "same icon: x range -84..-60 misses our top band")
    check(P({ { left = -12, right = 12, bottom = 6, top = 32 } }, "top", 60, 6, { -13, 13 }) == 26,
        "debuff row above the plate pushes top")
    check(P({ { left = 60, right = 90, bottom = -9, top = 9 } }, "right", 60, 6, band) == 30, "right mirrors left")
    check(P({ { left = -12, right = 12, bottom = -40, top = -14 } }, "bottom", 60, 6, { -13, 13 }) == 34,
        "bottom mirrors top")
    check(P({ { left = -84, right = -60, bottom = -12, top = 12 } }, "topleft", 60, 6, band) == 0, "corners never push")
    check(P({ { left = -84, right = -60, bottom = -12, top = 12 } }, "center", 60, 6, band) == 0, "centre never pushes")
    check(P({ { left = -84, right = -60, bottom = 13, top = 30 } }, "left", 60, 6, band) == 0,
        "touching the band edge is not overlap")
end

local SECRET = {}
issecretvalue = function(v) return v == SECRET end
UIParent = { GetEffectiveScale = function() return 1 end }

local function Same(rect, l, r, b, t)
    local e = 1e-6
    return rect and math.abs(rect.left - l) < e and math.abs(rect.right - r) < e
        and math.abs(rect.bottom - b) < e and math.abs(rect.top - t) < e
end

local function PlatyPlate(aurasInfo, scale, yOffset)
    local display = {
        aurasInfo = aurasInfo,
        BuffDisplay = {},
        IsShown = function() return true end,
        GetEffectiveScale = function() return scale or 1 end,
        GetPoint = function() return "CENTER", nil, "CENTER", 0, yOffset or 0 end,
    }
    local other = { IsShown = function() return true end }
    return { GetChildren = function() return other, display end }
end

do
    Platynator = {}
    local A = CastAheadClearance.Adapters.platynator
    check(A.loaded(), "Platynator global means loaded")
    local buffs = { anchor = { "RIGHT", -60, 0 }, scale = 1.2, height = 1 }
    local rects = A.rects(PlatyPlate({ buffs = buffs }))
    check(rects and #rects == 1 and Same(rects[1], -84, -60, -12, 12), "a RIGHT-anchored holder left of centre")
    rects = A.rects(PlatyPlate({ buffs = buffs }, 0.5))
    check(rects and Same(rects[1], -42, -30, -6, 6), "a smaller display scale shrinks the rect")
    rects = A.rects(PlatyPlate({ buffs = buffs }, 1, 10))
    check(rects and Same(rects[1], -84, -60, -2, 22), "the display's y offset moves the rect")
    rects = A.rects(PlatyPlate({ debuffs = { anchor = { -70, 0 }, scale = 1, height = 1 } }))
    check(rects and Same(rects[1], -80, -60, -10, 10), "a two-number anchor centres the holder")
    check(A.rects({ GetChildren = function() return { IsShown = function() return true end } end }) == nil,
        "no Platynator display on the plate")
    local secret = PlatyPlate({ buffs = buffs })
    local display = select(2, secret.GetChildren())
    display.GetEffectiveScale = function() return SECRET end
    check(A.rects(secret) == nil, "a Secret scale gives up")
    check(A.rects(PlatyPlate({ buffs = { scale = 1, height = 1 } })) == nil, "an entry without an anchor gives up")
    Platynator = nil
    check(not A.loaded(), "no Platynator global means not loaded")
end

print(failures == 0 and "OK" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
