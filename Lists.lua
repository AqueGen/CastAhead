CastAheadLists = {}
local L = CastAheadLists

local function Known(id)
    return type(id) == "number" and IsPlayerSpell and IsPlayerSpell(id)
end

L.Known = Known

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

local function Has(list, entry)
    for _, e in ipairs(list) do
        if SameEntry(e, entry) then return true end
    end
    return false
end

local function Exists(id)
    return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id) ~= nil
end

function L.ParseEntry(text, list, anySpell)
    local Usable = anySpell and Exists or Known
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    local itemLink = tonumber(text:match("|Hitem:(%d+)"))
    local spellLink = tonumber(text:match("|Hspell:(%d+)"))
    local number = tonumber(text)
    local entry, why
    if itemLink then
        entry, why = ItemEntry(itemLink)
    elseif spellLink then
        entry = Usable(spellLink) and spellLink or nil
    elseif number and anySpell then
        entry, why = ItemEntry(number)
        if not entry and why == NOT_FOUND and Exists(number) then entry, why = number, nil end
    elseif number then
        if Usable(number) then entry = number else entry, why = ItemEntry(number) end
    elseif text ~= "" and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(text)
        if info and Usable(info.spellID) then entry = info.spellID end
    end
    if not entry then return nil, why or NOT_FOUND end
    for _, e in ipairs(list or {}) do
        if SameEntry(e, entry) then return nil, "Already in the list" end
    end
    return entry
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

function L.New(opts)
    local store = {}

    function store.Keys() return opts.keys end

    function store.EditSpec() return opts.editSpecID and opts.editSpecID() or opts.specID() end

    local function EditingReal() return store.EditSpec() == opts.specID() end

    function store.ParseEntry(text, list) return L.ParseEntry(text, list, not EditingReal()) end

    function store.Shipped(spec, key)
        local all = opts.shipped()
        local s = all and all[spec]
        return type(s) == "table" and s[key] or {}
    end

    local function Own(spec, key)
        local o = spec and CastAheadDB and CastAheadDB[opts.dbKey] and CastAheadDB[opts.dbKey][spec]
        return o and type(o[key]) == "table" and o[key] or nil
    end

    function store.ListFor(spec, key)
        if not spec then return {} end
        return Own(spec, key) or store.Shipped(spec, key)
    end

    function store.Emptied(spec, key)
        local own = Own(spec, key)
        return own ~= nil and #own == 0
    end

    function store.List(key) return store.ListFor(opts.specID(), key) end
    function store.EditList(key) return store.ListFor(store.EditSpec(), key) end

    local function Write(spec, key, list)
        CastAheadDB = CastAheadDB or {}
        CastAheadDB[opts.dbKey] = CastAheadDB[opts.dbKey] or {}
        CastAheadDB[opts.dbKey][spec] = CastAheadDB[opts.dbKey][spec] or {}
        CastAheadDB[opts.dbKey][spec][key] = list
    end

    function store.SetList(key, list)
        local spec = store.EditSpec()
        if not spec then return end
        Write(spec, key, list)
        opts.onChange()
    end

    function store.Shift(key, index, step)
        local spec = store.EditSpec()
        local list = { unpack(store.EditList(key)) }
        local other = index + step
        if not (spec and list[index] and list[other]) then return end
        list[index], list[other] = list[other], list[index]
        Write(spec, key, list)
        opts.onChange()
    end

    function store.Catalogue(spec)
        local out = {}
        for _, specs in ipairs(CLASS_SPECS) do
            for _, s in ipairs(specs) do
                if s == spec then
                    for _, member in ipairs(specs) do
                        for _, key in ipairs(opts.keys) do
                            for _, e in ipairs(store.Shipped(member, key)) do
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

    function store.Addable(key)
        local spec, own = store.EditSpec(), EditingReal()
        local list, out = store.EditList(key), {}
        for _, e in ipairs(store.Catalogue(spec)) do
            if (type(e) ~= "number" or not own or Known(e)) and not Has(list, e) then out[#out + 1] = e end
        end
        return out
    end

    function store.ResetSpec()
        local spec = store.EditSpec()
        if spec and CastAheadDB and CastAheadDB[opts.dbKey] then CastAheadDB[opts.dbKey][spec] = nil end
        opts.onChange()
    end

    return store
end
