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
    if advice.key == "TANK" then
        return bit.bor(mask.TankRole or 0, mask.DeadlyEffect or 0)
    elseif advice.key == "AOE" then
        return bit.bor(mask.DpsRole or 0, mask.HealerRole or 0)
    elseif advice.key == "KICK" then
        return mask.MagicEffect
    end
    return nil
end

local function Severity(advice)
    local levels = Enum and Enum.EncounterEventSeverity
    if not levels then return nil end
    if advice and (advice.key == "TANK" or advice.key == "AOE") then
        return levels.High
    end
    return levels.Medium
end

function T.Cancel(track)
    if not track or not track.timelineEventID then return end
    if C_EncounterTimeline and C_EncounterTimeline.CancelScriptEvent then
        -- Only ever our own id. CancelAllScriptEvents would take out every other
        -- addon's events too.
        pcall(C_EncounterTimeline.CancelScriptEvent, track.timelineEventID)
    end
    track.timelineEventID = nil
    track.timelineTargetAt = nil
end

-- The cast we predicted has started: let the event resolve rather than yanking
-- it off the timeline.
function T.Finish(track)
    if not track or not track.timelineEventID then return end
    if C_EncounterTimeline and C_EncounterTimeline.FinishScriptEvent then
        pcall(C_EncounterTimeline.FinishScriptEvent, track.timelineEventID)
    end
    track.timelineEventID = nil
    track.timelineTargetAt = nil
end

-- `confident` is decided by the caller: one candidate, a real measured schedule,
-- and enough observations behind it.
function T.Sync(track, targetAt, row, advice, confident)
    if not track then return end
    if not (confident and targetAt and row and Available()) then
        T.Cancel(track)
        return
    end
    local remaining = targetAt - GetTime()
    if remaining <= 0 then
        T.Cancel(track)
        return
    end
    -- Already showing this cast at almost this time: leave it be, or the icon
    -- restarts its entry animation on every recalculation.
    if track.timelineEventID and track.timelineSpell == row.spell
        and track.timelineTargetAt
        and math.abs(track.timelineTargetAt - targetAt) < RETIME_THRESHOLD then
        return
    end
    T.Cancel(track)

    local info = C_Spell.GetSpellInfo(row.spell)
    local icon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(row.spell)
    local request = {
        spellID = row.spell,
        iconFileID = icon or (info and info.iconID) or 136243,
        duration = remaining,
        maxQueueDuration = QUEUE_GRACE,
        overrideName = advice and advice.say or (info and info.name) or row.name or "",
        severity = Severity(advice),
    }
    local icons = IconMask(advice)
    if icons then request.icons = icons end

    local ok, eventID = pcall(C_EncounterTimeline.AddScriptEvent, request)
    if ok and eventID then
        track.timelineEventID = eventID
        track.timelineTargetAt = targetAt
        track.timelineSpell = row.spell
    end
end
