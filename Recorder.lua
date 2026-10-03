CastAheadRecorder = {}
local R = CastAheadRecorder

BINDING_NAME_CASTAHEAD_MARK = "Mark a wrong call"
BINDING_NAME_CASTAHEAD_MARK_NOTE = "Mark a wrong call and add a note"

R.FORMAT = 1
R.MAX_KEYS = 5
R.MAX_LINES = 20000
R.RESUME_WINDOW = 7200
R.RECENT_WINDOW = 120
R.RECENT_MAX = 8
R.MARK_WINDOW = 60
R.EXPORT_LIMIT = 60000

local checksum
local mobOf = {}
local recent = {}
R.selected = nil

local function Journal()
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.journal = CastAheadDB.journal or { keys = {} }
    return CastAheadDB.journal
end

function R.Enabled()
    return CastAheadConfig.Get("devMode") == true and CastAheadConfig.Get("keyJournal") == true
end

local function Hash(h, text)
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return h
end

local function Serialize(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. Serialize(value[k]) end
    return "{" .. table.concat(parts, ";") .. "}"
end

function R.Checksum()
    if not checksum then
        local h = 5381
        h = Hash(h, Serialize(CastAheadData or {}))
        h = Hash(h, Serialize(CastAheadPriority or {}))
        h = Hash(h, Serialize(CastAheadTraits or {}))
        checksum = string.format("%08x", h)
    end
    return checksum
end

local function AddonVersion()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    return get and get("CastAhead", "Version") or "?"
end

function R.Keys() return Journal().keys end

function R.Current()
    local keys = Journal().keys
    local last = keys[#keys]
    if last and not last.ended then return last end
end

local function Forget()
    wipe(mobOf)
    wipe(recent)
    R.selected = nil
end

function R.StartKey(info)
    if R.Current() then R.EndKey("reset") end
    local keys = Journal().keys
    keys[#keys + 1] = {
        format = R.FORMAT, addon = AddonVersion(), data = R.Checksum(),
        instance = info.instance or 0, name = info.name or "?", level = info.level or 0,
        affixes = info.affixes or "", role = info.role or "NONE",
        startedAt = GetTime(), mobs = 0, marks = 0, lines = {},
    }
    while #keys > R.MAX_KEYS do table.remove(keys, 1) end
    Forget()
end

local function Kind(line) return line:match("^%d+|(%u+)|") end

function R.Summary(key)
    local casts, calls = 0, 0
    for _, line in ipairs(key.lines) do
        local kind = Kind(line)
        if kind == "STOP" then casts = casts + 1 end
        if kind == "START" and not line:match("^%d+|START|[^|]*|%d|[^|]*|%-|") then calls = calls + 1 end
    end
    return string.format("|cff33ff99Cast Ahead|r %d casts, %d calls, %d marks recorded - /ca report",
        casts, calls, key.marks or 0)
end

function R.EndKey(result)
    local key = R.Current()
    if not key then return end
    key.ended, key.endedAt = result or "completed", GetTime()
    if key.ended == "completed" then print(R.Summary(key)) end
end

function R.Restore()
    local key = R.Current()
    if not key then return end
    local _, _, _, _, _, _, _, instance = GetInstanceInfo()
    local age = GetTime() - key.startedAt
    if instance ~= key.instance or age < 0 or age > R.RESUME_WINDOW then
        R.EndKey("left")
    end
    Forget()
end

local function Clean(text)
    return (tostring(text):gsub("[|\r\n]", " "))
end

local function Field(value)
    if type(value) == "table" then
        local out = {}
        for i = 1, #value do out[i] = Clean(value[i]) end
        return table.concat(out, ",")
    end
    if value == nil then return "" end
    return Clean(value)
end

local function IsMobId(slot)
    return type(slot) == "string" and slot:match("^%d+%.%d+$") ~= nil
end

local function SlotNumber(slot)
    if type(slot) == "number" then return slot end
    if type(slot) == "string" and not IsMobId(slot) then return tonumber(slot:match("(%d+)$")) end
end

local function MobId(slot)
    if IsMobId(slot) then return slot end
    local n = SlotNumber(slot)
    if not n then return "-" end
    return mobOf[n] and (n .. "." .. mobOf[n]) or tostring(n)
end

local function Ms(key, at)
    return math.floor(((at or GetTime()) - key.startedAt) * 1000 + 0.5)
end

local function Touch(id, kind, fields, now)
    if id == "-" or kind == "SNAP" then return end
    local entry = recent[id]
    if not entry then
        entry = { id = id, state = "seen" }
        recent[id] = entry
    end
    entry.lastAt = now
    if kind == "START" then
        entry.state = "casting"
        if fields[2] ~= "-" then entry.spell = fields[2] end
        entry.call = fields[3]
    elseif kind == "STOP" then
        entry.state = "seen"
        if fields[3] ~= "" and not fields[3]:find(",", 1, true) then entry.spell = fields[3] end
        entry.call = fields[4]
    elseif kind == "PRED" then
        entry.spell = entry.spell or fields[1]
    elseif kind == "PLATE" and fields[1] == "removed" then
        entry.state = fields[2] == "died" and "dead" or "gone"
    end
end

local function Prune(now)
    local list = {}
    for id, entry in pairs(recent) do
        if now - entry.lastAt > R.RECENT_WINDOW and id ~= R.selected then
            recent[id] = nil
        else
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a, b) return a.lastAt > b.lastAt end)
    for i = R.RECENT_MAX + 1, #list do
        if list[i].id ~= R.selected then recent[list[i].id] = nil end
    end
end

local function Write(kind, id, fields)
    local key = R.Current()
    if not key or key.truncated then return end
    local lines = key.lines
    local now = GetTime()
    local t = Ms(key, now)
    if #lines >= R.MAX_LINES then
        lines[#lines + 1] = t .. "|TRIM|-|" .. #lines
        key.truncated = t
        return
    end
    lines[#lines + 1] = t .. "|" .. kind .. "|" .. id .. (#fields > 0 and ("|" .. table.concat(fields, "|")) or "")
    Touch(id, kind, fields, now)
end

function R.Note(kind, slot, ...)
    local key = R.Current()
    if not key then return end
    local fields = {}
    for i = 1, select("#", ...) do fields[i] = Field((select(i, ...))) end
    local n = SlotNumber(slot)
    if kind == "PLATE" and fields[1] == "added" and n then
        key.mobs = (key.mobs or 0) + 1
        mobOf[n] = key.mobs
    end
    Write(kind, MobId(slot), fields)
    if kind == "PLATE" and fields[1] == "removed" and n then mobOf[n] = nil end
end

function R.Recent()
    local now = GetTime()
    Prune(now)
    local list = {}
    for _, entry in pairs(recent) do
        list[#list + 1] = { id = entry.id, state = entry.state, spell = entry.spell, call = entry.call,
            ago = now - entry.lastAt, selected = entry.id == R.selected }
    end
    table.sort(list, function(a, b) return a.ago < b.ago end)
    return list
end

function R.Select(id)
    R.selected = (R.selected ~= id) and id or nil
end

local function EnsureKey()
    if R.Current() then return R.Current() end
    local name, _, _, _, _, _, _, instance = GetInstanceInfo()
    R.StartKey({ instance = instance, name = name, level = 0 })
    return R.Current()
end

function R.Mark()
    if not R.Enabled() then return end
    local key = EnsureKey()
    key.marks = (key.marks or 0) + 1
    local n = key.marks
    local selected = R.selected or "-"
    R.Note("MARK", nil, n, selected)
    local live = {}
    for _, entry in ipairs(CastAheadCore and CastAheadCore.Snapshot and CastAheadCore.Snapshot() or {}) do
        live[MobId(entry.slot)] = entry
    end
    for _, entry in ipairs(R.Recent()) do
        local now = live[entry.id] or {}
        local casting = now.casting or {}
        local preds = {}
        for i, p in ipairs(now.preds or {}) do preds[i] = p[1] .. "@" .. p[2] .. "~" .. p[3] end
        Write("SNAP", entry.id, { Field(entry.state), Field(casting.claimed or entry.spell or "-"),
            Field(casting.call or entry.call or "-"), Field(casting.candidates or {}),
            Field(casting.sinceMs or "-"), Field(table.concat(preds, ",")) })
    end
    R.selected = nil
    print("|cff33ff99Cast Ahead|r mark " .. n .. " recorded" .. (selected ~= "-" and (" on " .. selected) or ""))
    return n
end

function R.AddNote(n, text)
    if not n or not text or text:match("^%s*$") then return end
    if not R.Current() then return end
    R.Note("NOTE", nil, n, text)
end

local function Clock(ms)
    ms = tonumber(ms) or 0
    return string.format("%02d:%04.1f", math.floor(ms / 60000), (ms % 60000) / 1000)
end

local function Parse(line)
    local t, kind, id, rest = line:match("^(%d+)|(%u+)|([^|]*)|?(.*)$")
    return tonumber(t), kind, id, rest
end

local function MarkWindows(key)
    local marks = {}
    for i, line in ipairs(key.lines) do
        local t, kind, _, rest = Parse(line)
        if kind == "MARK" then
            local n, selected = rest:match("^(%d+)|(.*)$")
            marks[#marks + 1] = { index = i, t = t, n = tonumber(n), selected = selected }
        end
    end
    return marks
end

local function WindowLines(key, mark)
    local picked = {}
    for i, line in ipairs(key.lines) do
        local t, kind, id, rest = Parse(line)
        if t and ((t >= mark.t - R.MARK_WINDOW * 1000 and t <= mark.t)
            or (mark.selected ~= "-" and id == mark.selected)
            or (kind == "NOTE" and tonumber(rest:match("^(%d+)")) == mark.n)
            or (i > mark.index and kind == "SNAP" and t == mark.t)) then
            picked[i] = true
        end
    end
    return picked
end

local function MarkSummary(key, mark)
    local claim, call, note = "-", "-", {}
    for i = mark.index + 1, #key.lines do
        local _, kind, id, rest = Parse(key.lines[i])
        if kind ~= "SNAP" then break end
        if mark.selected == "-" or id == mark.selected then
            local _, c, k = rest:match("^([^|]*)|([^|]*)|([^|]*)")
            claim, call = c or "-", k or "-"
            break
        end
    end
    for _, line in ipairs(key.lines) do
        local _, kind, _, rest = Parse(line)
        if kind == "NOTE" then
            local n, text = rest:match("^(%d+)|(.*)$")
            if tonumber(n) == mark.n then note[#note + 1] = text end
        end
    end
    return string.format("# mark %d at %s on %s: claimed %s/%s; note: %s", mark.n, Clock(mark.t),
        mark.selected, claim, call, #note > 0 and table.concat(note, " / ") or "-")
end

function R.Export(key)
    local marks = MarkWindows(key)
    local dropped = 0
    local function Build(from)
        local picked = {}
        if #marks == 0 then
            for i = from, #key.lines do picked[i] = true end
        else
            for m = from, #marks do
                for i in pairs(WindowLines(key, marks[m])) do picked[i] = true end
            end
        end
        local body = {}
        for i = 1, #key.lines do
            if picked[i] then body[#body + 1] = key.lines[i] end
        end
        local out = { string.format("CastAhead-Report %d addon=%s data=%s instance=%s level=%s affixes=%s role=%s len=%d marks=%d%s%s",
            key.format, key.addon, key.data, key.instance, key.level, key.affixes ~= "" and key.affixes or "-",
            key.role, Ms(key, key.endedAt), key.marks or 0,
            key.truncated and (" truncated=" .. key.truncated) or "",
            dropped > 0 and (" dropped=" .. dropped) or "") }
        for m = from, #marks do out[#out + 1] = MarkSummary(key, marks[m]) end
        for _, line in ipairs(body) do out[#out + 1] = line end
        out[#out + 1] = "CastAhead-Report end lines=" .. #body
        return table.concat(out, "\n")
    end
    local from = 1
    local text = Build(from)
    local last = #marks > 0 and #marks or #key.lines
    while #text > R.EXPORT_LIMIT and from < last do
        from = from + 1
        dropped = from - 1
        text = Build(from)
    end
    return text
end
