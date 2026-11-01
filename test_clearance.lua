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

print(failures == 0 and "OK" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
