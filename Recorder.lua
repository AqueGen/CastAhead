CastAheadRecorder = {}
local R = CastAheadRecorder

BINDING_NAME_CASTAHEAD_MARK = "Mark a wrong call"
BINDING_NAME_CASTAHEAD_MARK_NOTE = "Mark a wrong call and add a note"

R.FORMAT = 1
R.MAX_KEYS = 12
R.MAX_LINES = 20000
R.RESUME_WINDOW = 7200
R.RECENT_WINDOW = 120
R.RECENT_MAX = 8
R.MARK_WINDOW = 60
R.EXPORT_LIMIT = 60000

local UNCAPPED = { MARK = true, SNAP = true, NOTE = true }

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
    return CastAheadConfig.Recording()
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
    if not R.Enabled() then return end
    local keys = Journal().keys
    local last = keys[#keys]
    if last and not last.ended then return last end
end

local function Forget()
    wipe(mobOf)
    wipe(recent)
    R.selected = nil
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

local SHOWN = {
    START = "^%d|(%d+)|",
    STOP = "^%d|%d+|(%d+)|",
    PRED = "^(%d+)|",
    TL = "^added|(%d+)|",
}

function R.Coverage(key)
    local shown = {}
    for _, line in ipairs(key.lines) do
        local kind, rest = line:match("^%d+|(%u+)|[^|]*|(.*)$")
        local spell = SHOWN[kind] and rest:match(SHOWN[kind])
        if spell then shown[tonumber(spell)] = true end
    end
    local never, seen, total = {}, {}, 0
    for _, row in ipairs(CastAheadData and CastAheadData[key.instance] or {}) do
        if not seen[row.spell] then
            seen[row.spell] = true
            total = total + 1
            if not shown[row.spell] then never[#never + 1] = row end
        end
    end
    table.sort(never, function(a, b)
        if (a.prio ~= nil) ~= (b.prio ~= nil) then return a.prio ~= nil end
        return a.spell < b.spell
    end)
    return never, total
end

local function CoverageLine(key)
    local never, total = R.Coverage(key)
    if #never == 0 then
        return string.format("|cff33ff99Cast Ahead|r every one of this dungeon's %d spells was shown", total)
    end
    local names = {}
    for i = 1, math.min(#never, 8) do names[i] = never[i].name or tostring(never[i].spell) end
    return string.format("|cff33ff99Cast Ahead|r shown %d of %d spells; never shown: %s%s",
        total - #never, total, table.concat(names, ", "), #never > 8 and (" and " .. (#never - 8) .. " more") or "")
end

local function Disposable(key)
    return key.pseudo and (key.marks or 0) == 0
end

function R.EndKey(result)
    if not R.Enabled() then return end
    local key = R.Current()
    if not key then return end
    key.ended, key.endedAt = result or "completed", GetTime()
    if Disposable(key) then
        local keys = Journal().keys
        table.remove(keys, #keys)
        return
    end
    if key.ended == "completed" then
        print(R.Summary(key))
        print(CoverageLine(key))
    end
end

function R.StartKey(info)
    if not R.Enabled() then return end
    local keys = Journal().keys
    local open = R.Current()
    if open and (#open.lines == 0 or Disposable(open)) then
        table.remove(keys)
    elseif open then
        R.EndKey("reset")
    end
    keys[#keys + 1] = {
        format = R.FORMAT, addon = AddonVersion(), data = R.Checksum(),
        instance = info.instance or 0, name = info.name or "?", level = info.level or 0,
        affixes = info.affixes or "", role = info.role or "NONE",
        startedAt = GetTime(), mobs = 0, marks = 0, lines = {},
    }
    while #keys > R.MAX_KEYS do
        local victim = 1
        for i = 1, #keys - 1 do
            if (keys[i].marks or 0) == 0 then victim = i break end
        end
        table.remove(keys, victim)
    end
    Forget()
end

function R.EnsureKey()
    if not R.Enabled() then return end
    if R.Current() then return R.Current() end
    local name, _, _, _, _, _, _, instance = GetInstanceInfo()
    R.StartKey({ instance = instance, name = name, level = 0 })
    R.Current().pseudo = true
    return R.Current()
end

function R.Restore()
    if not R.Enabled() then return end
    local key = R.Current()
    if not key then return end
    local _, _, _, _, _, _, _, instance = GetInstanceInfo()
    local age = GetTime() - key.startedAt
    if instance ~= key.instance or age < 0 or age > R.RESUME_WINDOW then
        R.EndKey("left")
    end
    wipe(mobOf)
    wipe(recent)
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

local TOUCHES = { START = true, STOP = true, CUT = true, ENGAGE = true, PRED = true, LOCK = true, PLATE = true }

local function Touch(id, kind, fields, now)
    if id == "-" or not TOUCHES[kind] then return end
    local entry = recent[id]
    if not entry then
        if kind == "PLATE" then return end
        entry = { id = id, state = "seen" }
        recent[id] = entry
    end
    entry.lastAt = now
    if kind == "START" then
        entry.state = "casting"
        if fields[2] ~= "-" then entry.spell = fields[2] end
        entry.call = fields[3]
    elseif kind == "STOP" or kind == "CUT" then
        entry.state = "seen"
        if kind == "STOP" and fields[3] ~= "" and not fields[3]:find(",", 1, true) then entry.spell = fields[3] end
        if kind == "STOP" then entry.call = fields[4] end
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

local function Write(key, kind, id, fields)
    if not key then return false end
    local lines = key.lines
    local now = GetTime()
    local t = Ms(key, now)
    if not UNCAPPED[kind] then
        if key.truncated then return false end
        if #lines >= R.MAX_LINES then
            lines[#lines + 1] = t .. "|TRIM|-|" .. #lines
            key.truncated = t
            return false
        end
    end
    lines[#lines + 1] = t .. "|" .. kind .. "|" .. id .. (#fields > 0 and ("|" .. table.concat(fields, "|")) or "")
    if key == R.Current() then Touch(id, kind, fields, now) end
    return true
end

function R.Note(kind, slot, ...)
    if not R.Enabled() then return end
    local key = R.Current()
    if not key then return end
    local fields = {}
    for i = 1, select("#", ...) do fields[i] = Field((select(i, ...))) end
    local n = SlotNumber(slot)
    if kind == "PLATE" and fields[1] == "added" and n then
        key.mobs = (key.mobs or 0) + 1
        mobOf[n] = key.mobs
    end
    Write(key, kind, MobId(slot), fields)
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

local function MarkTarget()
    local open = R.Current()
    if open then return open end
    local keys = Journal().keys
    local last = keys[#keys]
    if last and last.endedAt and GetTime() - last.endedAt <= R.RECENT_WINDOW then return last end
end

function R.Mark()
    if not R.Enabled() then return end
    local selected = R.selected or "-"
    local key = MarkTarget()
    local snapshot = key and R.Recent() or {}
    key = key or R.EnsureKey()
    key.marks = (key.marks or 0) + 1
    local n = key.marks
    if not Write(key, "MARK", "-", { tostring(n), selected }) then return end
    local live = {}
    for _, entry in ipairs(CastAheadCore and CastAheadCore.Snapshot and CastAheadCore.Snapshot() or {}) do
        live[MobId(entry.slot)] = entry
    end
    for _, entry in ipairs(snapshot) do
        local now = live[entry.id] or {}
        local casting = now.casting or {}
        local preds = {}
        for i, p in ipairs(now.preds or {}) do preds[i] = p[1] .. "@" .. p[2] .. "~" .. p[3] end
        Write(key, "SNAP", entry.id, { Field(entry.state), Field(casting.claimed or entry.spell or "-"),
            Field(casting.call or entry.call or "-"), Field(casting.candidates or {}),
            Field(casting.sinceMs or "-"), Field(table.concat(preds, ",")) })
    end
    R.selected = nil
    print("|cff33ff99Cast Ahead|r mark " .. n .. " recorded" .. (selected ~= "-" and (" on " .. selected) or ""))
    return n, key
end

local function KeyWithMark(n)
    local keys = Journal().keys
    for i = #keys, 1, -1 do
        if (keys[i].marks or 0) >= n then return keys[i] end
    end
end

function R.AddNote(n, text, key)
    if not R.Enabled() then return false end
    n = tonumber(n)
    if not n or not text or text:match("^%s*$") then return false end
    key = key or KeyWithMark(n)
    if not key then return false end
    return Write(key, "NOTE", "-", { tostring(n), Field(text) })
end

local function Clock(ms)
    ms = tonumber(ms) or 0
    return string.format("%02d:%04.1f", math.floor(ms / 60000), (ms % 60000) / 1000)
end

local function Parse(line)
    local t, kind, id, rest = line:match("^(%d+)|(%u+)|([^|]*)|?(.*)$")
    return tonumber(t), kind, id, rest
end

local function Marks(key)
    local marks = {}
    for i, line in ipairs(key.lines) do
        local t, kind, _, rest = Parse(line)
        if kind == "MARK" then
            local n, selected = rest:match("^(%d+)|(.*)$")
            local mobs = {}
            for j = i + 1, #key.lines do
                local tj, kj, idj = Parse(key.lines[j])
                if kj ~= "SNAP" or tj ~= t then break end
                if selected == "-" or idj == selected then mobs[idj] = true end
            end
            if selected ~= "-" then mobs[selected] = true end
            marks[#marks + 1] = { index = i, t = t, n = tonumber(n), selected = selected, mobs = mobs }
        end
    end
    return marks
end

local function Windows(key, marks)
    local windows = {}
    for m, mark in ipairs(marks) do windows[m] = {} end
    for i, line in ipairs(key.lines) do
        local t, kind, id, rest = Parse(line)
        if t then
            for m, mark in ipairs(marks) do
                if (t >= mark.t - R.MARK_WINDOW * 1000 and t <= mark.t)
                    or (id == mark.selected)
                    or (mark.mobs[id] and t <= mark.t)
                    or (kind == "NOTE" and tonumber(rest:match("^(%d+)")) == mark.n)
                    or (kind == "SNAP" and t == mark.t and i > mark.index) then
                    windows[m][i] = true
                end
            end
        end
    end
    return windows
end

local function MarkSummary(key, mark)
    local claim, call, note = "-", "-", {}
    for i = mark.index + 1, #key.lines do
        local t, kind, id, rest = Parse(key.lines[i])
        if kind ~= "SNAP" or t ~= mark.t then break end
        local _, c, k = rest:match("^([^|]*)|([^|]*)|([^|]*)")
        if (mark.selected ~= "-" and id == mark.selected) or (mark.selected == "-" and c and c ~= "-") then
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
    local marks = Marks(key)
    local picked, size, droppedMarks, droppedLines = {}, 0, 0, 0
    local summaries = {}
    for m, mark in ipairs(marks) do summaries[m] = MarkSummary(key, mark) end
    local ids = {}
    for i, row in ipairs((R.Coverage(key))) do ids[i] = row.spell end
    local coverage = "# never shown: " .. (#ids > 0 and table.concat(ids, ",") or "-")
    summaries[#summaries + 1] = coverage
    local budget = R.EXPORT_LIMIT - 400
    for m = 1, #summaries do budget = budget - #summaries[m] - 1 end
    if #marks == 0 then
        for i = #key.lines, 1, -1 do
            local cost = #key.lines[i] + 1
            if size + cost > budget then
                droppedLines = i
                break
            end
            picked[i], size = true, size + cost
        end
    else
        local windows = Windows(key, marks)
        for m = #marks, 1, -1 do
            local extra = 0
            for i in pairs(windows[m]) do
                if not picked[i] then extra = extra + #key.lines[i] + 1 end
            end
            if size + extra > budget and m < #marks then
                droppedMarks = m
                break
            end
            for i in pairs(windows[m]) do picked[i] = true end
            size = size + extra
        end
    end
    local body = {}
    for i = 1, #key.lines do
        if picked[i] then
            if size > budget then
                size = size - #key.lines[i] - 1
                droppedLines = droppedLines + 1
            else
                body[#body + 1] = key.lines[i]
            end
        end
    end
    local out = { string.format("CastAhead-Report %d addon=%s data=%s instance=%s level=%s affixes=%s role=%s len=%d marks=%d%s%s%s",
        key.format, key.addon, key.data, key.instance, key.level, key.affixes ~= "" and key.affixes or "-",
        key.role, Ms(key, key.endedAt), key.marks or 0,
        key.truncated and (" truncated=" .. key.truncated) or "",
        droppedMarks > 0 and (" droppedMarks=" .. droppedMarks) or "",
        droppedLines > 0 and (" droppedLines=" .. droppedLines) or "") }
    for m = droppedMarks + 1, #marks do out[#out + 1] = summaries[m] end
    out[#out + 1] = coverage
    for _, line in ipairs(body) do out[#out + 1] = line end
    out[#out + 1] = "CastAhead-Report end lines=" .. #body
    return table.concat(out, "\n")
end
