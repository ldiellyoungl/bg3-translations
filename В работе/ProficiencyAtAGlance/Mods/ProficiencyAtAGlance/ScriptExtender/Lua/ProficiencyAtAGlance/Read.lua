-- engine reads, all client side. A read that fails gives nil, which Rules treats as unknown (no
-- mark), never as "no". Which read path worked is logged once per world load (kind probe), so the
-- first log on a new game or SE version says what still works without a row per cell
--
-- caches hold plain Lua values only, never engine userdata:
--   stats info per statsId, passive and status Boosts per name, condition text per entry and
--   attribute, parsed passives per name, item uuid -> statsId and slot, names, tag names: cleared
--   each world load (R.Reset)
--   character snapshots: rebuilt when Hub sees a change signal for that character (R.Refresh)
local U, L, E = PaG.Util, PaG.Log, PaG.Enums

local R = {}
PaG.Read = R

-- ItemSlot by number, in SE's ItemSlot order: for slot values read as numbers, and for the cells of
-- the equipment inventory. That a cell's number is its ItemSlot is unproven: the first snapshot logs
-- that path and the visuals path side by side (probe equipped_read), which settles it
local SLOT_NAMES = { [0] = "Helmet", "Breast", "Cloak", "MeleeMainHand", "MeleeOffHand",
    "RangedMainHand", "RangedOffHand", "Ring", "Underwear", "Boots", "Gloves", "Amulet", "Ring2",
    "Wings", "Horns", "Overhead", "MusicalInstrument", "VanityBody", "VanityBoots", "MainHand",
    "OffHand" }

-- the passives and statuses that mean a character can bind a weapon (Pact of the Blade, Hexblade)
local BINDER_PASSIVES = { "PactOfTheBlade", "PactOfTheBlade_Hex", "HexWarrior" }
local BINDER_STATUSES = { "HEXBLADE_BIND_TECHNICAL", "PACTOFTHEBLADE_HEXBLADE" }

-- the stats fields each item type has (Shared/Stats/Generated/Structure/Modifiers.txt). Shields are
-- Armor. Reading a field a type lacks raises, so only these are read
local FIELDS = {
    Weapon = {
        boosts = { "Boosts", "DefaultBoosts", "BoostsOnEquipMainHand", "BoostsOnEquipOffHand" },
        passives = { "PassivesOnEquip", "PassivesMainHand", "PassivesOffHand" },
    },
    Armor = {
        boosts = { "Boosts", "DefaultBoosts" },
        passives = { "PassivesOnEquip" },
    },
}

-- the hand a weapon's passives or boosts field needs: PassivesOnEquip, Boosts and DefaultBoosts none
local HAND = { PassivesMainHand = "main", PassivesOffHand = "off",
    BoostsOnEquipMainHand = "main", BoostsOnEquipOffHand = "off" }

-- the passives fields of an item type ("Armor", "Weapon"), each { field, hand }; {} for any other
-- type. !pag_autoscan reads them as R.ItemInfo does
function R.PassiveFields(kind)
    local out = {}
    for _, f in ipairs(FIELDS[kind] and FIELDS[kind].passives or {}) do
        out[#out + 1] = { field = f, hand = HAND[f] }
    end
    return out
end

local GRANT = "Proficiency%(%s*([%w_]+)%s*%)"
local STEALTH = "Disadvantage%(%s*Skill%s*,%s*Stealth%s*%)"
-- the vanilla gate on scale mail and half plate: IF(not HasPassive('MediumArmorMaster',context.Source))
local MAM_GATE = "not%s+HasPassive%(%s*['\"]MediumArmorMaster['\"]"

-- an ItemSlot as its name, from enum userdata, a number or a string
function R.SlotName(v)
    if v == nil then return nil end
    if type(v) == "number" then return SLOT_NAMES[v] end
    if type(v) == "userdata" then
        local label = U.Field(v, "Label")
        if label ~= nil then return tostring(label) end
        local n = tonumber(U.Field(v, "Value"))
        if n ~= nil then return SLOT_NAMES[n] end
    end
    local s = tostring(v)
    local n = tonumber(s)
    if n ~= nil then return SLOT_NAMES[n] end
    if s == "" then return nil end
    return s
end

-- the stats spelling ("Melee Main Weapon", "Melee Offhand Weapon") as an ItemSlot name
local function statSlot(s)
    if type(s) ~= "string" or s == "" then return nil end
    s = s:gsub("%s+", "")
    s = s:gsub("MainWeapon$", "MainHand")
    s = s:gsub("OffhandWeapon$", "OffHand")
    return s
end

-- the entity for a uuid: Ext.Entity.Get takes a uuid string, UuidToHandle is the fallback
function R.Entity(uuid)
    if uuid == nil then return nil end
    local e = U.Get(Ext.Entity.Get, uuid)
    if e ~= nil then
        L.Once("probe.entity.get", E.LogKind.Probe, "entity_lookup", { path = "Ext.Entity.Get(uuid)" })
        return e
    end
    e = U.Get(function() return Ext.Entity.Get(Ext.Entity.UuidToHandle(uuid)) end)
    if e ~= nil then
        L.Once("probe.entity.handle", E.LogKind.Probe, "entity_lookup", { path = "UuidToHandle" })
        return e
    end
    L.Once("probe.entity.none", E.LogKind.Probe, "entity_lookup", { path = "none", uuid = uuid })
    return nil
end

-- a bitfield (ProficiencyGroupFlags) as a set of names, or nil when it can't be read. Never a
-- guess: an empty set only when the raw value says zero
function R.Labels(flags)
    if flags == nil then return nil end
    local value = tonumber(U.Field(flags, "__Value"))
    local function accept(path, out)
        if next(out) == nil and value ~= 0 then return nil end
        L.Once("probe.flags." .. path, E.LogKind.Probe, "flags_read",
            { path = path, n = U.Count(out), value = value })
        return out
    end

    local out = {}
    local labels = U.Field(flags, "__Labels")
    if labels ~= nil and pcall(function()
        for _, x in pairs(labels) do out[tostring(x)] = true end
    end) then
        local got = accept("__Labels", out)
        if got then return got end
    end

    out = {}
    if pcall(function()
        for k, x in pairs(flags) do
            if type(x) == "boolean" then
                if x and type(k) == "string" then out[k] = true end
            else
                out[tostring(x)] = true
            end
        end
    end) then
        local got = accept("pairs", out)
        if got then return got end
    end

    out = {}
    local parsed = U.Get(Ext.Json.Parse, U.ToJson(flags, 2) or "")
    if type(parsed) == "table" then
        for _, x in pairs(parsed) do
            if type(x) == "string" then out[x] = true end
        end
        local got = accept("json", out)
        if got then return got end
    end

    out = {}
    local inner = tostring(flags):match("%((.*)%)")
    if inner then
        for name in inner:gmatch("[^,%s]+") do out[name] = true end
        local got = accept("tostring", out)
        if got then return got end
    end

    L.Once("probe.flags.none", E.LogKind.Probe, "flags_read",
        { path = "none", value = value, text = tostring(flags) })
    return nil
end

-- the ids of a character's passives as a set, or nil when they can't be read. A container whose
-- passives exist but whose ids can't be read is unreadable, not empty
local function passiveSet(e)
    local list = U.ToList(U.Field(U.Field(e, "PassiveContainer"), "Passives"))
    if list == nil then return nil end
    local out = {}
    for _, p in ipairs(list) do
        local id = U.Field(U.Field(p, "Passive"), "PassiveId")
        if id ~= nil and tostring(id) ~= "" then out[tostring(id)] = true end
    end
    if #list > 0 and next(out) == nil then return nil end
    return out
end

-- U.Field (Util.lua) returns nil for two different facts: the field is not there, and the read
-- raised. It cannot grow a second return, because readers wrap it in tonumber (R.SlotName,
-- R.Labels) where a second value is taken as the number base. This reports both facts: the value,
-- and whether the read itself succeeded. A nil object is absence, which is an answer, not a failure
local function fieldOk(obj, name)
    if obj == nil then return nil, true end
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return nil, false end
    return v, true
end

-- an entity's status ids as a set (StatusContainer.Statuses maps status entity -> id). Empty when
-- the entity has no StatusContainer, nil only when a read raised.
--
-- StatusContainer is optional, so absence is a definite answer and not an unknown: TrueDarkness
-- calls GetAllEntitiesWithComponent("StatusContainer") precisely to find who has one
-- (DarknessController.lua:403) and guards on entity.StatusContainer and
-- entity.StatusContainer.Statuses (_DarknessGameplayUtils.lua:16-17), treating absence as no
-- statuses. The two stay apart because Rules.Judge reads nil as unknown: one nil for both would
-- leave unmarked every melee weapon a pact binder is not proficient in and that has no
-- StatusContainer
local function statusSet(e)
    local container, okContainer = fieldOk(e, "StatusContainer")
    if not okContainer then return nil end
    local statuses, okStatuses = fieldOk(container, "Statuses")
    if not okStatuses then return nil end
    local out = {}
    if statuses == nil then return out end
    if not pcall(function()
        for _, id in pairs(statuses) do out[tostring(id)] = true end
    end) then
        return nil
    end
    return out
end

local function anyOf(set, names)
    if set == nil then return false end
    for _, n in ipairs(names) do
        if set[n] then return true end
    end
    return false
end

-- an equipped item as plain values
local function itemRef(item)
    local statsId = U.Field(U.Field(item, "Data"), "StatsId")
    local uuid = U.Field(U.Field(item, "Uuid"), "EntityUuid") or U.Get(Ext.Entity.HandleToUuid, item)
    return { statsId = statsId and tostring(statsId) or nil, uuid = uuid and tostring(uuid) or nil }
end

-- path B: the character's equipment inventory. InventoryMember.EquipmentSlot is an item's cell in its
-- own container, so backpack items have one too: only the one inventory typed Equipment counts, never
-- the primary (backpack) one. Keyed by the cell; an item whose stats can't be read stays in, so Rules
-- fails quiet on it. Returns the map, its size and what was seen, for the equipped_read probe; nil
-- when unreadable
local function equippedFromInventory(e)
    local owner = U.Field(e, "InventoryOwner")
    local invs = U.ToList(U.Field(owner, "Inventories"))
    if invs == nil then return nil, 0, { why = "no Inventories" } end
    local primary = tostring(U.Field(owner, "PrimaryInventory"))
    local types, equipment = {}, {}
    for i, inv in ipairs(invs) do
        local ts = tostring(U.Field(U.Field(inv, "InventoryData"), "Type"))
        local isPrimary = tostring(inv) == primary
        types[i] = isPrimary and (ts .. " (primary)") or ts
        if ts == "Equipment" and not isPrimary then equipment[#equipment + 1] = inv end
    end
    if #equipment ~= 1 then return nil, 0, { why = #equipment .. " typed Equipment", types = types } end
    local items = U.Field(U.Field(equipment[1], "InventoryContainer"), "Items")
    if items == nil then return nil, 0, { why = "no Items", types = types } end
    local out, n, cells = {}, 0, {}
    local ok = pcall(function()
        for cell, slotData in pairs(items) do
            local item = U.Field(slotData, "Item")
            if item ~= nil then
                local ref = itemRef(item)
                cells[#cells + 1] = { cell = tostring(cell), statsId = ref.statsId,
                    equipmentSlot = tostring(U.Field(U.Field(item, "InventoryMember"), "EquipmentSlot")),
                    equipable = R.SlotName(U.Field(U.Field(item, "Equipable"), "Slot")) }
                out[SLOT_NAMES[tonumber(cell)] or ("#" .. tostring(cell))] = ref
                n = n + 1
            end
        end
    end)
    if not ok then return nil, 0, { why = "Items unreadable", types = types } end
    return out, n, { types = types, cells = cells }
end

-- path A: the client's equipment visuals, keyed by ItemSlot. An entry with neither stats nor an id
-- is an empty slot; an item with an id but no readable stats stays in, so Rules fails quiet on it,
-- as on path B. nil when unreadable
local function equippedFromVisuals(e)
    local equipment = U.Field(U.Field(e, "ClientEquipmentVisuals"), "Equipment")
    if equipment == nil then return nil end
    local out, n = {}, 0
    local ok = pcall(function()
        for slot, v in pairs(equipment) do
            local item = U.Field(v, "Item")
            if item ~= nil then
                local ref = itemRef(item)
                if ref.statsId ~= nil or U.FindUuid(ref.uuid) ~= nil then
                    out[R.SlotName(slot) or tostring(slot)] = ref
                    n = n + 1
                end
            end
        end
    end)
    if not ok then return nil end
    return out, n
end

local function slotsOf(equipped)
    if equipped == nil then return "unreadable" end
    local out = {}
    for slot, ref in pairs(equipped) do out[slot] = ref.statsId or "?" end
    return out
end

-- the ability scores, for detected drawbacks: Stats.Abilities indexed by AbilityId + 1, as
-- VolitionCabinet's GetAbilityScore reads it (None = 0 takes index 1). That the client's Stats
-- holds scores, not modifiers, is unproven: the ability_arrays probe logs both arrays once
local ABILITY_INDEX = { Strength = 2, Dexterity = 3, Constitution = 4, Intelligence = 5, Wisdom = 6,
    Charisma = 7 }

-- an engine array read index by index, so a log shows each value where ABILITY_INDEX reads it
-- (pairs() order isn't index order in every VM); nil when it can't be walked
local function byIndex(arr)
    local _, n = U.ToList(arr)
    if n == nil then return nil end
    local out = {}
    for i = 1, n do out[i] = U.Field(arr, i) end
    return out
end

-- { Strength = n, ... }, or nil and why. Six values all under 6 read as modifiers, so nil
local function abilitiesOf(e)
    local stats = U.Field(e, "Stats")
    local arr = U.Field(stats, "Abilities")
    L.Once("probe.ability_arrays", E.LogKind.Probe, "ability_arrays", function()
        return { stats = stats ~= nil, abilities = byIndex(arr) or "unreadable",
            modifiers = byIndex(U.Field(stats, "AbilityModifiers")) or "unreadable" }
    end)
    if arr == nil then return nil, "no Stats.Abilities" end
    local out, low = {}, true
    for name, i in pairs(ABILITY_INDEX) do
        local n = tonumber(U.Field(arr, i))
        if n == nil then return nil, "unreadable" end
        out[name] = n
        if n >= 6 then low = false end
    end
    if low then return nil, "all under 6" end
    return out
end

-- a static resource ("Tag", "Race") by GUID; nil when it, or Ext.StaticData, can't be read
local function staticData(guid, kind)
    return U.Get(function() return Ext.StaticData.Get(guid, kind) end)
end

-- a tag's name by its GUID. A name read is kept until the world unloads (R.Reset); a failed read
-- is not kept, so the next snapshot tries again
local tagNames = {}
local function tagName(guid)
    local n = tagNames[guid]
    if n ~= nil then return n end
    local res = staticData(guid, "Tag")
    n = res ~= nil and U.Field(res, "Name") or nil
    if n == nil or tostring(n) == "" then return nil end
    tagNames[guid] = tostring(n)
    return tagNames[guid]
end

-- adds the names of a GUID list to out; false when one wouldn't read
local function addTags(out, guids)
    local all = true
    for _, g in ipairs(guids) do
        local n = tagName(tostring(g))
        if n ~= nil then out[n] = true else all = false end
    end
    return all
end

local RACE_DEPTH, NULL_GUID = 4, "00000000-0000-0000-0000-000000000000"

-- the character's tags by name: Tag.Tags, and its race's tags up the ParentGuid chain, since a
-- client's Tag.Tags may lack the race tags (the server keeps those in ServerRaceTag). Returns the
-- set and whether every part read: nil, false when Tag.Tags is unreadable
local function tagsOf(e)
    local own = U.ToList(U.Field(U.Field(e, "Tag"), "Tags"))
    if own == nil then return nil, false end
    local out = {}
    local whole = addTags(out, own)
    local race = U.Field(U.Field(e, "Race"), "Race")
    local guid = race ~= nil and tostring(race) or nil
    if guid == nil then whole = false end
    local depth = 0
    while guid ~= nil and guid ~= "" and guid ~= NULL_GUID and depth < RACE_DEPTH do
        depth = depth + 1
        local res = staticData(guid, "Race")
        local tags = res ~= nil and U.ToList(U.Field(res, "Tags")) or nil
        if tags == nil then whole = false; break end
        if not addTags(out, tags) then whole = false end
        local parent = U.Field(res, "ParentGuid")
        guid = parent ~= nil and tostring(parent) or nil
    end
    return out, whole
end

local chars = {}

-- what Rules needs about a character, as plain values. Built on first use and kept until
-- R.Refresh or R.Reset; Rules adds lostCandidates, the candidate passives for detected losses,
-- the first time it reads them. Returns the snapshot and whether it was just built
function R.Char(uuid)
    local snap = chars[uuid]
    if snap ~= nil then return snap, false end
    local e = R.Entity(uuid)
    if e == nil then return nil, false end

    snap = { uuid = uuid }
    snap.flags = R.Labels(U.Field(U.Field(e, "Proficiency"), "Flags"))
    snap.passives = passiveSet(e)
    local statuses = statusSet(e)
    -- the field now says what its name says: whether the read succeeded. A character with no
    -- StatusContainer reads as an empty set, which is true. No mark reads this field: only the
    -- char_reads probe below does (the Mage Armor cause reads mageArmor, which carries its own nil)
    snap.statusesRead = statuses ~= nil
    snap.binder = anyOf(snap.passives, BINDER_PASSIVES) or anyOf(statuses, BINDER_STATUSES)
    -- Mage Armor, for the Mage Armor cause: nil when the statuses would not read. Only this status,
    -- so another status coming or going leaves the fingerprint as it was
    if statuses ~= nil then snap.mageArmor = statuses.MAGE_ARMOR == true end
    -- without passives a binder can't be ruled out
    snap.binderUnknown = not snap.binder and snap.passives == nil

    local inv, nInv, invInfo = equippedFromInventory(e)
    local vis, nVis = equippedFromVisuals(e)
    if inv ~= nil and nInv > 0 then
        snap.equipped, snap.equippedVia = inv, "inventory"
    elseif vis ~= nil and nVis > 0 then
        snap.equipped, snap.equippedVia = vis, "visuals"
    elseif inv ~= nil then
        snap.equipped, snap.equippedVia = inv, "inventory (nothing equipped)"
    end
    -- detected drawbacks: nil when unreadable, which leaves a condition on them undecided.
    -- tagsPartial: some tag would not read, so a tag missing from the set is unknown, not absent
    local why
    snap.abilities, why = abilitiesOf(e)
    local whole
    snap.tags, whole = tagsOf(e)
    snap.tagsPartial = snap.tags ~= nil and not whole
    L.Once("probe.equipped", E.LogKind.Probe, "equipped_read", function()
        return { inventory = slotsOf(inv), visuals = slotsOf(vis), used = snap.equippedVia or "none",
            inventoryHow = invInfo }
    end)
    L.Once("probe.char_reads", E.LogKind.Probe, "char_reads", function()
        return {
            flags = snap.flags ~= nil, passives = snap.passives ~= nil, statuses = snap.statusesRead,
            equipped = snap.equippedVia or "unreadable",
            abilities = snap.abilities or why,
            tags = snap.tags == nil and "unreadable" or (snap.tagsPartial and "partial" or "whole"),
            tagCount = snap.tags and U.Count(snap.tags) or nil,
        }
    end)

    snap.fingerprint = R.Fingerprint(snap)
    chars[uuid] = snap
    return snap, true
end

-- everything Rules reads from a snapshot, as one string, so Hub can tell a change that matters from
-- one that doesn't (a status change that isn't a binder status, a visual-only update)
function R.Fingerprint(snap)
    local function list(set)
        if set == nil then return "?" end
        return table.concat(U.Keys(set), ",")
    end
    local eq = "?"
    if snap.equipped ~= nil then
        local parts = {}
        for slot, ref in pairs(snap.equipped) do parts[#parts + 1] = slot .. "=" .. tostring(ref.statsId) end
        table.sort(parts)
        eq = table.concat(parts, ",")
    end
    local ab = "?"
    if snap.abilities ~= nil then
        local parts = {}
        for name, n in pairs(snap.abilities) do parts[#parts + 1] = name .. "=" .. tostring(n) end
        table.sort(parts)
        ab = table.concat(parts, ",")
    end
    local tags = list(snap.tags) .. (snap.tagsPartial and ",+?" or "")
    return table.concat({ list(snap.flags), list(snap.passives), tostring(snap.binder),
        tostring(snap.binderUnknown), tostring(snap.mageArmor), eq, ab, tags }, "|")
end

-- for the char log row: the snapshot without bulk
function R.Describe(snap)
    return {
        uuid = snap.uuid,
        flags = snap.flags and U.Keys(snap.flags) or "unreadable",
        passives = snap.passives and U.Count(snap.passives) or "unreadable",
        binder = snap.binder, binderUnknown = snap.binderUnknown,
        mageArmor = snap.mageArmor == nil and "unreadable" or snap.mageArmor,
        equipped = slotsOf(snap.equipped), via = snap.equippedVia or "unreadable",
        abilities = snap.abilities or "unreadable",
        tags = snap.tags and U.Count(snap.tags) or "unreadable", tagsPartial = snap.tagsPartial or nil,
    }
end

-- the snapshot kept for a character, or nil; never builds one, so Hub still sees its first build
function R.Kept(uuid)
    return chars[uuid]
end

-- the reads a snapshot makes, for Dev/Read.lua's character probe (!pag_char), which reads them as
-- R.Char does. Only Dev/ reads this, and a release build leaves Dev/ out
R.ForDev = { byIndex = byIndex, abilitiesOf = abilitiesOf, ABILITY_INDEX = ABILITY_INDEX,
    staticData = staticData, tagName = tagName, tagsOf = tagsOf, RACE_DEPTH = RACE_DEPTH,
    NULL_GUID = NULL_GUID }

-- re-reads a cached character. Returns the new snapshot and which parts changed: {} when none, and
-- also when nothing was cached, since nothing was judged against a snapshot that never existed
function R.Refresh(uuid)
    local old = chars[uuid]
    if old == nil then return nil, {} end
    chars[uuid] = nil
    local snap = R.Char(uuid)
    if snap == nil then return nil, { entity = true } end
    local changed = {}
    if old.fingerprint ~= snap.fingerprint then
        local a, b = {}, {}
        for part in (old.fingerprint .. "|"):gmatch("([^|]*)|") do a[#a + 1] = part end
        for part in (snap.fingerprint .. "|"):gmatch("([^|]*)|") do b[#b + 1] = part end
        -- R.Fingerprint's parts, in its order
        local NAMES = { "flags", "passives", "binder", "binderUnknown", "mageArmor", "equipped",
            "abilities", "tags" }
        for i, name in ipairs(NAMES) do
            if a[i] ~= b[i] then changed[name] = true end
        end
    end
    return snap, changed
end

local items = {}

-- an item's statsId and Equipable slot, or nil when its entity or Data can't be found yet (not
-- cached then, so the next judgment of it reads again)
function R.Item(uuid)
    local rec = items[uuid]
    if rec ~= nil then return rec end
    local e = R.Entity(uuid)
    if e == nil then return nil end
    local statsId = U.Field(U.Field(e, "Data"), "StatsId")
    if statsId == nil or tostring(statsId) == "" then return { noStats = true } end
    rec = {
        statsId = tostring(statsId),
        slot = R.SlotName(U.Field(U.Field(e, "Equipable"), "Slot")),
    }
    items[uuid] = rec
    return rec
end

-- the item's statuses, read fresh every time; Hub watches an item judged bound, so losing the
-- binding re-judges it. nil when the item has no readable StatusContainer
function R.ItemStatuses(uuid)
    local e = R.Entity(uuid)
    if e == nil then return nil end
    local set = statusSet(e)
    -- three outcomes, each with its own row: statuses, an empty set because the item has no
    -- StatusContainer, and nil because a read raised. A key on set ~= nil alone cannot tell the
    -- first two apart. L.ForgetOnce clears the guard on every world load and every !pag_bump, so
    -- one log can hold several rows per outcome and no rate can be read from them. The row is a
    -- shape and not a rate: the burst tally carries the counts
    local how = set == nil and "raised" or (next(set) == nil and "none" or "statuses")
    L.Once("probe.item_statuses." .. how, E.LogKind.Probe, "item_statuses", { read = how })
    return set
end

-- names for the equipped badge's tooltip (Why.lua), in the game's language. nil when one can't be
-- read, and Why falls back to PaG's own words. A name read is kept until the world unloads
-- (R.Reset); a failed read is not kept, so the next tooltip tries again
local names = {}

-- a translated string by its handle; nil when the game has no text for it
function R.Loca(handle)
    if type(handle) ~= "string" or handle == "" then return nil end
    local s = U.Get(Ext.Loca.GetTranslatedString, handle)
    if type(s) ~= "string" or s == "" then return nil end
    return s
end

-- a character's or item's name: its custom name first (a player's own character), then its
-- display name, read as VolitionCabinet's Loca.lua and hotbarsort's Panel.lua read them
function R.Name(uuid)
    if uuid == nil then return nil end
    local n = names[uuid]
    if n ~= nil then return n end
    local e = R.Entity(uuid)
    if e == nil then return nil end
    n = U.Field(U.Field(e, "CustomName"), "Name")
    if type(n) ~= "string" or n == "" then
        local dn = U.Field(e, "DisplayName")
        local h = U.Field(U.Field(U.Field(dn, "NameKey"), "Handle"), "Handle")
        n = R.Loca(h ~= nil and tostring(h) or nil)
        if n == nil then n = U.Get(function() return dn.Name:Get() end) end
    end
    if type(n) ~= "string" or n == "" then return nil end
    names[uuid] = n
    return n
end

-- a stats entry's display name: a passive's or a status's
function R.StatName(id)
    local key = "stats:" .. id
    local n = names[key]
    if n ~= nil then return n end
    local stat = U.Get(Ext.Stats.Get, id, nil, false)
    local h = stat ~= nil and U.Field(stat, "DisplayName") or nil
    n = R.Loca(type(h) == "string" and h or nil)
    if n ~= nil then names[key] = n end
    return n
end

-- the game's names for the proficiency groups: one handle family, suffixed with the group's
-- ProficiencyGroupFlags value
local GROUP_HANDLE = "ha4c5f0cfg93ebg47ecg8eecg6524ad70aee0_"
local GROUP_FLAG = { Battleaxes = "1", Clubs = "2", Daggers = "4", Darts = "8", Flails = "16",
    Glaives = "32", Greataxes = "64", Greatclubs = "128", Greatswords = "256", Halberds = "512",
    HandCrossbows = "1024", Handaxes = "2048", HeavyArmor = "4096", HeavyCrossbows = "8192",
    Javelins = "16384", LightArmor = "32768", LightCrossbows = "65536", LightHammers = "131072",
    Longbows = "262144", Longswords = "524288", Maces = "1048576", MartialWeapons = "2097152",
    Mauls = "4194304", MediumArmor = "8388608", Morningstars = "16777216", Pikes = "33554432",
    Quarterstaffs = "67108864", Rapiers = "134217728", Scimitars = "268435456", Shields = "536870912",
    Shortbows = "1073741824", Shortswords = "2147483648", Sickles = "4294967296",
    SimpleWeapons = "8589934592", Slings = "17179869184", Spears = "34359738368",
    Tridents = "68719476736", Warhammers = "137438953472", Warpicks = "274877906944",
    MusicalInstrument = "549755813888" }

-- a proficiency group's name ("Martial Weapons" for MartialWeapons); nil for a group the game
-- doesn't name
function R.GroupName(g)
    local flag = GROUP_FLAG[g]
    return flag and R.Loca(GROUP_HANDLE .. flag) or nil
end

-- is g a proficiency group's id (what HasProficiency can name and the character's flags hold)
function R.IsGroup(g)
    return GROUP_FLAG[g] ~= nil
end

local boostCache = {}

-- a stats entry's Boosts, "" when it has none, can't be read or there is no entry
local function readBoosts(stat)
    local b = stat and U.Field(stat, "Boosts")
    return type(b) == "string" and b or ""
end

-- a passive's or status's Boosts, "" when it has none or can't be read
local function boostsOf(name)
    local b = boostCache[name]
    if b ~= nil then return b end
    b = readBoosts(U.Get(Ext.Stats.Get, name, nil, false))
    boostCache[name] = b
    return b
end

-- boostsOf without its cache: the Boosts an item read kept, or the text read now, kept nowhere
local function peekBoosts(name)
    local b = boostCache[name]
    if b ~= nil then return b end
    return readBoosts(U.Get(Ext.Stats.Get, name, nil, false))
end

-- a passive's BoostConditions as R.Passive reads it: "" for a missing entry, false (unknown) when
-- not text
local function condOf(stat)
    if stat == nil then return "" end
    local cond = U.Field(stat, "BoostConditions")
    -- a Conditions attribute reads as a string, "" when empty; anything else is unknown, not
    -- "no condition"
    if type(cond) ~= "string" then return false end
    return cond
end

-- a passive's Boosts and BoostConditions as R.Passive reads them, read now, past every cache. The
-- probes (!pag_stat, !pag_autoscan) compare it with the texts R.Passive kept
function R.PassiveTexts(name)
    local stat = U.Get(Ext.Stats.Get, name, nil, false)
    return readBoosts(stat), condOf(stat)
end

-- BoostClass.Passive's parse of a passive's texts, keeping the texts it read (boostsText,
-- condText). A parse problem is logged once per name
local function parsePassive(name, boosts, cond)
    local p = PaG.BoostClass.Passive(boosts, cond)
    p.boostsText, p.condText = boosts, cond
    local guard
    for _, e in ipairs(p.effects) do
        if e.guardError ~= nil then guard = e.guardError; break end
    end
    if p.condError ~= nil or guard ~= nil or not p.balanced then
        L.Once("probe.passive_parse." .. name, E.LogKind.Probe, "passive_parse",
            { passive = name, cond = p.condError, guard = guard, balanced = p.balanced })
    end
    return p
end

-- a passive's effects as BoostClass.Passive reads them, for detected drawbacks. Parsed once
-- per name and kept until the world unloads (R.Reset); the conditions are evaluated per judgment,
-- since they read the candidate item and the character. A passive that can't be read has no effects.
-- The parse keeps the texts it read, and a second value says whether it was just built; Rules
-- reads neither, the probes do
local passiveCache = {}
function R.Passive(name)
    local p = passiveCache[name]
    if p ~= nil then return p, false end
    p = parsePassive(name, boostsOf(name), condOf(U.Get(Ext.Stats.Get, name, nil, false)))
    passiveCache[name] = p
    return p, true
end

-- the probes' passive reads, which keep nothing, so what a probe reports is what judgments left.
-- HeldPassive: the parse R.Passive holds, or nil. HeldBoosts: the Boosts an item read kept, or
-- nil. PeekPassive: what R.Passive would answer now, and keeps nowhere: the held parse (and
-- false), or one built from the kept Boosts or a fresh read (and true)
function R.HeldPassive(name) return passiveCache[name] end
function R.HeldBoosts(name) return boostCache[name] end
function R.PeekPassive(name)
    local p = passiveCache[name]
    if p ~= nil then return p, false end
    return parsePassive(name, peekBoosts(name), condOf(U.Get(Ext.Stats.Get, name, nil, false))), true
end

-- whether a stats entry's condition text holds `term`. This is the live game data, so a mod that
-- rewrites the condition changes the verdict (Q12). nil when the attribute could not be read; false
-- when the entry is missing or the term absent. Pass only an attribute the entry's type has: the
-- engine prints a console warning for a missing one
local condCache = {}
function R.CondHas(name, attr, term)
    local key = name .. "|" .. attr
    local text = condCache[key]
    if text == nil then
        local stat = U.Get(Ext.Stats.Get, name, nil, false)
        local v = stat ~= nil and U.Field(stat, attr) or nil
        if stat == nil then
            text = ""
        elseif type(v) == "string" then
            text = v
        else
            text = false
        end
        condCache[key] = text
        L.Once("probe.cond." .. key, E.LogKind.Probe, "live_condition", { entry = name, attr = attr,
            found = stat ~= nil, read = text ~= false, text = text ~= false and text:sub(1, 200) or nil })
    end
    if text == false then return nil end
    return text:find(term, 1, true) ~= nil
end

local infos = {}

-- what Rules needs about a stats entry, as plain values, or false for "no such stats entry".
-- boosts reads a passive's or status's Boosts (boostsOf, or the probes' peekBoosts)
local function readInfo(statsId, boosts)
    local stat = U.Get(Ext.Stats.Get, statsId, nil, false)
    if stat == nil then return false end

    local kind = tostring(U.Field(stat, "ModifierList") or "")
    if kind == "" then
        -- ModifierList unreadable: only weapons have Weapon Properties, only armor has ArmorType
        if U.Field(stat, "Weapon Properties") ~= nil then
            kind = "Weapon"
        elseif U.Field(stat, "ArmorType") ~= nil then
            kind = "Armor"
        end
        L.Once("probe.stats.kind_fallback", E.LogKind.Probe, "stats_kind",
            { statsId = statsId, path = "field test", kind = kind })
    end
    local info = { statsId = statsId, kind = kind }
    local fields = FIELDS[kind]
    info.known = fields ~= nil
    if not info.known then
        -- not equipment (Object, SpellData, ...): Rules stops at `known`, and the equipped-item
        -- paths read empty sets. The equipment attributes are not read at all, since the engine
        -- prints a console warning for each attribute a stats entry does not have
        info.groups, info.groupSet, info.groupEmpty = {}, {}, true
        info.props, info.grants, info.passives, info.effects = {}, {}, {}, {}
        info.stealthDisadv, info.stealthMAM, info.useConditions = false, false, false
        info.dexCap = 0
        return info
    end

    local groups = {}
    for _, g in ipairs(U.Names(U.Field(stat, "Proficiency Group"))) do
        if g ~= "None" then groups[#groups + 1] = g end
    end
    table.sort(groups)
    info.groups, info.groupSet, info.groupEmpty = groups, U.Set(groups), #groups == 0
    info.slot = statSlot(U.Field(stat, "Slot"))
    if kind == "Armor" then
        local at = tostring(U.Field(stat, "ArmorType") or "")
        info.armorType = at ~= "" and at or "None"
        -- the ability its armor class adds ("Dexterity"; "None" for heavy armor) and the cap on
        -- it, 0 for none
        local ab = tostring(U.Field(stat, "Armor Class Ability") or "")
        info.acAbility = (ab ~= "" and ab ~= "None") and ab or nil
        info.dexCap = tonumber(U.Field(stat, "Ability Modifier Cap")) or 0
    else
        info.dexCap = 0
    end
    local props = {}
    if kind == "Weapon" then
        for _, p in ipairs(U.Names(U.Field(stat, "Weapon Properties"))) do props[p:lower()] = true end
    end
    info.props = props
    -- a UseConditions that is not a string can not be read, so it counts as present (no mark)
    local uc = U.Field(stat, "UseConditions")
    if type(uc) == "string" then
        info.useConditions = uc:match("%S") ~= nil
    else
        info.useConditions = uc ~= nil
    end

    -- proficiency the item grants its wearer: its own boosts, its passives' and its statuses'
    -- stealth: some clause gives Disadvantage on Stealth. allGated: every such clause carries the
    -- Medium Armor Master gate itself. Decided per clause, so a plain clause beside a gated one,
    -- or MediumArmorMaster text in an unrelated clause, never reads as lifted
    local grants, stealth, allGated = {}, false, true
    -- passives: what it grants its wearer, each with the hand it needs (the item AC bonus cause)
    local passives = {}
    -- effects: its own boosts' and its statuses' effects (BoostClass), each with the hand it needs
    -- and its source field or status (the drawback causes)
    local effects = {}
    local function addEffects(text, hand, source)
        for _, e in ipairs(PaG.BoostClass.Passive(text, nil).effects) do
            e.hand, e.source = hand, source
            effects[#effects + 1] = e
        end
    end
    local function scan(text)
        for g in text:gmatch(GRANT) do grants[g] = true end
        for clause in text:gmatch("[^;]+") do
            if clause:find(STEALTH) then
                stealth = true
                if not clause:find(MAM_GATE) then allGated = false end
            end
        end
    end
    if fields ~= nil then
        for _, f in ipairs(fields.boosts) do
            local v = U.Field(stat, f)
            if type(v) == "string" then
                scan(v)
                addEffects(v, HAND[f], f)
            end
        end
        for _, f in ipairs(fields.passives) do
            for _, name in ipairs(U.Names(U.Field(stat, f))) do
                scan(boosts(name))
                passives[#passives + 1] = { name = name, hand = HAND[f] }
            end
        end
        for _, name in ipairs(U.Names(U.Field(stat, "StatusOnEquip"))) do
            local text = boosts(name)
            scan(text)
            addEffects(text, nil, name)
        end
    end
    info.grants = grants
    info.passives = passives
    info.effects = effects
    info.stealthDisadv = stealth
    -- Medium Armor Master lifts it when the boost says so. Every vanilla scale mail and half plate
    -- stealth boost carries IF(not HasPassive('MediumArmorMaster', context.Source)) (10 and 9 of
    -- them, none plain), so the boost is the whole truth, and a mod's armor is read as written
    info.stealthMAM = stealth and allGated

    L.Once("probe.stats." .. kind, E.LogKind.Probe, "stats_read", function()
        return {
            statsId = statsId, kind = kind, groups = groups, slot = info.slot,
            armorType = info.armorType, props = U.Keys(props), grants = U.Keys(grants),
            groupRaw = tostring(U.Field(stat, "Proficiency Group")), useConditions = info.useConditions,
            ucType = type(uc), stealth = info.stealthDisadv,
        }
    end)
    return info
end

-- what Rules needs about a stats entry (readInfo), read once per id and kept until the world
-- unloads; nil for no such entry
function R.ItemInfo(statsId)
    local info = infos[statsId]
    if info == nil then
        info = readInfo(statsId, boostsOf)
        infos[statsId] = info
    end
    return info or nil
end

-- the probes' item reads, which keep nothing. HeldItemInfo: the info R.ItemInfo holds, false for
-- no such entry, or nil. PeekItemInfo: what R.ItemInfo would answer now: the held info, or one read
-- now (its passives' Boosts as kept, or read fresh) and kept nowhere
function R.HeldItemInfo(statsId) return infos[statsId] end
function R.PeekItemInfo(statsId)
    local info = infos[statsId]
    if info == nil then info = readInfo(statsId, peekBoosts) end
    return info or nil
end

-- the uuids of the cached character snapshots, for !pag_status
function R.KnownCharacters()
    return U.Keys(chars)
end

-- world load: stats may have changed (another mod's stats reload), and every id is new
function R.Reset()
    chars, items, infos, boostCache, condCache, names = {}, {}, {}, {}, {}, {}
    passiveCache, tagNames = {}, {}
end
