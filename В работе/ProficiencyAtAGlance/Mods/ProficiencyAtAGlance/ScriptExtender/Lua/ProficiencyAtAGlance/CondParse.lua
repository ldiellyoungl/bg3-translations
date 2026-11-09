-- Pure-data parser for the part of the stats condition language that detected drawbacks and lost
-- benefits read (both causes in Rules.lua): a passive's BoostConditions and a boost's IF(...)
-- guard. Never `load`: the text comes from any mod's stats. Parse(text) always returns a tree,
-- never raises:
--   { k = "const", v = true|false }     empty text (no condition), or the words true and false
--   { k = "ability", ability, op, n }   context.Source.<Ability> <op> N, bare or in ConditionResult();
--                                       also IsCharismaModifierPositive() (Charisma >= 12) and
--                                       CharismaGreaterThan(N) (Charisma > N)
--   { k = "abcmp", a, op, b }           context.Source.<A> <op> context.Source.<B>, and
--                                       IsDexterityGreaterThanStrength() (Dexterity >= Strength)
--   { k = "tag", tag }                  Tagged('X') or Tagged('X', context.Source)
--   { k = "passive", name }             HasPassive('X'), the same way
--   { k = "prof", name }                HasProficiency('X'), the same way
--   { k = "pred", name }                WearingArmor, HasShieldEquipped, HasHeavyArmor or
--                                       IsOffHandSlotEmpty, with no argument or context.Source
--   { k = "situ", text }                a term about the moment, not the wearer or what is worn:
--                                       the attack (IsMeleeAttack, HasWeaponProperty...), a status,
--                                       combat, sunlight, the target's distance, a toggled feat
--                                       (GreatWeaponMaster, Sharpshooter), or any call with a
--                                       context.Target argument. Any of them can hold on some turn
--                                       (CondEval reads it so)
--   { k = "not", x }, { k = "and", a, b }, { k = "or", a, b }
--   { k = "unknown", text }             anything else; text is its source, for the log
-- A syntax error makes the whole condition one unknown node. A bare Tagged('X') is read as the
-- wearer's tag (inferred: the game's condition scripts default the entity to context.Source), and
-- the same for HasPassive and HasProficiency
local P = {}
PaG.CondParse = P

local ABILITY = { Strength = true, Dexterity = true, Constitution = true, Intelligence = true,
    Wisdom = true, Charisma = true }
local PRED = { WearingArmor = true, HasShieldEquipped = true, HasHeavyArmor = true,
    IsOffHandSlotEmpty = true }
-- the calls that test the moment rather than the wearer: the attack being made, a status, combat,
-- light, the target's distance, a feat's toggle. The last line's are the ones vanilla and the mod
-- corpus put in harmful boosts' conditions (2026-10-19)
local SITU = { IsMeleeAttack = true, IsRangedAttack = true, IsWeaponAttack = true, IsSpellAttack = true,
    IsUnarmedAttack = true, IsAttack = true, IsMeleeWeaponAttack = true, IsRangedWeaponAttack = true,
    IsAttackType = true, IsCritical = true, IsMeleeUnarmedAttack = true, IsRangedUnarmedAttack = true,
    SpellAttackCheck = true, AttackingWithMeleeWeapon = true, AttackingWithRangedWeapon = true,
    HasWeaponProperty = true, HasDamageEffectFlag = true, HasStatus = true, Combat = true,
    IsInSunlight = true, IsConcentrating = true,
    TurnBased = true, IsReactionAttack = true, WeaponAttackRollAbility = true, HasObscuredState = true,
    DistanceToTargetGreaterThan = true, GreatWeaponMaster = true, Sharpshooter = true }
-- the one-string calls about the wearer, by node kind
local NAMED = { Tagged = "tag", HasPassive = "passive", HasProficiency = "prof" }
local RELOP = { ["<"] = true, ["<="] = true, [">"] = true, [">="] = true, ["=="] = true,
    ["~="] = true, ["!="] = true }
-- the operator that keeps a comparison true with its sides swapped: 13 > x is x < 13
local FLIP = { ["<"] = ">", ["<="] = ">=", [">"] = "<", [">="] = "<=", ["=="] = "==", ["~="] = "~=" }
local WORD = { ["and"] = true, ["or"] = true, ["not"] = true }
local MAX_LEN, MAX_DEPTH = 4000, 64

-- the tokens of s, each { t, v, s, e }: t is "name", "num", "str", "op" or "eof"; s and e are its
-- span. nil and a message when s has a character the language doesn't use or an open quote
local function tokenize(s)
    local out, i, n = {}, 1, #s
    while true do
        i = s:find("%S", i) or n + 1
        if i > n then break end
        local c = s:sub(i, i)
        local name = s:match("^[%a_][%w_]*", i)
        local num = s:match("^%d+%.?%d*", i) or s:match("^%.%d+", i)
        if name then
            out[#out + 1] = { t = "name", v = name, s = i, e = i + #name - 1 }
            i = i + #name
        elseif num then
            local v = tonumber(num)
            if v == nil then return nil, "bad number at " .. i end
            out[#out + 1] = { t = "num", v = v, s = i, e = i + #num - 1 }
            i = i + #num
        elseif c == "'" or c == '"' then
            local close = s:find(c, i + 1, true)
            if close == nil then return nil, "open quote at " .. i end
            out[#out + 1] = { t = "str", v = s:sub(i + 1, close - 1), s = i, e = close }
            i = close + 1
        else
            local two = s:sub(i, i + 1)
            if RELOP[two] then
                out[#out + 1] = { t = "op", v = two, s = i, e = i + 1 }
                i = i + 2
            elseif c:find("^[%(%)%.,<>%+%-%*/]") then
                out[#out + 1] = { t = "op", v = c, s = i, e = i }
                i = i + 1
            else
                return nil, "unexpected '" .. c .. "' at " .. i
            end
        end
    end
    out[#out + 1] = { t = "eof", v = "", s = n + 1, e = n }
    return out
end

-- the raw tree, before its leaves are read: each node { r, s, e, ... } spans s..e of the text.
-- r is "or", "and" or "not" (a, b, x), "cmp" (op, a, b), "arith" (op, a, b), "neg" (x), "num"
-- (v), "str" (v), "path" (parts) or "call" (name, args). Errors raise a table { msg }, caught in
-- P.Parse, so the descent stays flat
local function parser(toks)
    local pos, depth = 1, 0
    local function peek() return toks[pos] end
    local function fail(msg) error({ msg = msg }, 0) end
    local function take(t, v)
        local tok = toks[pos]
        if tok.t ~= t or (v ~= nil and tok.v ~= v) then
            fail("expected " .. (v or t) .. " at " .. tok.s .. ", got '" .. tok.v .. "'")
        end
        pos = pos + 1
        return tok
    end
    local function isOp(v) local tok = toks[pos]; return tok.t == "op" and tok.v == v end
    local function isWord(v) local tok = toks[pos]; return tok.t == "name" and tok.v == v end
    local expr
    local function enter()
        depth = depth + 1
        if depth > MAX_DEPTH then fail("nested too deep") end
    end
    local function primary()
        local tok = peek()
        if isOp("(") then
            pos = pos + 1
            enter()
            local x = expr()
            depth = depth - 1
            local close = take("op", ")")
            x.s, x.e = tok.s, close.e
            return x
        elseif tok.t == "num" or tok.t == "str" then
            pos = pos + 1
            return { r = tok.t, v = tok.v, s = tok.s, e = tok.e }
        elseif tok.t == "name" and not WORD[tok.v] then
            pos = pos + 1
            if isOp("(") then
                pos = pos + 1
                local args = {}
                if not isOp(")") then
                    enter()
                    args[1] = expr()
                    while isOp(",") do
                        pos = pos + 1
                        args[#args + 1] = expr()
                    end
                    depth = depth - 1
                end
                local close = take("op", ")")
                return { r = "call", name = tok.v, args = args, s = tok.s, e = close.e }
            end
            local parts, e = { tok.v }, tok.e
            while isOp(".") do
                pos = pos + 1
                local part = take("name")
                parts[#parts + 1], e = part.v, part.e
            end
            return { r = "path", parts = parts, s = tok.s, e = e }
        end
        fail("unexpected '" .. tok.v .. "' at " .. tok.s)
    end
    local function unary()
        if isOp("-") then
            local tok = take("op")
            enter()
            local x = unary()
            depth = depth - 1
            return { r = "neg", x = x, s = tok.s, e = x.e }
        end
        return primary()
    end
    local function binary(side, ops)
        return function()
            local a = side()
            while peek().t == "op" and ops[peek().v] do
                local op = take("op").v
                local b = side()
                a = { r = "arith", op = op, a = a, b = b, s = a.s, e = b.e }
            end
            return a
        end
    end
    local term = binary(unary, { ["*"] = true, ["/"] = true })
    local sum = binary(term, { ["+"] = true, ["-"] = true })
    local function cmp()
        local a = sum()
        if peek().t == "op" and RELOP[peek().v] then
            local op = take("op").v
            local b = sum()
            return { r = "cmp", op = op == "!=" and "~=" or op, a = a, b = b, s = a.s, e = b.e }
        end
        return a
    end
    local function notExpr()
        if isWord("not") then
            local tok = take("name")
            enter()
            local x = notExpr()
            depth = depth - 1
            return { r = "not", x = x, s = tok.s, e = x.e }
        end
        return cmp()
    end
    local function chain(side, word)
        return function()
            local a = side()
            while isWord(word) do
                pos = pos + 1
                local b = side()
                a = { r = word, a = a, b = b, s = a.s, e = b.e }
            end
            return a
        end
    end
    expr = chain(chain(notExpr, "and"), "or")
    return function()
        local x = expr()
        take("eof")
        return x
    end
end

-- "Strength" when node is context.Source.Strength (any ability), else nil
local function abilityOf(node)
    local p = node.r == "path" and node.parts
    if not p or #p ~= 3 or p[1] ~= "context" or p[2] ~= "Source" then return nil end
    return ABILITY[p[3]] and p[3] or nil
end

local function isSource(node)
    local p = node.r == "path" and node.parts
    return p and #p == 2 and p[1] == "context" and p[2] == "Source" or false
end

-- true when node is context.Target or a field of it
local function isTarget(node)
    local p = node.r == "path" and node.parts
    return p and #p >= 2 and p[1] == "context" and p[2] == "Target" or false
end

-- true when args are none, or the one context.Source
local function onSource(args)
    return #args == 0 or (#args == 1 and isSource(args[1]))
end

-- the number a node is: a literal, or a negated one
local function numberOf(node)
    if node.r == "num" then return node.v end
    if node.r == "neg" and node.x.r == "num" then return -node.x.v end
    return nil
end

-- the condition tree of a raw node in a true/false position
local function read(src, node)
    local function unknown() return { k = "unknown", text = src:sub(node.s, node.e) } end
    local r = node.r
    if r == "and" or r == "or" then
        return { k = r, a = read(src, node.a), b = read(src, node.b) }
    elseif r == "not" then
        return { k = "not", x = read(src, node.x) }
    elseif r == "cmp" then
        local a, b = abilityOf(node.a), abilityOf(node.b)
        if a ~= nil and b ~= nil then return { k = "abcmp", a = a, op = node.op, b = b } end
        local ab, n, op = a, numberOf(node.b), node.op
        if ab == nil then ab, n, op = b, numberOf(node.a), FLIP[node.op] end
        if ab ~= nil and n ~= nil and op ~= nil then return { k = "ability", ability = ab, op = op, n = n } end
        return unknown()
    elseif r == "path" then
        if #node.parts == 1 and (node.parts[1] == "true" or node.parts[1] == "false") then
            return { k = "const", v = node.parts[1] == "true" }
        end
        return unknown()
    elseif r == "call" then
        local name, args = node.name, node.args
        if name == "ConditionResult" and #args == 1 then return read(src, args[1]) end
        for _, x in ipairs(args) do
            if isTarget(x) then return { k = "situ", text = src:sub(node.s, node.e) } end
        end
        if SITU[name] then return { k = "situ", text = src:sub(node.s, node.e) } end
        local kind = NAMED[name]
        if kind and args[1] and args[1].r == "str" and args[1].v ~= ""
            and (#args == 1 or (#args == 2 and isSource(args[2]))) then
            if kind == "tag" then return { k = "tag", tag = args[1].v } end
            return { k = kind, name = args[1].v }
        end
        if PRED[name] and onSource(args) then return { k = "pred", name = name } end
        if name == "IsDexterityGreaterThanStrength" and onSource(args) then
            return { k = "abcmp", a = "Dexterity", op = ">=", b = "Strength" }
        end
        if name == "IsCharismaModifierPositive" and onSource(args) then
            return { k = "ability", ability = "Charisma", op = ">=", n = 12 }
        end
        local n = args[1] and numberOf(args[1])
        if name == "CharismaGreaterThan" and n ~= nil and (#args == 1 or (#args == 2 and isSource(args[2]))) then
            return { k = "ability", ability = "Charisma", op = ">", n = n }
        end
        return unknown()
    end
    return unknown()
end

-- the condition tree of text (see the header); a second value names a syntax error, for the log
function P.Parse(text)
    if type(text) ~= "string" then return { k = "unknown", text = tostring(text) }, "not text" end
    -- some vanilla conditions end in ';' (Passive.txt "Combat();")
    local src = text:gsub("[%s;]+$", ""):gsub("^%s+", "")
    if src == "" then return { k = "const", v = true } end
    if #src > MAX_LEN then return { k = "unknown", text = src:sub(1, 80) .. "..." }, "too long" end
    local toks, err = tokenize(src)
    if toks == nil then return { k = "unknown", text = src }, err end
    local run = parser(toks)
    local ok, tree = pcall(function() return read(src, run()) end)
    if not ok then
        return { k = "unknown", text = src }, type(tree) == "table" and tree.msg or tostring(tree)
    end
    return tree
end

-- true when the tree reads the wearer's abilities, tags, passives or proficiencies: the
-- conditions only some wearers meet (design D36). Equipment predicates and the moment alone don't
-- count
function P.CharDependent(t)
    local k = t.k
    if k == "ability" or k == "tag" or k == "passive" or k == "prof" or k == "abcmp" then return true end
    if k == "and" or k == "or" then return P.CharDependent(t.a) or P.CharDependent(t.b) end
    if k == "not" then return P.CharDependent(t.x) end
    return false
end

-- true when the tree reads an equipment predicate: the conditions what is worn can change
-- (lost benefits)
function P.HasPred(t)
    local k = t.k
    if k == "pred" then return true end
    if k == "and" or k == "or" then return P.HasPred(t.a) or P.HasPred(t.b) end
    if k == "not" then return P.HasPred(t.x) end
    return false
end

-- true when the tree has an unknown node
function P.HasUnknown(t)
    local k = t.k
    if k == "unknown" then return true end
    if k == "and" or k == "or" then return P.HasUnknown(t.a) or P.HasUnknown(t.b) end
    if k == "not" then return P.HasUnknown(t.x) end
    return false
end

-- both conditions at once: a passive's BoostConditions and a boost's IF guard
function P.And(a, b)
    if a.k == "const" and a.v == true then return b end
    if b.k == "const" and b.v == true then return a end
    return { k = "and", a = a, b = b }
end

-- the tree as one line for the log: Strength<13 and not tag:DWARF
function P.Show(t)
    local k = t.k
    if k == "const" then return tostring(t.v) end
    if k == "ability" then return t.ability .. t.op .. tostring(t.n) end
    if k == "abcmp" then return t.a .. t.op .. t.b end
    if k == "tag" then return "tag:" .. t.tag end
    if k == "passive" then return "passive:" .. t.name end
    if k == "prof" then return "prof:" .. t.name end
    if k == "pred" then return t.name .. "()" end
    if k == "situ" then return "~" .. t.text end
    if k == "not" then
        local x = t.x.k
        return (x == "and" or x == "or") and "not (" .. P.Show(t.x) .. ")" or "not " .. P.Show(t.x)
    end
    if k == "and" or k == "or" then
        local function side(x)
            local s = P.Show(x)
            return (x.k == "and" or x.k == "or") and x.k ~= k and "(" .. s .. ")" or s
        end
        return side(t.a) .. " " .. k .. " " .. side(t.b)
    end
    return "?{" .. t.text .. "}"
end
