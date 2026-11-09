-- Pure-data evaluator for CondParse's trees, in three values: true, false, or nil when it can't
-- tell (an unknown node, or a read env couldn't make). Each node has two such values: can it hold,
-- and can it fail. A term about the wearer or what is worn is one or the other; a term about the
-- moment (situ: the attack being made, a status) can do both. not swaps them; and can hold when
-- both sides can (Kleene's and) and can fail when either can (Kleene's or); or the other way round.
-- With no situ term, can-hold is the Kleene value of the tree. Eval(tree, env) returns can-hold and,
-- when nil, a reason: "unknown" (the text has a part CondParse can't read) or "read" (env couldn't
-- read an ability, tag, passive, proficiency or equipment predicate this time). env supplies
--   ability(name)  the wearer's score, or nil
--   tagged(tag)    true or false, or nil
--   passive(name)  true or false, or nil (optional: a missing one is a failed read)
--   prof(name)     true or false, or nil (optional, the same)
--   pred(name)     WearingArmor, HasShieldEquipped, HasHeavyArmor or IsOffHandSlotEmpty with the
--                  item in, or nil
-- tagged, passive, prof and pred may also return the string "unknown": a term no read can settle
-- (HasProficiency with a name that isn't a proficiency group), which counts as an unknown node.
local V = {}
PaG.CondEval = V

local CMP = {
    ["<"] = function(a, b) return a < b end, ["<="] = function(a, b) return a <= b end,
    [">"] = function(a, b) return a > b end, [">="] = function(a, b) return a >= b end,
    ["=="] = function(a, b) return a == b end, ["~="] = function(a, b) return a ~= b end,
}

-- a boolean, or nil; anything else env returns counts as a failed read
local function bool(v)
    if v == true or v == false then return v end
    return nil
end

-- "unknown" outranks "read": a fresh read can't settle text that can't be read
local function worse(r1, r2)
    if r1 == "unknown" or r2 == "unknown" then return "unknown" end
    return r1 or r2
end

local function kand(x, y)
    if x == false or y == false then return false end
    if x == nil or y == nil then return nil end
    return true
end

local function kor(x, y)
    if x == true or y == true then return true end
    if x == nil or y == nil then return nil end
    return false
end

-- a term that is one value: can hold, can fail, and the reason when it is nil
local function definite(v, why)
    if v == nil then return nil, nil, why or "read" end
    return v, not v
end

-- env's answer; the string "unknown" says no read could ever settle the term
local function call(env, field, arg)
    local f = env[field]
    if type(f) ~= "function" then return nil end
    local v = f(arg)
    if v == "unknown" then return nil, "unknown" end
    return bool(v)
end

local eval
eval = function(t, env)
    local k = t.k
    if k == "const" then return t.v, not t.v end
    if k == "ability" then
        local score, cmp = env.ability(t.ability), CMP[t.op]
        if cmp == nil then return nil, nil, "unknown" end
        if type(score) ~= "number" then return nil, nil, "read" end
        return definite(cmp(score, t.n))
    end
    if k == "abcmp" then
        local a, b, cmp = env.ability(t.a), env.ability(t.b), CMP[t.op]
        if cmp == nil then return nil, nil, "unknown" end
        if type(a) ~= "number" or type(b) ~= "number" then return nil, nil, "read" end
        return definite(cmp(a, b))
    end
    if k == "tag" then return definite(call(env, "tagged", t.tag)) end
    if k == "passive" then return definite(call(env, "passive", t.name)) end
    if k == "prof" then return definite(call(env, "prof", t.name)) end
    if k == "pred" then return definite(call(env, "pred", t.name)) end
    if k == "situ" then return true, true end
    if k == "not" then
        local h, f, why = eval(t.x, env)
        return f, h, why
    end
    if k == "and" or k == "or" then
        local hold, fail = kand, kor
        if k == "or" then hold, fail = kor, kand end
        local ah, af, ra = eval(t.a, env)
        -- a side that decides alone: and can't hold when a side can't; or can't fail when a side can't
        if k == "and" and ah == false then return false, true end
        if k == "or" and af == false then return true, false end
        local bh, bf, rb = eval(t.b, env)
        local h, f = hold(ah, bh), fail(af, bf)
        if h == nil or f == nil then return h, f, worse(ra, rb) end
        return h, f
    end
    return nil, nil, "unknown"
end

-- can the tree hold: true, false, or nil and a reason (see the header)
function V.Eval(t, env)
    local h, _, why = eval(t, env)
    if h == nil then return nil, why or "unknown" end
    return h
end
