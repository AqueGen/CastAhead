CastAheadSaves = {}
local S = CastAheadSaves
local M = CastAheadMatch

local scheduled = {}

function S.SpecID()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local index = GetSpecialization()
    return index and GetSpecializationInfo(index) or nil
end

local function Known(id)
    return type(id) == "number" and IsPlayerSpell and IsPlayerSpell(id)
end

local function SpellReady(id)
    local get = C_Spell and C_Spell.GetSpellCooldownDuration
    if not get then return true end
    local ok, d = pcall(get, id, true)
    if not ok or not d or not d.HasSecretValues or d:HasSecretValues() then return true end
    local ok2, zero = pcall(d.IsZero, d)
    if not ok2 then return true end
    return zero == true
end

local useToItem = {}
local bagsPending = false
local memo = {}

local function Shipped(spec, size)
    local s = CastAheadSaveButtons and CastAheadSaveButtons[spec]
    return s and s[size] or {}
end

function S.List(size)
    local spec = S.SpecID()
    if not spec then return {} end
    local o = CastAheadDB and CastAheadDB.saveButtons and CastAheadDB.saveButtons[spec]
    if o and type(o[size]) == "table" then return o[size] end
    return Shipped(spec, size)
end

function S.ScanBags()
    if InCombatLockdown and InCombatLockdown() then bagsPending = true return end
    bagsPending = false
    wipe(memo)
    wipe(useToItem)
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemID
        and C_Item and C_Item.GetItemSpell) then return end
    for bag = 0, 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = C_Container.GetContainerItemID(bag, slot)
            if item then
                local _, use = C_Item.GetItemSpell(item)
                if use then
                    local items = useToItem[use] or {}
                    useToItem[use] = items
                    local seen = false
                    for _, known in ipairs(items) do seen = seen or known == item end
                    if not seen then items[#items + 1] = item end
                end
            end
        end
    end
end

local function ItemFor(use)
    local items = useToItem[use]
    if not items then return nil end
    if C_Item and C_Item.GetItemCount then
        for _, item in ipairs(items) do
            if (C_Item.GetItemCount(item) or 0) > 0 then return item end
        end
    end
    return items[1]
end

local function SpellTexture(id)
    return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id) or nil
end

function S.BagsPending() return bagsPending end

local function ItemReady(item)
    if not (C_Item and C_Item.GetItemCount and (C_Item.GetItemCount(item) or 0) > 0) then return false end
    local start, duration, enable = 0, 0, true
    if C_Item.GetItemCooldown then start, duration, enable = C_Item.GetItemCooldown(item) end
    if enable == false then return false end
    return (start or 0) == 0 or (start + (duration or 0)) <= GetTime()
end

local function Collect(list, out)
    local resolved = false
    for _, e in ipairs(list) do
        if type(e) == "number" then
            if Known(e) then
                resolved = true
                if SpellReady(e) then out[#out + 1] = { kind = "spell", id = e, icon = SpellTexture(e) } end
            end
        elseif type(e) == "table" and e.use then
            local item = ItemFor(e.use)
            resolved = resolved or item ~= nil
            if item and ItemReady(item) then
                out[#out + 1] = { kind = "item", id = item, icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(item) }
            end
        end
    end
    return resolved
end

function S.Available(size)
    local stamp = GetTime()
    local hit = memo[size]
    if hit and hit.stamp == stamp then return hit.list end
    local out = {}
    memo[size] = { stamp = stamp, list = out }
    local list = S.List(size)
    if not Collect(list, out) and #list > 0 then
        local shipped = Shipped(S.SpecID(), size)
        if shipped ~= list then Collect(shipped, out) end
    end
    return out
end

S.ItemFor = ItemFor

local NOT_FOUND = "Not a spell you know or an item with a use effect"

local function ItemEntry(item)
    if not (C_Item and C_Item.GetItemSpell) then return nil, NOT_FOUND end
    local _, use = C_Item.GetItemSpell(item)
    if use then return { use = use } end
    if C_Item.GetItemInfoInstant and not C_Item.GetItemInfoInstant(item) then return nil, NOT_FOUND end
    if C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(item) then return nil, NOT_FOUND end
    if not C_Item.RequestLoadItemDataByID then return nil, NOT_FOUND end
    C_Item.RequestLoadItemDataByID(item)
    return nil, "Loading item data, try again"
end

local function SameEntry(a, b)
    if type(a) == "table" and type(b) == "table" then return a.use == b.use end
    return a == b
end

function S.ParseEntry(text, list)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    local itemLink = tonumber(text:match("|Hitem:(%d+)"))
    local spellLink = tonumber(text:match("|Hspell:(%d+)"))
    local number = tonumber(text)
    local entry, why
    if itemLink then
        entry, why = ItemEntry(itemLink)
    elseif spellLink then
        entry = Known(spellLink) and spellLink or nil
    elseif number then
        if Known(number) then entry = number else entry, why = ItemEntry(number) end
    elseif text ~= "" and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(text)
        if info and Known(info.spellID) then entry = info.spellID end
    end
    if not entry then return nil, why or NOT_FOUND end
    for _, e in ipairs(list or {}) do
        if SameEntry(e, entry) then return nil, "Already in the list" end
    end
    return entry
end

local function Write(spec, size, list)
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.saveButtons = CastAheadDB.saveButtons or {}
    CastAheadDB.saveButtons[spec] = CastAheadDB.saveButtons[spec] or {}
    CastAheadDB.saveButtons[spec][size] = list
end

function S.SetList(size, list)
    local spec = S.SpecID()
    if not spec then return end
    Write(spec, size, list)
    S.Refresh()
end

local function Has(list, entry)
    for _, e in ipairs(list) do
        if SameEntry(e, entry) then return true end
    end
    return false
end

function S.MoveEntry(from, index, to)
    local spec = S.SpecID()
    local source = S.List(from)
    local entry = source[index]
    if not (spec and entry) or from == to then return end
    local kept = {}
    for i, e in ipairs(source) do
        if i ~= index then kept[#kept + 1] = e end
    end
    local target = { unpack(S.List(to)) }
    if not Has(target, entry) then target[#target + 1] = entry end
    Write(spec, from, kept)
    Write(spec, to, target)
    S.Refresh()
end

function S.Shift(size, index, step)
    local spec = S.SpecID()
    local list = { unpack(S.List(size)) }
    local other = index + step
    if not (spec and list[index] and list[other]) then return end
    list[index], list[other] = list[other], list[index]
    Write(spec, size, list)
    S.Refresh()
end

local CLASS_SPECS = {
    { 265, 266, 267 },
    { 65, 66, 70 },
    { 577, 581, 1480 },
    { 250, 251, 252 },
    { 102, 103, 104, 105 },
    { 1467, 1468, 1473 },
    { 253, 254, 255 },
    { 62, 63, 64 },
    { 268, 269, 270 },
    { 256, 257, 258 },
    { 259, 260, 261 },
    { 262, 263, 264 },
    { 71, 72, 73 },
}

function S.Catalogue(spec)
    local out = {}
    for _, specs in ipairs(CLASS_SPECS) do
        for _, s in ipairs(specs) do
            if s == spec then
                for _, member in ipairs(specs) do
                    for _, size in ipairs({ "small", "big", "heal" }) do
                        for _, e in ipairs(Shipped(member, size)) do
                            if not Has(out, e) then out[#out + 1] = e end
                        end
                    end
                end
                return out
            end
        end
    end
    return out
end

function S.Addable(size)
    local list, out = S.List(size), {}
    for _, e in ipairs(S.Catalogue(S.SpecID())) do
        if (type(e) ~= "number" or Known(e)) and not Has(list, e) then out[#out + 1] = e end
    end
    return out
end

function S.ResetSpec()
    local spec = S.SpecID()
    if spec and CastAheadDB and CastAheadDB.saveButtons then CastAheadDB.saveButtons[spec] = nil end
    S.Refresh()
end

if StaticPopupDialogs then
    StaticPopupDialogs.CASTAHEAD_RESET_SAVES = {
        text = "Reset Small, Big and Heal lists for this specialization to the defaults?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function()
            S.ResetSpec()
            if CastAheadOptions and CastAheadOptions.RefreshDefensives then CastAheadOptions.RefreshDefensives() end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local SIZE = { SMALL = "small", BIG = "big", HEAL = "heal" }
local NO_ICONS = {}
function S.Icons(advice)
    local size = advice and SIZE[advice.key]
    if not size then return NO_ICONS end
    local out = {}
    for _, e in ipairs(S.Available(size)) do
        if e.icon then out[#out + 1] = e.icon end
        if #out == 3 then break end
    end
    return out
end

local function Wins(row)
    local advice = M.Beats(row)
    return advice and advice.key or nil
end

local function ViewButtons(size)
    local ready = {}
    for _, e in ipairs(S.Available(size)) do ready[e.kind .. e.id] = true end
    local out = {}
    for _, e in ipairs(S.List(size)) do
        if type(e) == "number" then
            out[#out + 1] = { kind = "spell", id = e, available = ready["spell" .. e] == true,
                icon = SpellTexture(e) }
        elseif type(e) == "table" and e.use then
            local item = ItemFor(e.use)
            local icon = item and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item)
            out[#out + 1] = { kind = "item", id = item, use = e.use, available = item ~= nil and ready["item" .. item] == true,
                icon = icon or SpellTexture(e.use) }
        end
    end
    return out
end

local function ViewOrder(a, b)
    if (a.boss == "") ~= (b.boss == "") then return a.boss ~= "" end
    if a.boss ~= b.boss then return a.boss < b.boss end
    if a.size ~= b.size then return a.size == "BIG" end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
end

local NO_CADENCE = {}
local function BossCadence(id)
    return CastAheadBossCadence and CastAheadBossCadence[id] or NO_CADENCE
end

function S.ViewRows(instanceID)
    local out = {}
    local spells = CastAheadDefensives and CastAheadDefensives.spells
    local role = M.SpecRole()
    if not (spells and role) then return out end
    local cast, wins, buttons = {}, {}, {}
    for _, c in ipairs(CastAheadData and CastAheadData[instanceID] or {}) do
        local _, id = M.SaveRow(c.spell)
        if id then
            cast[id] = cast[id] or c
            wins[id] = wins[id] or Wins(c)
        end
    end
    for id, row in pairs(spells) do
        local size = M.SaveKey(row, role, CastAheadPriority and CastAheadPriority[id])
        if size and (row.dungeon == instanceID or cast[id]) then
            buttons[size] = buttons[size] or ViewButtons(SIZE[size])
            out[#out + 1] = {
                id = id, name = row.name or "", boss = row.boss or "", size = size, lead = row.lead,
                mob = row.mob == "Environment" and "ground effect" or row.mob,
                trigger = { cast = cast[id] ~= nil, bar = row.bar == true, debuff = row.aura == true },
                first = (cast[id] or BossCadence(id)).first, cd = (cast[id] or BossCadence(id)).cd,
                repeating = cast[id] ~= nil,
                wins = wins[id] or Wins({ prio = CastAheadPriority and CastAheadPriority[id] }),
                buttons = buttons[size],
            }
        end
    end
    table.sort(out, ViewOrder)
    return out
end

local function SpellName(id)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
    return name or ("spell " .. id)
end

local function ButtonName(b)
    local name = b.kind == "item" and b.id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(b.id)
    return name or SpellName(b.kind == "item" and b.use or b.id)
end

local function Heard(t)
    local how = {}
    if t.cast then how[#how + 1] = "cast" end
    if t.bar then how[#how + 1] = "boss timer" end
    if t.debuff then how[#how + 1] = "debuff on you" end
    return #how > 0 and table.concat(how, ", ") or "not heard"
end

local function Seconds(s) return string.format("~%ds", math.floor(s + 0.5)) end

local function Cadence(r)
    local parts = {}
    if r.first then parts[#parts + 1] = "first " .. Seconds(r.first) .. " after the pull" end
    local cd = r.cd or {}
    local lead = r.first and "then " or ""
    if #cd == 1 then
        parts[#parts + 1] = lead .. "every " .. Seconds(cd[1])
    elseif #cd > 1 then
        local steps, i = {}, 1
        while i <= #cd do
            local word, n = Seconds(cd[i]), 1
            while cd[i + n] and Seconds(cd[i + n]) == word do n = n + 1 end
            steps[#steps + 1] = n > 1 and (word .. " x" .. n) or word
            i = i + n
        end
        parts[#parts + 1] = (r.first and "then " or "with gaps of ") .. table.concat(steps, ", ") .. (r.repeating and ", repeating" or "")
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

local function Icon(texture) return texture and ("|T" .. texture .. ":16|t ") or "" end

local function GuideLine(r)
    local names = {}
    for _, b in ipairs(r.buttons) do names[#names + 1] = Icon(b.icon) .. ButtonName(b) end
    local press = #names > 0 and table.concat(names, ", then ") or "no button in your list"
    local line = string.format("- %s%s from %s (%s): %s save - %s", Icon(SpellTexture(r.id)), r.name, r.mob or "?", Heard(r.trigger),
        r.size == "BIG" and "big" or "small", press)
    if r.size == "BIG" and #S.List("heal") > 0 then line = line .. "; heal up after the hit" end
    local wins = r.wins and M.ADVICE[r.wins]
    if wins then line = line .. string.format(" (%s comes first)", wins.say) end
    local cadence = Cadence(r)
    if cadence then line = line .. ". Casts " .. cadence end
    return line
end

function S.GuideLines(instanceID)
    local lines, group = {}, nil
    for _, r in ipairs(S.ViewRows(instanceID)) do
        if r.boss ~= group then
            group = r.boss
            if #lines > 0 then lines[#lines + 1] = "" end
            lines[#lines + 1] = r.boss ~= "" and ("Boss: " .. r.boss) or "Trash"
        end
        lines[#lines + 1] = GuideLine(r)
    end
    return lines
end

function S.HealReady()
    return CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Get("healCalls") == true and #S.Available("heal") > 0
end

local SOUND_ROOT = "Interface\\AddOns\\CastAhead\\Sounds\\en\\"
local auraIDs = {}
local auraPending = false

local function ClearAuraSounds()
    for i = #auraIDs, 1, -1 do
        pcall(C_UnitAuras.RemoveAuraSound, auraIDs[i])
        auraIDs[i] = nil
    end
end

local function Blocked()
    return (InCombatLockdown and InCombatLockdown())
        or (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown())
end

local function PickedFile(advice)
    local name = CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[advice.key]
    local lsm = name and LibStub and LibStub("LibSharedMedia-3.0", true)
    local sound = lsm and lsm:Fetch("sound", name, true)
    return type(sound) == "string" and sound or nil
end

local function RegisterAuraSounds()
    if not (C_UnitAuras and C_UnitAuras.AddAuraSound and Enum and Enum.UnitAuraSoundTrigger) then return end
    if Blocked() then auraPending = true return end
    auraPending = false
    ClearAuraSounds()
    if not (CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Enabled("sound")) then return end
    local voice = CastAheadConfig.Enabled("voice")
    for spellID, row in pairs(CastAheadDefensives and CastAheadDefensives.spells or {}) do
        local advice = row.aura and M.SaveAdvice({ save = row, prio = CastAheadPriority and CastAheadPriority[spellID] })
        local file = advice and (PickedFile(advice) or voice and SOUND_ROOT .. advice.file .. ".ogg")
        if file then
            local ok, id = pcall(C_UnitAuras.AddAuraSound, Enum.UnitAuraSoundTrigger.Added, {
                unitToken = "player", spellID = spellID, soundFileName = file, outputChannel = "Master" })
            if ok and id then auraIDs[#auraIDs + 1] = id end
        end
    end
end

function S.AuraSoundCount() return #auraIDs end
function S.AuraPending() return auraPending end

function S.Refresh()
    wipe(memo)
    RegisterAuraSounds()
end

function S.Schedule(key, spellID, fireAt, endAt, advice)
    scheduled[key] = { spell = spellID, fireAt = fireAt, endAt = endAt, advice = advice }
end

local flashes = 0
function S.Flash(advice, now, seconds)
    flashes = flashes + 1
    scheduled["flash:" .. flashes] = { fireAt = now, endAt = now + seconds, advice = advice, fired = true, firedAt = now }
end

function S.Cancel(key)
    scheduled[key] = nil
end

function S.CancelPrefix(prefix)
    for key in pairs(scheduled) do
        if key:sub(1, #prefix) == prefix then scheduled[key] = nil end
    end
end

function S.Pause(key, now)
    local c = scheduled[key]
    if c and not c.pausedAt then c.pausedAt = now end
end

function S.Resume(key, now)
    local c = scheduled[key]
    if c and c.pausedAt then
        local held = now - c.pausedAt
        c.fireAt, c.endAt, c.pausedAt = c.fireAt + held, c.endAt + held, nil
    end
end

function S.Move(key, remaining, lead, now)
    local c = scheduled[key]
    if not c then return false end
    c.endAt = (c.pausedAt or now) + remaining
    c.fireAt = c.endAt - lead
    if c.fired and c.fireAt > now and c.fireAt - (c.firedAt or now) >= lead then c.fired = nil end
    return true
end

local pending = {}
function S.Pending(now)
    wipe(pending)
    for _, c in pairs(scheduled) do
        if not c.pausedAt and c.fired and c.endAt > now then
            local icons = S.Icons(c.advice)
            if c.advice ~= M.ADVICE.HEAL or #icons > 0 then
                pending[#pending + 1] = { endAt = c.endAt, advice = c.advice, row = { spell = c.spell }, icons = icons }
            end
        end
    end
    return pending
end

function S.Tick(now)
    local healed = false
    for key, c in pairs(scheduled) do
        if not c.pausedAt then
            if not c.fired and now >= c.fireAt and now < c.endAt then
                c.fired, c.firedAt = true, now
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(c.advice, true) end
            end
            if now >= c.endAt then
                if c.fired and c.advice == M.ADVICE.BIG and S.HealReady()
                    and CastAheadCore and CastAheadCore.Announce then
                    CastAheadCore.Announce(M.ADVICE.HEAL)
                    healed = true
                end
                scheduled[key] = nil
            end
        end
    end
    if healed then S.Flash(M.ADVICE.HEAL, now, 3) end
end
