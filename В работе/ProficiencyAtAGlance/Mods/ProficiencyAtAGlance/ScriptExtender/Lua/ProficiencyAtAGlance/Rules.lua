-- the verdict for one (character, item) pair (design §5). Reads the snapshot it's given and Read's
-- caches and logs nothing itself: Hub logs what it returns. The only things it writes are three
-- reads kept on the snapshot, each built on the first judgment that needs it: grantMap (the
-- passives the equipped items grant), lostCandidates (the held passives detected losses and
-- detected drawbacks read) and capOverrides (the held passives' Dexterity cap overrides)
--
-- Rules.Judge(cfg, snap, itemUuid, at, want, peek) returns tier, reason, slot, detail, ac, causes.
-- `at` is the slot an equipped item sits in, since an off-hand weapon's stats name the main hand; nil
-- for a bag's item, and the item detected losses' before leaves out (Q17). `want` asks for the
-- causes (the equipped badge's tooltip, Why.lua). `peek` is !pag_n14's and !pag_lost's: passives
-- are read with Read.PeekPassive, so the probe leaves no parse behind:
--   tier    an E.Tier value, or nil for no mark (unknown, out of scope, fail quiet). Unknown is never
--           "no": a failed read ends in nil whenever its answer could change the tier (penalize)
--   reason  an E.Reason value. A prefix value (out_of_scope:, pen:) has its detail appended
--   slot    the item's slot name, once it's known
--   detail  extra words for the log (why no_stats), the passive or slot a penalty cause names (the
--           unarmored AC's passive, the item whose AC bonus ends, the emptied hand, a detected
--           drawback's or loss's word:passive, or the bare word for an item's own boost), the
--           Dexterity cap that stands, or nil
--   ac      true when only Armor vs AC bonuses causes gave the tier (Hub's shield badge)
--   causes  with `want`, everything that gave the tier, each { code, detail }: "bad" or
--           "bindable" with the item's proficiency groups first when the tier is the rules' own,
--           then each penalty cause (E.Cause) that hit at that tier, in Settings.FAMILIES order,
--           with its detail (the unarmored AC's passive, the slot of the item whose AC bonus
--           ends). nil without `want`, on the returns before penalize and when an unread cause
--           leaves the tier unknown; an empty list when nothing gives a tier
local R, E, Settings, CondEval = PaG.Read, PaG.Enums, PaG.Settings, PaG.CondEval

local Rules = {}
PaG.Rules = Rules

local T, Rn, Cause = E.Tier, E.Reason, E.Cause

-- the slots the game treats as weapons and armor (design §5.1)
local IN_SCOPE = { MeleeMainHand = true, MeleeOffHand = true, RangedMainHand = true,
    RangedOffHand = true, Breast = true, Helmet = true, Gloves = true, Boots = true }
local CLOAK_UNDERWEAR = { Cloak = true, Underwear = true }
local WEAPON_SLOT = { MeleeMainHand = true, MeleeOffHand = true, RangedMainHand = true,
    RangedOffHand = true }
local MELEE_SLOT = { MeleeMainHand = true, MeleeOffHand = true }

-- an off-hand slot's main hand, and a main-hand slot's off hand
local MAIN_OF = { MeleeOffHand = "MeleeMainHand", RangedOffHand = "RangedMainHand" }
local OFF_OF = { MeleeMainHand = "MeleeOffHand", RangedMainHand = "RangedOffHand" }

-- body armor types: wearsArmor spares clothing, the Barbarian heavy armor cause reads the four
-- heaviest (design §5.3)
local LIGHT_BODY = { None = true, Cloth = true }
local HEAVY_BODY = { RingMail = true, ChainMail = true, Splint = true, Plate = true }
local PIECE_SLOT = { Helmet = true, Gloves = true, Boots = true }

-- whether the game's WearingArmor() counts this item, worn in `slot`, as armor (the Monk armor,
-- unarmored AC, Mage Armor and item AC bonus causes): body armor heavier than clothing, or a
-- helmet, gloves or boots in an armor group, Light, Medium or Heavy. Tested in play (findings,
-- 2026-10-11): ARM_Gloves_Metal (ArmorType None, MediumArmor group) and Plate boots of the
-- MediumArmor group end a monk's Unarmored Defense and Movement; paladin gloves of metal with no
-- armor group don't. Light-group pieces count too: all armor costs a monk these, clothing doesn't
-- (user, 2026-10-22). Plate pieces with no group follow by inference
local function wearsArmor(info, slot)
    if slot == "Breast" then return not LIGHT_BODY[info.armorType or "None"] end
    if not PIECE_SLOT[slot] then return false end
    return info.groupSet.LightArmor == true or info.groupSet.MediumArmor == true
        or info.groupSet.HeavyArmor == true
end

-- statuses on an item that bind it to its wielder (design §5.2)
local BOUND = { "PACT_BLADE", "HEXBLADE_BIND" }

-- whether a status set (or nil) holds one of them. Hub's item watch reads it too
function Rules.IsBound(statuses)
    if statuses == nil then return false end
    for _, s in ipairs(BOUND) do
        if statuses[s] then return true end
    end
    return false
end

-- verdicts that come from a read that failed this time, not from the item: Hub judges them again
-- later, as Read leaves those reads uncached. "char" when a fresh read of the character is what can
-- change the answer, "item" when the item's own reads are
local NO_STATS_ID = "no StatsId"
local RETRY = { [Rn.NoEntity] = "item", [Rn.BinderStatusUnreadable] = "item",
    [Rn.ConditionUnreadable] = "item", [Rn.NoCharEntity] = "char", [Rn.NoFlags] = "char",
    [Rn.NoPassives] = "char", [Rn.EquippedUnreadable] = "char", [Rn.StatusesUnreadable] = "char",
    [Rn.DetectUnread] = "char" }

-- "item", "char" or nil, for a reason and detail Rules.Judge returned
function Rules.Retry(reason, detail)
    if reason == Rn.NoStats then return detail == NO_STATS_ID and "item" or nil end
    return RETRY[reason]
end

-- whether any member of `set` is in `other` and not in `except`
local function overlaps(set, other, except)
    for name in pairs(set) do
        if other[name] and not (except and except[name]) then return true end
    end
    return false
end

-- whether any held passive named prefix* has `term` in its `attr`: true, false, or nil when one
-- could not be read and none said true
local function anyCond(set, prefix, attr, term)
    local unread = false
    for name in pairs(set) do
        if name:sub(1, #prefix) == prefix then
            local has = R.CondHas(name, attr, term)
            if has then return true end
            if has == nil then unread = true end
        end
    end
    if unread then return nil end
    return false
end

-- a linked entry's condition, for a character holding the passive `holder`; false without it
local function heldCond(snap, holder, entry, attr, term)
    if not snap.passives[holder] then return false end
    return R.CondHas(entry, attr, term)
end

-- the equipped slots that equipping into `slot` would empty. A two-handed main-hand item empties the
-- off hand too; an off-hand item empties the main hand when it holds a two-handed weapon. nil when
-- that depends on an equipped item that can't be read
local function replacedSlots(snap, slot, info)
    local out = { slot }
    if OFF_OF[slot] ~= nil then
        if info.props.twohanded then out[2] = OFF_OF[slot] end
    elseif MAIN_OF[slot] ~= nil then
        local main = snap.equipped[MAIN_OF[slot]]
        if main ~= nil then
            if main.statsId == nil then return nil end
            local mainInfo = R.ItemInfo(main.statsId)
            if mainInfo == nil then return nil end
            if mainInfo.props.twohanded then out[2] = MAIN_OF[slot] end
        end
    end
    return out
end

-- a judgment's replaced slots as a list, read once and kept on its context as ctx.slots (the
-- proficient path has them already). nil when the equipped items can't be read
local function replacedSlotList(ctx)
    if ctx.slots == nil then
        if ctx.snap.equipped == nil then return nil end
        ctx.slots = replacedSlots(ctx.snap, ctx.slot, ctx.info) or false
    end
    return ctx.slots or nil
end

-- the same slots as a set (slot -> true), built once and kept on the context as ctx.replacedSet.
-- nil when the equipped items can't be read, and then not kept (replacedSlotList keeps that).
-- Judge's own ctx.slots come from the same replacedSlots() read, so the two agree
local function replacedSlotSet(ctx)
    if ctx.replacedSet == nil then
        local list = replacedSlotList(ctx)
        if list == nil then return nil end
        local set = {}
        for _, s in ipairs(list) do set[s] = true end
        ctx.replacedSet = set
    end
    return ctx.replacedSet
end

-- the condition term armor or a shield trips in an AC bonus that ends in it (the unarmored AC,
-- item AC bonus and detected loss causes): a shield trips "not HasShieldEquipped", armor
-- (wearsArmor) "not WearingArmor". nil for anything else. The "not" keeps a bonus that needs
-- armor (FightingStyle_Defense's "WearingArmor(context.Source)") from reading as one armor ends
local function acEndingTerm(info, slot)
    if info.groupSet.Shields then return "not HasShieldEquipped" end
    if wearsArmor(info, slot) then return "not WearingArmor" end
    return nil
end

-- the passives whose AC formula ends in armor (the unarmored AC cause). Vanilla: Barbarian
-- "not WearingArmor", Monk "not WearingArmor ... and not HasShieldEquipped", Draconic Resilience
-- "not WearingArmor", each in its BoostConditions. Note the spellings: Barbarian's id is British
-- (Unarmoured, Defence), Monk's American
local UNARMORED = { "UnarmouredDefence_Barbarian", "UnarmoredDefense_Monk", "DraconicResilience" }

-- detected drawbacks: the passives other causes read by name are theirs, not detected drawbacks'
local NAMED = { Rage_Rage_Boosts = true, FastMovement = true, MAGE_ARMOR = true }
for _, name in ipairs(UNARMORED) do NAMED[name] = true end
local function namedElsewhere(name)
    return NAMED[name] == true or name:sub(1, #"UnarmoredMovement") == "UnarmoredMovement"
end

-- the effect kinds detected drawbacks mark when harmful and detected losses read when beneficial,
-- each the union of its causes' kinds in Settings.FAMILIES
local DRAWBACK_KINDS, LOST_KINDS = Settings.DRAWBACK_KINDS, Settings.LOST_KINDS

-- whether a passive in an item's field for `hand` (nil, "main", "off") applies with the item in
-- `slot`: a main-hand passive in a main-hand slot, an off-hand one in an off-hand slot
local function appliesInSlot(hand, slot)
    return hand == nil or (hand == "main" and OFF_OF[slot] ~= nil) or (hand == "off" and MAIN_OF[slot] ~= nil)
end

-- the passives the equipped items grant, each in the hand it sits in (appliesInSlot): { from,
-- unread }, from mapping a passive's name to the set of equipped slots whose item grants it,
-- unread the set of equipped slots whose item can't be read. Empty when the equipped items can't
-- be read. Built once per snapshot and kept on it as snap.grantMap (Read.Refresh builds a new
-- snapshot when the character changes); it reads item stats only, so the probes' peek reads keep
-- it too
local function grantMap(snap)
    if snap.grantMap == nil then
        local from, unread = {}, {}
        for at, ref in pairs(snap.equipped or {}) do
            local info = ref.statsId and R.ItemInfo(ref.statsId)
            if not info then
                unread[at] = true
            else
                for _, p in ipairs(info.passives) do
                    if appliesInSlot(p.hand, at) then
                        from[p.name] = from[p.name] or {}
                        from[p.name][at] = true
                    end
                end
            end
        end
        snap.grantMap = { from = from, unread = unread }
    end
    return snap.grantMap
end

-- the slots that hold neither armor nor a shield: no EQUIPMENT_PREDICATES test passes for an item
-- in one
local NEVER_ARMOR_OR_SHIELD_SLOT = { Ring = true, Ring2 = true, Amulet = true, Cloak = true,
    Underwear = true, Wings = true, Horns = true, Overhead = true, MusicalInstrument = true,
    VanityBody = true, VanityBoots = true }

-- the slots whose item can pass an equipment predicate: armor (wearsArmor) and a shield
local ARMOR_OR_SHIELD_SLOT = { Breast = true, Helmet = true, Gloves = true, Boots = true, MeleeOffHand = true }

-- the equipment predicates CondParse reads, each a test of one item worn ({ info, slot }):
-- WearingArmor as wearsArmor counts armor, HasHeavyArmor as the Barbarian heavy armor cause reads
-- it (the Breast item's ArmorType)
local EQUIPMENT_PREDICATES = {
    WearingArmor = function(w) return wearsArmor(w.info, w.slot) end,
    HasShieldEquipped = function(w) return w.info.groupSet.Shields == true end,
    HasHeavyArmor = function(w) return w.slot == "Breast" and HEAVY_BODY[w.info.armorType or ""] == true end,
}

-- whether an item worn in `slot` passes any equipment predicate
local function passesAnyPredicate(info, slot)
    local item = { info = info, slot = slot }
    for _, test in pairs(EQUIPMENT_PREDICATES) do
        if test(item) then return true end
    end
    return false
end

-- whether the equipment predicate `name` holds over a list of items worn (wornItems): true when
-- one passes it, false when none does, nil when none does but one can't be read (or the list
-- can't be, or `name` is no predicate PaG reads)
local function predicateHolds(items, name)
    local test = EQUIPMENT_PREDICATES[name]
    if items == nil or test == nil then return nil end
    for _, item in ipairs(items) do
        if test(item) then return true end
    end
    if items.partial then return nil end
    return false
end

-- adds to `out` each equipped item as { info, slot }, but those in a slot of `leftOut` or of
-- NEVER_ARMOR_OR_SHIELD_SLOT, and sets out.partial when one can't be read. Returns out
local function addWornItems(out, equipped, leftOut)
    for at, ref in pairs(equipped) do
        if not leftOut[at] and not NEVER_ARMOR_OR_SHIELD_SLOT[at] then
            local info = ref.statsId and R.ItemInfo(ref.statsId)
            if info then out[#out + 1] = { info = info, slot = at } else out.partial = true end
        end
    end
    return out
end

-- the items worn on one side of equipping this one. "before": every equipped item, leaving out
-- the item judged when it is worn itself (ctx.at, Q17). "after": this one in ctx.slot, and every
-- equipped item it would not replace. nil when the equipped items can't be read
local function readWornItems(ctx, side)
    local equipped = ctx.snap.equipped
    if side == "before" then
        if equipped == nil then return nil end
        return addWornItems({}, equipped, ctx.at ~= nil and { [ctx.at] = true } or {})
    end
    local replaced = replacedSlotSet(ctx)
    if replaced == nil then return nil end
    return addWornItems({ { info = ctx.info, slot = ctx.slot } }, equipped, replaced)
end

-- readWornItems(ctx, side) for side "before" or "after", read once and kept on the context as
-- ctx.worn.before and ctx.worn.after. nil when the equipped items can't be read
local function wornItems(ctx, side)
    local worn = ctx.worn
    if worn == nil then
        worn = {}
        ctx.worn = worn
    end
    if worn[side] == nil then worn[side] = readWornItems(ctx, side) or false end
    return worn[side] or nil
end

-- condEnv's sides, each to the side of wornItems() its equipment predicates read
local WORN_SIDE = { before = "before", after = "after", everyWearer = "after" }

-- IsOffHandSlotEmpty on one side of this judgment, as condEnv reads it: "before", whether the
-- melee off hand holds nothing, leaving out the item judged when it is worn there (Q17); "after"
-- (and "everyWearer"), whether it holds nothing once this item is equipped: false for an item that
-- goes there, true when it takes the place of the off hand's item (or a two-hander empties it).
-- nil when the equipped items can't be read
local function offHandEmpty(ctx, side)
    local equipped = ctx.snap.equipped
    if side == "before" then
        if equipped == nil then return nil end
        return equipped.MeleeOffHand == nil or ctx.at == "MeleeOffHand"
    end
    if ctx.slot == "MeleeOffHand" then return false end
    local replaced = replacedSlotSet(ctx)
    if replaced == nil then return nil end
    if replaced.MeleeOffHand then return true end
    return equipped.MeleeOffHand == nil
end

-- HasPassive on one side of this judgment, as condEnv reads it. "before": whether the character
-- holds it now. "after": true when this item grants it in the slot it goes to; otherwise whether
-- the character holds it once this item is equipped, which is unsure (nil) when the items this
-- one replaces may be where it comes from: they grant it and no kept item does, or one of them
-- can't be read. "everyWearer": true when this item grants it, nil otherwise. nil when the
-- passives or the equipped items can't be read
local function hasPassive(ctx, side, name)
    local passives = ctx.snap.passives
    if side == "before" then
        if passives == nil then return nil end
        return passives[name] == true
    end
    for _, p in ipairs(ctx.info.passives) do
        if p.name == name and appliesInSlot(p.hand, ctx.slot) then return true end
    end
    if side == "everyWearer" or passives == nil then return nil end
    if not passives[name] then return false end
    local replaced = replacedSlotSet(ctx)
    if replaced == nil then return nil end
    local map = grantMap(ctx.snap)
    local from = map.from[name]
    if from ~= nil then
        for at in pairs(from) do
            if not replaced[at] then return true end
        end
        return nil
    end
    for at in pairs(map.unread) do
        if replaced[at] then return nil end
    end
    return true
end

-- CondEval's env for one side of this judgment, built once and kept on the context as
-- ctx.envs[side]. "before" and "after" read the character's abilities, tags, passives
-- (hasPassive) and proficiency, and the equipment predicates over wornItems() for that side (and
-- IsOffHandSlotEmpty, offHandEmpty): detected losses and held detected drawbacks compare the two,
-- the item's own detected drawbacks read "after". "everyWearer" reads the abilities, tags and
-- proficiency as unknown, a passive as hasPassive does, and the predicates as "after" does, so a
-- condition still true under it holds for every wearer (detected drawbacks). Proficiency is the
-- character's flags, plus what this item grants on the after sides; what an item it replaces
-- grants is not read. HasProficiency of a name that is no proficiency group reads as text PaG
-- can't read. Any other side raises
local function condEnv(ctx, side)
    local envs = ctx.envs
    if envs == nil then
        envs = {}
        ctx.envs = envs
    end
    if envs[side] == nil then
        local itemsSide = WORN_SIDE[side]
        if itemsSide == nil then error("PaG: condEnv has no side " .. tostring(side), 2) end
        local snap = ctx.snap
        local everyWearer = side == "everyWearer"
        envs[side] = {
            ability = function(name)
                if everyWearer or snap.abilities == nil then return nil end
                return snap.abilities[name]
            end,
            tagged = function(tag)
                if everyWearer or snap.tags == nil then return nil end
                if snap.tags[tag] then return true end
                if snap.tagsPartial then return nil end
                return false
            end,
            passive = function(name)
                return hasPassive(ctx, side, name)
            end,
            prof = function(name)
                if not R.IsGroup(name) then return "unknown" end
                if side ~= "before" and ctx.info.grants[name] then return true end
                if everyWearer or snap.flags == nil then return nil end
                return snap.flags[name] == true
            end,
            pred = function(name)
                if name == "IsOffHandSlotEmpty" then return offHandEmpty(ctx, side) end
                return predicateHolds(wornItems(ctx, itemsSide), name)
            end,
        }
    end
    return envs[side]
end

-- the reason a condition CondEval can't answer leaves a cause undecided: DetectUnread when it
-- needs a value that couldn't be read (CondEval's why "read"), DetectUnknown when it holds text
-- PaG can't read
local function undecidedReason(evalWhy)
    return evalWhy == "read" and Rn.DetectUnread or Rn.DetectUnknown
end

-- the reason that stands of two, either of which may be nil: DetectUnknown outranks the rest,
-- since a fresh read can't settle it; otherwise the first one gathered
local function worseReason(a, b)
    if a == Rn.DetectUnknown or b == Rn.DetectUnknown then return Rn.DetectUnknown end
    return a or b
end

-- why detected drawbacks pass over a passive of the item's own (`p`, one of info.passives) with
-- the item in `slot`, or nil when it reads it: one for the other hand, or one another cause reads
-- by name
local function drawbackPassiveSkip(p, slot)
    if not appliesInSlot(p.hand, slot) then return "other hand" end
    if namedElsewhere(p.name) then return "another cause's" end
    return nil
end

-- why detected drawbacks pass over an effect, or nil when it can be a drawback: one not known, of
-- a kind not in DRAWBACK_KINDS (stealth is the Stealth cause's), or not harmful. Whether every
-- wearer pays it is ownDrawback's to say
local function drawbackEffectSkip(e)
    if e.confidence ~= "known" then return "not a known effect" end
    if not DRAWBACK_KINDS[e.kind] then
        return e.kind == "stealth" and "the " .. Cause.Stealth .. " cause's" or "not a drawback kind"
    end
    if e.valence ~= "harmful" then return "not harmful" end
    return nil
end

-- an effect's condition with this item equipped: holds and evalWhy, CondEval's answer for this
-- character and its why, then, only when it holds, everyWearer, its answer for every wearer
local function drawbackHolds(ctx, e)
    local holds, evalWhy = CondEval.Eval(e.cond, condEnv(ctx, "after"))
    if holds ~= true then return holds, evalWhy end
    local everyWearer = CondEval.Eval(e.cond, condEnv(ctx, "everyWearer"))
    return holds, evalWhy, everyWearer
end

-- a detected drawback's or loss's detail: the effect's word (a combat effect's: attack, save) or
-- kind, then ":" and the passive it comes from, when it comes from one
local function effectDetail(e, name)
    local word = e.word or e.kind
    if name == nil then return word end
    return word .. ":" .. name
end

-- the item's own effects in the slot it goes to, each { effect, name }: those of its passives
-- that drawbackPassiveSkip keeps (name is the passive's), then those of its Boosts, its
-- main-hand or off-hand boosts where it is in that hand, and the boosts of its StatusOnEquip
-- statuses (Read's info.effects; name nil). Read once and kept on the context as ctx.ownEffects
local function ownEffects(ctx)
    if ctx.ownEffects == nil then
        local passiveOf = ctx.passiveOf or R.Passive
        local list = {}
        for _, p in ipairs(ctx.info.passives) do
            if drawbackPassiveSkip(p, ctx.slot) == nil then
                for _, e in ipairs(passiveOf(p.name).effects) do
                    list[#list + 1] = { effect = e, name = p.name }
                end
            end
        end
        for _, e in ipairs(ctx.info.effects or {}) do
            if appliesInSlot(e.hand, ctx.slot) then list[#list + 1] = { effect = e } end
        end
        ctx.ownEffects = list
    end
    return ctx.ownEffects
end

-- where one of the item's own effects lands: nil when it is no drawback (drawbackEffectSkip) or
-- its condition fails for this character; otherwise "every" for a drawback every wearer pays (its
-- condition holds for every wearer: the universal drawback cause's) or "char" for one this
-- character pays and not every wearer does (detected drawbacks'), then true when it holds, or nil
-- and a reason when that can't be told. An unread condition lands by what it reads: "char" when
-- it reads the wearer or text PaG can't read, "every" when it reads only what is worn
local function ownDrawback(ctx, e)
    if drawbackEffectSkip(e) ~= nil then return nil end
    local holds, evalWhy, everyWearer = drawbackHolds(ctx, e)
    if holds == false then return nil end
    if holds == nil then
        return (e.charDependent or e.condUnknown) and "char" or "every", nil, undecidedReason(evalWhy)
    end
    return everyWearer == true and "every" or "char", true
end

-- the item's own drawbacks that land at `lands` ("char" or "every", ownDrawback), of effect kind
-- `kind` or any kind when it is nil: true and the detail (effectDetail) of the first that holds,
-- nil and a reason when one can't be told, false otherwise
local function ownDrawbacks(ctx, lands, kind)
    local why = nil
    for _, o in ipairs(ownEffects(ctx)) do
        local e = o.effect
        if kind == nil or e.kind == kind then
            local at, hit, reason = ownDrawback(ctx, e)
            if at == lands then
                if hit then return true, effectDetail(e, o.name) end
                why = worseReason(why, reason)
            end
        end
    end
    if why ~= nil then return nil, why end
    return false
end

-- the held passives' candidates for a snapshot (design §5.3.c): each passive the character
-- holds, and each one an equipped item grants in the hand it sits in (appliesInSlot, grantMap),
-- with an effect that is known and read from an equipment predicate (a condition that reads none
-- can't change when an item does). The list holds detected losses' (beneficial, of a kind in
-- LOST_KINDS); list.drawbacks holds held detected drawbacks' (harmful, of a kind in
-- DRAWBACK_KINDS). One entry per such effect, { name, effect, from, own }: from is the set of
-- equipped slots whose item grants the passive, own is true when none does. A passive that is held
-- and also granted by an item is taken as the item's: whether the game's passive list holds the
-- ones items grant is unsettled, and a passive both innate and granted is rare. list.unread is the
-- set of equipped slots whose item can't be read. Sorted by name, so a verdict never hangs on
-- table order. Built once per snapshot and kept on it (Read.Refresh builds a new one when the
-- character changes), but not for the probes' peek reads, which keep nothing. trace (!pag_lost,
-- !pag_n14) also lists the passives other causes read, each marked named
local function candidates(ctx, trace)
    local snap = ctx.snap
    local keep = ctx.passiveOf == nil and not trace
    if keep and snap.lostCandidates ~= nil then return snap.lostCandidates end
    local passiveOf = ctx.passiveOf or R.Passive
    local map = grantMap(snap)
    local from = map.from
    local names = {}
    for name in pairs(from) do names[#names + 1] = name end
    for name in pairs(snap.passives or {}) do
        if from[name] == nil then names[#names + 1] = name end
    end
    table.sort(names)
    local list = { unread = map.unread, drawbacks = {} }
    for _, name in ipairs(names) do
        local named = namedElsewhere(name)
        if trace or not named then
            for _, e in ipairs(passiveOf(name).effects) do
                if e.confidence == "known" and e.hasPred then
                    local c = { name = name, effect = e, from = from[name], own = from[name] == nil,
                        named = named or nil }
                    if e.valence == "beneficial" and LOST_KINDS[e.kind] then
                        list[#list + 1] = c
                    elseif e.valence == "harmful" and DRAWBACK_KINDS[e.kind] then
                        list.drawbacks[#list.drawbacks + 1] = c
                    end
                end
            end
        end
    end
    if keep then snap.lostCandidates = list end
    return list
end

-- whether equipping this item can change an equipment predicate: it passes one, it goes in the
-- melee off hand, or an item it takes the place of (`replaced`, leaving out ctx.at, which before
-- never held) sits in the melee off hand (IsOffHandSlotEmpty), passes one or can't be read. When
-- it can't, the rest of what is worn is the same before and after, read or not, so every
-- condition reads the same and nothing is lost or gained
local function canChangePredicate(ctx, replaced)
    if passesAnyPredicate(ctx.info, ctx.slot) or ctx.slot == "MeleeOffHand" then return true end
    for at in pairs(replaced) do
        local ref = ctx.snap.equipped[at]
        if ref ~= nil and at ~= ctx.at and not NEVER_ARMOR_OR_SHIELD_SLOT[at] then
            if at == "MeleeOffHand" then return true end
            local info = ref.statsId and R.ItemInfo(ref.statsId)
            if not info or passesAnyPredicate(info, at) then return true end
        end
    end
    return false
end

-- whether a candidate's passive is granted by an item that stays equipped (one in a slot not in
-- `replaced`)
local function grantedByKeptItem(c, replaced)
    for at in pairs(c.from or {}) do
        if not replaced[at] then return true end
    end
    return false
end

-- why detected losses pass over a candidate, or nil when it reads it: a passive another cause
-- reads by name (listed for the trace only), one granted only by the items this one replaces (lost
-- with them, which is not this cause's business), or a kept item's passive whose BoostConditions
-- armor or a shield ends (endingTerm, acEndingTerm's), which is the item AC bonus cause's
local function lostCandidateSkip(c, fromKeptItem, endingTerm)
    if c.named then return "another cause's" end
    if not (c.own or fromKeptItem) then return "lost with the replaced item" end
    if fromKeptItem and endingTerm ~= nil and R.CondHas(c.name, "BoostConditions", endingTerm) == true then
        return "the " .. Cause.ItemACBonus .. " cause's"
    end
    return nil
end

-- what detected losses and held detected drawbacks read for a judgment before any one candidate,
-- the same for each family's kinds: nil when equipping this item can change no held passive's
-- condition, { reason } when that can't be told, otherwise { replaced, candidates, endingTerm,
-- keptUnread, replacedUnread }
local function readLostSetup(ctx)
    local replaced = replacedSlotSet(ctx)
    if replaced == nil then
        -- the equipped items can't be read (or, for an off-hand item, the main hand's). The item
        -- still changes no predicate when it passes none, goes anywhere but the melee off hand
        -- (IsOffHandSlotEmpty), and can empty no slot whose item may pass one: its own, or the off
        -- hand a two-hander empties (the main hand holds neither armor nor a shield). An item
        -- judged where it is worn empties neither: its slot held nothing before (Q17), and a worn
        -- two-hander's off hand is empty
        if passesAnyPredicate(ctx.info, ctx.slot) or ctx.slot == "MeleeOffHand" then
            return { reason = Rn.EquippedUnreadable }
        end
        local off = ctx.info.props.twohanded and OFF_OF[ctx.slot]
        if ctx.at == nil and (ARMOR_OR_SHIELD_SLOT[ctx.slot] or (off and ARMOR_OR_SHIELD_SLOT[off])) then
            return { reason = Rn.EquippedUnreadable }
        end
        return nil
    end
    if not canChangePredicate(ctx, replaced) then return nil end
    local list = candidates(ctx)
    -- an equipped item that can't be read may grant a candidate. One left equipped (keptUnread)
    -- leaves "no cause" unsure, but a hit still stands; one this item replaces (replacedUnread) may
    -- be where a passive held now comes from, so a hit on a held passive can't stand
    local keptUnread, replacedUnread = false, false
    for at in pairs(list.unread) do
        if replaced[at] then replacedUnread = true else keptUnread = true end
    end
    return { replaced = replaced, candidates = list, endingTerm = acEndingTerm(ctx.info, ctx.slot),
        keptUnread = keptUnread, replacedUnread = replacedUnread }
end

-- readLostSetup(ctx), read once per judgment and kept on the context as ctx.lostSetup, so each
-- family's detected loss and detected drawback causes read the same
local function lostSetup(ctx)
    if ctx.lostSetup == nil then ctx.lostSetup = readLostSetup(ctx) or false end
    return ctx.lostSetup or nil
end

-- one candidate for the detected loss cause's `kinds`: true and its detail (effectDetail) when
-- its condition holds with the items worn now and fails once this one is equipped, nil and a
-- reason when that can't be told, false otherwise. Unknown before is no cause (design §5.3.c)
local function candidateLost(ctx, c, kinds, setup)
    local e = c.effect
    if not kinds[e.kind] then return false end
    local fromKeptItem = grantedByKeptItem(c, setup.replaced)
    if lostCandidateSkip(c, fromKeptItem, setup.endingTerm) ~= nil then return false end
    if CondEval.Eval(e.cond, condEnv(ctx, "before")) ~= true then return false end
    local after, evalWhy = CondEval.Eval(e.cond, condEnv(ctx, "after"))
    if after == nil then
        return nil, undecidedReason(evalWhy)
    elseif after ~= false then
        return false
    elseif fromKeptItem or not setup.replacedUnread then
        return true, effectDetail(e, c.name)
    else
        -- a held passive may come from a replaced item that can't be read, and go with it
        return nil, Rn.EquippedUnreadable
    end
end

-- detected losses for a set of effect kinds: see CAUSES[Cause.DetectedLoss]
local function lostBenefit(ctx, kinds)
    local setup = lostSetup(ctx)
    if setup == nil then
        return false
    elseif setup.reason ~= nil then
        return nil, setup.reason
    end
    local why = setup.keptUnread and Rn.EquippedUnreadable or nil
    for _, c in ipairs(setup.candidates) do
        local lost, detail = candidateLost(ctx, c, kinds, setup)
        if lost == true then return true, detail end
        if lost == nil then why = worseReason(why, detail) end
    end
    if ctx.snap.passives == nil then why = worseReason(why, Rn.NoPassives) end
    if why ~= nil then return nil, why end
    return false
end

-- why held detected drawbacks pass over a candidate, or nil when they read it: a passive another
-- cause reads by name (listed for the trace only), or one granted only by the items this one
-- replaces (gone with them)
local function heldDrawbackSkip(c, fromKeptItem)
    if c.named then return "another cause's" end
    if not (c.own or fromKeptItem) then return "lost with the replaced item" end
    return nil
end

-- one held candidate for the detected drawback cause's `kind`: true and its detail (effectDetail)
-- when its condition fails with the items worn now and holds once this one is equipped, nil and a
-- reason when that can't be told, false otherwise. Unknown before is no cause, as for losses: a
-- drawback that may hold now is not one this item brings
local function heldDrawback(ctx, c, kind, setup)
    local e = c.effect
    if e.kind ~= kind then return false end
    local fromKeptItem = grantedByKeptItem(c, setup.replaced)
    if heldDrawbackSkip(c, fromKeptItem) ~= nil then return false end
    if CondEval.Eval(e.cond, condEnv(ctx, "before")) ~= false then return false end
    local after, evalWhy = CondEval.Eval(e.cond, condEnv(ctx, "after"))
    if after == nil then
        return nil, undecidedReason(evalWhy)
    elseif after ~= true then
        return false
    elseif fromKeptItem or not setup.replacedUnread then
        return true, effectDetail(e, c.name)
    else
        -- a held passive may come from a replaced item that can't be read, and go with it
        return nil, Rn.EquippedUnreadable
    end
end

-- held detected drawbacks for one effect kind: the candidates' list.drawbacks, read as lostBenefit
-- reads its own
local function heldDrawbacks(ctx, kind)
    local setup = lostSetup(ctx)
    if setup == nil then
        return false
    elseif setup.reason ~= nil then
        return nil, setup.reason
    end
    local why = setup.keptUnread and Rn.EquippedUnreadable or nil
    for _, c in ipairs(setup.candidates.drawbacks) do
        local hit, detail = heldDrawback(ctx, c, kind, setup)
        if hit == true then return true, detail end
        if hit == nil then why = worseReason(why, detail) end
    end
    if ctx.snap.passives == nil then why = worseReason(why, Rn.NoPassives) end
    if why ~= nil then return nil, why end
    return false
end

-- detected drawbacks for one effect kind: see CAUSES[Cause.DetectedDrawback]. The item's own
-- (ownDrawbacks, "char") first, then the held passives' (heldDrawbacks); a hit in either stands
local function detectedDrawback(ctx, kind)
    local own, ownDetail = ownDrawbacks(ctx, "char", kind)
    if own == true then return true, ownDetail end
    local held, heldDetail = heldDrawbacks(ctx, kind)
    if held == true then return true, heldDetail end
    local why = worseReason(own == nil and ownDetail or nil, held == nil and heldDetail or nil)
    if why ~= nil then return nil, why end
    return false
end

-- the held passives' Dexterity cap overrides (known cap_override effects), each { name, effect },
-- in name order. Read once per snapshot and kept on it as snap.capOverrides, but not for the
-- probes' peek reads. nil and NoPassives when the passives can't be read
local function heldCapOverrides(ctx)
    local snap = ctx.snap
    local keep = ctx.passiveOf == nil
    if keep and snap.capOverrides ~= nil then return snap.capOverrides end
    if snap.passives == nil then return nil, Rn.NoPassives end
    local passiveOf = ctx.passiveOf or R.Passive
    local names = {}
    for name in pairs(snap.passives) do names[#names + 1] = name end
    table.sort(names)
    local list = {}
    for _, name in ipairs(names) do
        for _, e in ipairs(passiveOf(name).effects) do
            if e.kind == "cap_override" and e.confidence == "known" then
                list[#list + 1] = { name = name, effect = e }
            end
        end
    end
    if keep then snap.capOverrides = list end
    return list
end

-- one Dexterity cap override, weighed for this body armor and a Dexterity modifier `mod`: "lifts"
-- when it holds once the armor is on and sets the cap at `mod` or above; the cap it sets when it
-- holds and sets it lower; otherwise nil, then a reason when one that would lift it can't be told.
-- Only an override for the armor's own ArmorType counts
local function capOverride(ctx, e, mod)
    if e.kind ~= "cap_override" or e.confidence ~= "known" or e.armorType ~= ctx.info.armorType
        or type(e.value) ~= "number" then
        return nil
    end
    local holds, evalWhy = CondEval.Eval(e.cond, condEnv(ctx, "after"))
    if holds == true then return e.value >= mod and "lifts" or e.value end
    if holds == nil and e.value >= mod then return nil, undecidedReason(evalWhy) end
    return nil
end

-- whether a held passive goes with the body armor this item takes the place of: true when only the
-- Breast item grants it (when that is this item, ownEffects reads it already), "unread" when no
-- item read grants it and the Breast item (or every equipped item) can't be read, false otherwise
local function withReplacedArmor(ctx, name)
    if ctx.snap.equipped == nil then return "unread" end
    local map = grantMap(ctx.snap)
    local from = map.from[name]
    if from == nil then return map.unread.Breast and "unread" or false end
    for at in pairs(from) do
        if at ~= "Breast" then return false end
    end
    return true
end

-- the penalty causes (design §5.3), by code. Each takes the judgment's context
-- ctx = { snap, info, slot, at, weapon, slots, passiveOf }, on which the causes keep what they read
-- once (replacedSet, worn.before and worn.after, envs, lostSetup, ownEffects), and its Settings.FAMILIES
-- cause entry (detected drawbacks read its kind, detected losses its kinds), and returns true (and
-- a detail for the log) when it applies, false when it doesn't, and nil plus a reason when it
-- can't tell (the character's passives, statuses or equipped items, or the game condition, could
-- not be read). Each penalty is read from the game's own condition text (Q12), so a mod that lifts
-- it turns the cause off; only the holder test and the item side are PaG's. Bladesong is not one:
-- its armor test lives in the engine function BladesongAvaliable(), with no stats text to read.
-- Fast Movement is the Barbarian heavy armor cause's second reader
local CAUSES = {
    -- Monk: a shield, or armor (wearsArmor), while Unarmored Movement's BoostConditions end in
    -- them: vanilla UnarmoredMovement_1/_2/_3/_DifficultTerrain carry
    -- "not WearingArmor(context.Source) and not HasShieldEquipped(context.Source)"
    [Cause.MonkArmor] = function(ctx)
        local snap, info, slot = ctx.snap, ctx.info, ctx.slot
        local term
        if info.groupSet.Shields then
            term = "HasShieldEquipped"
        elseif wearsArmor(info, slot) then
            term = "WearingArmor"
        else
            return false
        end
        if snap.passives == nil then return nil, Rn.NoPassives end
        local hit = anyCond(snap.passives, "UnarmoredMovement", "BoostConditions", term)
        if hit == nil then return nil, Rn.ConditionUnreadable end
        return hit
    end,
    -- Monk: a Heavy or Two-Handed melee weapon, while the bonus unarmed strike needs a monk weapon
    -- (MartialArts_BonusUnarmedStrike Conditions: IsMonkWeaponAttack()). Proficiency is Bad's
    -- business. A bow or crossbow sits in the ranged slot and leaves the melee slots free
    [Cause.MonkWeapon] = function(ctx)
        local snap, info = ctx.snap, ctx.info
        if not (ctx.weapon and MELEE_SLOT[ctx.slot]) then return false end
        if not (info.props.heavy or info.props.twohanded) then return false end
        if snap.passives == nil then return nil, Rn.NoPassives end
        if not snap.passives.MartialArts_BonusUnarmedStrike then return false end
        local cond = R.CondHas("MartialArts_BonusUnarmedStrike", "Conditions", "IsMonkWeaponAttack")
        if cond == nil then return nil, Rn.ConditionUnreadable end
        return cond
    end,
    -- Barbarian: heavy body armor, while rage (Rage_Rage_Boosts, for a holder of
    -- UnarmouredDefence_Barbarian) or Fast Movement (FastMovement) ends in it: both BoostConditions
    -- read "not HasHeavyArmor(context.Source)". Body only: HasHeavyArmor tests the ArmorType of
    -- GetActiveArmor, which Heat Metal treats as the Breast item (design §5.3), so Plate helmets
    -- and boots are taken not to count (untested, design E4). Fast Movement is this cause's
    -- second reader
    [Cause.BarbarianHeavy] = function(ctx)
        local snap = ctx.snap
        if not (ctx.slot == "Breast" and HEAVY_BODY[ctx.info.armorType or ""]) then return false end
        if snap.passives == nil then return nil, Rn.NoPassives end
        local rage = heldCond(snap, "UnarmouredDefence_Barbarian", "Rage_Rage_Boosts", "BoostConditions", "HasHeavyArmor")
        local fast = heldCond(snap, "FastMovement", "FastMovement", "BoostConditions", "HasHeavyArmor")
        if rage or fast then return true end
        if rage == nil or fast == nil then return nil, Rn.ConditionUnreadable end
        return false
    end,
    -- anyone: Disadvantage on Stealth, unless Medium Armor Master lifts it. Both are read from the
    -- armor's own boost (Read.lua), which is the game's data already
    [Cause.Stealth] = function(ctx)
        local info = ctx.info
        if not info.stealthDisadv then return false end
        if not info.stealthMAM then return true end
        if ctx.snap.passives == nil then return nil, Rn.NoPassives end
        return not ctx.snap.passives.MediumArmorMaster
    end,
    -- Rogue: a melee weapon without Finesse, while both ways to Sneak Attack need one:
    -- Target_SneakAttack RequirementConditions and Interrupt_SneakAttack Conditions both test
    -- WieldingFinesseWeaponInSpecificHand. Either one lifted by a mod is a way left, so no mark.
    -- Ranged weapons always qualify, so the ranged slots are never marked
    [Cause.SneakAttack] = function(ctx)
        local snap = ctx.snap
        if not (ctx.weapon and MELEE_SLOT[ctx.slot]) or ctx.info.props.finesse then return false end
        if snap.passives == nil then return nil, Rn.NoPassives end
        if not snap.passives.SneakAttack_Unlock then return false end
        local react = R.CondHas("Interrupt_SneakAttack", "Conditions", "WieldingFinesseWeaponInSpecificHand")
        local spell = R.CondHas("Target_SneakAttack", "RequirementConditions", "WieldingFinesseWeaponInSpecificHand")
        if react == false or spell == false then return false end
        if react == nil or spell == nil then return nil, Rn.ConditionUnreadable end
        return true
    end,
    -- Unarmored Defense (barbarian or monk) or Draconic Resilience: armor (wearsArmor), or a
    -- shield where the passive's BoostConditions end it in one (the monk's do, the barbarian's and
    -- Draconic Resilience's don't)
    [Cause.UnarmoredAC] = function(ctx)
        local term = acEndingTerm(ctx.info, ctx.slot)
        if term == nil then return false end
        local passives = ctx.snap.passives
        if passives == nil then return nil, Rn.NoPassives end
        local unread = false
        for _, holder in ipairs(UNARMORED) do
            if passives[holder] then
                local has = R.CondHas(holder, "BoostConditions", term)
                if has then return true, holder end
                if has == nil then unread = true end
            end
        end
        if unread then return nil, Rn.ConditionUnreadable end
        return false
    end,
    -- Mage Armor: armor (wearsArmor), while the character has the MAGE_ARMOR status and its
    -- RemoveConditions ("WearingArmor()") end it in armor. Shields don't
    [Cause.MageArmor] = function(ctx)
        local snap = ctx.snap
        if not wearsArmor(ctx.info, ctx.slot) then return false end
        if snap.mageArmor == nil then return nil, Rn.StatusesUnreadable end
        if not snap.mageArmor then return false end
        local cond = R.CondHas("MAGE_ARMOR", "RemoveConditions", "WearingArmor")
        if cond == nil then return nil, Rn.ConditionUnreadable end
        return cond
    end,
    -- an equipped item's AC bonus that ends in armor or a shield, such as Bracers of Defense
    -- (MAG_OfDefense_Gloves_Passive: "not WearingArmor(context.Source) and not
    -- HasShieldEquipped(context.Source)"). Read from the BoostConditions of the passives each
    -- equipped item grants, leaving out the items this one would replace, and a weapon's
    -- main-hand or off-hand passives where it isn't in that hand (appliesInSlot)
    [Cause.ItemACBonus] = function(ctx)
        local endingTerm = acEndingTerm(ctx.info, ctx.slot)
        if endingTerm == nil then return false end
        local replaced = replacedSlotSet(ctx)
        if replaced == nil then return nil, Rn.EquippedUnreadable end
        local why = nil
        for at, ref in pairs(ctx.snap.equipped) do
            if not replaced[at] then
                local info = ref.statsId and R.ItemInfo(ref.statsId)
                if not info then
                    why = why or Rn.EquippedUnreadable
                else
                    for _, p in ipairs(info.passives) do
                        if appliesInSlot(p.hand, at) then
                            local has = R.CondHas(p.name, "BoostConditions", endingTerm)
                            if has then return true, at end
                            if has == nil then why = why or Rn.ConditionUnreadable end
                        end
                    end
                end
            end
        end
        if why then return nil, why end
        return false
    end,
    -- Defensive Duelist: a main-hand melee weapon without Finesse, while the reaction needs one
    -- (Interrupt_DefensiveDuelist Conditions: HasWeaponProperty(WeaponProperties.Finesse,
    -- GetActiveWeapon(context.Observer)))
    [Cause.DefensiveDuelist] = function(ctx)
        local snap = ctx.snap
        if not (ctx.weapon and ctx.slot == "MeleeMainHand") or ctx.info.props.finesse then return false end
        if snap.passives == nil then return nil, Rn.NoPassives end
        if not snap.passives.DefensiveDuelist then return false end
        local cond = R.CondHas("Interrupt_DefensiveDuelist", "Conditions", "WeaponProperties.Finesse")
        if cond == nil then return nil, Rn.ConditionUnreadable end
        return cond
    end,
    -- Polearm Master: a main-hand melee weapon without Reach that is not a quarterstaff or spear,
    -- while either benefit needs one: Interrupt_PolearmMaster (the opportunity attack) and
    -- PolearmMaster_BonusAttack both test HasWeaponProperty(WeaponProperties.Reach, ...) or
    -- Tagged('WPN_STAVE') or Tagged('WPN_SPEAR'). The two are separate benefits, so losing either
    -- one is the penalty. The Quarterstaffs and Spears groups stand in for the two tags
    [Cause.PolearmMaster] = function(ctx)
        local snap, info = ctx.snap, ctx.info
        if not (ctx.weapon and ctx.slot == "MeleeMainHand") then return false end
        if info.props.reach or info.groupSet.Quarterstaffs or info.groupSet.Spears then return false end
        if snap.passives == nil then return nil, Rn.NoPassives end
        local aoo = heldCond(snap, "PolearmMaster_AttackOfOpportunity", "Interrupt_PolearmMaster", "Conditions", "WeaponProperties.Reach")
        local bonus = heldCond(snap, "PolearmMaster_BonusAttack", "PolearmMaster_BonusAttack", "Conditions", "WeaponProperties.Reach")
        if aoo or bonus then return true end
        if aoo == nil or bonus == nil then return nil, Rn.ConditionUnreadable end
        return false
    end,
    -- Q11: equipping it would empty the other hand: a two-handed weapon while an off-hand item is
    -- equipped, or an off-hand item while a two-handed weapon is. Never true of an equipped item,
    -- since the game does not hold the two together. The detail is the slot it empties
    [Cause.EmptiesHand] = function(ctx)
        local slots = replacedSlotList(ctx)
        if slots == nil then return nil, Rn.EquippedUnreadable end
        if slots[2] ~= nil and ctx.snap.equipped[slots[2]] ~= nil then return true, slots[2] end
        return false
    end,
    -- detected drawbacks (design D36, §5.3.b): a known harmful effect of the family's `kind`
    -- (movement, ac, ability, combat), read from the game's boost and condition text (CondParse,
    -- BoostClass), that this character pays once the item is on and not every wearer does. Two
    -- sources. The item's own (ownEffects: its passives, its Boosts and the boosts of its
    -- StatusOnEquip statuses), whose condition holds for this character and not for every
    -- wearer: heavy armor that slows anyone under Strength 13 who isn't a dwarf. A held
    -- passive's (the character's, or a kept item's), whose condition fails with the items worn
    -- now and holds once this one is equipped: a penalty while wearing a shield. A drawback every
    -- wearer pays is the universal drawback cause's (N16), and Stealth the Stealth cause's. The
    -- detail is "word:passive", or the bare word for the item's own boost
    [Cause.DetectedDrawback] = function(ctx, cause)
        return detectedDrawback(ctx, cause.kind)
    end,
    -- drawbacks every wearer pays (N16): a known harmful effect of a drawback kind on the item
    -- itself (ownEffects) whose condition holds for every wearer, such as a mod's attack penalty
    -- on heavy armor. A held passive's never lands here. Stealth is the Stealth cause's, which
    -- shares this cause's family. The detail is as detected drawbacks' is
    [Cause.UniversalDrawback] = function(ctx)
        return ownDrawbacks(ctx, "every", nil)
    end,
    -- N17: body armor whose Dexterity cap stands below the character's Dexterity modifier
    -- (floor((score - 10) / 2)), so its AC leaves part of the Dexterity bonus unused. Read from
    -- the armor's "Armor Class Ability" (Dexterity) and "Ability Modifier Cap" (0 or none is no
    -- cap), less what an override for its ArmorType lifts (ArmorAbilityModifierCapOverride, such
    -- as Medium Armor Master's 3): the armor's own (ownEffects) and the held passives' (but those
    -- only the armor it replaces grants). One that holds once the armor is on and reaches the
    -- modifier ends the cause; one that may and would leaves it undecided. The detail is the cap
    -- that stands
    [Cause.DexCap] = function(ctx)
        local info = ctx.info
        if ctx.slot ~= "Breast" or info.acAbility ~= "Dexterity" or (info.dexCap or 0) <= 0 then
            return false
        end
        local abilities = ctx.snap.abilities
        local score = abilities and abilities.Dexterity
        if type(score) ~= "number" then return nil, Rn.DetectUnread end
        local mod = math.floor((score - 10) / 2)
        if mod <= info.dexCap then return false end
        local cap, why = info.dexCap, nil
        for _, o in ipairs(ownEffects(ctx)) do
            local set, reason = capOverride(ctx, o.effect, mod)
            if set == "lifts" then return false end
            if type(set) == "number" and set > cap then cap = set end
            why = worseReason(why, reason)
        end
        local held, heldWhy = heldCapOverrides(ctx)
        if held == nil then why = worseReason(why, heldWhy) end
        for _, o in ipairs(held or {}) do
            local gone = withReplacedArmor(ctx, o.name)
            if gone ~= true then
                local set, reason = capOverride(ctx, o.effect, mod)
                if set == "lifts" and gone ~= "unread" then return false end
                if set == "lifts" then
                    -- it may come from the armor this one replaces, and go with it
                    why = worseReason(why, Rn.EquippedUnreadable)
                elseif type(set) == "number" and set > cap and gone ~= "unread" then
                    cap = set
                end
                why = worseReason(why, reason)
            end
        end
        if why ~= nil then return nil, why end
        return true, tostring(cap)
    end,
    -- detected lost benefits (design §5.3.c): a passive the character holds, or one an item it
    -- keeps equipped grants, with a known beneficial effect of one of the family's `kinds`
    -- (movement, ac, ac_override, ability, combat) whose condition holds with the items worn now
    -- (leaving this one out, Q17) and fails once this one is equipped: a feat's AC bonus "while
    -- not wearing armor". Read from the game's condition text, so before and after differ only in
    -- the equipment predicates, the passives and proficiency this item grants (condEnv;
    -- abilities and tags read the same). Unknown before is no cause; unknown after leaves it
    -- undecided. What a named cause reads is skipped: the passives of namedElsewhere, and an
    -- item's passive whose BoostConditions the item AC bonus cause reads as ending. An AC override
    -- lost is never weighed against the AC this item gives (D37). Only an item that can change an
    -- equipment predicate is read (canChangePredicate). When the equipped items can't be read, an
    -- item that can change none is no cause, and any other is undecided: no cause for one that
    -- passes none and is worn already, or goes anywhere but the melee off hand and can empty no
    -- armor or shield slot (a one-handed main-hand weapon, a ranged one). What is read before any
    -- one candidate (lostSetup) is read once per judgment, for every family's detected loss and
    -- detected drawback cause. The detail is "word:passive" (effectDetail)
    [Cause.DetectedLoss] = function(ctx, cause)
        return lostBenefit(ctx, cause.kinds)
    end,
}

-- nil and Good rank 0
local RANK = { [T.NotIdeal] = 1, [T.Bad] = 2 }

-- the penalty families (design §5.3) on top of the verdict the rules reached without them: tier
-- nil (Proficiency Group ""), Good (proficient) or Not Ideal (Bindable). The worst tier wins, and
-- a tie keeps the base. A cause that can't tell, in a family whose tier would beat the result,
-- leaves the cell unmarked with its reason: unknown is never "no". Returns tier, reason, detail,
-- ac. A family's causes count only while its radio is not Off and their checkbox is on. ac: the
-- tier came from causes, every one that hit at that tier is an Armor vs AC bonuses cause, and no
-- other cause at that tier was undecided (Hub's shield badge). With ctx.want it also returns the
-- causes (Rules.Judge's header), `lead` first when the base tier stands. Listing them reads the
-- families at the base tier too, which the verdict itself never needs
local function penalize(cfg, ctx, tier, reason, lead)
    local base = RANK[tier] or 0
    local hit, hitTier, hitReason, hitDetail, acOnly = 0, nil, nil, nil, true
    local open, openReason, openOther = 0, nil, 0
    local found = ctx.want and {} or nil
    for _, fam in ipairs(Settings.FAMILIES) do
        local famTier = Settings.PENALTY_TIER[cfg[fam.key]]
        local rank = famTier and RANK[famTier] or 0
        -- a family at or below the base, or below a hit already found, can change nothing
        local decides = rank > base and rank >= hit
        if decides or (found and rank > 0 and rank == base) then
            for _, cause in ipairs(fam.causes) do
                if cause.key == nil or cfg[cause.key] then
                    local yes, extra = CAUSES[cause.code](ctx, cause)
                    if yes and found then
                        found[#found + 1] = { rank = rank, code = cause.code, detail = extra }
                    end
                    if not decides then
                        -- read for the causes only
                    elseif yes then
                        if rank > hit then
                            hit, hitTier, hitReason, hitDetail = rank, famTier, Rn.Penalty .. cause.code, extra
                            acOnly = fam.ac == true
                        elseif not fam.ac then
                            acOnly = false
                        end
                    elseif yes == nil then
                        if rank > open then open, openReason = rank, extra or Rn.NoPassives end
                        if not fam.ac and rank > openOther then openOther = rank end
                    end
                end
            end
        end
    end
    local detail, ac = nil, false
    if hit > base then
        tier, reason, detail = hitTier, hitReason, hitDetail
        ac = acOnly and openOther < hit
    end
    if open > base and open > hit then return nil, openReason, nil, false end
    local causes = nil
    if found then
        local win = math.max(hit, base)
        causes = {}
        if win == base and lead then causes[1] = lead end
        for _, c in ipairs(found) do
            if c.rank == win then causes[#causes + 1] = { code = c.code, detail = c.detail } end
        end
    end
    return tier, reason, detail, ac, causes
end

-- the proficiency the items equipped in `slots` grant. nil when one of them can't be read
local function grantsOf(snap, slots)
    local out = {}
    for _, s in ipairs(slots) do
        local ref = snap.equipped[s]
        if ref ~= nil then
            if ref.statsId == nil then return nil end
            local info = R.ItemInfo(ref.statsId)
            if info == nil then return nil end
            for g in pairs(info.grants) do out[g] = true end
        end
    end
    return out
end

-- Judge's return order, with penalize's verdict after the slot
local function verdict(slot, tier, reason, detail, ac, causes)
    return tier, reason, slot, detail, ac, causes
end

-- the rule order is the design's: each step either decides or passes to the next
function Rules.Judge(cfg, snap, itemUuid, at, want, peek)
    if not cfg.enabled then return nil, Rn.Disabled end

    local rec = R.Item(itemUuid)
    if rec == nil then return nil, Rn.NoEntity end
    if snap == nil then return nil, Rn.NoCharEntity end
    if rec.noStats then return nil, Rn.NoStats, nil, NO_STATS_ID end
    local info = R.ItemInfo(rec.statsId)
    if info == nil then return nil, Rn.NoStats, nil, "no stats entry " .. rec.statsId end
    if not info.known then return nil, Rn.NoStats, nil, "stats type " .. tostring(info.kind) end

    local slot = at or rec.slot or info.slot
    if slot == nil then return nil, Rn.NoSlot end
    if CLOAK_UNDERWEAR[slot] then return nil, Rn.CloakUnderwear, slot end
    if not IN_SCOPE[slot] then return nil, Rn.OutOfScope .. slot, slot end

    if info.useConditions then return nil, Rn.UseConditions, slot end
    if rec.statsId == "WPN_ShadowBlade" then return nil, Rn.ShadowBlade, slot end
    -- a torch is carried for its light, so an attack-roll verdict on it is noise: the same
    -- reasoning D14 settled for instruments. Weapon Properties "Torch" names exactly WPN_Torch
    -- and Quest_GLO_Moonlantern corpus-wide. "Light" is the finesse-adjacent property and would
    -- take daggers and shortswords with it, so it is not the test
    if info.props.torch then return nil, Rn.LightSource, slot end

    local weapon = WEAPON_SLOT[slot] and not info.groupSet.Shields
    local ctx = { snap = snap, info = info, slot = slot, at = at, weapon = weapon, want = want,
        passiveOf = peek and R.PeekPassive or nil }

    -- Proficiency Group "": nothing to be proficient in, but a penalty cause can still apply
    if info.groupEmpty then
        return verdict(slot, penalize(cfg, ctx, nil, Rn.NoGroup))
    end

    if overlaps(info.grants, info.groupSet) then return nil, Rn.PactBoost, slot end

    if snap.flags == nil then return nil, Rn.NoFlags, slot end
    if not overlaps(info.groupSet, snap.flags) then
        -- Bad is the only verdict a bind can overturn, so the bind gate belongs here and nowhere
        -- else. A bind ADDS proficiency: PACT_BLADE's boost list is purely additive (SharedDev
        -- Status_BOOST.txt:2977) and none of the penalty causes reads anything it touches, so
        -- below this branch -- where the character is already proficient -- an unread bind
        -- cannot make PaG wrong. Placed ahead of the comparison, the gate would throw away every
        -- Good and Not Ideal verdict on a weapon whose statuses do not read, a weapon the
        -- character is proficient in among them
        --
        -- melee only. Shout_PactOfTheBlade_Bind applies PACT_BLADE to MainHand
        -- (SharedDev/Stats/Generated/Data/Spell_Shout.txt:4654, StatsItemSlot 19) and carries
        -- data "Sheathing" "Melee" (:4672), and Larian write RangedMainHand explicitly when they
        -- mean ranged, so no status can make a crossbow proficient. Run on all four weapon slots,
        -- this gate would leave a warlock's heavy crossbow unmarked instead of Bad
        if weapon and MELEE_SLOT[slot] then
            local statuses = R.ItemStatuses(itemUuid)
            if statuses == nil then
                -- statusSet returns an empty set for an item with no StatusContainer, so nil
                -- is a read that actually raised (Read.lua): a real unknown, and rule 10 holds
                if snap.binder or snap.binderUnknown then
                    return nil, Rn.BinderStatusUnreadable, slot
                end
            elseif Rules.IsBound(statuses) then
                return nil, Rn.BoundStatus, slot
            elseif snap.binder then
                -- bad + bindable. One bind makes this proficient, so Bad overstates it, and D2's
                -- middle tier is exactly "usable at a cost" -- the pact slot and the bind action.
                -- Only a known binder routes here: binderUnknown keeps the Bad it had, so no path
                -- loses a mark. The penalty families still apply: one set to Bad raises it (the
                -- worst tier wins), one at Not Ideal changes nothing
                return verdict(slot, penalize(cfg, ctx, T.NotIdeal, Rn.Bindable,
                    { code = Rn.Bindable, detail = info.groups }))
            end
        end
        -- no family outranks Bad, so penalize can only add the causes at it
        if want then
            local _, _, _, _, causes = penalize(cfg, ctx, T.Bad, Rn.Bad, { code = Rn.Bad, detail = info.groups })
            return T.Bad, Rn.Bad, slot, nil, nil, causes
        end
        return T.Bad, Rn.Bad, slot
    end

    -- proficient now, but maybe only through an item this one would take the place of
    if snap.equipped == nil then return nil, Rn.EquippedUnreadable, slot end
    local slots = replacedSlots(snap, slot, info)
    local lost = slots and grantsOf(snap, slots)
    if lost == nil then return nil, Rn.EquippedUnreadable, slot end
    if next(lost) ~= nil and not overlaps(info.groupSet, snap.flags, lost) then
        return nil, Rn.ReplaceGrant, slot
    end

    ctx.slots = slots
    return verdict(slot, penalize(cfg, ctx, T.Good, Rn.Good))
end

-- the reads Judge makes, for Dev/Rules.lua's item traces (!pag_n14, !pag_lost), which read them as
-- Judge does. Only Dev/ reads this, and a release build leaves Dev/ out
Rules.ForDev = { IN_SCOPE = IN_SCOPE, WEAPON_SLOT = WEAPON_SLOT, condEnv = condEnv,
    replacedSlotSet = replacedSlotSet, replacedSlotList = replacedSlotList, acEndingTerm = acEndingTerm,
    appliesInSlot = appliesInSlot, grantMap = grantMap,
    drawbackPassiveSkip = drawbackPassiveSkip, drawbackEffectSkip = drawbackEffectSkip,
    drawbackHolds = drawbackHolds, effectDetail = effectDetail, ownEffects = ownEffects,
    ownDrawback = ownDrawback, ownDrawbacks = ownDrawbacks, detectedDrawback = detectedDrawback,
    candidates = candidates, canChangePredicate = canChangePredicate,
    grantedByKeptItem = grantedByKeptItem, lostSetup = lostSetup, heldDrawbackSkip = heldDrawbackSkip,
    heldDrawbacks = heldDrawbacks, heldCapOverrides = heldCapOverrides,
    lostCandidateSkip = lostCandidateSkip, lostBenefit = lostBenefit }
