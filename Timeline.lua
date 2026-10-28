-- Feeds confident predictions into Blizzard's own encounter timeline.
--
-- Why not draw our own: the game already ships the sliding-icon timeline, and
-- the player positions, orients and sizes it in Edit Mode. Blizzard explicitly
-- supports addon events outside boss fights - see the comment in
-- Blizzard_EncounterTimeline/EncounterTimeline.lua:EvaluateVisibility, "Also
-- works for custom events".
--
-- Why only *confident* predictions: the timeline has no way for an addon to say
-- a time is an estimate (`isApproximate` exists on the event info but not on the
-- request), so anything uncertain would be drawn as though it were exact. Those
-- stay on the nameplate icons, which can show "~" and "!" honestly.

CastAheadTimeline = {}
local T = CastAheadTimeline

local function Record(...)
    local recorder = CastAheadRecorder
    if recorder and recorder.Enabled() then recorder.Note("TL", nil, ...) end
end

-- Re-adding is the only way to change an event's time, and each add replays the
-- icon's entry animation. Below this drift it is better to leave it alone.
local RETIME_THRESHOLD = 1.0
local QUEUE_GRACE = 4.0        -- how long an overdue event lingers at the line

local function Available()
    return C_EncounterTimeline and C_EncounterTimeline.AddScriptEvent
        and CastAheadConfig.Enabled("timeline")
        -- The player can switch the timeline off entirely; then this is a no-op
        -- and the nameplate icons carry everything.
        and (not C_EncounterTimeline.IsFeatureEnabled or C_EncounterTimeline.IsFeatureEnabled())
end

-- Role and effect badges the timeline draws for us, so "tank buster" and "raid
-- damage" need no text of our own - handy, because the spell name only shows in
-- vertical orientation and only when the player enabled it.
local function IconMask(advice)
    local mask = Enum and Enum.EncounterEventIconmask
    if not mask or not advice then return nil end
    if advice.key == "TANK" or advice.key == "BUSTER" then
        return bit.bor(mask.TankRole or 0, mask.DeadlyEffect or 0)
    elseif advice.key == "AOE" then
        return bit.bor(mask.DpsRole or 0, mask.HealerRole or 0)
    elseif advice.key == "KICK" then
        return mask.MagicEffect
    end
    return nil
end

-- What the bar is labelled with. The verdict's spoken line is the right words
-- - the bar has room for a phrase, and "tank buster" says more there than the
-- nameplate icon's cramped "BUSTER" - but it is written for a voice, so it
-- arrives in lower case. The game's own entries on this bar are spell names in
-- ordinary case, so ours are capitalised to match rather than shouted.
local function TimelineName(advice, info, row)
    local say = advice and advice.say
    if say and say ~= "" then
        return say:sub(1, 1):upper() .. say:sub(2)
    end
    return (info and info.name) or row.name or ""
end

local function Severity(advice)
    local levels = Enum and Enum.EncounterEventSeverity
    if not levels then return nil end
    if advice and (advice.key == "TANK" or advice.key == "BUSTER" or advice.key == "AOE") then
        return levels.High
    end
    return levels.Medium
end

-- BigWigs hides the game's timeline by default and leaves addon events out of
-- its own bars (BigWigs_Plugins/Timeline.lua skips source Script), so with it
-- nothing of ours shows. "Show in BigWigs bars" sends the same predictions to
-- its bars over its message bus. That bus is not a documented API, so every
-- call is guarded: if BigWigs changes it, only the bar is lost.
-- A sub-option of feeding the timeline, so it follows that switch too.
local function BigWigsOn()
    return CastAheadConfig.Get("bigwigsBars") == true and CastAheadConfig.Enabled("timeline")
        and type(BigWigsLoader) == "table" and type(BigWigsLoader.SendMessage) == "function"
end

-- BigWigs enables its core, and with it the bars, only inside an instance it
-- has modules for; elsewhere the messages reach nothing.
local function BigWigsLive()
    return type(BigWigs) == "table" and type(BigWigs.IsEnabled) == "function" and BigWigs:IsEnabled() == true
end

-- For the samples (test drive, Size and position), which run anywhere: say
-- why no BigWigs bars appear outside an instance.
function T.NoteBigWigsAsleep()
    if BigWigsOn() and not BigWigsLive() then
        print("|cff33ff99CastAhead|r BigWigs bars show only where BigWigs is running, inside a dungeon or raid.")
    end
end

local function SendBigWigs(...)
    if type(BigWigsLoader) == "table" and type(BigWigsLoader.SendMessage) == "function" then
        pcall(BigWigsLoader.SendMessage, BigWigsLoader, ...)
    end
end

-- BigWigs finds a bar by its module and text. Each track passes its own table
-- as the module, so two mobs on the same spell get a bar each, the way the
-- timeline shows an icon each. With no option key BigWigs colours the bar by
-- its defaults and never reads the module; `name` is for anything else that
-- listens to these messages.
local function BarModule(track)
    track.barModule = track.barModule or { name = "CastAhead" }
    return track.barModule
end

local function StopBar(track)
    if not track.barText then return end
    SendBigWigs("BigWigs_StopBar", BarModule(track), track.barText)
    track.barText, track.barTargetAt = nil, nil
end

local function CancelEvent(track)
    if not track.timelineEventID then return end
    if C_EncounterTimeline and C_EncounterTimeline.CancelScriptEvent then
        -- Only ever our own id. CancelAllScriptEvents would take out every other
        -- addon's events too.
        pcall(C_EncounterTimeline.CancelScriptEvent, track.timelineEventID)
    end
    Record("cancelled", track.timelineSpell)
    track.timelineEventID = nil
    track.timelineTargetAt = nil
end

function T.Cancel(track)
    if not track then return end
    CancelEvent(track)
    StopBar(track)
end

-- The cast we predicted has started: let the event resolve rather than yanking
-- it off the timeline.
function T.Finish(track)
    if not track then return end
    StopBar(track)
    if not track.timelineEventID then return end
    if C_EncounterTimeline and C_EncounterTimeline.FinishScriptEvent then
        pcall(C_EncounterTimeline.FinishScriptEvent, track.timelineEventID)
    end
    Record("finished", track.timelineSpell)
    track.timelineEventID = nil
    track.timelineTargetAt = nil
end

local function SyncBar(track, targetAt, row, advice, remaining)
    -- Nothing is recorded while BigWigs is not running, so the bar is sent
    -- once it is rather than counted as already shown.
    if not (BigWigsOn() and BigWigsLive()) then
        StopBar(track)
        return
    end
    if track.barText and track.barTargetAt and math.abs(track.barTargetAt - targetAt) < RETIME_THRESHOLD then
        return
    end
    StopBar(track)
    local info = C_Spell.GetSpellInfo(row.spell)
    local name = (info and info.name) or row.name or ""
    local text = TimelineName(advice, info, row)
    if name ~= "" and name ~= text then text = text .. ": " .. name end
    local icon = (C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(row.spell)) or (info and info.iconID) or 136243
    -- An overdue prediction waits at zero as long as the timeline's does.
    SendBigWigs("BigWigs_StartBar", BarModule(track), nil, text, remaining, icon, QUEUE_GRACE)
    track.barText, track.barTargetAt = text, targetAt
end

-- `confident` is decided by the caller: one candidate, a real measured schedule,
-- and enough observations behind it.
function T.Sync(track, targetAt, row, advice, confident)
    if not track then return end
    local remaining = confident and targetAt and row and targetAt - GetTime()
    if not remaining or remaining <= 0 then
        T.Cancel(track)
        return
    end
    SyncBar(track, targetAt, row, advice, remaining)
    if not Available() then
        CancelEvent(track)
        return
    end
    -- Already showing this cast at almost this time: leave it be, or the icon
    -- restarts its entry animation on every recalculation.
    if track.timelineEventID and track.timelineSpell == row.spell
        and track.timelineTargetAt
        and math.abs(track.timelineTargetAt - targetAt) < RETIME_THRESHOLD then
        return
    end
    CancelEvent(track)

    local info = C_Spell.GetSpellInfo(row.spell)
    local icon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(row.spell)
    local request = {
        spellID = row.spell,
        iconFileID = icon or (info and info.iconID) or 136243,
        duration = remaining,
        maxQueueDuration = QUEUE_GRACE,
        overrideName = TimelineName(advice, info, row),
        severity = Severity(advice),
    }
    local icons = IconMask(advice)
    if icons then request.icons = icons end

    local ok, eventID = pcall(C_EncounterTimeline.AddScriptEvent, request)
    if ok and eventID then
        track.timelineEventID = eventID
        track.timelineTargetAt = targetAt
        track.timelineSpell = row.spell
        local key = CastAheadRecorder and CastAheadRecorder.Current()
        Record("added", row.spell, key and math.floor((targetAt - key.startedAt) * 1000 + 0.5) or "?")
    end
end
