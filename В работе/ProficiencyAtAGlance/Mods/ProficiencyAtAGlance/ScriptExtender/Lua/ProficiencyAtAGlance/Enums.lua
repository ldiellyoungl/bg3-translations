-- the mod's string codes, one closed set per enum. The values show up in the JSONL log and the
-- console, so never change a value; add a member instead
--
-- reading a missing member raises, so a typo fails. An enum can't be iterated, counted or
-- serialized, so anything that needs the raw values (Settings' choices, L.LEVELS,
-- Settings' S.TIERS) spells them out where it's used
local E = {}
PaG.Enums = E

local function CreateEnum(tbl)
    return setmetatable({}, {
        __index = function(_, k)
            local v = tbl[k]
            if v == nil then error("Errors: Unknown enum member '" .. tostring(k) .. "'!", 2) end
            return v
        end,
        __newindex = function()
            error("Errors: Cannot modify a read-only enum!", 2)
        end,
        __metatable = false -- locks the metatable so it can't be swapped out
    })
end

E.Level = CreateEnum({ Off = "off", Basic = "basic", Verbose = "verbose" })

E.SettingsSource = CreateEnum({ MCM = "MCM", Defaults = "defaults" })

-- how a trade page's item cells are marked, as MCM's enum stores it (the blueprint's Choices for
-- trade_marks; Hub buildLooks)
E.TradeMarks = CreateEnum({ Full = "full", Subtle = "subtle", Off = "off" })

-- where the badge and the dot sit, as MCM's enum stores it (the blueprint's Choices for placement_corners; Hub
-- buildLooks turns it into the template's corner switch)
E.Corners = CreateEnum({ BadgeTopLeft = "badge_top_left", BadgeBottomRight = "badge_bottom_right" })

-- the three tiers (design §5). Each is also the prefix of its settings ids
E.Tier = CreateEnum({ Bad = "bad", NotIdeal = "not_ideal", Good = "good" })

-- badge icons, as MCM's radio stores them (the blueprint's Choices). Each tier offers its own set
-- (Settings.ICONS): Good three checks and a star, Not Ideal three cautions, Bad two crosses and a
-- skull. A stored value outside its tier's set reads as the tier's default. Shield is no tier's
-- choice: it stands in for the badge icon of a mark that only Armor vs AC bonuses causes gave
-- (setting ac_shield_badge, design §5.3). Each names a mask, PaG.Mask.<Name> in Lib_Keyboard.xaml,
-- listed there in this order
E.Icon = CreateEnum({
    Check = "check", CheckThin = "check_thin", CheckGlow = "check_glow", Star = "star",
    Warning = "warning", Exclamation = "exclamation", Minus = "minus",
    Cross = "cross", CrossThin = "cross_thin", Skull = "skull",
    Shield = "shield",
})

-- the tier a penalty family marks, as MCM's radio stores it: the blueprint's Choices, which are
-- also the labels the menu shows (design §5.3)
E.Penalty = CreateEnum({ Off = "Off", NotIdeal = "Not ideal", Bad = "Bad" })

-- mark colors, as MCM's enum stores them (the blueprint's Choices). Each names a palette brush,
-- PaG.Brush.<Name>, and the glow's pair of fades, PaG.Glow.<Name>.Sides and .Ends, in
-- Lib_Keyboard.xaml, listed there in this order
E.Color = CreateEnum({ Red = "red", Orange = "orange", Yellow = "yellow", Green = "green", Blue = "blue", Purple = "purple" })

-- the penalty causes: what equipping an item would cost its wearer (design §5.3). A cause's
-- reason is Reason.Penalty and its value. Why.lua's WORDS give its label under its value, except
-- for the causes whose line Why.lua's LINE builds from the detail. The design names each by the
-- id beside it, as the log did before 2026-10-18 (pen:N14)
E.Cause = CreateEnum({
    MonkArmor = "monk_armor",               -- N1: a Monk's shield or armor ends Unarmored Movement
    MonkWeapon = "monk_weapon",             -- N2: a Monk's Heavy or Two-Handed melee weapon ends
                                            -- Martial Arts' bonus strike
    BarbarianHeavy = "barbarian_heavy",     -- N3: heavy body armor ends Rage's benefits or Fast
                                            -- Movement
    Stealth = "stealth",                    -- N4: armor with Disadvantage on Stealth
    SneakAttack = "sneak_attack",           -- N5: a Rogue's melee weapon without Finesse ends Sneak
                                            -- Attack
    UnarmoredAC = "unarmored_ac",           -- N8: armor ends Unarmored Defense's or Draconic
                                            -- Resilience's AC
    MageArmor = "mage_armor",               -- N9: armor ends Mage Armor
    ItemACBonus = "item_ac_bonus",          -- N10: armor or a shield ends another item's AC bonus
                                            -- (Bracers of Defense)
    DefensiveDuelist = "defensive_duelist", -- N11: a main-hand melee weapon without Finesse ends
                                            -- the reaction
    PolearmMaster = "polearm_master",       -- N12: a main-hand melee weapon that is no polearm ends
                                            -- its attacks
    EmptiesHand = "empties_hand",           -- N13: equipping it empties the other hand (Q11,
                                            -- design §5.5)
    DetectedDrawback = "detected_drawback", -- N14 (design §5.3.b): a harmful effect, the
                                            -- item's own or a held passive's, that this wearer
                                            -- pays and not every wearer does
    DetectedLoss = "detected_loss",         -- N15 (design §5.3.c): a benefit the
                                            -- character has now that equipping the item ends
    UniversalDrawback = "universal_drawback", -- N16 (design §5.3.e): a harmful effect of the
                                              -- item's own that every wearer pays
    DexCap = "dex_cap",                     -- N17 (design §5.3.f): body armor whose Dexterity cap
                                            -- is below the character's Dexterity modifier
})

-- why a cell got what it got. A value ending in ":" is a prefix; a detail gets appended
E.Reason = CreateEnum({
    -- Hub, before Rules
    NoChar = "no_char",                 -- the judged character (the trading one while the Trade
                                        -- widget is shown, else the selected one) could not be
                                        -- read, or an equipment slot's item is not worn by it
    JudgeError = "judge_error",         -- Rules.Judge raised for this item (the error prints once per message)
    -- Rules, in the order they are tried
    Disabled = "disabled",
    NoEntity = "no_entity",             -- the item's entity was not found on the client
    NoCharEntity = "no_char_entity",    -- the character's entity was not found on the client
    NoStats = "no_stats",
    NoSlot = "no_slot",
    CloakUnderwear = "cloak_underwear",
    OutOfScope = "out_of_scope:",       -- + the slot
    UseConditions = "use_conditions",
    ShadowBlade = "shadow_blade",
    LightSource = "light_source",       -- a torch or moonlantern: carried for light, never judged
    NoGroup = "no_group",               -- Proficiency Group "", and no penalty cause applies
    PactBoost = "pact_boost",           -- the item grants proficiency in its own group
    BoundStatus = "bound_status",       -- PACT_BLADE or HEXBLADE_BIND on the item
    BinderStatusUnreadable = "binder_status_unreadable",
    NoFlags = "no_flags",               -- the character's proficiencies could not be read
    NoPassives = "no_passives",         -- the character's passives could not be read
    ConditionUnreadable = "condition_unreadable", -- a penalty cause's game condition could not be read
    StatusesUnreadable = "statuses_unreadable",   -- the character's statuses could not be read
                                                  -- (Cause.MageArmor)
    DetectUnknown = "detect_unknown",   -- a detected cause's condition has text CondParse can't
                                        -- read
    DetectUnread = "detect_unread",     -- a detected cause's condition needs a read that failed
    Bad = "bad",
    Bindable = "bindable",              -- Not Ideal: not proficient, but this binder can bind it
    EquippedUnreadable = "equipped_unreadable",
    ReplaceGrant = "replace_grant",     -- proficient only through an equipped item this replaces
    Penalty = "pen:",                   -- + a Cause value, a penalty cause (design §5.3). Its
                                        -- family's setting chose the tier
    Good = "good",
})

-- JSONL record kinds. basic writes all but Sample; verbose adds Sample
E.LogKind = CreateEnum({
    Milestone = "milestone", -- attach steps, once per world load
    Probe = "probe",         -- which read path worked, once per world load
    Char = "char",           -- a character snapshot: when built, and when a re-read finds it changed
    Item = "item",           -- a watched item's binding changed
    Burst = "burst",         -- one aggregate row per burst of judging and rendering, with its new examples
    Sample = "sample",       -- verbose: up to SAMPLES_PER_BURST single judgments per burst
    Bump = "bump",           -- a generation moved (rules G, looks or a character), and why
    Cost = "cost",           -- timing: a write that may be slow, flushed before it starts; a long gap between ticks
    Settings = "settings",   -- one row per run of ticks with settings changes
    Warn = "warn",
    Error = "error",
})
