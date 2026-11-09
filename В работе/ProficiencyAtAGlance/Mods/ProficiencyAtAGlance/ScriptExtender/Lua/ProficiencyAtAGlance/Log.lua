-- levels, from the `debug_level` setting:
--
--   off      the banner, warnings and errors on the console (shipped default). No log files
--   basic    + JSONL records in Script Extender/ProficiencyAtAGlance/client_sNNN_pN.jsonl, one file
--            set per client Lua state: a new one starts at each save load and each Lua reset, and
--            sNNN counts on across launches. Sized for opening inventories: attach steps and
--            read-path probes once per world load, a character snapshot when built or changed, one
--            aggregate row per burst of judging and rendering and never one per cell (with the first
--            example of each new (character, tier, reason, slot)), one row per generation move
--            (rules, looks or a character), and one row per run of settings changes. Plus one
--            console line per burst
--   verbose  + up to Hub's SAMPLES_PER_BURST single-judgment rows per burst
--
-- Warnings and errors print at every level, since they mean something's wrong rather than something
-- happened. Each kind prints once, so a broken read can't flood the console. They only reach the
-- file when the file is on.
--
-- Ext.IO.SaveFile can't append, so a part is buffered and rewritten whole at most every FLUSH_MS,
-- and rolls over to a new part at PART_BYTES. A flush costs more as its part grows: with 1 MiB parts,
-- most Ticks that flushed a part past about 400 KB crossed SE's 2 ms slow line (s062), so parts are
-- kept small. The session number is taken on the first write. Adapted from Auto Disarm's Log.lua
local U, E = PaG.Util, PaG.Enums
local L = {}
PaG.Log = L

local DIR = "ProficiencyAtAGlance/"
local PART_BYTES = 128 * 1024
local FLUSH_MS = 250

L.LEVELS = { [E.Level.Off] = 0, [E.Level.Basic] = 1, [E.Level.Verbose] = 2 }

local level = L.LEVELS[E.Level.Off]
local session, part, file = nil, 1, nil
local lines, bytes, pending, lastFlush, seq = {}, 0, 0, 0, 0

-- keys already written by L.Once (cleared each world load) and printed by L.WarnOnce (once per Lua
-- state: a new one at each save load)
local once, warned = {}, {}

-- Hub sets PaG.InDefer while an Ext.UI.Defer callback runs. A callback queues its rows with Hub's
-- dlog and Tick writes them, so file saves stay off the UI update and no row carries a Noesis handle
-- past the callback. Every writer and printer below refuses to run inside one
local function noDefer()
    if PaG.InDefer then error("PaG: L.* inside Ext.UI.Defer; use dlog", 3) end
end

local function fileName()
    return string.format("%sclient_s%03d_p%d.jsonl", DIR, session, part)
end

-- a failed write is reported once per file, on the console only: L.Warn would write again
local failed = {}

-- Later writes still try: each flush rewrites the whole part, so the next one that works recovers it
local function save(path, text, note)
    local ok, res = pcall(Ext.IO.SaveFile, path, text)
    if ok and res ~= false then return true end
    if not failed[path] then
        failed[path] = true
        Ext.Utils.PrintWarning("[PaG] could not write Script Extender/" .. path .. ": "
            .. (ok and "SaveFile returned false" or tostring(res)) .. (note or ""))
    end
    return false
end

local function open()
    local path = DIR .. "session_client.txt"
    session = (tonumber(U.Get(Ext.IO.LoadFile, path) or "") or 0) + 1
    save(path, tostring(session), " (the next session may reuse this number)")
    part = 1
    file = fileName()
    Ext.Utils.Print("[PaG] logging to Script Extender/" .. file)
end

function L.File() return file end
function L.Level() return level end
function L.Basic() return level >= L.LEVELS[E.Level.Basic] end
function L.Verbose() return level >= L.LEVELS[E.Level.Verbose] end

function L.Flush(force)
    noDefer()
    if pending == 0 then return end
    local now = U.Now()
    if not force and now - lastFlush < FLUSH_MS then return end
    lastFlush = now
    pending = 0
    save(file, table.concat(lines))
end

-- flush on the way down, so turning logging off doesn't lose what's already buffered
function L.SetLevel(name)
    local want = L.LEVELS[name]
    if want == nil or want == level then return level end
    if want < level then L.Flush(true) end
    level = want
    return level
end

function L.OnTick()
    L.Flush(false)
end

-- kind: an E.LogKind value
function L.Write(kind, name, data)
    noDefer()
    if level < L.LEVELS[E.Level.Basic] then return end
    if session == nil then open() end
    seq = seq + 1
    local rec = { seq = seq, t = U.Now(), tk = U.Ticks(), ctx = "client", kind = kind, name = name }
    if data ~= nil then rec.d = U.Safe(data) end -- not and/or: that drops a false
    local s = U.ToJson(rec, 8)
        or U.ToJson({ seq = seq, t = rec.t, ctx = "client", kind = E.LogKind.Error, name = name,
                      d = { unencodable = true } }, 4)
        or "{}"
    s = s:gsub("[\r\n]", " ") .. "\n"
    lines[#lines + 1] = s
    bytes = bytes + #s
    pending = pending + 1
    if bytes >= PART_BYTES then
        L.Flush(true)
        part = part + 1
        file = fileName()
        lines, bytes = {}, 0
    end
end

-- true the first time `key` comes up in this world load while the file is on. A key is only marked
-- then, so turning logging on mid-game still gets the first one after that
function L.First(key)
    if once[key] or level < L.LEVELS[E.Level.Basic] then return false end
    once[key] = true
    return true
end

-- writes the record the first time `key` comes up in this world load (L.First). `data` may be a
-- function, called only when the record is written. Returns whether it wrote
function L.Once(key, kind, name, data)
    noDefer()
    if not L.First(key) then return false end
    if type(data) == "function" then data = U.Get(data) end
    L.Write(kind, name, data)
    return true
end

-- each world load logs its own probes and examples (Hub.Attach)
function L.ForgetOnce()
    once = {}
end

function L.Say(msg)
    noDefer()
    if level >= L.LEVELS[E.Level.Basic] then Ext.Utils.Print("[PaG] " .. msg) end
end

-- prints at every level, so a bug report can say what PaG thought it was doing without logging
-- having been turned on first
function L.Banner(msg)
    noDefer()
    Ext.Utils.Print("[PaG] " .. msg)
end

-- always printed: the console is the only place a player will see that something went wrong
function L.Warn(msg, data)
    noDefer()
    Ext.Utils.PrintWarning("[PaG] " .. msg)
    L.Write(E.LogKind.Warn, msg, data)
    L.Flush(true)
end

-- L.Warn, the first time `key` comes up this Lua state (a new one at each save load)
function L.WarnOnce(key, msg, data)
    noDefer()
    if warned[key] then return false end
    warned[key] = true
    L.Warn(msg, data)
    return true
end

-- called from Util.Try / Util.Guard, and once per kind from Hub's handler
function L.Error(label, err, n)
    noDefer()
    Ext.Utils.PrintWarning("[PaG] " .. label .. ": " .. tostring(err))
    L.Write(E.LogKind.Error, label, { err = tostring(err), n = n })
    L.Flush(true)
end
