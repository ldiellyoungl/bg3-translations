-- the badge's tooltip (design §6.2): why an item has its tier for the character it is judged for,
-- for example
--   Not Ideal for Shadowheart
--   Not proficient until bound: Longswords, Martial Weapons
--   Ends Unarmored Defense
-- Hub builds it when it judges a slot with Equipped tooltips on, or a Bad or Not Ideal cell with
-- Cell tooltips on, and writes it into the slot's PaGSlotWhy or the cell's PaGWhy in the same
-- Defer pass as the badge. "" means no tooltip: the XAML turns the hover targets off while the text
-- is empty
--
-- the names come from the game, in its language (R.Name, R.StatName, R.GroupName). The words
-- around them are PaG's own, in English.xml, so they are translated with the menu
local R = PaG.Read
local E = PaG.Enums
local T, Rn, Cause = E.Tier, E.Reason, E.Cause
local Why = {}
PaG.Why = Why

-- each word is a handle and its English, shown when the handle can't be read. [1] and [2] are
-- filled with names. tools/loca.py sync writes the handles and keeps each English in step with
-- English.xml: a "lua:" key is this file's own text, and any other key reuses the menu's text
-- loca: begin
local WORDS = {
    tier_for = { "h0e01f205g365fg5ac8gab16g7800de3e887a", "[1] for [2]" }, -- lua:why:tier_for -- item badge tooltip, first line: [1] = Bad or Not Ideal, [2] = the character the item is judged for
    bad = { "h44d8af80gef22g510cg91a6gc5ee22047121", "Bad" }, -- choice:bad
    not_ideal = { "hf0e71c39g5ed4g5b89ga277g7bed3355039f", "Not Ideal" }, -- choice:not ideal
    not_proficient = { "h5a8eaaf9ga78cg534ag94b3g525cfb7f1de6", "Not proficient: [1]" }, -- lua:why:not_proficient -- item badge tooltip: [1] = the item's proficiency groups, such as Longswords, Martial Weapons
    until_bound = { "hb77ab0edg859dg50begae80g4d65ebe90676", "Not proficient until bound: [1]" }, -- lua:why:until_bound -- item badge tooltip, for a Pact of the Blade warlock: [1] = the item's proficiency groups
    ends = { "h26d47b54gf844g5825g9617g4d5dd8670533", "Ends [1]" }, -- lua:why:ends -- item badge tooltip: [1] = what wearing the item ends, such as Unarmored Defense or Mage Armor
    ends_bonus = { "ha292c828ga613g57dfga38cgb2a6c7188f97", "Ends the AC bonus from [1]" }, -- lua:why:ends_bonus -- item badge tooltip: [1] = another equipped item, such as Bracers of Defense
    monk_armor = { "h4a2d6753g34fbg571ega6d1g2737772816fe", "Monk: shield or armor" }, -- setting:class_armor_monk:name
    monk_weapon = { "h94331984g0ab7g5553g82b6g92eefc1afa2f", "Monk: Heavy or Two-Handed melee weapon" }, -- setting:class_weapon_monk:name
    barbarian_heavy = { "he80bf380g48efg561eg988dg87e8803fc66f", "Barbarian: heavy body armor" }, -- setting:class_armor_barbarian:name
    stealth = { "h47af2550gb806g5278g80a9g637fecefb849", "Stealth Disadvantage" }, -- setting:universal_stealth:name
    sneak_attack = { "h57832276g0ba4g5d6cg8ed7g10f3eebec1c9", "Rogue: non-Finesse melee weapon" }, -- setting:class_weapon_rogue:name
    unarmored_ac = { "h97ddcbe8ge363g53e2ga644g94f600da4d42", "Unarmored Defense or Draconic Resilience" }, -- setting:ac_unarmored:name
    mage_armor = { "hf3ed8928gce54g5b80g9e61g8da5101cc3f2", "Mage Armor" }, -- setting:ac_mage_armor:name
    item_ac_bonus = { "h8119eb21g38ccg56d0ga3eegc8e410c56e69", "Items like Bracers of Defense" }, -- setting:ac_items:name
    defensive_duelist = { "h939b7d14ga8feg547bg8526gaa5637deaa5a", "Defensive Duelist" }, -- setting:feat_defensive_duelist:name
    polearm_master = { "h7307ca67gbc1dg59cfg97efg7f23f87f47db", "Polearm Master" }, -- setting:feat_polearm_master:name
    empties_hand = { "hfae8a006g96abg5499g9474g925bb6dc94e6", "Two-Handed weapon vs off-hand item" }, -- setting:hands_tier:name
    movement = { "h174395a6g4e42g5f0dgb6d3g780bd52a8ca8", "Movement penalty" }, -- setting:movement_penalty:name
    ac = { "h9d19edeega494g5f4ag96f2g32c728e4ef38", "AC penalty" }, -- setting:ac_penalty:name
    ability = { "h361b1f00ge867g5538g9f8ag77feba693305", "Ability penalty" }, -- lua:why:ability -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item lowers one of the wearer's ability scores
    attack = { "he407aa03g08cag5fd9g916dgd713c4d28abe", "Attack roll penalty" }, -- lua:why:attack -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item worsens the wearer's attack rolls
    save = { "hfa1627bbg4597g52a5g9e17gbffdb87cd45a", "Saving throw penalty" }, -- lua:why:save -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item worsens the wearer's saving throws
    check = { "hbd970093geae2g5f20ga18dg18f86a43e62f", "Ability check penalty" }, -- lua:why:check -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item worsens the wearer's ability or skill checks
    initiative = { "h82cbdfa0g2a9dg5e2bgaaa6g8ed2c6c66c0a", "Initiative penalty" }, -- lua:why:initiative -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item lowers the wearer's initiative
    damage = { "h7222e905gaa9bg560aga9f3g76f238b51d70", "Damage penalty" }, -- lua:why:damage -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item lowers the damage the wearer deals
    crit = { "h432cb778g19adg59b4gb4e9g220af13decac", "Critical hit penalty" }, -- lua:why:crit -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item makes the wearer's critical hits rarer
    vulnerable = { "hd30e129eg9410g5a13g9bf1gb7169c3c0905", "Takes more damage" }, -- lua:why:vulnerable -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item makes the wearer take more damage, such as a vulnerability
    targeted = { "hb040668ag409eg5f82gaca0g278a1757cf5a", "Easier to hit" }, -- lua:why:targeted -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item gives attacks against the wearer Advantage
    resource = { "he4676ff0g8b2cg5aaega500g1fb25b21bb69", "Fewer resources" }, -- lua:why:resource -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item takes away or blocks some of the wearer's actions, spell slots or other class resources
    hp = { "h7b03fd7dg533cg5038g8f6bg3820dcb56be5", "Hit point penalty" }, -- lua:why:hp -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item lowers the wearer's maximum hit points
    spell = { "h3bc23d1bg0739g5c55gb739g389b2a74cebb", "Spell save DC penalty" }, -- lua:why:spell -- item badge tooltip, before the passive that has the drawback (the [1] of "[1]: [2]"), or alone for the item's own: the item lowers the wearer's spell save DC
    dex_cap = { "he7e4a66dg8fd1g536dgb2f1gdf9cfb5552f4", "Dexterity bonus capped at +[1]" }, -- lua:why:dex_cap -- item badge tooltip, for body armor: [1] = the most of the Dexterity modifier the armor adds to AC, less than the wearer's own
    detected = { "h91718ff2gf8a6g55c6g916cgf7cc6de6ab9d", "[1]: [2]" }, -- lua:why:detected -- item badge tooltip: [1] = the drawback, such as Movement penalty or Attack roll penalty, [2] = the passive that has it
}
-- loca: end

local TIER_WORD = { [T.Bad] = WORDS.bad, [T.NotIdeal] = WORDS.not_ideal }

local function word(w)
    return R.Loca(w[1]) or w[2]
end

-- the word with [1] and [2] filled in
local function fill(w, ...)
    local args = { ... }
    return (word(w):gsub("%[(%d)%]", function(n) return args[tonumber(n)] or "" end))
end

-- the weapon categories, named after the item's own group. Read sorts the groups by id, which
-- put "Daggers, Simple Weapons" but "Martial Weapons, Rapiers"
local CATEGORY = { SimpleWeapons = true, MartialWeapons = true }

-- "Longswords, Martial Weapons"; a group the game doesn't name shows as its id, spaced
local function groupNames(groups)
    local out, last = {}, {}
    for _, g in ipairs(groups or {}) do
        local into = CATEGORY[g] and last or out
        into[#into + 1] = R.GroupName(g) or (g:gsub("(%l)(%u)", "%1 %2"))
    end
    for _, n in ipairs(last) do out[#out + 1] = n end
    return table.concat(out, ", ")
end

-- a cause's line, by its code (a Cause value, or the Bad or Bindable reason). Each takes the cause's detail and the character's snapshot, and falls
-- back to the cause's menu label when a name can't be read
local LINE = {
    [Rn.Bad] = function(groups)
        local names = groupNames(groups)
        return names ~= "" and fill(WORDS.not_proficient, names) or nil
    end,
    [Rn.Bindable] = function(groups)
        local names = groupNames(groups)
        return names ~= "" and fill(WORDS.until_bound, names) or nil
    end,
    -- the detail is the passive the armor ends
    [Cause.UnarmoredAC] = function(passive)
        local n = passive and R.StatName(passive)
        return n and fill(WORDS.ends, n) or word(WORDS.unarmored_ac)
    end,
    [Cause.MageArmor] = function()
        local n = R.StatName("MAGE_ARMOR")
        return n and fill(WORDS.ends, n) or word(WORDS.mage_armor)
    end,
    -- the detail is the slot of the item whose bonus ends
    [Cause.ItemACBonus] = function(at, snap)
        local ref = at and snap.equipped and snap.equipped[at]
        local n = ref and R.Name(ref.uuid)
        return n and fill(WORDS.ends_bonus, n) or word(WORDS.item_ac_bonus)
    end,
    -- the detail is "word:passive", the effect's word (Rules effectDetail: its kind, or a combat
    -- effect's word) and the passive that has it, or the word alone for a boost of the item's own
    [Cause.DetectedDrawback] = function(detail)
        local kind, passive = tostring(detail):match("^([%a_]+):(.+)$")
        if kind == nil then kind = tostring(detail):match("^[%a_]+$") end
        local what = WORDS[kind or ""]
        if what == nil then return nil end
        local n = passive and R.StatName(passive)
        return n and fill(WORDS.detected, word(what), n) or word(what)
    end,
    -- the detail is "kind:passive", the effect kind and the passive whose benefit the item ends,
    -- named by its id when the game gives it no name
    [Cause.DetectedLoss] = function(detail)
        local kind, passive = tostring(detail):match("^([%a_]+):(.+)$")
        if kind == nil then return nil end
        return fill(WORDS.ends, R.StatName(passive) or passive)
    end,
    -- the detail is the cap that stands, a number
    [Cause.DexCap] = function(cap)
        return fill(WORDS.dex_cap, tostring(cap))
    end,
}
-- every wearer's drawbacks read as detected drawbacks do
LINE[Cause.UniversalDrawback] = LINE[Cause.DetectedDrawback]

-- the tooltip for an item of this tier, from Rules.Judge's causes (read with `want`), worn by the
-- snapshot's character. "" for Good, or when there are no causes. A line two causes share shows
-- once (a passive a detected loss reads in both the AC and the movement family)
function Why.Text(tier, causes, snap)
    local tw = TIER_WORD[tier]
    if tw == nil or causes == nil or causes[1] == nil then return "" end
    local name = snap and R.Name(snap.uuid)
    local lines, seen = { name and fill(WORDS.tier_for, word(tw), name) or word(tw) }, {}
    for _, c in ipairs(causes) do
        local line
        if LINE[c.code] then
            line = LINE[c.code](c.detail, snap)
        elseif WORDS[c.code] then
            line = word(WORDS[c.code])
        end
        if line ~= nil and line ~= "" and not seen[line] then
            seen[line] = true
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end
