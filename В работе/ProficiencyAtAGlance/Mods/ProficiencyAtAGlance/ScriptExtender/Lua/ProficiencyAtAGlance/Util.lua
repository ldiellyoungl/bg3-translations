-- small helpers, no dependencies. Errors go to PaG.Log once it's loaded, straight to the console
-- before that.
local U = {}
PaG.Util = U

local NULL_GUID = "00000000-0000-0000-0000-000000000000"

local startTime = Ext.Timer.MonotonicTime()
local ticks = 0

-- ms since this file loaded
function U.Now()
    return Ext.Timer.MonotonicTime() - startTime
end

function U.Tick() ticks = ticks + 1 end
function U.Ticks() return ticks end

local function report(label, err, n)
    local L = PaG.Log
    if L then
        L.Error(label, err, n)
    else
        Ext.Utils.PrintWarning("[PaG] " .. label .. ": " .. tostring(err))
    end
end

-- pcall that reports every failure. Bounded paths only (load, attach, console commands); anything
-- that repeats wants Guard
function U.Try(label, fn, ...)
    local res = table.pack(pcall(fn, ...))
    if res[1] then return table.unpack(res, 2, res.n) end
    report(label, res[2])
    return nil
end

-- pcall for repeating paths (ticks, entity change callbacks). Reports the first REPORT_LIMIT faults
-- for a label, then latches it off and skips it from then on.
-- returns (first result, true), or (nil, false) on a fault or once latched
local REPORT_LIMIT = 2
local failures = {}

function U.Guard(label, fn, ...)
    local rec = failures[label]
    if rec and rec.tripped then
        rec.n = rec.n + 1
        return nil, false
    end
    local ok, res = pcall(fn, ...)
    if ok then return res, true end
    if rec == nil then
        rec = { n = 0, err = tostring(res) }
        failures[label] = rec
    end
    rec.n = rec.n + 1
    report(label, tostring(res), rec.n)
    if rec.n >= REPORT_LIMIT then
        rec.tripped = true
        report(label, "disabled after " .. REPORT_LIMIT .. " faults")
    end
    return nil, false
end

-- the labels latched off after REPORT_LIMIT faults, sorted
function U.Latched()
    local list = {}
    for label, rec in pairs(failures) do
        if rec.tripped then list[#list + 1] = label end
    end
    table.sort(list)
    return list
end

-- !pag_bump and each world load: forget every fault, so a latched guard runs again. Returns the
-- labels that were latched
function U.ResetGuards()
    local list = U.Latched()
    failures = {}
    return list
end

-- pcall that returns the first result, or nil on error. For engine reads, where "unknown" is data
function U.Get(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

function U.Field(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[name] end)
    if ok then return v end
    return nil
end

-- engine arrays are userdata: pairs() walks them, # and ipairs aren't reliable. Returns list, n
function U.ToList(v)
    if v == nil then return nil end
    local out, n = {}, 0
    local ok = pcall(function()
        for _, x in pairs(v) do n = n + 1; out[n] = x end
    end)
    if not ok then return nil end
    return out, n
end

function U.Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- the first uuid anywhere in s, lowercased; nil if there is none or it is the null guid. Unanchored,
-- because an id, read from the UI's data or from an entity, arrives in whatever format the engine
-- prints
local UUID_ANY = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
function U.FindUuid(s)
    if s == nil then return nil end
    local m = tostring(s):match(UUID_ANY)
    if m == nil or m == NULL_GUID then return nil end
    return m:lower()
end

local function trim(s)
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- a stats list field as a list of names. SE gives some as tables or bitfields (flags, enumerations)
-- and some as ";"-separated strings (PassivesOnEquip, StatusOnEquip). Empty entries are dropped.
-- Never use it on Boosts: a boost's own arguments contain commas and parentheses
function U.Names(v)
    local out = {}
    if v == nil then return out end
    if type(v) == "string" then
        for part in v:gmatch("[^;]+") do
            local s = trim(part)
            if s ~= "" then out[#out + 1] = s end
        end
        return out
    end
    local labels = U.Field(v, "__Labels")
    if labels ~= nil then v = labels end
    pcall(function()
        for k, x in pairs(v) do
            -- a set ({Name = true}) gives its keys, a list or bitfield its values
            local name = (x == true and type(k) == "string") and k or x
            if type(name) ~= "boolean" then
                local s = trim(name)
                if s ~= "" then out[#out + 1] = s end
            end
        end
    end)
    return out
end

function U.Set(list)
    local out = {}
    for _, x in ipairs(list or {}) do out[x] = true end
    return out
end

function U.Keys(set)
    local out = {}
    for k in pairs(set or {}) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return out
end

function U.ToJson(v, depth)
    local ok, s = pcall(Ext.Json.Stringify, v, {
        Beautify = false, StringifyInternalTypes = true, IterateUserdata = true, AvoidRecursion = true,
        MaxDepth = depth or 6,
    })
    if ok then return s end
    return nil
end

-- Stringify refuses most engine userdata and you lose every field, so walk it by hand: pairs()
-- where the object allows it, else the member list from the type registry
local MAX_FLAT_KEYS = 120
local memberCache = {}

local function membersOf(typeName)
    if memberCache[typeName] ~= nil then return memberCache[typeName] end
    local list = {}
    pcall(function()
        local out = {}
        for k in pairs(Ext.Types.GetTypeInfo(typeName).Members) do out[#out + 1] = tostring(k) end
        if #out > 0 then table.sort(out); list = out end
    end)
    memberCache[typeName] = list
    return list
end

local function typeOf(v)
    local ok, n = pcall(Ext.Types.GetObjectType, v)
    if ok and n ~= nil and tostring(n) ~= "" then return tostring(n) end
    return nil
end

local function flatten(v, depth)
    local t = type(v)
    if v == nil or t == "number" or t == "boolean" or t == "string" then return v end
    if t == "function" or t == "thread" or depth <= 0 then return tostring(v) end

    local out, n = {}, 0
    local function put(k, x)
        if n >= MAX_FLAT_KEYS then return end
        n = n + 1
        out[tostring(k)] = flatten(x, depth - 1)
    end
    if t == "table" then
        for k, x in pairs(v) do put(k, x) end
        return out
    end

    local typeName = typeOf(v)
    local iterated = pcall(function()
        for k, x in pairs(v) do put(k, x) end
    end)
    if (not iterated or n == 0) and typeName then
        for _, k in ipairs(membersOf(typeName)) do
            local ok, x = pcall(function() return v[k] end)
            if ok then put(k, x) end
        end
    end
    if n == 0 then return { __unencodable = tostring(v), __type = typeName } end
    out.__type = typeName
    return out
end

-- JSON-safe copy of anything: a JSON round trip when it encodes, else the hand walk above
function U.Safe(v, depth)
    local s = U.ToJson(v, depth)
    if s then
        local ok, parsed = pcall(Ext.Json.Parse, s)
        if ok then return parsed end
    end
    return flatten(v, depth or 5)
end

function U.Environment()
    local env = {
        se = U.Get(Ext.Utils.Version),
        game = U.Get(Ext.Utils.GameVersion),
    }
    env.loadOrder = U.Get(function()
        local list = {}
        for _, uuid in ipairs(Ext.Mod.GetLoadOrder()) do
            local m = Ext.Mod.GetMod(uuid)
            list[#list + 1] = tostring(m and m.Info and m.Info.Name or "?") .. " [" .. uuid .. "]"
        end
        return list
    end)
    return env
end
