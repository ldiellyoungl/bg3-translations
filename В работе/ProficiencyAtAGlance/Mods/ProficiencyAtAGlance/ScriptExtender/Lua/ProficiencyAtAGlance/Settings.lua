-- settings: MCM owns the values when it's installed, SPEC below when it isn't. MCM is optional on
-- purpose (no dependency in meta.lsx, "Optional" in the blueprint), so every MCM call is guarded.
-- Without MCM every setting is its default. With MCM, a value it can't give (read fails, nothing
-- back, wrong type, not a valid choice) takes its strict value, the one showing fewer marks
--
-- when the values are read (design §7.2):
--   * every world load: all of them, with MCM.Get (Hub.Attach). Main-menu edits raise no event, so
--     this is the only way they arrive
--   * a save or reset event: the one value in the event's payload. Handlers never call MCM.Get:
--     whether MCM's own handler has stored the value yet would be a race
--   * a profile event: the values in its payload. Of MCM's three profile payloads only that one
--     reaches the client (ProfileManager.lua:115-118 relays it; MCMServer.lua:152-161 and
--     MCMAPI.lua:82 stay on the server). One without our values changes nothing and warns once:
--     MCM.Get would be right only after MCM stored the new profile, and no event says when. The
--     next world load reads it
-- Adapted from Auto Disarm's Settings.lua
local U, L, E = PaG.Util, PaG.Log, PaG.Enums
local Cause = E.Cause

local S = {}
PaG.Settings = S

S.TIERS = { E.Tier.Bad, E.Tier.NotIdeal, E.Tier.Good }
S.STYLES = { "dim", "gray", "glow", "badge", "dot" }
-- tier x style pairs with no setting: Dim and Grayscale are the penalty looks vanilla itself
-- uses, so Good never offers them (D23, Q10). cfg reads nil for these, which render treats as off
S.NOT_OFFERED = { good_dim = true, good_gray = true }

-- the penalty families (design §5.3), in menu order. Not proficient is always Bad; each family is
-- one radio (`key`) choosing the tier its causes mark: Off, Not Ideal or Bad. Under it sit its
-- causes' checkboxes, one per cause key; a cause without a key has none and is on whenever its
-- family is. Rules reads `code`, the cause, for its reasons, and a detected drawback's `kind` and
-- a detected loss's `kinds`, the effect kinds each reads. `ac`: the family's causes are AC the
-- character would lose (bonuses, an AC formula, a detected AC penalty, Dexterity a cap leaves
-- unused), so a mark only they gave can show the AC shield for its badge icon (ac_shield_badge).
-- The detected causes sit with the vanilla family of their kind (Q15): ac_penalty and
-- ac_bonus_lost under ac_tier, both movement ones under movement_tier. A drawback every wearer
-- pays is universal_tier's, Off by default: Stealth Disadvantage and the universal drawback cause
-- (N16). Keys follow design §7.1's pattern: a family's is <family>_tier and its causes' start with
-- <family>; a detected drawback's is <family>_penalty and a detected loss's <family>_bonus_lost
S.FAMILIES = {
    { key = "class_armor_tier", default = E.Penalty.Bad, causes = {
        { key = "class_armor_monk",      code = Cause.MonkArmor,      default = true },
        { key = "class_armor_barbarian", code = Cause.BarbarianHeavy, default = true },
    } },
    { key = "class_weapon_tier", default = E.Penalty.Bad, causes = {
        { key = "class_weapon_monk",  code = Cause.MonkWeapon,  default = true },
        { key = "class_weapon_rogue", code = Cause.SneakAttack, default = false },
    } },
    { key = "ac_tier", default = E.Penalty.NotIdeal, ac = true, causes = {
        { key = "ac_unarmored",   code = Cause.UnarmoredAC, default = false },
        { key = "ac_mage_armor",  code = Cause.MageArmor,   default = true },
        { key = "ac_items",       code = Cause.ItemACBonus, default = true },
        { key = "ac_dex_cap",     code = Cause.DexCap,      default = true },
        { key = "ac_penalty",     code = Cause.DetectedDrawback, kind = "ac", default = true },
        { key = "ac_bonus_lost",  code = Cause.DetectedLoss, kinds = { ac = true, ac_override = true }, default = true },
    } },
    { key = "feat_tier", default = E.Penalty.NotIdeal, causes = {
        { key = "feat_defensive_duelist", code = Cause.DefensiveDuelist, default = true },
        { key = "feat_polearm_master",    code = Cause.PolearmMaster,    default = true },
    } },
    { key = "hands_tier",   default = E.Penalty.NotIdeal, causes = { { code = Cause.EmptiesHand } } },
    -- movement speed (Q18): only detected causes. Monk Unarmored Movement (Cause.MonkArmor) stays
    -- in class_armor_tier
    { key = "movement_tier", default = E.Penalty.NotIdeal, causes = {
        { key = "movement_penalty",    code = Cause.DetectedDrawback, kind = "movement", default = true },
        { key = "movement_bonus_lost", code = Cause.DetectedLoss, kinds = { movement = true }, default = true },
    } },
    -- ability scores: no vanilla rule reads them, so the detected drawback and the lost
    -- benefit (design §5.3.b, §5.3.c) have a family of their own
    { key = "ability_tier", default = E.Penalty.NotIdeal, causes = {
        { key = "ability_penalty",    code = Cause.DetectedDrawback, kind = "ability", default = true },
        { key = "ability_bonus_lost", code = Cause.DetectedLoss, kinds = { ability = true }, default = true },
    } },
    -- rolls, damage, hit points and resources (BoostClass's combat words: attack, save, check,
    -- initiative, damage, crit, vulnerable, targeted, resource, hp, spell): only detected causes
    { key = "combat_tier", default = E.Penalty.NotIdeal, causes = {
        { key = "combat_penalty",    code = Cause.DetectedDrawback, kind = "combat", default = true },
        { key = "combat_bonus_lost", code = Cause.DetectedLoss, kinds = { combat = true }, default = true },
    } },
    -- drawbacks every wearer pays: the item's, known before it is picked up, so Off by default.
    -- Stealth Disadvantage (N4) and the rest (N16)
    { key = "universal_tier", default = E.Penalty.Off, causes = {
        { key = "universal_stealth", code = Cause.Stealth,           default = true },
        { key = "universal_penalty", code = Cause.UniversalDrawback, default = true },
    } },
}

-- the effect kinds the detected causes read, each the union of its causes' kinds above: the
-- detected drawbacks' `kind` (DRAWBACK_KINDS, marked when harmful) and the detected losses' `kinds`
-- (LOST_KINDS, read when beneficial). Rules and Console read these two, so a new detect family
-- needs no second list
S.DRAWBACK_KINDS, S.LOST_KINDS = {}, {}
for _, fam in ipairs(S.FAMILIES) do
    for _, cause in ipairs(fam.causes) do
        if cause.code == Cause.DetectedDrawback then
            S.DRAWBACK_KINDS[cause.kind] = true
        elseif cause.code == Cause.DetectedLoss then
            for kind in pairs(cause.kinds) do S.LOST_KINDS[kind] = true end
        end
    end
end
-- a family's radio value as the tier it marks. Off, and anything else, marks nothing
S.PENALTY_TIER = { [E.Penalty.NotIdeal] = E.Tier.NotIdeal, [E.Penalty.Bad] = E.Tier.Bad }
local PENALTIES = { [E.Penalty.Off] = true, [E.Penalty.NotIdeal] = true, [E.Penalty.Bad] = true }

-- each tier's badge icons, in menu order (the blueprint's Choices for <tier>_badge_icon). A stored
-- value outside its tier's list is not a valid choice, so coerce returns the tier default (strict,
-- TIER_DEFAULTS) and the mark still shows
S.ICONS = {
    [E.Tier.Bad]      = { E.Icon.Cross, E.Icon.CrossThin, E.Icon.Skull },
    [E.Tier.NotIdeal] = { E.Icon.Warning, E.Icon.Exclamation, E.Icon.Minus },
    [E.Tier.Good]     = { E.Icon.Check, E.Icon.CheckThin, E.Icon.CheckGlow, E.Icon.Star },
}
local ICON_SETS = {}
for tier, list in pairs(S.ICONS) do
    ICON_SETS[tier] = {}
    for _, icon in ipairs(list) do ICON_SETS[tier][icon] = true end
end
-- the palette: the game freezes the brushes the marks are drawn with, so a tier picks one of six fixed
-- brushes (Lib_Keyboard.xaml PaG.Brush.*) rather than any color
local COLORS = { [E.Color.Red] = true, [E.Color.Orange] = true, [E.Color.Yellow] = true,
    [E.Color.Green] = true, [E.Color.Blue] = true, [E.Color.Purple] = true }
local LEVELS = { off = true, basic = true, verbose = true }
local TRADE_MARKS = { [E.TradeMarks.Full] = true, [E.TradeMarks.Subtle] = true, [E.TradeMarks.Off] = true }
local CORNERS = { [E.Corners.BadgeTopLeft] = true, [E.Corners.BadgeBottomRight] = true }

-- per tier: its color (one of the palette's six) and badge icon defaults (design D4)
local TIER_DEFAULTS = {
    [E.Tier.Bad]      = { color = E.Color.Red,    icon = E.Icon.CrossThin },
    [E.Tier.NotIdeal] = { color = E.Color.Orange, icon = E.Icon.Warning },
    [E.Tier.Good]     = { color = E.Color.Green,  icon = E.Icon.CheckThin },
}
-- the looks on by default (design D4); every other tier x style starts off
local LOOKS_ON = { bad_dim = true, bad_gray = true, bad_badge = true, not_ideal_dim = true,
    not_ideal_glow = true, not_ideal_badge = true, good_badge = true }

-- key     the setting's Id in MCM_blueprint.json and the cfg field the rest of the mod reads
--         (tools/pag_harness/settings_ids_test.py checks the two match)
-- strict  used when MCM is installed but can't give this one
-- choices the values a radio or enum may hold
--
-- in menu order: the General tab, then Penalties, then Looks
local SPEC = {
    { key = "enabled", default = true, strict = false },
    { key = "equipped_marks", default = true, strict = false },
    -- on: an equipped item's badge explains itself on hover (Why.lua)
    { key = "equipped_tooltips", default = true, strict = false },
    -- on: a cell's badge and dot explain a Bad or Not Ideal item on hover (Why.lua); Good has none
    { key = "cell_tooltips", default = true, strict = false },
    -- off: a cell holding an item the player marked as a Ware shows no mark (Hub keyOf)
    { key = "ware_marks", default = false, strict = false },
    -- the marks on a trade page's item cells, both sides (the doll's slots keep theirs): Full, as
    -- anywhere else; Subtle, without Dim and Grayscale and the rest at Hub's TRADE_FAINT strength;
    -- Off, none (Hub buildLooks). Strict is Off, the fewest marks
    { key = "trade_marks", default = E.TradeMarks.Subtle, strict = E.TradeMarks.Off, choices = TRADE_MARKS },
    -- where the badge and the dot sit: badge top-left and dot bottom-right, or the other way round
    -- (Hub buildLooks: the template's corner switch). It changes no mark, so strict is the default
    { key = "placement_corners", default = E.Corners.BadgeTopLeft, strict = E.Corners.BadgeTopLeft, choices = CORNERS },
    -- logging changes no mark, so its strict value is just the default
    { key = "debug_level", default = E.Level.Off, strict = E.Level.Off, choices = LEVELS },
}
-- an Off family marks nothing, so Off is every radio's strict value
for _, fam in ipairs(S.FAMILIES) do
    SPEC[#SPEC + 1] = { key = fam.key, default = fam.default, strict = E.Penalty.Off, choices = PENALTIES }
    for _, cause in ipairs(fam.causes) do
        if cause.key then
            SPEC[#SPEC + 1] = { key = cause.key, default = cause.default, strict = false }
        end
    end
    -- a look, not a rule: it sits with the causes it is about
    if fam.ac then SPEC[#SPEC + 1] = { key = "ac_shield_badge", default = true, strict = false } end
end
for _, tier in ipairs(S.TIERS) do
    for _, style in ipairs(S.STYLES) do
        local key = tier .. "_" .. style
        if not S.NOT_OFFERED[key] then
            SPEC[#SPEC + 1] = { key = key, default = LOOKS_ON[key] == true, strict = false }
        end
    end
    local d = TIER_DEFAULTS[tier]
    SPEC[#SPEC + 1] = { key = tier .. "_color_preset", default = d.color, strict = d.color, choices = COLORS }
    SPEC[#SPEC + 1] = { key = tier .. "_badge_icon", default = d.icon, strict = d.icon, choices = ICON_SETS[tier] }
end

-- KEYS keeps SPEC order, so anything listing the settings lists them the way the menu does
S.KEYS, S.DEFAULTS = {}, {}
for i, spec in ipairs(SPEC) do
    S.KEYS[i] = spec.key
    S.DEFAULTS[spec.key] = spec.default
end

-- the setting ids renamed to design §7.1's pattern on 2026-10-19, old = new. MCM_blueprint.json
-- gives each renamed setting its old id as OldId, which carries a saved value over; this lets
-- !pag_set take an old id too. Drop both together a couple of releases on (docs/RELEASE.md).
-- pen_stealth's radio became universal_tier, Stealth Disadvantage now one of its causes
S.RENAMED = {
    pen_class_armor = "class_armor_tier", ni_monk_armor = "class_armor_monk",
    ni_barbarian_heavy = "class_armor_barbarian",
    pen_class_weapon = "class_weapon_tier", ni_monk_weapon = "class_weapon_monk",
    ni_sneak_attack = "class_weapon_rogue",
    pen_ac = "ac_tier", detect_ac = "ac_penalty", detect_ac_lost = "ac_bonus_lost",
    pen_feat_weapon = "feat_tier",
    pen_hands = "hands_tier", pen_stealth = "universal_tier",
    pen_movement = "movement_tier", detect_movement = "movement_penalty",
    detect_movement_lost = "movement_bonus_lost",
    pen_detected = "ability_tier", detect_ability = "ability_penalty",
    detect_ability_lost = "ability_bonus_lost",
    corners = "placement_corners",
}

local function specOf(key)
    for _, spec in ipairs(SPEC) do
        if spec.key == key then return spec end
    end
    return nil
end

-- a value MCM shouldn't be able to produce (hand-edited settings file, blueprint drifted from SPEC)
-- gets replaced, not trusted. Returns the reason too so the caller can report it
local function coerce(spec, v)
    if type(v) ~= type(spec.default) then return spec.strict, "wrong type" end
    if spec.choices and not spec.choices[v] then return spec.strict, "not a valid choice" end
    return v
end

local function same(a, b)
    if type(a) == "table" and type(b) == "table" then
        for i = 1, 4 do
            if a[i] ~= b[i] then return false end
        end
        return true
    end
    return a == b
end

local function show(v)
    if type(v) == "table" then
        return string.format("%.2f,%.2f,%.2f", v[1] or -1, v[2] or -1, v[3] or -1)
    end
    return tostring(v)
end
S.Show = show

-- MCM injects itself into the namespace of mods that load after it; for the rest it's Mods.BG3MCM.
-- Either one reads our values, since every call passes our ModuleUUID. Never call this at file
-- scope: this file may load before MCM
local function mcm()
    local m = MCM
    if type(m) == "table" and type(m.Get) == "function" then return m end
    m = Mods and Mods.BG3MCM
    if type(m) == "table" and type(m.Get) == "function" then return m end
    return nil
end

local cfg = nil
local source = E.SettingsSource.Defaults

local function readAll(m)
    local out, bad = {}, nil
    local function report(spec, rec)
        bad = bad or {}
        bad[spec.key] = rec
    end
    for _, spec in ipairs(SPEC) do
        local v = spec.default
        if m then
            local ok, got = pcall(m.Get, spec.key, ModuleUUID)
            if not ok then
                v = spec.strict
                report(spec, { why = "unreadable", err = tostring(got), used = show(v) })
            elseif got == nil then
                v = spec.strict
                report(spec, { why = "no value", used = show(v) })
            else
                local fixed, why = coerce(spec, got)
                v = fixed
                if why then report(spec, { why = why, got = show(got), used = show(fixed) }) end
            end
        end
        out[spec.key] = v
    end
    return out, bad
end

local UNUSABLE = "some MCM settings were unusable: each took its strict value"

-- the log level is just another setting, so it's applied here with the rest, not by callers
local function apply(values, from)
    cfg, source = values, from
    L.SetLevel(values.debug_level)
end

-- `early` = the read at file load, only there to get the log level. MCM may not have its values yet,
-- so unusable ones aren't reported; Hub.Attach reads again at Running and reports then
function S.Load(early)
    local m = mcm()
    local values, bad = readAll(m)
    apply(values, m and E.SettingsSource.MCM or E.SettingsSource.Defaults)
    if bad and not early then L.Warn(UNUSABLE, bad) end
    return cfg, source
end

function S.Get()
    if cfg == nil then S.Load() end
    return cfg
end

function S.Source()
    if cfg == nil then S.Load() end
    return source
end

-- one readable line for the attach banner, the console and after a settings change
function S.Describe()
    local c = S.Get()
    local tiers = {}
    for _, tier in ipairs(S.TIERS) do
        local on = {}
        for _, style in ipairs(S.STYLES) do
            if c[tier .. "_" .. style] then
                on[#on + 1] = style == "badge" and ("badge:" .. tostring(c[tier .. "_badge_icon"])) or style
            end
        end
        tiers[#tiers + 1] = string.format("%s %s [%s]", tier, tostring(c[tier .. "_color_preset"]), #on > 0 and table.concat(on, " ") or "-")
    end
    -- each family as name=tier, then the settings of its causes that are on, e.g.
    -- class_armor=Bad(class_armor_monk class_armor_barbarian). An Off family lists none, as its menu hides them
    local pen = {}
    for _, fam in ipairs(S.FAMILIES) do
        local live = c[fam.key] ~= E.Penalty.Off
        local on = {}
        for _, cause in ipairs(fam.causes) do
            if live and cause.key and c[cause.key] then on[#on + 1] = cause.key end
        end
        local said = string.format("%s=%s", (fam.key:gsub("_tier$", "")), tostring(c[fam.key]))
        if #on > 0 then said = said .. "(" .. table.concat(on, " ") .. ")" end
        if live and fam.ac and c.ac_shield_badge then said = said .. "+shield" end
        pen[#pen + 1] = said
    end
    return string.format("%s (%s): %s; penalties [%s]; equipped marks %s; equipped tooltips %s; cell tooltips %s; ware marks %s; trade marks %s; corners %s; log %s",
        c.enabled and "on" or "OFF", source, table.concat(tiers, ", "), table.concat(pen, ", "),
        c.equipped_marks and "on" or "off", c.equipped_tooltips and "on" or "off",
        c.cell_tooltips and "on" or "off", c.ware_marks and "on" or "off",
        tostring(c.trade_marks), tostring(c.placement_corners),
        c.debug_level)
end

-- called with (changed, event) after the cache changed, `changed` = {key = new value} (set by S.Watch)
local onChange = nil
-- called with (changed) on the tick a run of updates has ended (set by S.Settle)
local onSettle = nil

-- the log side of a run of updates. The events of a run and the last value of each changed setting
-- are gathered here and written as one row, with one console line, on the first tick that brings no
-- update (as Hub does with bursts of judging and rendering). A run that changed nothing writes nothing
local run, updatesThisTick, lastSaid = nil, 0, nil

local function update(event, values, bad)
    local before = cfg or S.DEFAULTS
    local changed, n = {}, 0
    for _, spec in ipairs(SPEC) do
        if not same(before[spec.key], values[spec.key]) then
            changed[spec.key] = values[spec.key]
            n = n + 1
        end
    end
    apply(values, mcm() and E.SettingsSource.MCM or source)
    if bad then L.Warn(UNUSABLE, bad) end
    updatesThisTick = updatesThisTick + 1
    run = run or { events = {}, changed = {}, n = 0 }
    run.events[event] = (run.events[event] or 0) + 1
    for k, v in pairs(changed) do run.changed[k] = show(v) end
    run.n = run.n + n
    if n > 0 and onChange then onChange(changed, event) end
end

local function copyCfg()
    local out = {}
    for k, v in pairs(S.Get()) do out[k] = v end
    return out
end

-- a save or a reset: one value, from the payload
local function one(event, key, value)
    local spec = specOf(key)
    if spec == nil then
        L.WarnOnce("settings.unknown." .. tostring(key), "MCM sent a setting PaG does not have: " .. tostring(key))
        return
    end
    local values = copyCfg()
    local fixed, why = coerce(spec, value)
    values[key] = fixed
    update(event, values, why and { [key] = { why = why, got = show(value), used = show(fixed) } } or nil)
end

-- a profile switch: every value, from the payload, a missing one taking its strict value. Returns
-- false when the payload has no values for us
local function profile(payload)
    local all = payload.newSettings
    local mine = type(all) == "table" and all[ModuleUUID] or nil
    local values = type(mine) == "table" and mine.settingsValues or nil
    if type(values) ~= "table" then return false end
    local out, bad = {}, nil
    for _, spec in ipairs(SPEC) do
        local got = values[spec.key]
        if got == nil then
            out[spec.key] = spec.strict
            bad = bad or {}
            bad[spec.key] = { why = "not in the profile", used = show(spec.strict) }
        else
            local fixed, why = coerce(spec, got)
            out[spec.key] = fixed
            if why then
                bad = bad or {}
                bad[spec.key] = { why = why, got = show(got), used = show(fixed) }
            end
        end
    end
    update("MCM_Profile_Activated", out, bad)
    return true
end

local HANDLERS = {
    MCM_Setting_Saved = function(p)
        if p.modUUID ~= ModuleUUID then return end
        one("MCM_Setting_Saved", p.settingId, p.value)
    end,
    MCM_Setting_Reset = function(p)
        if p.modUUID ~= ModuleUUID then return end
        local spec = specOf(p.settingId)
        local value = p.defaultValue
        if value == nil and spec then value = spec.default end
        one("MCM_Setting_Reset", p.settingId, value)
    end,
    MCM_Profile_Activated = function(p)
        if profile(p) then return end
        L.WarnOnce("settings.profile_without_values", "a profile switch came without PaG's values: "
            .. "!pag_status shows the settings in use; the next save load reads the new profile",
            { fields = U.Keys(p) })
    end,
}
local CHANNELS = { "MCM_Setting_Saved", "MCM_Setting_Reset", "MCM_Profile_Activated" }

-- the log row of a run of updates that has ended
function S.OnTick()
    if run ~= nil and updatesThisTick == 0 then
        local done = run
        run = nil
        if done.n > 0 then
            L.Write(E.LogKind.Settings, "changed", { events = done.events, changed = done.changed })
            local said = S.Describe()
            if said ~= lastSaid then
                lastSaid = said
                L.Say("settings: " .. said)
            end
            if onSettle ~= nil then onSettle(done.changed) end
        end
    end
    updatesThisTick = 0
end

-- the settle callback: a run of changes has ended
function S.Settle(fn) onSettle = fn end

-- subscribes once per Lua state, at attach time, so MCM has surely finished loading. Returns whether
-- the save channel (the one a menu change comes through) was found. Later calls only swap the
-- callback
local subscribed = false

function S.Watch(fn)
    onChange = fn
    if subscribed then return true end
    local events = Ext.ModEvents and Ext.ModEvents.BG3MCM
    if events == nil or events["MCM_Setting_Saved"] == nil then return false end
    for _, name in ipairs(CHANNELS) do
        local channel = events[name]
        if channel ~= nil then
            channel:Subscribe(function(payload)
                if type(payload) ~= "table" then payload = {} end
                U.Try("settings." .. name, HANDLERS[name], payload)
            end)
        end
    end
    subscribed = true
    return true
end

-- console escape hatch (!pag_set), so a player without MCM can still change a setting or turn
-- logging on. Only takes values the menu itself could set, and with MCM it is stored there too.
--
-- It always applies the value here, in this session. In game MCM.Set only queues the write, so
-- waiting for MCM's save event meant !pag_set debug_level verbose changed nothing in the session
-- that asked for it, which is the one session where the logging is wanted. MCM still has the last
-- word: its save event comes through the same one() path, so a value MCM stored differently
-- replaces this one, and an event carrying the value already applied finds nothing changed and
-- writes no second row. Without MCM the value lasts until the next game launch
-- Returns the stored value and a note, or nil and the error. The stored value can be false, so test
-- the result with == nil or ~= nil, never for truth
function S.Set(key, value)
    local old = S.RENAMED[key] and key
    key = S.RENAMED[key] or key
    local spec = specOf(key)
    if spec == nil then return nil, "no such setting: " .. tostring(key) end
    -- an old id works, and the note gives its new one
    local function noted(note)
        return old and string.format("%s; %s is now %s", note, old, key) or note
    end
    local fixed, why = coerce(spec, value)
    if why then
        return nil, noted(string.format("%s does not accept %s (%s)", key, show(value), why))
    end
    local m = mcm()
    if m and type(m.Set) == "function" then
        local ok, res = pcall(m.Set, spec.key, fixed, ModuleUUID, true)
        if not ok then return nil, tostring(res) end
        if res == false then return nil, "MCM did not store it" end
        one("console", key, fixed)
        return fixed, noted(subscribed and "applied now, and saved to MCM" or "saved to MCM")
    end
    one("console", key, fixed)
    return fixed, noted("this session only, since MCM is not installed")
end
