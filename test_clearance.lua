-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
-- Standalone check for Clearance.lua: lua test_clearance.lua

local failures = 0
local function check(ok, msg)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local frames, hooks = {}, {}
CreateFrame = function()
    local f = { events = {} }
    function f:RegisterEvent(event) self.events[event] = true end
    function f:SetScript(_, fn) self.onEvent = fn end
    frames[#frames + 1] = f
    return f
end
hooksecurefunc = function(_, name, fn) hooks[name] = fn end

dofile("Config.lua")
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
    check(P({ { left = -84, right = -60, bottom = 40, top = 64, anyHeight = true } }, "left", 60, 6, band) == 24,
        "a rect whose height is unknown counts beside the plate")
    check(P({ { left = -12, right = 12, bottom = 6, top = 32, anyHeight = true } }, "top", 60, 6, band) == 26,
        "and is measured as given above it")
end

local SECRET = {}
issecretvalue = function(v) return v == SECRET end
UIParent = { GetEffectiveScale = function() return 1 end }

local function Same(rect, l, r, b, t)
    local e = 1e-6
    return rect and math.abs(rect.left - l) < e and math.abs(rect.right - r) < e
        and math.abs(rect.bottom - b) < e and math.abs(rect.top - t) < e
end

-- What the game answers inside an instance for frames on a nameplate.
local function Restricted()
    error("Frame:GetPoint(): Action[FrameMeasurement] failed because[Can't measure restricted regions]")
end

local function PlatyPlate(aurasInfo, scale)
    local display = {
        aurasInfo = aurasInfo,
        BuffDisplay = {},
        IsShown = function() return true end,
        GetEffectiveScale = function() return scale or 1 end,
        GetPoint = Restricted, GetWidth = Restricted, GetHeight = Restricted,
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
    check(rects and rects[1].anyHeight, "the display's height on the plate cannot be read, so any height counts")
    rects = A.rects(PlatyPlate({ buffs = buffs }, 0.5))
    check(rects and Same(rects[1], -42, -30, -6, 6), "a smaller display scale shrinks the rect")
    rects = A.rects(PlatyPlate({ debuffs = { anchor = { -70, 0 }, scale = 1, height = 1 } }))
    check(rects and Same(rects[1], -80, -60, -10, 10), "a two-number anchor centres the holder")
    check(A.rects({ GetChildren = function() return { IsShown = function() return true end } end }) == nil,
        "no Platynator display on the plate")
    local secret = PlatyPlate({ buffs = buffs })
    local display = select(2, secret.GetChildren())
    display.GetEffectiveScale = function() return SECRET end
    check(A.rects(secret) == nil, "a Secret scale gives up")
    rects = A.rects(PlatyPlate({ buffs = { scale = 1, height = 1 }, debuffs = { anchor = { -70, 0 }, scale = 1, height = 1 } }))
    check(rects and #rects == 1 and Same(rects[1], -80, -60, -10, 10),
        "an entry without an anchor is skipped, the rest still count")
    Platynator = nil
    check(not A.loaded(), "no Platynator global means not loaded")
end

local function EuiStub(profile)
    local defaults = { buffSlot = "left", debuffSlot = "top", ccSlot = "right" }
    local health = {
        GetHeight = Restricted, GetWidth = Restricted, GetPoint = Restricted,
        GetEffectiveScale = function() return 1 end,
    }
    local plate = { health = health }
    EllesmereNameplates_NS = {
        plates = { nameplate1 = plate },
        NP_GetProfile = function() return profile end,
        NP_GetDefaults = function() return defaults end,
        GetHealthBarWidth = function() return 120 end,
        GetHealthBarHeight = function() return 10 end,
        GetNameplateYOffset = function() return 0 end,
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
    plate.health.GetEffectiveScale = function() return SECRET end
    check(A.rects({}, "nameplate1") == nil, "a Secret bar scale gives up")
    EuiStub(nil)
    EllesmereNameplates_NS.GetNameplateYOffset = function() return 4 end
    check(Has(A.rects({}, "nameplate1"), -86, -62, -1, 23), "the bar's own y offset moves its side rows")
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
            GetWidth = Restricted, GetHeight = Restricted, GetPoint = Restricted,
            GetEffectiveScale = scale,
            healthBar = { GetEffectiveScale = scale },
        },
    }
end

do
    local A = CastAheadClearance.Adapters.plater
    -- The Blizzard plate's own size is readable in an instance, 120 x 40 here.
    local function R(plate) return A.rects(plate, "nameplate1", 120, 40) end
    local plate = PlaterStub()
    check(A.loaded(), "Plater global means loaded")
    local rects = R(plate)
    check(rects and #rects == 2, "defaults give the main aura row and the extra icons")
    check(Has(rects, -13, 13, 11, 27), "main auras centred above the health bar")
    check(Has(rects, 56, 86, -9, 9), "extra icons right of the plate frame, not the health bar")
    -- Lifted into UIParent the unit frame still covers the Blizzard plate and
    -- the bar is still centred on it (Plater.lua UpdatePlateSize, DB_USE_UIPARENT).
    rects = R(PlaterStub({ use_ui_parent = true }))
    check(rects and #rects == 2 and Has(rects, 56, 86, -9, 9), "plates lifted into UIParent are measured the same way")
    rects = R(PlaterStub({ extra_icon_anchor = { side = 11, x = 0, y = 0 } }))
    check(rects and #rects == 1, "an inner side adds nothing")
    rects = R(PlaterStub({ aura_frame1_anchor = { side = 2, x = -2, y = 0 }, aura_grow_direction = 1 }))
    check(Has(rects, -84, -58, -8, 8), "a left main row, not centred, ends at the bar's left edge")
    rects = R(PlaterStub({ buffs_on_aura2 = true, aura_frame2_anchor = { side = 4, x = 0, y = -1 } }))
    check(rects and #rects == 3 and Has(rects, -13, 13, -23, -7), "the second row counts when buffs go there")
    plate = PlaterStub()
    plate.unitFrame = nil
    check(R(plate) == nil, "no Plater unit frame on the plate")
    Plater = nil
    check(not A.loaded(), "no Plater global means not loaded")
end

do
    local H = CastAheadClearance.Hint
    CastAheadDB = {}
    Platynator, EllesmereNameplates_NS, Plater = nil, nil, nil
    check(H("left") == nil, "hint: nothing loaded, nothing to say")
    EuiStub(nil)
    check(H("left") == "EllesmereUI Nameplates draws auras on the left of its plates. Icons are moved out by one aura icon.",
        "hint: EUI buffs on our side, room made")
    CastAheadConfig.SetEnabled("auraClearance", false)
    check(H("left", "The switch") == "EllesmereUI Nameplates draws auras on the left of its plates. "
        .. "Turn on The switch, or pick another side.", "hint: switched off, names the switch")
    CastAheadConfig.SetEnabled("auraClearance", true)
    check(H("top") == "EllesmereUI Nameplates draws auras on the top of its plates. Icons are moved out by one aura icon.",
        "hint: debuffs above count for top")
    check(H("bottom") == nil, "hint: nothing of theirs below the plate")
    check(H("topleft") == nil and H("center") == nil, "hint: corners and centre are never pushed, so never hinted")
    EllesmereNameplates_NS = nil
    PlaterStub()
    check(H("right") == "Plater draws auras on the right of its plates. Icons are moved out by one aura icon.",
        "hint: Plater extra icons on the right")
    check(H("left") == nil, "hint: Plater defaults leave the left free")
    PlaterStub({ use_ui_parent = true })
    check(H("right") == "Plater draws auras on the right of its plates. Icons are moved out by one aura icon.",
        "hint: plates lifted into UIParent are handled like any other")
    Plater = nil
    Platynator = {}
    check(H("left") == "Platynator can draw auras on the left of its plates. Icons are moved out by one aura icon.",
        "hint: Platynator designs are per unit, so it can draw")
    Platynator = nil
end

do
    local F, H = CastAheadClearance.ForPlate, CastAheadClearance.Hint
    local measured = true
    CastAheadCore = { MeasurePlate = function() if measured then return 120, 12 end end }
    CastAheadDB = {}

    Platynator = {}
    local plate = PlatyPlate({ buffs = { anchor = { "RIGHT", -60, 0 }, scale = 1.2, height = 1 } })
    local display = select(2, plate.GetChildren())
    CastAheadClearance.Invalidate()
    check(F(plate, "nameplate1", "left", 26, 0) == 24, "forplate: Platynator buff left of the plate")
    display.aurasInfo = { buffs = { anchor = { "RIGHT", -60, 0 }, scale = 1.5, height = 1 } }
    check(F(plate, "nameplate1", "left", 26, 0) == 30, "forplate: a new design on the same plate is measured again")
    local swapped = PlatyPlate({ buffs = { anchor = { "RIGHT", -60, 0 }, scale = 1, height = 1 } })
    local fresh = select(2, swapped.GetChildren())
    display.IsShown = function() return false end
    plate.GetChildren = function() return display, fresh end
    check(F(plate, "nameplate1", "left", 26, 0) == 20, "forplate: a display swapped for another is measured again")

    measured = false
    CastAheadClearance.Invalidate()
    check(F(plate, "nameplate1", "left", 26, 0) == 0, "forplate: an unreadable plate gives no push")
    measured = true
    check(F(plate, "nameplate1", "left", 26, 0) == 20, "forplate: and is measured once it reads again")
    Platynator = nil

    local p = PlaterStub({ aura_frame1_anchor = { side = 2, x = -2, y = 0 }, aura_grow_direction = 1 })
    Plater.db.profile.plate_config.enemynpc.health_incombat = { 120, 16 }
    check(Has(CastAheadClearance.Adapters.plater.rects(p, "nameplate1", 120, 40), -88, -62, -8, 8),
        "plater: the wider in-combat bar decides, so the icons do not move mid-fight")

    PlaterStub({ aura_frame1_anchor = { side = 7, x = 0, y = 0 }, extra_icon_anchor = { side = 11, x = 0, y = 0 } })
    check(H("top") == nil, "hint: a corner row does not reach our centred top icon")
    Plater = nil
    EuiStub({ debuffSlot = "topleft", buffSlot = "none", ccSlot = "none" })
    check(H("top") == nil, "hint: an EUI corner slot does not claim top")

    EuiStub(nil)
    local ns = EllesmereNameplates_NS
    ns.GetAuraCrop = function(kind) return kind == "buffs" and 0.8 or nil end
    ns.GetAuraCropHeight = function(crop, size) return size * crop end
    ns.NP_ClassicSide = function(side) return side == "left" and 3 or 0 end
    check(Has(CastAheadClearance.Adapters.ellesmere.rects({}, "nameplate1"), -89, -65, -5, 14.2),
        "eui: cropped icons are shorter and the classic border widens the gap")
    EllesmereNameplates_NS = nil

    local events = frames[1]
    check(events and events.events.NAME_PLATE_UNIT_ADDED and events.events.NAME_PLATE_UNIT_REMOVED,
        "events: plate add and remove are watched")
    Platynator = {}
    local onPlate = PlatyPlate({ buffs = { anchor = { "RIGHT", -60, 0 }, scale = 1.2, height = 1 } })
    C_NamePlate = { GetNamePlateForUnit = function() return onPlate end }
    CastAheadClearance.Invalidate()
    F(onPlate, "nameplate1", "left", 26, 0)
    select(2, onPlate.GetChildren()).aurasInfo.buffs.scale = 1.5
    check(F(onPlate, "nameplate1", "left", 26, 0) == 24, "events: the same design table stays cached")
    events.onEvent(events, "NAME_PLATE_UNIT_ADDED", "nameplate1")
    check(F(onPlate, "nameplate1", "left", 26, 0) == 30, "events: a plate added again is measured again")
    Platynator = nil
    PlaterStub()
    Plater.UpdateAllPlates = function() end
    EllesmereNameplates_NS = { NPC_ReloadAll = function() end }
    events.onEvent(events, "PLAYER_LOGIN")
    check(hooks.UpdateAllPlates and hooks.NPC_ReloadAll, "events: Plater and EUI relayouts are hooked at login")
    Plater, EllesmereNameplates_NS, C_NamePlate = nil, nil, nil
end

print(failures == 0 and "OK" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
