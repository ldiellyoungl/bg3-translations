-- Pure-data reader for a passive's or an item's Boosts, for detected drawbacks and lost benefits
-- (both causes in Rules.lua). Split cuts the text at top-level ';' into boosts, each with its IF(...)
-- guard; Classify says what one boost does to its wearer: { kind, word, value, valence, confidence,
-- target, name, raw }. The kinds, each with confidence "known":
--   movement     ActionResource(Movement, n[, lvl]), ActionResourceMultiplier(Movement, N, lvl)
--                (value N-100), ActionResourceConsumeMultiplier(Movement, f, lvl) (value 1-f),
--                JumpMaxDistanceMultiplier(f) (value f-1), JumpMaxDistanceBonus(n);
--                ActionResourceBlock(Movement) and MovementSpeedLimit(X) are harmful
--   ac           AC(n); BlockAbilityModifierFromAC(<ability>) is harmful
--   ability      Ability(<ability>, n[, N[, true|false]]), with `ability` its name
--   ac_override  ACOverrideFormula(base, true|false, <ability>...), value the base
--   cap_override ArmorAbilityModifierCapOverride(<armor type>, N): value N, `armorType` the type,
--                valence neutral (only the Dexterity cap cause reads it)
--   stealth      Disadvantage(Skill, Stealth), the Stealth cause's
--   combat       the rest, with `word` naming the part of play: attack, save, check, initiative,
--                damage, crit, vulnerable, targeted, resource, hp or spell (see FORMS)
-- valence is "harmful" when the boost makes its wearer worse off, "beneficial" when better, else
-- "neutral"; a number n is read by magnitude, so dice and ProficiencyBonus count as positive and
-- -XModifier as negative. Any other boost, or one whose sign can't be told, has confidence
-- "unknown" and no kind or valence: it is never a cause. Passive reads both of a passive's texts
-- into its effects. Never `load`: the text comes from any mod's stats
local CP = PaG.CondParse
local B = {}
PaG.BoostClass = B

local MAX_LEN = 4000

local ABILITY = { Strength = true, Dexterity = true, Constitution = true, Intelligence = true,
    Wisdom = true, Charisma = true }

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- s cut at each top-level `sep` (outside parentheses and quotes), trimmed; nil when the
-- parentheses or quotes don't balance
local function cut(s, sep)
    local out, depth, quote, from = {}, 0, nil, 1
    for i = 1, #s do
        local c = s:sub(i, i)
        if quote then
            if c == quote then quote = nil end
        elseif c == "'" or c == '"' then
            quote = c
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth < 0 then return nil end
        elseif c == sep and depth == 0 then
            out[#out + 1] = trim(s:sub(from, i - 1))
            from = i + 1
        end
    end
    if depth ~= 0 or quote then return nil end
    out[#out + 1] = trim(s:sub(from))
    return out
end

-- the index of the ')' that closes the '(' at i, outside quotes; nil when none does
local function closer(s, i)
    local depth, quote = 0, nil
    for j = i, #s do
        local c = s:sub(j, j)
        if quote then
            if c == quote then quote = nil end
        elseif c == "'" or c == '"' then
            quote = c
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return j end
        end
    end
    return nil
end

-- the boosts of text, each { body, guard, raw }: guard is the IF(...) condition's text, or nil.
-- Empty pieces are skipped. A second value is false when the text doesn't balance, which comes back
-- as one boost with body nil (unknown)
function B.Split(text)
    if type(text) ~= "string" or text == "" then return {}, true end
    if #text > MAX_LEN then return { { raw = text:sub(1, 80) .. "..." } }, false end
    local pieces = cut(text, ";")
    if pieces == nil then return { { raw = trim(text) } }, false end
    local out = {}
    for _, p in ipairs(pieces) do
        if p ~= "" then
            local b = { raw = p, body = p }
            if p:find("^IF%s*%(") then
                local open = p:find("(", 1, true)
                local close = closer(p, open)
                local rest = close and p:sub(close + 1):match("^%s*:%s*(.-)$")
                if rest == nil or rest == "" then
                    b.body = nil
                else
                    b.guard, b.body = trim(p:sub(open + 1, close - 1)), rest
                end
            end
            out[#out + 1] = b
        end
    end
    return out, true
end

-- the number s spells, decimal only; nil for anything else (dice, expressions, hex)
local function number(s)
    if s == nil then return nil end
    if not s:find("^%-?%d+%.?%d*$") and not s:find("^%-?%.%d+$") then return nil end
    return tonumber(s)
end

local function sign(n)
    if n < 0 then return -1 end
    if n > 0 then return 1 end
    return 0
end

-- the sign of one term with no sign of its own (magnitude cut it off), and its value when it is a
-- number: 1 for dice, ProficiencyBonus or either with a *N or /N; nil when the sign can't be told
local function term(t)
    local n = number((t:gsub("%%$", "")))
    if n ~= nil then return sign(n), n end
    local base = t:gsub("[%*/]%d+$", "")
    if base:find("^%d*d%d+$") or base == "ProficiencyBonus" then return 1 end
    return nil
end

-- the sign of a magnitude, -1, 0 or 1, and its value when every term is a number. Terms are cut at
-- top-level + and -; each is a number (20% included), dice, ProficiencyBonus or one of those two
-- with *N or /N (positive), or -<Ability>Modifier (negative). Terms that aren't numbers must agree
-- in sign, which wins over the numbers: 1d4-1 is 1. nil for anything else (a call, Level*2,
-- Cause.X, a bare <Ability>Modifier, whose sign the wearer decides)
local function magnitude(s)
    if s == nil then return nil end
    s = s:gsub("%s+", "")
    if s == "" or s:find("[%(%)]") then return nil end
    local terms, from, sg = {}, 1, 1
    local first = s:sub(1, 1)
    if first == "+" or first == "-" then sg, from = first == "-" and -1 or 1, 2 end
    for i = from, #s + 1 do
        local c = s:sub(i, i)
        if c == "+" or c == "-" or i > #s then
            local t = s:sub(from, i - 1)
            if t == "" then return nil end
            terms[#terms + 1] = { sg = sg, text = t }
            sg, from = c == "-" and -1 or 1, i + 1
        end
    end
    local sum, other = 0, nil
    for _, t in ipairs(terms) do
        local ab = t.text:match("^(%a+)Modifier$")
        local tsg, n
        if ab ~= nil and ABILITY[ab] then
            if t.sg ~= -1 then return nil end
            tsg = -1
        else
            tsg, n = term(t.text)
            if tsg == nil then return nil end
            tsg = tsg * t.sg
        end
        if n ~= nil then
            sum = sum + t.sg * n
        elseif other == nil then
            other = tsg
        elseif other ~= tsg then
            return nil
        end
    end
    if other ~= nil then return other, nil end
    return sign(sum), sum
end

local VALENCE = { [-1] = "harmful", [0] = "neutral", [1] = "beneficial" }

local function isName(s)
    return s ~= nil and s:find("^[%a_][%w_]*$") ~= nil
end

-- the roll types RollBonus adds to, by word
local ROLL = {
    Attack = "attack", MeleeWeaponAttack = "attack", RangedWeaponAttack = "attack",
    MeleeSpellAttack = "attack", RangedSpellAttack = "attack", MeleeUnarmedAttack = "attack",
    RangedUnarmedAttack = "attack", RangedOffHandWeaponAttack = "attack",
    MeleeOffHandWeaponAttack = "attack", SavingThrow = "save", DeathSavingThrow = "save",
    SkillCheck = "check", RawAbility = "check", Damage = "damage",
}

-- Resistance's second argument, by sign
local RESIST = { Vulnerable = -1, Resistant = 1, Immune = 1, ResistantToNonMagical = 1,
    ImmuneToNonMagical = 1, ResistantToMagical = 1, ImmuneToMagical = 1 }

-- CriticalHit's arguments, each a sign: whose roll, which outcome, how
local CRIT = {
    { AttackRoll = 1, AttackTarget = -1 },
    { Success = 1, Failure = -1 },
    { Always = 1, ForcedAlways = 1, Never = -1 },
}

-- each form's reader: args (trailing empty ones dropped) -> kind, sign, value, word; nil when the
-- form isn't read. A sign of -1 is harmful
local FORMS = {}

-- ActionResource(<resource>, n[, lvl[, die]]): Movement takes no die
FORMS.ActionResource = function(a)
    if not isName(a[1]) or #a < 2 or #a > 4 or (a[3] ~= nil and number(a[3]) == nil) then return nil end
    local s, v = magnitude(a[2])
    if s == nil then return nil end
    if a[1] == "Movement" then
        if #a == 4 then return nil end
        return "movement", s, v
    end
    if a[4] ~= nil and not a[4]:find("^%d*d%d+$") then return nil end
    return "combat", s, v, "resource"
end

-- the multipliers: Multiplier(<resource>, percent, lvl) and ConsumeMultiplier(<resource>, factor, lvl)
local function multiplier(a, value)
    if not isName(a[1]) or #a < 2 or #a > 3 or (a[3] ~= nil and number(a[3]) == nil) then return nil end
    local n = number(a[2])
    if n == nil then return nil end
    local v = value(n)
    if a[1] == "Movement" then return "movement", sign(v), v end
    return "combat", sign(v), v, "resource"
end
FORMS.ActionResourceMultiplier = function(a) return multiplier(a, function(n) return n - 100 end) end
FORMS.ActionResourceConsumeMultiplier = function(a) return multiplier(a, function(n) return 1 - n end) end

FORMS.ActionResourceBlock = function(a)
    if not isName(a[1]) or #a > 2 or (a[2] ~= nil and number(a[2]) == nil) then return nil end
    if a[1] == "Movement" then return "movement", -1 end
    return "combat", -1, nil, "resource"
end

FORMS.JumpMaxDistanceMultiplier = function(a)
    local n = #a == 1 and number(a[1])
    if not n then return nil end
    return "movement", sign(n - 1), n - 1
end

FORMS.JumpMaxDistanceBonus = function(a)
    if #a ~= 1 then return nil end
    local s, v = magnitude(a[1])
    if s == nil then return nil end
    return "movement", s, v
end

FORMS.MovementSpeedLimit = function(a)
    if #a ~= 1 or not isName(a[1]) then return nil end
    return "movement", -1
end

FORMS.AC = function(a)
    if #a ~= 1 then return nil end
    local s, v = magnitude(a[1])
    if s == nil then return nil end
    return "ac", s, v
end

FORMS.BlockAbilityModifierFromAC = function(a)
    if #a ~= 1 or not ABILITY[a[1]] then return nil end
    return "ac", -1
end

-- Advantage and Disadvantage: what the roll is decides the word. Disadvantage(Skill, Stealth) is
-- the stealth kind; SourceDialogue (dialogue checks) isn't read
local function edge(a, sg)
    local what = a[1]
    if (what == "AttackRoll" or what == "AttackTarget") and #a <= 2 and (a[2] == nil or isName(a[2])) then
        if what == "AttackTarget" then return "combat", -sg, nil, "targeted" end
        return "combat", sg, nil, "attack"
    elseif what == "SavingThrow" and #a == 2 and ABILITY[a[2]] then
        return "combat", sg, nil, "save"
    elseif (what == "AllSavingThrows" or what == "Concentration" or what == "DeathSavingThrow") and #a == 1 then
        return "combat", sg, nil, "save"
    elseif what == "Skill" and #a == 2 and a[2] == "Stealth" and sg < 0 then
        return "stealth", -1
    elseif (what == "Skill" or what == "Ability") and (#a == 2 or #a == 3) and isName(a[2])
        and (what == "Skill" or ABILITY[a[2]]) and (a[3] == nil or isName(a[3])) then
        return "combat", sg, nil, "check"
    elseif what == "AllAbilities" and #a <= 2 and (a[2] == nil or isName(a[2])) then
        return "combat", sg, nil, "check"
    end
    return nil
end
FORMS.Advantage = function(a) return edge(a, 1) end
FORMS.Disadvantage = function(a) return edge(a, -1) end

FORMS.RollBonus = function(a)
    local word = ROLL[a[1]]
    if word == nil or #a < 2 or #a > 3 or (a[3] ~= nil and not isName(a[3])) then return nil end
    if word == "damage" and #a ~= 2 then return nil end
    local s, v = magnitude(a[2])
    if s == nil then return nil end
    return "combat", s, v, word
end

-- the boosts that are one magnitude (after a name, when lead) and at most `max` more arguments,
-- each a name, a number or empty; flip makes a positive one harmful
local MAG = {
    Skill = { word = "check", lead = true, max = 0 },
    Initiative = { word = "initiative", max = 0 },
    WeaponAttackRollBonus = { word = "attack", max = 0 },
    WeaponEnchantment = { word = "attack", max = 0 },
    DamageBonus = { word = "damage", max = 2 },
    CharacterWeaponDamage = { word = "damage", max = 1 },
    CharacterUnarmedDamage = { word = "damage", max = 1 },
    WeaponDamage = { word = "damage", max = 2 },
    IncreaseMaxHP = { word = "hp", max = 0 },
    SpellSaveDC = { word = "spell", max = 0 },
    ReduceCriticalAttackThreshold = { word = "crit", max = 99 },
    DamageTakenBonus = { word = "vulnerable", max = 2, flip = true },
}
for name, m in pairs(MAG) do
    FORMS[name] = function(a)
        local at = m.lead and 2 or 1
        if m.lead and not isName(a[1]) then return nil end
        if #a < at or #a > at + m.max then return nil end
        -- the trailing arguments: a damage type (possibly empty: DamageBonus(1,,false)), a flag or N
        for i = at + 1, #a do
            if a[i] ~= "" and not isName(a[i]) and number(a[i]) == nil then return nil end
        end
        local s, v = magnitude(a[at])
        if s == nil then return nil end
        if m.flip then return "combat", -s, v, m.word end
        return "combat", s, v, m.word
    end
end

FORMS.Resistance = function(a)
    local s = #a == 2 and isName(a[1]) and RESIST[a[2]]
    if not s then return nil end
    return "combat", s, nil, "vulnerable"
end

FORMS.CriticalHit = function(a)
    if #a < 3 or #a > 4 or (a[4] ~= nil and number(a[4]) == nil) then return nil end
    local s = 1
    for i, signs in ipairs(CRIT) do
        local x = signs[a[i]]
        if x == nil then return nil end
        s = s * x
    end
    return "combat", s, nil, "crit"
end

FORMS.HalveWeaponDamage = function(a)
    if #a ~= 1 or not isName(a[1]) then return nil end
    return "combat", -1, nil, "damage"
end

FORMS.AbilityFailedSavingThrow = function(a)
    if #a ~= 1 or not ABILITY[a[1]] then return nil end
    return "combat", -1, nil, "save"
end

-- BlockRegainHP() blocks all healing; with creature types (Undead;Construct) it isn't read
FORMS.BlockRegainHP = function(a)
    if #a ~= 0 then return nil end
    return "combat", -1, nil, "hp"
end

FORMS.BlockSpellCast = function(a)
    if #a ~= 0 then return nil end
    return "combat", -1, nil, "spell"
end
FORMS.BlockVerbalComponent = FORMS.BlockSpellCast

-- Ability(<ability>, n[, N[, true|false]])
FORMS.Ability = function(a)
    if not ABILITY[a[1]] or #a < 2 or #a > 4 then return nil end
    if a[3] ~= nil and number(a[3]) == nil then return nil end
    if a[4] ~= nil and a[4] ~= "true" and a[4] ~= "false" then return nil end
    local s, v = magnitude(a[2])
    if s == nil then return nil end
    return "ability", s, v
end

-- an AC formula that replaces the armor's (Unarmored Defense, Draconic Resilience): never harmful,
-- and never weighed against the AC an item gives (D37)
FORMS.ACOverrideFormula = function(a)
    if #a < 2 or (a[2] ~= "true" and a[2] ~= "false") then return nil end
    local n = number(a[1])
    for i = 3, #a do
        if not ABILITY[a[i]] then return nil end
    end
    if n == nil then return nil end
    return "ac_override", 1, n
end

FORMS.ArmorAbilityModifierCapOverride = function(a)
    local n = #a == 2 and isName(a[1]) and number(a[2])
    if not n then return nil end
    return "cap_override", 0, n
end

-- what one boost's body (no guard) does: see the header
function B.Classify(body)
    local out = { confidence = "unknown", raw = body }
    if type(body) ~= "string" then return out end
    local name, inner = body:match("^([%a_][%w_]*)%s*%((.*)%)$")
    if name == nil then return out end
    out.name = name
    local args = cut(inner, ",")
    if args == nil then return out end
    -- a trailing empty argument is a slip in the stats (Advantage(DeathSavingThrow,)), as is the
    -- one empty argument of a call with none (BlockRegainHP())
    while #args > 0 and args[#args] == "" do args[#args] = nil end
    local form = FORMS[name]
    local kind, s, value, word
    if form ~= nil then kind, s, value, word = form(args) end
    if kind == nil then return out end
    out.kind, out.valence, out.value, out.word = kind, VALENCE[s], value, word
    if kind == "ability" then out.ability = args[1] end
    if kind == "cap_override" then out.armorType = args[1] end
    out.confidence, out.target = "known", "wearer"
    return out
end

-- a passive's effects, from its Boosts and BoostConditions texts: { effects, cond, condError,
-- balanced }. Each effect is Classify's table plus cond, the tree that must hold for it to apply
-- (BoostConditions and its IF guard together), guardError when its guard didn't parse, and
-- charDependent, condUnknown and hasPred, CondParse's CharDependent, HasUnknown and HasPred of cond.
-- conditions nil is no condition; any other value that is not text is an unknown one
function B.Passive(boosts, conditions)
    local cond, condError = CP.Parse(conditions == nil and "" or conditions)
    local list, balanced = B.Split(boosts)
    local out = { effects = {}, cond = cond, condError = condError, balanced = balanced }
    for _, b in ipairs(list) do
        local e = B.Classify(b.body)
        e.raw = b.raw
        e.cond = cond
        if b.guard ~= nil then
            local g, gErr = CP.Parse(b.guard)
            e.cond, e.guardError = CP.And(cond, g), gErr
        end
        e.charDependent, e.condUnknown = CP.CharDependent(e.cond), CP.HasUnknown(e.cond)
        e.hasPred = CP.HasPred(e.cond)
        out.effects[#out.effects + 1] = e
    end
    return out
end
