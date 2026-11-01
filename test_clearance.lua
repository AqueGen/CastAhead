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

local function EuiStub(profile)
    local defaults = { buffSlot = "left", debuffSlot = "top", ccSlot = "right" }
    local health = {
        GetHeight = function() return 10 end,
        GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
        GetEffectiveScale = function() return 1 end,
    }
    local plate = { health = health }
    EllesmereNameplates_NS = {
        plates = { nameplate1 = plate },
        NP_GetProfile = function() return profile end,
        NP_GetDefaults = function() return defaults end,
        GetHealthBarWidth = function() return 120 end,
        GetBuffIconSize = function() return 24 end,
        GetDebuffIconSize = function() return 26 end,
        GetCCIconSize = function() return 24 end,
        GetSideAuraXOffset = function() return 2 end,
        GetDebuffYOffset = function() return 2 end,
        GetAuraSlotOffsets = function() return 0, 0 end,
    }
    return plate
end

local function Has(rects, l, r, b, t)
    for _, rect in ipairs(rects or {}) do
        if Same(rect, l, r, b, t) then return true end
    end
    return false
end

do
    local A = CastAheadClearance.Adapters.ellesmere
    EuiStub(nil)
    check(A.loaded(), "EllesmereNameplates_NS means loaded")
    local rects = A.rects({}, "nameplate1")
    check(rects and #rects == 3, "defaults give three rows")
    check(Has(rects, -86, -62, -5, 19), "buffs left of the health bar, bottom-aligned")
    check(Has(rects, 62, 86, -5, 19), "CC right of the health bar")
    check(Has(rects, -13, 13, 7, 33), "debuffs above the health bar")
    check(A.rects({}, "nameplate2") == nil, "a unit EUI does not draw")
    EuiStub({ buffSlot = "none" })
    rects = A.rects({}, "nameplate1")
    check(rects and #rects == 2 and not Has(rects, -86, -62, -5, 19), "a slot set to none adds nothing")
    EuiStub({ buffSlot = "bottom" })
    check(Has(A.rects({}, "nameplate1"), -12, 12, -31, -7), "a bottom slot hangs under the bar")
    EuiStub({ buffSlot = "topleft" })
    check(Has(A.rects({}, "nameplate1"), -60, -36, 7, 31), "a topleft slot sits on the bar's top-left corner")
    local plate = EuiStub(nil)
    plate.health.GetHeight = function() return SECRET end
    check(A.rects({}, "nameplate1") == nil, "a Secret bar height gives up")
    EllesmereNameplates_NS = nil
    check(not A.loaded(), "no namespace means not loaded")
end

local function PlaterStub(profileChanges)
    local profile = {
        use_ui_parent = false,
        aura_frame1_anchor = { side = 8, x = 0, y = 5 },
        aura_frame2_anchor = { side = 8, x = 0, y = 5 },
        aura_grow_direction = 2,
        aura2_grow_direction = 2,
        aura_width = 26, aura_height = 16, aura_width2 = 26, aura_height2 = 16,
        buffs_on_aura2 = false,
        extra_icon_anchor = { side = 6, x = -4, y = 0 },
        extra_icon_width = 30, extra_icon_height = 18,
        global_offset_x = 0, global_offset_y = 0,
        plate_config = { enemynpc = { health = { 112, 12 }, buff_frame_y_offset = 0 } },
    }
    for k, v in pairs(profileChanges or {}) do profile[k] = v end
    Plater = { db = { profile = profile } }
    local scale = function() return 1 end
    return {
        unitFrame = {
            GetWidth = function() return 120 end,
            GetHeight = function() return 40 end,
            GetEffectiveScale = scale,
            healthBar = { GetEffectiveScale = scale },
        },
    }
end

do
    local A = CastAheadClearance.Adapters.plater
    local plate = PlaterStub()
    check(A.loaded(), "Plater global means loaded")
    local rects = A.rects(plate)
    check(rects and #rects == 2, "defaults give the main aura row and the extra icons")
    check(Has(rects, -13, 13, 11, 27), "main auras centred above the health bar")
    check(Has(rects, 56, 86, -9, 9), "extra icons right of the plate frame, not the health bar")
    check(A.rects(PlaterStub({ use_ui_parent = true })) == nil, "plates lifted into UIParent are not measured")
    rects = A.rects(PlaterStub({ extra_icon_anchor = { side = 11, x = 0, y = 0 } }))
    check(rects and #rects == 1, "an inner side adds nothing")
    rects = A.rects(PlaterStub({ aura_frame1_anchor = { side = 2, x = -2, y = 0 }, aura_grow_direction = 1 }))
    check(Has(rects, -84, -58, -8, 8), "a left main row, not centred, ends at the bar's left edge")
    rects = A.rects(PlaterStub({ buffs_on_aura2 = true, aura_frame2_anchor = { side = 4, x = 0, y = -1 } }))
    check(rects and #rects == 3 and Has(rects, -13, 13, -23, -7), "the second row counts when buffs go there")
    plate = PlaterStub()
    plate.unitFrame = nil
    check(A.rects(plate) == nil, "no Plater unit frame on the plate")
    Plater = nil
    check(not A.loaded(), "no Plater global means not loaded")
end

print(failures == 0 and "OK" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
