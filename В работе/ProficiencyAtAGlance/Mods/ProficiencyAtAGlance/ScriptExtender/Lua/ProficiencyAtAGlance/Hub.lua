-- the hub: finds PaG's cells in the game's UI, has Rules judge each cell's item for one character,
-- and shows the verdict as marks.
--
-- Threading (Script Extender v33). The game updates its UI on a job it does not join, so a tick, an
-- input event or a command handler that touches Noesis races that job (the s038 crash, the hang
-- dump). The one race-free door is Ext.UI.Defer: its callback runs at the start of the next UI
-- update, on the UI thread, under the game's UI locks, with SE holding the Lua lock. So:
--   - every Noesis read and write happens in a Defer callback (ui), and asserts it (assertDefer)
--   - Tick never touches Noesis. It judges items (Ext.Entity and Ext.Stats are not allowed in a
--     Defer callback), writes the log, and queues the next callback
--   - a Noesis handle lives only for the Lua call that produced it, so none is kept across
--     callbacks: a cursor is a path of child indices and names, followed again from GetRoot
--   - Tick and a callback never run at once (both hold the Lua lock), so the plain tables they
--     share need no lock
-- Without Ext.UI.Defer (SE v32) PaG makes no UI calls at all (_Init.lua).
--
-- Finding cells. The template (Lib_Keyboard.xaml) names each inventory cell PaGRoot and each
-- equipment slot PaGSlotRoot. A panel is a child of ContentRoot. A walk of a panel reads only Name
-- and VisualChildrenCount; two cells whose paths differ at one index make that index's parent a
-- host, and the host's other children are probed along the same suffix. What a walk learned is
-- kept by panel name, so a panel that opens again is verified rather than walked.
--
-- Keys. A cell's item is its DataContext.Object.EntityUUID, a slot's DataContext.Item.EntityUUID.
-- A bound property reads nil through SE (NsHelpers.inl PushValue returns nil for a complex
-- expression), so the key comes from the data, never from a bound TextBlock.
--
-- Marks. A cell PaG has written to carries an id in PaGId ("seed:serial"); `shown` remembers, per
-- id, the key and verdict it shows, so a poll writes only what changed. Marks show and hide through
-- Opacity only, never Visibility (crash M5).
--
-- Order, not timing (METHODOLOGY rule 10): nothing here depends on which of two things happens
-- first. A callback queued before an Invalidate (seq) does nothing.
local U, L, E = PaG.Util, PaG.Log, PaG.Enums
local R, Rules, Settings, Why = PaG.Read, PaG.Rules, PaG.Settings, PaG.Why
local PanelPlan = PaG.PanelPlan

local Hub = {}
PaG.Hub = Hub

local Rn, K = E.Reason, E.LogKind

-- ===== constants and startup =====

-- Constants live in one table, and the sections after the engine helpers sit in do-blocks:
-- Lua allows 200 active locals in one function, the chunk included, and Hub has more names.
local C = PaG.HubConstants

local seed = string.format("%x", math.floor(Ext.Timer.MonotonicTime()))

local diag = "full"
local diagSkipped = 0

-- the feature test (design §8.2): v32 has no Ext.UI.Defer, and there PaG makes no UI call at all
local HAS_DEFER = U.Get(function() return type(Ext.UI.Defer) == "function" end) == true
Hub.HAS_DEFER = HAS_DEFER

-- ===== state =====

local inWorld, attached = false, false
local layout = nil                -- cells: false when not laid out as the template says
local slotLayout = nil
local cellSerial = 0              -- never reset, so an id is never reused in this Lua state
local shown, shownN = {}, 0       -- id -> what that cell shows: { key, tier, lg, pid, ...render state }

-- generations. A verdict is current iff it was judged at G and at its character's charGen
local G, looksGen = 0, 0
local charGen = {}
-- verdicts: VC[who] = { by = { [key] = { tier, why, g, cg } }, n, used }. Tick writes, a callback
-- only reads
local VC, vcN = {}, 0
-- the looks, as plain data built on Tick: render reads it inside the callback
local lookCfg = {}

-- what the callback hands Tick
local toTick = { who = nil, via = nil, whoChanged = false,
                 show = false,                -- a panel with cells was shown: re-read (rereadDirty)
                 r = nil }                    -- render counters, see newRenders
-- keys wanted: { who, key, wk } in poll order, and wk = who.."|"..key for those queued
local wantedSet, wantedList, wantedHead = {}, {}, 1

-- Tick's copy of the observed character: its snapshot is built and re-read when it changes (takeWho).
-- Each wanted key names the character it is judged for
local judged, judgedVia = nil, nil
-- the callback's character, observed in the UI; false when it could not be read (no marks)
local obsWho, obsVia = nil, nil

-- characters and items (Tick only, but OnChange handlers set dirty and itemDirty). subscribed: uuid
-- -> its OnChange ids. dirty, itemDirty: uuid -> why it is read again, the first reason since its
-- last read ("shown", "judged", "retry", "onchange:<Component>")
local subs, subscribed, dirty, rereadAt = {}, {}, {}, {}
local watched, itemDirty, nWatched = {}, {}, 0

-- the scheduler (design §8.3)
local seq, armed, armedAt, lastRan = 0, false, 0, -1e9
local hot, idleK, idleQuiet = 0, C.IDLE_FIRST, 0
local want = {}
local faults, tickFaults, latched, terminal = 0, 0, false, false
local treeSafe = false
local pollable = false            -- a visible panel holds cells: a callback every POLL_EVERY ticks
local burstMode = false
local jobs = {}

-- the UI as last read (plain data only)
local panels = {}                 -- pid -> panel, see newPanel
local order = {}                  -- pids in ContentRoot order
local seenAt = nil                -- panel name -> its first index under ContentRoot
local markSig = nil
local learned = {}                -- panel name -> { cells, lists, plan } from its last walk; survives Reset
-- panel name -> true. hadCells: some walk of that name found a cell (a slot counts). barrenNames: a
-- show's walks read nodes and found none, and the name never had cells and is not in CELL_PAGES, so a
-- later show is walked once, not EMPTY_REWALKS times. Both survive Reset, like learned
local hadCells, barrenNames = {}, {}
local pollCur = nil               -- { k, pid, h, i, r0, at }: the poll pass's place, renders and tick at its start
local pollNext = 0                -- after a pass that found nothing: the tick the next may start
local deepWalk = nil
local deepRestarts = 0               -- !pag_walk restarts since it was asked for

local burst = nil
local cause, causeTick = nil, -1
local totals, errors, errorKinds = nil, {}, 0
local lastTickAt, lastTickEnd = nil, nil

-- metrics (design §8.3)
local metrics = nil

local function resetCounters()
    -- onchange: OnChange fires per component ("item.StatusContainer" for watched items). slowCb,
    -- slowTick, slowDefer: cost/cb callbacks, cost/tick ticks and cost/defer_wait callbacks, and *Over
    -- those past C.COST_ROWS. rereads, rereadUs: re-reads and their R.Refresh time; rereadOver: reread
    -- rows past C.REREAD_ROWS
    totals = { bursts = 0, renders = 0, judged = 0, callbacks = 0, stale = 0, stalls = 0,
               unitErrors = 0, deferRaises = 0, unsafe = 0, lastBurst = nil,
               onchange = {}, slowCb = 0, slowCbOver = 0, slowDefer = 0, slowDeferOver = 0,
               slowTick = 0, slowTickOver = 0,
               rereads = 0, rereadUs = 0, rereadOver = 0 }
    errors, errorKinds = {}, 0
    -- armedFor: treeSafe ticks the queued callback has waited. ocFirst: counter key -> { comp, uuid,
    -- item } of its first fire, written by Tick (flushRows). tick: when each of this tick's steps
    -- ended (us), for Hub.NoteTick (tickAll)
    metrics = { cbUs = {}, cbI = 0, tickUs = {}, tickI = 0, tick = {}, armWait = {}, armI = 0,
                heapAt = nil, heapKB = nil, heapRate = nil, heapMax = nil,
                armedFor = 0, ocFirst = {} }
end
resetCounters()

local function ring(t, field, v)
    local i = metrics[field] % C.RING + 1
    metrics[field] = i
    t[i] = v
end

local function percentile(t, p)
    local s = {}
    for _, v in pairs(t) do s[#s + 1] = v end
    if #s == 0 then return nil end
    table.sort(s)
    return s[math.max(1, math.ceil(#s * p))]
end

-- ===== the callback's guards and its log =====

-- true only while a callback runs. Log.lua reads PaG.InDefer and raises if an L.* call is made
-- from inside one: a callback writes rows (dlog) and Tick writes them out (flushRows)
local inDefer = false
PaG.InDefer = false

local function assertDefer(what)
    if not inDefer then error("PaG: " .. what .. " outside Ext.UI.Defer", 3) end
end

local function assertTick(what)
    if inDefer then error("PaG: " .. what .. " inside Ext.UI.Defer", 3) end
end

-- a row's data, made safe to keep past the callback: a Noesis handle expires when the callback
-- returns, so it is kept as its string
local function clean(v, depth)
    local t = type(v)
    if t == "userdata" then return U.Get(tostring, v) or "userdata" end
    if t == "function" or t == "thread" then return t end
    if t ~= "table" then return v end
    if depth <= 0 then return "table" end
    local out, n = {}, 0
    for k, x in pairs(v) do
        n = n + 1
        if n > 64 then out["..."] = true; break end
        local kk = (type(k) == "string" or type(k) == "number") and k or tostring(k)
        out[kk] = clean(x, depth - 1)
    end
    return out
end

local rows, rowsDropped, dOnce = {}, 0, {}

-- queues a log row from inside a callback. op: "write" (kind, name, data), "warnonce" (key, msg,
-- data), "error" (label, err, n), "say" (msg), "print" (msg: printed at every level). A row with
-- a onceKey is queued once per world load, and a probe row only while the file is on
local function dlog(onceKey, op, a, b, c)
    if onceKey ~= nil then
        if dOnce[onceKey] then return end
        if op == "write" and not L.Basic() then return end
        dOnce[onceKey] = true
    end
    if #rows >= C.DLOG_MAX then rowsDropped = rowsDropped + 1; return end
    rows[#rows + 1] = { op = op, once = onceKey, a = a, b = clean(b, 6), c = clean(c, 6) }
end

local function flushRows()
    assertTick("flushRows")
    if next(metrics.ocFirst) ~= nil then
        -- an OnChange counter's first move this world load (they write no rows themselves)
        for key, f in pairs(metrics.ocFirst) do
            L.Once("probe.onchange_first." .. key, K.Probe, "onchange_first", f)
        end
        metrics.ocFirst = {}
    end
    if #rows == 0 and rowsDropped == 0 then return end
    local list, dropped = rows, rowsDropped
    rows, rowsDropped = {}, 0
    for _, r in ipairs(list) do
        if r.op == "write" then
            if r.once ~= nil then L.Once(r.once, r.a, r.b, r.c) else L.Write(r.a, r.b, r.c) end
        elseif r.op == "warnonce" then
            L.WarnOnce(r.a, r.b, r.c)
        elseif r.op == "error" then
            L.Error(r.a, r.b, r.c)
        elseif r.op == "say" then
            L.Say(r.a)
        elseif r.op == "print" then
            Ext.Utils.Print("[PaG] " .. tostring(r.a))
        end
    end
    if dropped > 0 then L.Write(K.Probe, "dlog_overflow", { dropped = dropped, max = C.DLOG_MAX }) end
end

-- a !pag_walk that will not finish (a rebuild, leaving the world, a latch) is dropped with a line
-- saying so: the console promised a result
local function dropDeep(why)
    if not want.deep then return end
    want.deep, deepWalk = nil, nil
    local line = "!pag_walk dropped (" .. why .. "); run it again"
    if inDefer then
        dlog(nil, "print", line)
    else
        L.Write(K.Probe, "deep_dropped", { why = why })
        L.Banner(line)
    end
end

-- ===== engine access (callback only) =====

local function setField(obj, name, v) obj[name] = v end
local function setProp(obj, name, v) obj:SetProperty(name, v) end
local function getField(obj, name) return obj[name] end
local function logicalChild(node, i) return node:Child(i) end
local function visualChild(node, i) return node:VisualChild(i) end
local GETTERS = { Child = logicalChild, VisualChild = visualChild }

local function read(obj, name)
    assertDefer("read")
    local ok, v = pcall(getField, obj, name)
    if ok then return v end
    return nil
end

-- writes a property: a field write, else SetProperty. A field write can report success for a write
-- the engine refused: SetNamedProperty prints its own error and returns rather than raising, so a
-- write path can log as working while it writes nothing. A caller that can recognize the value
-- passes `check`, and only a value that reads back counts. `what` groups the probe rows: the path
-- that worked is logged once per group, a failure once per group and property.
-- !pag_diag nowrite: returns before Script Extender is asked, and counts the write
local function write(obj, name, v, what, check)
    assertDefer("write")
    if diag == "nowrite" then diagSkipped = diagSkipped + 1; return true end
    local ok1, err1 = pcall(setField, obj, name, v)
    local held1 = ok1 and (check == nil or check(read(obj, name)))
    if held1 then
        dlog("probe.write." .. what, "write", K.Probe, "write", { what = what, path = "field" })
        return true
    end
    local ok2, err2 = pcall(setProp, obj, name, v)
    if ok2 and (check == nil or check(read(obj, name))) then
        dlog("probe.write." .. what, "write", K.Probe, "write", { what = what, path = "SetProperty" })
        return true
    end
    dlog("probe.write_failed." .. what .. "." .. name, "write", K.Probe, "write_failed",
        { what = what, prop = name,
          field = ok1 and "no error, but the value did not read back" or tostring(err1),
          SetProperty = ok2 and "no error, but the value did not read back" or tostring(err2) })
    return false
end

-- a node at `path` below `root`, through `getter`; nil when a step is missing
local function follow(getter, root, path)
    assertDefer("follow")
    local node = root
    for _, i in ipairs(path) do
        node = U.Get(getter, node, i)
        if node == nil then return nil end
    end
    return node
end

local function uiRoot()
    assertDefer("uiRoot")
    return U.Get(Ext.UI.GetRoot)
end

local function contentOf(root)
    assertDefer("contentOf")
    return U.Get(function() return root:Find("ContentRoot") end)
end

-- a value for a log row. A node's Type is not read: reading Type is a virtual call through a raw
-- Noesis pointer (se_v32/NsHelpers.inl:11), and one that lands on a dying node, as when Camp Chest
-- Everywhere opens, kills the process. An access violation is not a Lua error
local function describe(v)
    if v == nil then return "nil" end
    local out = { lua = type(v) }
    if type(v) == "userdata" then
        assertDefer("describe")
        out.str = U.Get(tostring, v)
        out.name = U.Get(function() return tostring(v.Name) end)
    else
        out.str = tostring(v)
    end
    return out
end

local function nameOf(node)
    if type(node) == "userdata" then assertDefer("nameOf") end
    return tostring(read(node, "Name") or "-")
end

-- the four 0..1 components of a color, however it reads back: a table, a Noesis Color with named
-- fields (0..1 or 0..255), or "#AARRGGBB". nil when it is none of those
local function colorParts(v)
    local p = nil
    if type(v) == "table" and type(v[1]) == "number" then
        p = { v[1], v[2] or 0, v[3] or 0, v[4] or 1 }
    elseif type(v) == "userdata" then
        assertDefer("colorParts")
        p = U.Get(function() return { v.R, v.G, v.B, v.A } end)
        if p == nil or type(p[1]) ~= "number" then p = U.Get(function() return { v.r, v.g, v.b, v.a } end) end
        if p == nil or type(p[1]) ~= "number" then
            local s = U.Get(tostring, v)
            if type(s) == "string" and s:sub(1, 1) == "#" then return colorParts(s) end
        end
    elseif type(v) == "string" then
        local a, r, g, b = v:match("^#(%x%x)(%x%x)(%x%x)(%x%x)$")
        if a ~= nil then p = { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), tonumber(a, 16) } end
    end
    if p == nil then return nil end
    local over = false
    for i = 1, 4 do
        if type(p[i]) ~= "number" then return nil end
        if p[i] > 1 then over = true end
    end
    if over then
        for i = 1, 4 do p[i] = p[i] / 255 end
    end
    return p
end

-- a panel's visibility: IsVisible when it reads as a boolean, else Visibility; nil when neither
local function visibleOf(node)
    local v = read(node, "IsVisible")
    if type(v) == "boolean" then return v end
    local vis = read(node, "Visibility")
    if vis ~= nil then return tostring(vis) == "Visible" end
    return nil
end

-- declared here: the names later code uses. The rest leave scope at the block's end.
local count, flushBurst, theBurst, newRenders, noteError, heat, moveG, buildLooks, verdictOf,
    wantKey, clearWanted, dropSubscriptions, rereadDirty, checkItems, takeWho, judgeWanted,
    onSettingsSettle, onSettingsChange
do

    -- ===== bursts (Tick) =====

    -- a burst: a run of ticks with judging or rendering, ended by a tick with neither. One row per burst
    local function newBurst()
        local now = U.Now()
        local c = "ui"
        if cause ~= nil and U.Ticks() - causeTick <= C.CAUSE_TICKS then c = cause end
        cause = nil
        return { n = 0, start = now, last = now, cause = c, byReason = {}, byTier = {}, items = {},
                 chars = {}, keys = {}, us = 0, maxUs = 0, errors = 0, samples = 0, judged = 0,
                 examples = {}, fresh = 0, cells = 0, slots = 0, writes = 0 }
    end

    function count(t, k) t[k] = (t[k] or 0) + 1 end

    function flushBurst()
        local b = burst
        if b == nil then return end
        burst = nil
        totals.bursts = totals.bursts + 1
        local row = {
            n = b.n, judged = b.judged, cause = b.cause, ms = b.last - b.start,
            luaMs = math.floor(b.us / 10) / 100, maxJudgeMs = math.floor(b.maxUs / 10) / 100,
            items = U.Count(b.items), chars = U.Count(b.chars), keys = U.Count(b.keys),
            byTier = b.byTier, byReason = b.byReason, errors = b.errors, G = G, looksGen = looksGen,
            fresh = b.fresh, cells = b.cells, who = judged, via = judgedVia,
            writes = b.writes, slots = b.slots > 0 and b.slots or nil,
            examples = b.examples[1] ~= nil and b.examples or nil,
        }
        totals.lastBurst = row
        L.Write(K.Burst, "burst", row)
        L.Say(string.format("burst %d (%s): %d renders, %d judged; bad %d, not ideal %d, good %d; %.2f ms judging",
            totals.bursts, b.cause, b.n, b.judged, b.byTier.bad or 0, b.byTier.not_ideal or 0,
            b.byTier.good or 0, row.luaMs))
    end

    function theBurst()
        if burst == nil then burst = newBurst() end
        burst.last = U.Now()
        return burst
    end

    -- the render counters a callback fills (plain numbers), merged into the burst on Tick
    function newRenders()
        return { n = 0, writes = 0, fresh = 0, cells = 0, slots = 0, errors = 0 }
    end
    toTick.r = newRenders()

    -- an error from a judge (Tick) or a poll unit (callback): printed once per message, then counted
    function noteError(label, err)
        local msg = tostring(err)
        if burst then burst.errors = burst.errors + 1 end
        if errors[msg] then errors[msg] = errors[msg] + 1; return end
        errors[msg] = 1
        errorKinds = errorKinds + 1
        local say = nil
        if errorKinds <= C.ERROR_KINDS then
            say = msg
        elseif errorKinds == C.ERROR_KINDS + 1 then
            say = "more than " .. C.ERROR_KINDS .. " kinds of error; the rest are only counted"
        end
        if say == nil then return end
        if inDefer then dlog(nil, "error", label, say, errorKinds) else L.Error(label, say, errorKinds) end
    end

    local function record(b, key, item, char, tier, reason, slot, detail, ac, us)
        assertTick("record")
        b.judged = b.judged + 1
        totals.judged = totals.judged + 1
        count(b.byReason, reason)
        if tier then count(b.byTier, tier) end
        if item then b.items[item] = true end
        if char then b.chars[char] = true end
        if key then b.keys[key] = true end
        b.us = b.us + us
        if us > b.maxUs then b.maxUs = us end
        -- the first verdict of each (character, tier, reason, slot) this world load is an example in the
        -- burst row, never a row of its own
        if char and item then
            if L.First("verdict." .. char .. "." .. tostring(tier) .. "." .. reason .. "." .. tostring(slot)) then
                local rec = U.Get(R.Item, item)
                b.examples[#b.examples + 1] = { char = char, item = item, statsId = rec and rec.statsId,
                    tier = tier or "none", reason = reason, slot = slot, detail = detail, ac = ac or nil }
            end
        elseif L.First("verdict.hub." .. reason) then
            b.examples[#b.examples + 1] = { reason = reason, key = key, detail = detail }
        end
        -- verbose: every verdict once per (character, stats entry, slot, tier, reason, ac) this world
        -- load, for pag_verdicts.py's full diff (an example holds only the first verdict of its key)
        if L.Verbose() and char and item then
            local rec = U.Get(R.Item, item)
            local sid = rec and rec.statsId
            if L.First("verdict_all." .. char .. "." .. tostring(sid) .. "." .. tostring(slot) .. "."
                .. tostring(tier) .. "." .. reason .. "." .. tostring(ac)) then
                L.Write(K.Sample, "verdict", { char = char, statsId = sid, slot = slot, tier = tier or "none",
                    reason = reason, ac = ac or nil, detail = detail })
            end
        end
        if L.Verbose() and b.samples < C.SAMPLES_PER_BURST then
            b.samples = b.samples + 1
            L.Write(K.Sample, "judge", { key = key, tier = tier or "none", reason = reason, slot = slot,
                detail = detail, us = math.floor(us) })
        end
    end

    -- ===== generations (Tick) =====

    -- marks the cells to look at again soon: any change sets hot and resets the idle backoff
    function heat()
        hot = C.HOT_TICKS
        idleK, idleQuiet = C.IDLE_FIRST, 0
    end

    -- a generation moved: G (rules), looksGen (display) or a character's charGen. One row each
    local function moved(what, why, data)
        assertTick("moved")
        cause, causeTick = why, U.Ticks()
        heat()
        burstMode = true
        want.render = true
        local row = data or {}
        row.what, row.why, row.G, row.looksGen = what, why, G, looksGen
        L.Write(K.Bump, what, row)
    end

    function moveG(why)
        G = G + 1
        moved("G", why)
    end

    -- the looks render reads inside the callback, as plain data: each tier's styles, color and badge
    -- icon, the icon already checked against the tier's set (Settings.ICONS), and whether a mark only
    -- Armor vs AC bonuses causes gave takes the shield icon instead (ac_shield)
    function buildLooks()
        assertTick("buildLooks")
        local cfg = Settings.Get()
        local out = { enabled = cfg.enabled == true, equipped_marks = cfg.equipped_marks == true,
                      ware_marks = cfg.ware_marks == true, swap = cfg.placement_corners == E.Corners.BadgeBottomRight,
                      ac_shield = cfg.ac_shield_badge == true, mark = {} }
        for _, tier in ipairs(Settings.TIERS) do
            local any = false
            for _, style in ipairs(Settings.STYLES) do
                local k = tier .. "_" .. style
                out[k] = cfg[k] == true
                any = any or out[k]
            end
            out.mark[tier] = any
            out[tier .. "_color_preset"] = cfg[tier .. "_color_preset"]
            local set = Settings.ICONS and Settings.ICONS[tier]
            local v = cfg[tier .. "_badge_icon"]
            local icon = Settings.DEFAULTS[tier .. "_badge_icon"]
            if set ~= nil then
                for _, i in ipairs(set) do if i == v then icon = v end end
                if icon ~= v then
                    L.Once("probe.badge_icon_fallback." .. tier, K.Probe, "badge_icon_fallback",
                        { tier = tier, value = tostring(v), used = icon })
                end
            end
            out[tier .. "_badge_icon"] = icon
        end
        -- a trade page's item cells take their own looks (looksFor), nil for Full: Subtle drops Dim
        -- and Grayscale and shows the rest at TRADE_FAINT (`marks`, render); Off shows nothing
        local tm = cfg.trade_marks
        if tm == E.TradeMarks.Subtle or tm == E.TradeMarks.Off then
            local t = {}
            for k, v in pairs(out) do t[k] = v end
            t.mark = {}
            for _, tier in ipairs(Settings.TIERS) do
                local any = false
                for _, style in ipairs(Settings.STYLES) do
                    local k = tier .. "_" .. style
                    if tm == E.TradeMarks.Off or style == "dim" or style == "gray" then t[k] = false end
                    any = any or t[k]
                end
                t.mark[tier] = any
            end
            if tm == E.TradeMarks.Subtle then t.marks = C.TRADE_FAINT end
            out.trade = t
        end
        lookCfg = out
    end

    local function moveLooks(why)
        buildLooks()
        looksGen = looksGen + 1
        moved("looksGen", why)
    end

    -- ===== verdicts (Tick writes, the callback reads) =====

    local function vcFor(who)
        local v = VC[who]
        if v ~= nil then v.used = U.Ticks(); return v end
        if vcN >= C.VC_CHARS then
            local oldest, at = nil, math.huge
            for w, e in pairs(VC) do
                if e.used < at then oldest, at = w, e.used end
            end
            if oldest ~= nil then VC[oldest] = nil; vcN = vcN - 1 end
            L.Once("probe.vc_evict", K.Probe, "vc_evict", { max = C.VC_CHARS })
        end
        v = { by = {}, n = 0, used = U.Ticks() }
        VC[who] = v
        vcN = vcN + 1
        return v
    end

    -- ac: only Armor vs AC bonuses causes gave the tier (Rules.Judge). retry: the verdict came from a
    -- read that failed (Rules.Retry), so it stops being current after RETRY_TICKS, backing off while
    -- the same G keeps failing. text: the tooltip (Why.Text) of an equipped badge, or of a cell's
    -- badge and dot; nil for none
    local function vcPut(who, key, tier, why, retry, ac, text)
        assertTick("vcPut")
        local v = vcFor(who)
        local old = v.by[key]
        if old == nil then
            if v.n >= C.VC_KEYS then
                L.Once("probe.vc_reset", K.Probe, "vc_reset", { max = C.VC_KEYS })
                v.by, v.n = {}, 0
            end
            v.n = v.n + 1
        end
        local e = { tier = tier, why = why, ac = ac == true, text = text, g = G, cg = charGen[who] or 0 }
        if retry then
            e.tries = (old ~= nil and old.g == G and old.tries or 0) + 1
            e.retry = U.Ticks() + C.RETRY_TICKS[math.min(e.tries, #C.RETRY_TICKS)]
        end
        v.by[key] = e
    end

    -- the current verdict for `who` and `key`, or nil. Never writes (the callback calls it)
    function verdictOf(who, key)
        local v = VC[who]
        local e = v and v.by[key]
        if e == nil or e.g ~= G or e.cg ~= (charGen[who] or 0) then return nil end
        if e.retry ~= nil and U.Ticks() >= e.retry then return nil end
        return e
    end

    -- an item's binding changed: its verdicts go, in every character's
    local function dropKey(item)
        for _, v in pairs(VC) do
            for _, k in ipairs({ item, item .. "@eq" }) do
                if v.by[k] ~= nil then v.by[k] = nil; v.n = v.n - 1 end
            end
        end
    end

    -- keys a callback found no current verdict for, each with the character it is judged for, in
    -- poll order
    function wantKey(who, key)
        local wk = who .. "|" .. key
        if wantedSet[wk] then return end
        if #wantedList - wantedHead + 1 >= C.WANTED_MAX then return end
        wantedSet[wk] = true
        wantedList[#wantedList + 1] = { who = who, key = key, wk = wk }
    end

    function clearWanted()
        wantedSet, wantedList, wantedHead = {}, {}, 1
    end

    -- ===== characters and items (Tick) =====

    -- us: the R.Char or R.Refresh call's time. reread: why the re-read ran (rereadDirty)
    local function charRow(snap, why, changed, us, reread)
        local d = R.Describe(snap)
        d.why = why
        d.changed = changed and U.Keys(changed) or nil
        d.us, d.reread = us, reread
        L.Write(K.Char, "snapshot", d)
    end

    -- re-reads a character when one of its components changes. The handler only counts the fire and
    -- marks it dirty (no rows: Tick writes the first fire, flushRows): the re-read waits for the tick
    -- (rereadDirty)
    local function subscribe(uuid)
        assertTick("subscribe")
        if subscribed[uuid] then return end
        local e = R.Entity(uuid)
        if e == nil then return end -- left unmarked, so the next snapshot built for it tries again
        local ids = {}
        subscribed[uuid] = ids
        for _, comp in ipairs(C.CHAR_COMPONENTS) do
            local why = "onchange:" .. comp
            local ok, id = pcall(Ext.Entity.OnChange, comp, function()
                local n = (totals.onchange[comp] or 0) + 1
                totals.onchange[comp] = n
                if n == 1 then metrics.ocFirst[comp] = { comp = comp, uuid = uuid } end
                dirty[uuid] = dirty[uuid] or why
            end, e)
            if ok and id ~= nil then subs[#subs + 1] = id; ids[#ids + 1] = id end
            L.Once("probe.onchange." .. comp, K.Probe, "onchange_subscribe",
                { component = comp, ok = ok, id = ok and tostring(id) or nil, err = not ok and tostring(id) or nil })
        end
    end

    function dropSubscriptions()
        for _, id in ipairs(subs) do pcall(Ext.Entity.Unsubscribe, id) end
        subs, subscribed, dirty, rereadAt = {}, {}, {}, {}
        watched, itemDirty, nWatched = {}, {}, 0
        VC, vcN = {}, 0
        clearWanted()
        judged, judgedVia = nil, nil
        toTick.who, toTick.via, toTick.whoChanged, toTick.show = nil, nil, false, false
    end

    -- a snapshot built where there was none moves the character's generation: what was judged
    -- without one (no_char_entity, an equipped slot "not worn") is judged again against it
    local function charFor(uuid)
        assertTick("charFor")
        local t0 = Ext.Timer.MicrosecTime()
        local snap, built = R.Char(uuid)
        if built then
            charRow(snap, "built", nil, math.floor(Ext.Timer.MicrosecTime() - t0))
            subscribe(uuid)
            charGen[uuid] = (charGen[uuid] or 0) + 1
            moved("charGen", "built", { char = uuid, charGen = charGen[uuid] })
        end
        return snap
    end

    -- each dirty character, at most once per REREAD_GAP_TICKS: changes in between merge into one
    -- re-read, and a change moves only that character's generation. A panel with cells shown (the
    -- callback's toTick.show) marks the judged character, every kept snapshot and every watched item
    -- (an item read within the gap is skipped). Each re-read writes a row: the snapshot or gone row
    -- when something changed, a reread row when nothing did (the first C.REREAD_ROWS re-reads; the
    -- rest are counted)
    function rereadDirty()
        local now = U.Ticks()
        if toTick.show then
            toTick.show = false
            if judged then dirty[judged] = dirty[judged] or "shown" end
            for _, uuid in ipairs(R.KnownCharacters()) do dirty[uuid] = dirty[uuid] or "shown" end
            for uuid in pairs(watched) do
                if now - (rereadAt[uuid] or -1e9) >= C.REREAD_GAP_TICKS then
                    itemDirty[uuid] = itemDirty[uuid] or "shown"
                end
            end
        end
        for uuid, why in pairs(dirty) do
            if now - (rereadAt[uuid] or -1e9) >= C.REREAD_GAP_TICKS then
                dirty[uuid] = nil
                rereadAt[uuid] = now
                local t0 = Ext.Timer.MicrosecTime()
                local snap, changed = R.Refresh(uuid)
                local us = math.floor(Ext.Timer.MicrosecTime() - t0)
                totals.rereads, totals.rereadUs = totals.rereads + 1, totals.rereadUs + us
                if changed ~= nil and next(changed) ~= nil then
                    if snap ~= nil then
                        charRow(snap, "changed", changed, us, why)
                    else
                        -- the entity it subscribed on is gone: its OnChange ids go with it, and the
                        -- next build subscribes on the new one
                        local ids = subscribed[uuid] or {}
                        if #ids > 0 then
                            local drop, keep = {}, {}
                            for _, id in ipairs(ids) do pcall(Ext.Entity.Unsubscribe, id); drop[id] = true end
                            for _, id in ipairs(subs) do if not drop[id] then keep[#keep + 1] = id end end
                            subs = keep
                        end
                        L.Write(K.Char, "gone", { uuid = uuid, reread = why, us = us, unsubscribed = #ids })
                        subscribed[uuid] = nil
                    end
                    charGen[uuid] = (charGen[uuid] or 0) + 1
                    moved("charGen", "char", { char = uuid, charGen = charGen[uuid] })
                elseif totals.rereads > C.REREAD_ROWS then
                    totals.rereadOver = totals.rereadOver + 1
                else
                    L.Write(K.Char, "reread", { uuid = uuid, why = why, us = us, changed = "none",
                        uncached = snap == nil or nil })
                end
            end
        end
    end

    -- a bound item (pact weapon, hexblade) can lose its binding without the character changing
    local function watchItem(uuid, state)
        assertTick("watchItem")
        if watched[uuid] then return end
        if nWatched >= C.WATCH_MAX then
            L.Once("probe.item_watch_cap", K.Probe, "item_watch_cap", { max = C.WATCH_MAX })
            return
        end
        local e = R.Entity(uuid)
        if e == nil then return end
        nWatched = nWatched + 1
        watched[uuid] = state or "bound"
        local ok, id = pcall(Ext.Entity.OnChange, "StatusContainer", function()
            local n = (totals.onchange["item.StatusContainer"] or 0) + 1
            totals.onchange["item.StatusContainer"] = n
            if n == 1 then
                metrics.ocFirst["item.StatusContainer"] = { comp = "StatusContainer", uuid = uuid, item = true }
            end
            itemDirty[uuid] = itemDirty[uuid] or "onchange:StatusContainer"
        end, e)
        if ok and id ~= nil then subs[#subs + 1] = id end
        L.Once("probe.item_onchange_subscribe", K.Probe, "item_onchange_subscribe",
            { item = uuid, ok = ok, id = ok and tostring(id) or nil, err = not ok and tostring(id) or nil })
    end

    local function itemState(uuid)
        local st = R.ItemStatuses(uuid)
        if st == nil then return "unreadable" end
        return Rules.IsBound(st) and "bound" or "free"
    end

    function checkItems()
        for _, uuid in ipairs(U.Keys(itemDirty)) do
            local why = itemDirty[uuid]
            itemDirty[uuid] = nil
            rereadAt[uuid] = U.Ticks()
            local now = itemState(uuid)
            if now ~= watched[uuid] then
                L.Write(K.Item, "item_status", { item = uuid, from = watched[uuid], to = now, why = why })
                watched[uuid] = now
                dropKey(uuid)
                heat()
            end
        end
    end

    -- the character the UI shows, handed over by the callback (observeUi)
    function takeWho()
        if not toTick.whoChanged then return end
        toTick.whoChanged = false
        local from = judged
        judged, judgedVia = toTick.who or nil, toTick.via
        L.Write(K.Char, "judged", { from = from, to = judged, via = judgedVia })
        if judged then
            charFor(judged)
            dirty[judged] = dirty[judged] or "judged"
        end
        heat()
        burstMode = true
    end

    -- ===== judging (Tick) =====

    -- the slot `item` is equipped in, per a character's snapshot; nil when it is not there
    local function slotOf(snap, item)
        if snap == nil or snap.equipped == nil then return nil end
        for s, ref in pairs(snap.equipped) do
            if U.FindUuid(ref.uuid) == item then return s end
        end
        return nil
    end

    -- a verdict from a read that failed is kept with a retry (vcPut); one that a fresh read of the
    -- character could change also marks it dirty, so the retry judges against that read
    local function retryOf(who, kind)
        if kind == "char" then dirty[who] = dirty[who] or "retry" end
        return kind ~= nil
    end

    -- one key's verdict for `who`. A cell's key is its item, judged for the observed character; an
    -- equipment slot's is item.."@eq", judged for the slot's wearer (D27), and a slot shows a mark only
    -- for Bad and Not Ideal (Q13: the slot says what is wrong with what is worn)
    local function judgeKey(who, key)
        assertTick("judgeKey")
        local t0 = Ext.Timer.MicrosecTime()
        local b = theBurst()
        local isSlot = key:sub(-3) == "@eq"
        local item = isSlot and key:sub(1, -4) or key
        local cfg = Settings.Get()
        L.Once("probe.judged." .. who, K.Probe, "judged_character",
            { char = who, via = isSlot and "wearer" or judgedVia })
        local tier, reason, slot, detail, ac, causes
        if not isSlot then
            -- the badge and dot's tooltip, with Cell tooltips on: Bad and Not Ideal only, as Good gets
            -- none. A fault words no tooltip, and the marks still show. Its own guard label, so cell
            -- faults never latch off the equipped badge's text ("hub.why")
            local tips = cfg.cell_tooltips == true
            local text = nil
            if not cfg.enabled then
                reason = Rn.Disabled
            else
                local snap = charFor(who)
                tier, reason, slot, detail, ac, causes = Rules.Judge(cfg, snap, item, nil, tips)
                if reason == Rn.BoundStatus then watchItem(item) end
                if tips and (tier == E.Tier.Bad or tier == E.Tier.NotIdeal) then
                    text = U.Guard("hub.why.cell", Why.Text, tier, causes, snap)
                    if text ~= nil and text ~= "" then
                        L.Once("probe.cell_why." .. who .. "." .. tostring(tier), K.Probe, "cell_why",
                            { item = item, char = who, tier = tier, lines = select(2, text:gsub("\n", "")) + 1,
                                text = text })
                    else
                        L.Once("probe.cell_why_empty", K.Probe, "cell_why_empty",
                            { item = item, char = who, tier = tier, reason = reason, fault = text == nil })
                    end
                end
            end
            vcPut(who, key, tier, reason, retryOf(who, Rules.Retry(reason, detail)), ac, text)
            record(b, key, item, who, tier, reason, slot, detail, ac, Ext.Timer.MicrosecTime() - t0)
            return
        end
        local function off(why, d, retry)
            vcPut(who, key, nil, why, retry)
            record(b, key, item, who, nil, why, nil, d, nil, Ext.Timer.MicrosecTime() - t0)
        end
        if not cfg.enabled then return off(Rn.Disabled, "equipped") end
        if not cfg.equipped_marks then return off(Rn.Disabled, "equipped marks off") end
        local snap = charFor(who)
        local at = slotOf(snap, item)
        -- the slot shows an item the wearer's snapshot does not hold: the snapshot is behind (a swap
        -- between two items of one statsId leaves its fingerprint as it was), or the wearer could not
        -- be read
        if at == nil then
            return off(Rn.NoChar, "equipped: not in the wearer's snapshot", retryOf(who, "char"))
        end
        local tips = cfg.equipped_tooltips == true
        tier, reason, slot, detail, ac, causes = Rules.Judge(cfg, snap, item, at, tips)
        if reason == Rn.BoundStatus then
            watchItem(item)
        elseif reason == Rn.Bindable then
            watchItem(item, "free")
        end
        local marked = tier == E.Tier.Bad or tier == E.Tier.NotIdeal
        L.Once("probe.slot_verdict." .. who .. "." .. tostring(tier) .. "." .. tostring(reason) .. "." .. tostring(at),
            K.Probe, "slot_verdict", { item = item, char = who, at = at, tier = tier or "none",
                reason = reason, shown = marked })
        -- the badge's tooltip, with Equipped tooltips on. A fault words no tooltip, and the badge
        -- still shows
        local text = nil
        if marked and tips then text = U.Guard("hub.why", Why.Text, tier, causes, snap) end
        vcPut(who, key, marked and tier or nil, reason, retryOf(who, Rules.Retry(reason, detail)), marked and ac,
            text)
        record(b, key, item, who, tier, reason, slot,
            "equipped" .. (detail ~= nil and (" " .. tostring(detail)) or ""), ac, Ext.Timer.MicrosecTime() - t0)
    end

    -- judges the keys the callback wanted, in poll order, each for the character it names, within a
    -- budget
    function judgeWanted()
        if wantedHead > #wantedList then return end
        local t0 = Ext.Timer.MicrosecTime()
        local any = false
        while wantedHead <= #wantedList do
            local w = wantedList[wantedHead]
            wantedList[wantedHead] = false
            wantedHead = wantedHead + 1
            wantedSet[w.wk] = nil
            local who, key = w.who, w.key
            if verdictOf(who, key) == nil then
                local ok, err = pcall(judgeKey, who, key)
                if not ok then
                    vcPut(who, key, nil, Rn.JudgeError)
                    noteError("hub.judge", err)
                end
                any = true
            end
            if Ext.Timer.MicrosecTime() - t0 >= C.JUDGE_BUDGET_US then break end
        end
        if wantedHead > #wantedList then clearWanted() end
        if any then
            want.render = true
            heat()
        end
    end

    -- ===== settings change handlers =====

    -- a run of settings changes has ended (Settings.OnTick). Rule keys move G, so every verdict is
    -- judged again; display keys move looksGen, so every mark is drawn again from the verdicts kept
    function onSettingsSettle(changed)
        if not attached then return end
        local rules, looks = false, false
        for k in pairs(changed or {}) do
            if k == "debug_level" then
                -- the log level only (Settings.lua apply)
            elseif C.RULE_KEYS[k] then
                rules = true
            else
                looks = true
            end
        end
        if rules then
            buildLooks()
            moveG("settings")
        end
        if looks then moveLooks("settings") end
    end

    -- MCM's or the console's call: the subscription only. Changes apply when the run settles
    function onSettingsChange(changed, event) end
end

-- declared here: the names later code uses. The rest leave scope at the block's end.
local fresh, layoutFor, part, setVisible, remember, forget, claimOk, claimBad, render, diff,
    sampleCell
do

    -- ===== a cell's parts (callback only) =====

    -- whether a once-row with this key would still be written: lets a callback skip building its data
    function fresh(key)
        return dOnce[key] == nil and L.Basic()
    end

    -- the getter under which every part in `map` is where it says and carries its name in `names`.
    -- Returns { how, get } and what was seen, or false and what was seen
    local function findLayout(root, map, names)
        local seen = {}
        for _, how in ipairs({ "Child", "VisualChild" }) do
            local getter, ok, got = GETTERS[how], true, {}
            for name, path in pairs(map) do
                local node = follow(getter, root, path)
                local n = node ~= nil and tostring(read(node, "Name")) or "nil"
                got[name] = n
                if n ~= names[name] then ok = false end
            end
            seen[how] = got
            if ok then return { how = how, get = getter }, seen end
        end
        return false, seen
    end

    -- the layout of a kind's parts, decided by its first root this world load: { how, get }, or false
    -- when the parts are not where the template puts them (no marks for that kind)
    function layoutFor(kind, parts)
        local cur
        if kind.slot then cur = slotLayout else cur = layout end
        if cur ~= nil then return cur end
        local found, seen = findLayout(parts, kind.map, kind.names)
        if kind.slot then slotLayout = found else layout = found end
        if found then
            dlog(nil, "write", K.Probe, kind.kind .. "_layout", { how = found.how, root = describe(parts) })
        else
            dlog(nil, "write", K.Probe, kind.kind .. "_layout_failed", { seen = seen, root = describe(parts) })
            dlog("warn.hub.layout." .. kind.kind, "warnonce", "hub.layout." .. kind.kind,
                kind.slot and "equipment slots are not laid out as PaG's template says; no marks there"
                    or "inventory cells are not laid out as PaG's template says; no marks", seen)
        end
        return found
    end

    -- a cell's or slot's parts, each looked up at most once per poll unit. c.map is PART or SLOT_PART,
    -- and c.get the getter its layout chose
    function part(c, name)
        local p = c.parts[name]
        if p == nil then
            local path = c.map[name]
            p = path ~= nil and follow(c.get, c.root, path) or false
            c.parts[name] = p
        end
        return p or nil
    end

    -- marks show and hide through Opacity, never Visibility (crash M5): an Opacity write is render-only
    -- and queues no measure, where Collapsed<->Visible queues layout work in the node pool the crashes
    -- poison (INFERRED). A write counts once it reads back as the number written; the form it reads back
    -- in is logged once (opacity_back)
    local OPA_HELD = {}
    for _, on in ipairs({ true, false }) do
        OPA_HELD[on] = function(back)
            if fresh("probe.opacity_back") then
                dlog("probe.opacity_back", "write", K.Probe, "opacity_back", { wrote = C.OPA[on], back = describe(back) })
            end
            return tonumber(back) == C.OPA[on]
        end
    end

    -- shows (Opacity 1) or hides (Opacity 0) one part; counts the write. False when the part is
    -- missing or the write did not read back
    function setVisible(c, name, visible)
        local node = part(c, name)
        if node == nil then return false end
        c.writes = c.writes + 1
        return write(node, "Opacity", C.OPA[visible], "opacity", OPA_HELD[visible])
    end

    -- sets one part's Opacity to a strength between 0 and 1 (PaGMarks: the glow, badge and dot
    -- together); counts the write. A float may read back rounded, so it holds within LEVEL_EPS. False
    -- when the part is missing or the write did not read back
    local LEVEL_HELD = {}
    local function setLevel(c, name, level)
        local node = part(c, name)
        if node == nil then return false end
        local held = LEVEL_HELD[level]
        if held == nil then
            held = function(back)
                local b = tonumber(back)
                return b ~= nil and math.abs(b - level) < C.LEVEL_EPS
            end
            LEVEL_HELD[level] = held
        end
        c.writes = c.writes + 1
        return write(node, "Opacity", level, "opacity", held)
    end

    -- the color parts of a brush, or nil
    local function brushParts(brush)
        return brush ~= nil and colorParts(read(brush, "Color")) or nil
    end

    -- whether a brush property now holds a brush of the same color as `src` (the engine hands Lua a
    -- new reference on every read, so the color stands in for identity). It compares the color of
    -- the brush read back
    local function sameBrush(src)
        local want = brushParts(src)
        if want == nil then return function(back) return back ~= nil end end
        return function(back)
            local p = brushParts(back)
            if p == nil then return false end
            for i = 1, 4 do
                if math.abs(p[i] - want[i]) > 1 / 255 + 1e-6 then return false end
            end
            return true
        end
    end

    -- the native address a Noesis object's tostring prints ("Noesis::DependencyObject (0000028BDA4C62F0)"),
    -- or nil. A shared brush prints the same address read after read: render_brush logged the same
    -- three palette addresses in s045 and s046, where the panels' addresses differed
    local function addressOf(v)
        if v == nil then return nil end
        assertDefer("addressOf")
        local s = U.Get(tostring, v)
        return type(s) == "string" and s:match("%((%x+)%)$") or nil
    end

    -- whether a brush property now holds the very brush `src`, by its address: for the glow's fades,
    -- which have no Color for sameBrush to compare. When no address prints, only that a brush is there;
    -- which check ran is logged once (glow_check)
    local function sameObject(src)
        local want = addressOf(src)
        if fresh("probe.glow_check") then
            dlog("probe.glow_check", "write", K.Probe, "glow_check",
                { by = want ~= nil and "address" or "presence", src = describe(src) })
        end
        if want == nil then return function(back) return back ~= nil end end
        return function(back) return addressOf(back) == want end
    end

    -- writes one part's brush property; counts the write. False when the part is missing or the brush
    -- read back fails `same` (the color for a solid brush, the object for the glow's fades)
    local function brushOn(c, name, prop, brush, same)
        local node = part(c, name)
        if node == nil then return false end
        c.writes = c.writes + 1
        return write(node, prop, brush, "brush", same)
    end

    -- the brush of the tier's configured color, read off the holder for that color in the cell's (or
    -- slot's) palette. The palette brushes come from the XAML, which freezes them, so a tier's color is
    -- one of six (V2.5). Each color's brush logs its color once, to show the palette reads as drawn
    local function tierBrush(c, tier, cfg)
        local color = cfg[tier .. "_color_preset"]
        local name = C.COLOR_PART[color]
        local holder = name ~= nil and part(c, name) or nil
        local brush = holder ~= nil and read(holder, "Fill") or nil
        if brush == nil then
            if fresh("probe.brush_missing." .. tier) then
                dlog("probe.brush_missing." .. tier, "write", K.Probe, "brush_missing",
                    { tier = tier, color = tostring(color), holder = describe(holder) })
            end
            return nil
        end
        if fresh("probe.palette." .. tostring(color)) then
            dlog("probe.palette." .. tostring(color), "write", K.Probe, "palette",
                { color = color, tier = tier, parts = brushParts(brush) })
        end
        return brush, color
    end

    -- the glow's two fades in a palette color, read off their holders in the cell's PaGGlowColors, in
    -- C.GLOW_PARTS order; nil when either is missing. Each color's pair logs once, to show it reads
    local function glowFades(c, tier, color)
        local names = C.GLOW_COLOR_PART[color]
        local fades = {}
        for i = 1, #C.GLOW_PARTS do
            local holder = names ~= nil and part(c, names[i]) or nil
            fades[i] = holder ~= nil and read(holder, "Fill") or nil
            if fades[i] == nil then
                if fresh("probe.glow_missing." .. tier) then
                    dlog("probe.glow_missing." .. tier, "write", K.Probe, "glow_missing",
                        { tier = tier, color = tostring(color), holder = describe(holder) })
                end
                return nil
            end
        end
        if fresh("probe.glow_palette." .. tostring(color)) then
            dlog("probe.glow_palette." .. tostring(color), "write", K.Probe, "glow_palette",
                { color = color, tier = tier, sides = describe(fades[1]), ends = describe(fades[2]) })
        end
        return fades
    end

    -- the badge icon of a mark of this tier: the AC shield when only Armor vs AC bonuses causes gave
    -- it and ac_shield_badge is on, else the tier's icon, which buildLooks has already checked against
    -- the tier's icons
    local function iconFor(tier, cfg, ac)
        if ac and cfg.ac_shield then return E.Icon.Shield end
        return cfg[tier .. "_badge_icon"]
    end

    -- ===== what a cell shows (callback only) =====

    -- `shown` holds, per PaGId, what Lua last wrote to that cell: the key it was written for, the tier
    -- and looksGen it shows, its panel (pid), and the render state: swap (the corner switch on or
    -- not), shade, gray, glow, badge, dot (each shown or not), glyph (the icon part left visible inside the badge), glowC and dotC (the color of
    -- the brush they hold), fill (icon part -> color of its brush) and marks (the strength of the glow,
    -- badge and dot, PaGMarks' Opacity; nil when not known). A cell whose PaGId reads "-" has
    -- never been written, so it shows the template's state, NONE. A PaGId with no entry (an earlier Lua
    -- state's, or forgotten) is UNKNOWN: every part is written. A render whose writes did not all read
    -- back is remembered with err: it is written in full again only when its key, tier or looks change.
    -- A poll unit that raised is remembered with stuck: nothing until its key changes

    function remember(id, state)
        if shown[id] == nil then
            if shownN >= C.SHOWN_MAX then
                dlog("probe.shown_reset", "write", K.Probe, "shown_reset", { max = C.SHOWN_MAX })
                shown, shownN = {}, 0
            end
            shownN = shownN + 1
        end
        shown[id] = state
    end

    function forget(id)
        if id ~= nil and shown[id] ~= nil then
            shown[id] = nil
            shownN = shownN - 1
        end
    end

    -- gives a cell (or slot) its PaGId before its first write: this Lua state's seed and a serial, so
    -- no two cells and no two Lua states share one. Counts only once it reads back; a cell that cannot
    -- be labeled gets no marks (D10). After CLAIM_GIVE_UP failures with no success this world load,
    -- claims stop: the label write is refused everywhere, and retrying it on every poll is only cost
    claimOk, claimBad = 0, 0

    local function claim(c)
        if claimOk == 0 and claimBad >= C.CLAIM_GIVE_UP then
            c.claimFailed = true
            return false
        end
        local node = part(c, "id")
        local id = seed .. ":" .. tostring(cellSerial + 1)
        c.writes = c.writes + 1
        if node == nil or not write(node, "Text", id, "id", function(back) return tostring(back) == id end) then
            c.claimFailed = true
            claimBad = claimBad + 1
            dlog("warn.hub.id", "warnonce", "hub.id",
                "could not label an inventory cell, so it shows no marks. Please send the log")
            return false
        end
        claimOk = claimOk + 1
        cellSerial = cellSerial + 1
        c.id = id
        c.r.fresh = c.r.fresh + 1
        return true
    end

    -- shows or hides one part of a cell, labeling the cell first if this is its first write.
    -- !pag_diag nowrite: counts the write and returns before the label (no false hub.id warning)
    local function put(c, name, visible)
        if diag == "nowrite" then diagSkipped = diagSkipped + 1; return true end
        if c.id == nil and (c.claimFailed or not claim(c)) then return false end
        return setVisible(c, name, visible)
    end

    -- the same for the strength of the glow, badge and dot (setLevel on PaGMarks)
    local function putLevel(c, level)
        if diag == "nowrite" then diagSkipped = diagSkipped + 1; return true end
        if c.id == nil and (c.claimFailed or not claim(c)) then return false end
        return setLevel(c, "marks", level)
    end

    -- writes a part's Text; counts the write. False when the part is missing or the text did not read
    -- back. An empty Text may read back as nil
    local function setText(c, name, text)
        local node = part(c, name)
        if node == nil then return false end
        c.writes = c.writes + 1
        return write(node, "Text", text, name, function(back)
            return tostring(back) == text or (back == nil and text == "")
        end)
    end

    -- a part's Text, "" for an empty one (which may read back as nil); nil when the part is missing
    -- or the read raised. A read queues no measure
    local function getText(c, name)
        local node = part(c, name)
        if node == nil then return nil end
        assertDefer("read")
        local ok, v = pcall(getField, node, "Text")
        if not ok then return nil end
        return v == nil and "" or tostring(v)
    end

    -- a tooltip text split for its layout parts (WHY_LINE_PARTS): one line each, "" past the last.
    -- Lines past the last part stay in it, one per line (Why.Text gives at most the title and 7)
    local function splitLines(t)
        local out = {}
        for line in (t .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
        local n = #C.WHY_LINE_PARTS
        if #out > n then
            out[n] = table.concat(out, "\n", n)
            for i = #out, n + 1, -1 do out[i] = nil end
        end
        for i = #out + 1, n do out[i] = "" end
        return out
    end

    -- writes the layout parts for text `t`, given the text they were last written for (`from`; nil:
    -- not known, so each part is read first). Only a part that differs is written (a Text write
    -- queues a measure). True when every part holds its line
    local function setLines(c, t, from)
        local want = splitLines(t)
        local was = from ~= nil and splitLines(from) or nil
        local ok = true
        for i, name in ipairs(C.WHY_LINE_PARTS) do
            local cur
            if was ~= nil then cur = was[i] else cur = getText(c, name) end
            if cur ~= want[i] then ok = setText(c, name, want[i]) and ok end
        end
        return ok
    end

    -- the marks of one cell, from its verdict (tier nil: no marks; ac: only Armor vs AC bonuses
    -- causes gave it; text: the badge and dot's tooltip, nil for none) and the looks, given what it
    -- shows now (`have`). Brushes first, then the tooltip text, then hides, then shows, so a mark never
    -- shows with an old brush or another item's tooltip. Writes only what differs from `have`,
    -- everything when `have` is UNKNOWN. Returns the new render state, or nil when a write did not
    -- read back
    function render(c, tier, cfg, have, ac, text)
        local unknown = have.unknown == true
        local fill = have.fill or {}
        -- the tooltip text the cell holds: the template's "" until a claimed cell writes one, nil
        -- when not known (read before it is compared)
        local held = nil
        if have == C.NONE then held = "" elseif not unknown then held = have.text end
        -- the same for the text the layout parts were last written for (setLines)
        local lines = nil
        if have == C.NONE then lines = "" elseif not unknown then lines = have.lines end
        -- the corner switch follows the looks alone, whatever the tier
        local want = { swap = cfg.swap == true, shade = false, gray = false, glow = false, badge = false, dot = false }
        local brush, color, glyph = nil, nil, nil
        if tier ~= nil then
            want.shade = cfg[tier .. "_dim"] == true
            want.gray = cfg[tier .. "_gray"] == true
            if cfg[tier .. "_glow"] or cfg[tier .. "_badge"] or cfg[tier .. "_dot"] then
                brush, color = tierBrush(c, tier, cfg)
            end
            if brush ~= nil then
                want.glow = cfg[tier .. "_glow"] == true
                want.dot = cfg[tier .. "_dot"] == true
                glyph = C.GLYPH_PART[iconFor(tier, cfg, ac)]
                want.badge = cfg[tier .. "_badge"] == true and glyph ~= nil
            end
        end
        local now = { glowC = have.glowC, dotC = have.dotC, fill = fill }
        if brush ~= nil then
            local same = sameBrush(brush)
            if fresh("probe.render.brush." .. tier) then
                dlog("probe.render.brush." .. tier, "write", K.Probe, "render_brush",
                    { tier = tier, brush = describe(brush), parts = brushParts(brush) })
            end
            -- the glow takes its color's pair of fades, not the tier brush (D29)
            if want.glow and (unknown or have.glowC ~= color) then
                local fades = glowFades(c, tier, color)
                local ok = fades ~= nil
                if ok then
                    for i, name in ipairs(C.GLOW_PARTS) do
                        ok = brushOn(c, name, "Fill", fades[i], sameObject(fades[i])) and ok
                    end
                end
                now.glowC = ok and color or nil
                want.glow = ok
            end
            if want.dot and (unknown or have.dotC ~= color) then
                local ok = brushOn(c, "dotShape", "Fill", brush, same)
                now.dotC = ok and color or nil
                want.dot = ok
            end
            if want.badge and (unknown or fill[glyph] ~= color) then
                local ok = brushOn(c, glyph, "Fill", brush, same)
                local f = {}
                for k, v in pairs(fill) do f[k] = v end
                f[glyph] = ok and color or nil
                now.fill = f
                want.badge = ok
            end
        end
        -- the strength of the glow, badge and dot (cfg.marks, 1 unless a trade page's Subtle looks),
        -- before any of them shows. Written only while one of them shows, so a cell with none costs
        -- no write. Unwritten, they stay hidden, as for an unwritten brush: a mark never shows at a
        -- strength not verified
        local level = cfg.marks or 1
        local marks = nil
        if not unknown then marks = have.marks end
        if (want.glow or want.badge or want.dot) and marks ~= level then
            if putLevel(c, level) then
                marks = level
            else
                marks = nil
                want.glow, want.badge, want.dot = false, false, false
            end
        end
        -- the tooltip text, before the badge or dot shows, so neither offers another item's: Good
        -- carries none, so a recycled cell's old text gives way to "" before a Good badge shows. Only
        -- a change is written (a Text write queues a measure); one that did not read back keeps the
        -- badge and dot hidden, as an unwritten brush does. A hidden badge and dot leave the text as
        -- it was: the XAML takes the mouse only while one of them shows with a text. The layout parts
        -- go first, so PaGWhy holding a text means they hold its lines; "" leaves them as they are
        -- (no text, no tooltip)
        if want.badge or want.dot then
            local t = text or ""
            if held == nil then held = getText(c, "why") end
            local okLines = true
            if t ~= "" and t ~= lines then
                okLines = setLines(c, t, lines)
                lines = okLines and t or nil
            end
            if not okLines then
                want.badge, want.dot = false, false
            elseif t ~= held then
                if setText(c, "why", t) then
                    held = t
                else
                    held = nil
                    want.badge, want.dot = false, false
                end
            end
        end
        now.text = held
        now.lines = lines
        local tg = nil
        if want.badge then tg = glyph elseif not unknown then tg = have.glyph end
        local okAll = true
        for _, pass in ipairs({ false, true }) do
            for _, g in ipairs(C.GLYPHS) do
                local w = g == tg
                if w == pass then
                    local was = not unknown and have.glyph == g
                    if unknown or was ~= w then okAll = put(c, g, w) and okAll end
                end
            end
            for _, n in ipairs(C.MARK_PARTS) do
                if want[n] == pass and (unknown or have[n] ~= want[n]) then
                    okAll = put(c, n, want[n]) and okAll
                end
            end
        end
        if not okAll then return nil end
        now.swap, now.shade, now.gray, now.glow, now.badge, now.dot =
            want.swap, want.shade, want.gray, want.glow, want.badge, want.dot
        now.glyph = tg
        now.marks = marks
        return now
    end

    -- an equipment slot's badge for a Bad or Not Ideal verdict: the tier's color on the tier's icon
    -- (the AC shield for an `ac` verdict, iconFor), the other icons hidden, then the tooltip text and
    -- the icon and the badge shown. `text` is the tooltip ("" for none), `held` the text the slot
    -- holds and `lines` the text its layout parts hold (nil: not known, so it is read). Returns whether
    -- every write held, and the text the slot and its layout parts now hold
    local function renderSlot(c, tier, cfg, ac, text, held, lines)
        local brush = tierBrush(c, tier, cfg)
        local glyph = C.SLOT_GLYPH_PART[iconFor(tier, cfg, ac)]
        local ok = brush ~= nil and glyph ~= nil and brushOn(c, glyph, "Fill", brush, sameBrush(brush))
        if not ok then
            setVisible(c, "badge", false)
            return false, held, lines
        end
        for _, g in ipairs(C.SLOT_GLYPHS) do
            if g ~= glyph then setVisible(c, g, false) end
        end
        -- the text before the badge shows, so the badge never offers the last verdict's tooltip. Only
        -- a change is written: a Text write, unlike an Opacity write, queues a measure (as the label's
        -- does, once per slot)
        local okWhy = true
        -- a slot painted from unknown is read first: with the setting off it holds the template's "",
        -- and writing "" again would queue a measure for nothing
        if held == nil then held = getText(c, "why") end
        -- the layout parts first, as in a cell. Parts that did not read back leave the slot no
        -- tooltip ("") rather than a wrong one, and the paint is remembered with err
        local want = text
        if text ~= "" and text ~= lines then
            if setLines(c, text, lines) then
                lines = text
            else
                lines, okWhy, want = nil, false, ""
            end
        end
        if want ~= held then
            local okText = setText(c, "why", want)
            held = okText and want or nil
            okWhy = okWhy and okText
        end
        -- the corner first, so the badge never shows in the corner it is leaving. All three writes
        -- always run: an Opacity that lands but reads back in an unexpected form must not keep the
        -- badge hidden (the read-back form is logged once, see OPA_HELD)
        local okSwap = setVisible(c, "swap", cfg.swap == true)
        local okGlyph = setVisible(c, glyph, true)
        local okBadge = setVisible(c, "badge", true)
        return okWhy and okSwap and okGlyph and okBadge, held, lines
    end

    -- a slot's marks: the badge for a verdict that has one (judgeKey keeps a tier only for Bad and Not
    -- Ideal), else the badge hidden. A slot is labeled like a cell before its first write. `have` is
    -- what it showed (as for render); the result keeps the tooltip text the slot holds, which a hidden
    -- badge leaves as it was (the XAML takes the mouse only while the badge shows)
    local function paintSlot(c, tier, ac, text, have)
        if diag ~= "nowrite" and c.id == nil and (c.claimFailed or not claim(c)) then return nil end
        local held, lines = nil, nil
        if have == C.NONE then
            held, lines = "", ""
        elseif have ~= C.UNKNOWN then
            held, lines = have.text, have.lines
        end
        local ok
        if tier ~= nil then
            ok, held, lines = renderSlot(c, tier, lookCfg, ac, text or "", held, lines)
        else
            ok = setVisible(c, "badge", false)
        end
        return ok and { text = held, lines = lines } or nil
    end

    -- the looks a cell of this kind in this panel is drawn with: a trade page's item cells take
    -- trade_marks' (lookCfg.trade, nil for Full); every other cell, and every slot, lookCfg
    local function looksFor(kind, pid)
        if kind.slot or lookCfg.trade == nil then return lookCfg end
        local p = panels[pid]
        if p ~= nil and C.TRADE_PAGES[p.name] then return lookCfg.trade end
        return lookCfg
    end

    -- whether a verdict of this tier shows anything on a cell (or slot) of this kind, drawn with `cfg`
    local function hasMark(kind, tier, cfg)
        if tier == nil then return false end
        if kind.slot then return true end
        return cfg.mark ~= nil and cfg.mark[tier] == true
    end

    -- renders one cell or slot and remembers what it now shows, with the key, tier, ac and looks it
    -- was written for, and its tooltip text: the text it holds and `want`, the text it was asked
    -- for, which diff compares, so a cell or slot whose paint failed repaints once per change of
    -- text. A render that did not fully read back is remembered with err (see `shown`)
    local function paint(c, kind, tier, ac, have, key, pid, text)
        forget(c.id)
        local now
        if kind.slot then
            now = paintSlot(c, tier, ac, text, have)
        else
            now = render(c, tier, looksFor(kind, pid), have, ac, text)
        end
        local r = c.r
        r.n = r.n + 1
        r.writes = r.writes + c.writes
        if kind.slot then r.slots = r.slots + 1 else r.cells = r.cells + 1 end
        totals.renders = totals.renders + 1
        if c.id ~= nil then
            if now == nil then now = { err = true } end
            now.want = text or ""
            now.key, now.tier, now.ac, now.lg, now.pid = key, tier, ac == true, looksGen, pid
            remember(c.id, now)
        end
    end

    -- one cell's marks against its current verdict (design §8.5). `c` holds its parts and its id (nil
    -- while PaGId reads "-"), `key` its item ("" for an empty cell), `who` the character it is judged
    -- for (false: nobody). A key with no current verdict is wanted, in poll order, for Tick to judge.
    -- Hides need no verdict: a cell whose item changed is hidden at once, and marked when its new
    -- item's verdict arrives
    function diff(c, kind, key, pid, who)
        local vkey = nil
        -- a Ware's key (keyOf, ware_marks off) has no verdict, so its cell shows no mark
        if key ~= "" and key:sub(-#C.WARE) ~= C.WARE then vkey = kind.slot and (key .. "@eq") or key end
        local v = nil
        if who and vkey then
            v = verdictOf(who, vkey)
            if v == nil then
                wantKey(who, vkey)
            else
                -- a panel shown with cells waits for its first verdict (panel_open, openRow)
                local p = panels[pid]
                if p ~= nil and p.open ~= nil and p.open.first == nil then p.open.first = U.Ticks() end
            end
        end
        if c.id == nil then
            -- labeled before any write (D10): a cell that cannot be labeled gets none, and costs one
            -- refused label write per poll until claims give up
            if v ~= nil and hasMark(kind, v.tier, looksFor(kind, pid)) and (diag == "nowrite" or claim(c)) then
                paint(c, kind, v.tier, v.ac, C.NONE, key, pid, v.text)
            end
            return
        end
        local s = shown[c.id]
        if s == nil then
            heat()
            paint(c, kind, v and v.tier, v and v.ac, C.UNKNOWN, key, pid, v and v.text)
        elseif s.key ~= key then
            heat()
            paint(c, kind, v and v.tier, v and v.ac, (s.err or s.stuck) and C.UNKNOWN or s, key, pid, v and v.text)
        elseif s.stuck then
            -- a poll unit raised on this cell: nothing until its key changes
        elseif not who then
            -- nobody judges it (no observed character, observeUi; a slot with no wearer, slotKeyOf):
            -- a mark still showing is hidden
            if s.tier ~= nil then paint(c, kind, nil, nil, s.err and C.UNKNOWN or s, key, pid) end
        elseif v ~= nil and (v.tier ~= s.tier or v.ac ~= (s.ac == true)
            or (v.tier ~= nil and s.lg ~= looksGen)
            or (v.tier ~= nil and (v.text or "") ~= s.want)) then
            paint(c, kind, v.tier, v.ac, s.err and C.UNKNOWN or s, key, pid, v.text)
        end
    end

    -- the first children of a cell's PaGIO (or of the node itself), for a probe row
    function sampleCell(node)
        for _, step in ipairs({ { 2, "PaGParts" }, { 3, "PaGIO" } }) do
            local okc, child = pcall(visualChild, node, step[1])
            if not okc or child == nil or tostring(read(child, "Name")) ~= step[2] then break end
            node = child
        end
        local n = read(node, "VisualChildrenCount")
        if type(n) ~= "number" then return { VisualChildrenCount = tostring(n) } end
        local out = {}
        for i = 1, math.min(n, 12) do
            local okc, child = pcall(visualChild, node, i)
            if okc and child ~= nil then
                local text = read(child, "Text")
                out[#out + 1] = { i = i, name = tostring(read(child, "Name")),
                    text = text ~= nil and tostring(text) or nil }
            end
        end
        return out
    end
end

-- declared here: the names later code uses. The rest leave scope at the block's end.
local walkDueAt, planPanels, trace, ui
do

    -- ===== panels: plain data (Tick and the callback) =====

    -- the tick from which walk work is due (a panel to discover, verify or rewalk); math.huge if none.
    -- The callback sets it, the scheduler reads it
    walkDueAt = math.huge

    -- a panel: one child of ContentRoot, as plain data. pid = name#ordinal among same-named children.
    -- state: discover (needs a full walk), verify (cells learned from an earlier panel of this name,
    -- being checked), live, empty (walked, no cells; walked again at EMPTY_REWALKS), barren (no more
    -- walks until it is shown again or renamed), stuck (restarted too often; the same).
    -- cells: { kind, path, names, counts, pstr } per cell root found, path being child indexes from the
    -- panel root. hosts, pins and nodeList are built from cells on Tick (PanelPlan). slots: how many
    -- cells are slots. slotOnly: live with slots only, never learned, and on a trade page walked again
    -- at slotAt for item cells (SLOT_REWALK_PAGES). why: what the next full walk is for (the walk row). chainVisits: visits of the walks
    -- since emptyN was last 0. lists: { path, pstr, name } per item list (C.LIST_ROOTS) the walks found
    -- no cell in, the outermost only
    local function newPanel(pid, name, idx)
        return { pid = pid, name = name, idx = idx, visible = nil, state = "discover", lists = {},
                 cells = {}, cellSet = {}, counts = {}, hosts = {}, pins = {}, nodeList = {},
                 walk = nil, verify = nil, subQ = {}, subWalks = 0, needHosts = false,
                 verifyAt = 0, nextRewalk = 0, emptyN = 0, missAt = -1e9,
                 restarts = { n = 0, since = U.Ticks() },
                 slots = 0, slotOnly = false, slotTries = 0, slotAt = math.huge, why = "new", chainVisits = 0 }
    end

    local function slice(t, i, j)
        local out = {}
        for k = i, j do out[#out + 1] = t[k] end
        return out
    end

    local function computePollable()
        pollable = false
        for _, p in pairs(panels) do
            if p.visible ~= false and (#p.hosts > 0 or #p.pins > 0) then pollable = true; return end
        end
    end

    local function sameCells(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do
            if a[i] ~= b[i] then return false end
        end
        return true
    end

    -- Tick: plans every panel whose cells changed, and keeps what a live panel learned by its name. A
    -- plan made with no count a verify kept (p.counts empty) follows from the cells alone, so it is kept
    -- with them, never handed out; a panel shown again from those same cells (newPanel, from learned)
    -- takes a copy instead of planning them again (panel_plan reused)
    function planPanels()
        assertTick("planPanels")
        local any = false
        for _, p in pairs(panels) do
            if p.needHosts then
                p.needHosts = false
                local l = learned[p.name]
                local reused = l ~= nil and l.plan ~= nil and next(p.counts) == nil and sameCells(p.cells, l.cells)
                if reused then
                    -- the same cells under lists found again (a full walk after a restart): kept as found,
                    -- so a list path that no longer holds does not restart every later show
                    l.lists = PanelPlan.CopyLists(p.lists)
                else
                    PanelPlan.Build(p, C.HOST_SPAN, C.SLOT_PROPS)
                    l = nil
                    -- slots alone are a page not yet filled (Trade): kept, they would stand for it on every open
                    if #p.cells > 0 and not p.slotOnly then
                        l = { cells = slice(p.cells, 1, #p.cells), lists = PanelPlan.CopyLists(p.lists) }
                        if next(p.counts) == nil then l.plan = { hosts = p.hosts, pins = p.pins, nodeList = p.nodeList } end
                        learned[p.name] = l
                    end
                end
                if l ~= nil and l.plan ~= nil then p.hosts, p.pins, p.nodeList = PanelPlan.Copy(l.plan) end
                -- a verify in progress starts again on the new node list
                if p.verify ~= nil then p.verify.k = 1 end
                if p.state == "verify" and p.verify == nil then p.verify = { k = 1 } end
                L.Write(K.Probe, "panel_plan", { panel = p.pid, state = p.state, cells = #p.cells,
                    hosts = #p.hosts, pins = #p.pins, nodes = #p.nodeList, subWalks = p.subWalks,
                    lists = #p.lists > 0 and #p.lists or nil, reused = reused or nil })
                any = true
            end
        end
        if any then
            computePollable()
            heat()
        end
    end

    -- a panel walked again from scratch: a name it relied on is gone, or a count dropped where items do
    -- not come and go. More than RESTARTS_MAX in SAFETY_REWALK ticks: stuck until shown again or renamed
    local function restart(p, why)
        local now = U.Ticks()
        if now - p.restarts.since > C.SAFETY_REWALK then p.restarts.n, p.restarts.since = 0, now end
        p.restarts.n = p.restarts.n + 1
        p.walk, p.verify, p.subQ = nil, nil, {}
        if p.restarts.n > C.RESTARTS_MAX then
            p.state = "stuck"
            dlog(nil, "write", K.Probe, "panel_stuck", { panel = p.pid, why = why, restarts = p.restarts.n })
        else
            p.state, p.why = "discover", why
            p.counts = {}
            dlog(nil, "write", K.Probe, "panel_rediscover", { panel = p.pid, why = why })
        end
    end

    -- a verify soon, at most once per SAFETY_REWALK ticks: a host or pin did not resolve
    local function requestVerify(p)
        local now = U.Ticks()
        if p.verify ~= nil or p.needHosts or p.state == "stuck" or now - p.missAt < C.SAFETY_REWALK then return end
        p.missAt = now
        p.verify = { k = 1 }
    end

    -- ===== nodes (callback only) =====

    -- each callback keeps its handles in `ctx`, which dies with it: content, a panel's root and the nodes
    -- below it by path string (memo), and each host's node and child count
    local function panelRoot(ctx, p)
        local r = ctx.roots[p.pid]
        if r ~= nil then return r or nil end
        local node = U.Get(visualChild, ctx.content, p.idx)
        if node == nil or nameOf(node) ~= p.name then node = nil end
        ctx.roots[p.pid] = node or false
        return node
    end

    local function memoFor(ctx, p, root)
        local m = ctx.memo[p.pid]
        if m == nil then
            m = { [""] = root }
            ctx.memo[p.pid] = m
        end
        return m
    end

    -- the node at path[1..upto] below the memo's root, or nil
    local function nodeAt(memo, path, upto)
        upto = upto or #path
        if upto == 0 then return memo[""] end
        local key = table.concat(path, ".", 1, upto)
        local hit = memo[key]
        if hit ~= nil then return hit or nil end
        local parent = nodeAt(memo, path, upto - 1)
        local node = parent ~= nil and U.Get(visualChild, parent, path[upto]) or nil
        memo[key] = node or false
        return node
    end

    -- a host's node, Name-checked, and its child count, read once per callback
    local function hostNode(ctx, memo, host)
        local h = ctx.hostAt[host]
        if h ~= nil then return h.node, h.n end
        local node = nodeAt(memo, host.path)
        local n = 0
        if node ~= nil and nameOf(node) == host.name then
            local c = read(node, "VisualChildrenCount")
            if type(c) == "number" then n = c else node = nil end
        else
            node = nil
        end
        if node ~= nil and host.lastN ~= n then
            if host.lastN ~= nil then heat() end
            host.lastN = n
        end
        ctx.hostAt[host] = { node = node, n = n }
        return node, n
    end

    -- the cell root under a host's child `i`, the node above it, and for a slot the node named for its
    -- slot (host.propStep); nil when the host's suffix does not lead to a root of the host's kind
    local function hostCell(hn, host, i)
        local node = U.Get(visualChild, hn, i)
        if node == nil then return nil end
        local parent, at = hn, host.propStep == 0 and node or nil
        for s, j in ipairs(host.suffix) do
            parent = node
            node = U.Get(visualChild, node, j)
            if node == nil then return nil end
            if s == host.propStep then at = node end
        end
        if nameOf(node) ~= host.rootName then return nil end
        return node, parent, at
    end

    -- a host child that led to no cell root is walked on its own once (it may hold cells along another
    -- path), and again only after MISS_RETRY_TICKS
    local function hostMissed(p, host, i)
        local now = U.Ticks()
        local at = host.missed[i]
        if at ~= nil and now - at < C.MISS_RETRY_TICKS then return end
        host.missed[i] = now
        p.subQ[#p.subQ + 1] = { path = host.path, from = i, to = i }
    end

    -- ===== keys (callback only) =====

    -- whether a cell's item is marked as a Ware, from the item's view model: IsWare is the property the
    -- game's own Ware icon triggers on (DataTemplates.xaml:632-641, InventoryWaresCellItemImageStyle)
    local function isWare(obj)
        local v = read(obj, "IsWare")
        if type(v) ~= "boolean" then
            if fresh("probe.ware_unread") then
                dlog("probe.ware_unread", "write", K.Probe, "ware_unread", { got = describe(v) })
            end
            return false
        end
        if v and fresh("probe.ware_seen") then dlog("probe.ware_seen", "write", K.Probe, "ware_seen", {}) end
        return v
    end

    -- a cell's item: DataContext.Object.EntityUUID on the cell root, or on the node above it when the
    -- root has none, with C.WARE appended for a Ware while ware_marks is off. "" for an empty cell; nil
    -- when neither node has a DataContext (the cell is skipped; key_unread is logged once per kind).
    -- Not a slot's: see slotKeyOf
    local function keyOf(node, parent, kind)
        local dc, which = read(node, "DataContext"), "root"
        if dc == nil and parent ~= nil then dc, which = read(parent, "DataContext"), "parent" end
        if dc == nil then
            dlog("probe.key_unread." .. kind.kind, "write", K.Probe, "key_unread", { kind = kind.kind })
            return nil
        end
        dlog("probe.key_source." .. kind.kind .. "." .. which, "write", K.Probe, "key_source",
            { kind = kind.kind, node = which })
        local obj = read(dc, "Object")
        if obj == nil then return "" end
        local raw = U.Get(function() return tostring(obj.EntityUUID) end)
        local uuid = U.FindUuid(raw)
        if uuid == nil then
            if fresh("probe.key_unparsed." .. kind.kind) then
                dlog("probe.key_unparsed." .. kind.kind, "write", K.Probe, "key_unparsed",
                    { kind = kind.kind, raw = tostring(raw) })
            end
            return ""
        end
        if not lookCfg.ware_marks and isWare(obj) then return uuid .. C.WARE end
        return uuid
    end

    -- ===== equipment slots: whose, and what (callback only) =====

    -- A slot's DataContext is bound ({Binding Equipment.<Prop>}) and the nodes between it and its
    -- doll inherit theirs, so neither its item nor its wearer reads off the slot (s045). Both read off
    -- the wearer's view model: the nearest node above the slots whose own DataContext reads as a
    -- character (s047: a party panel doll's EquipmentHolder), or, on a panel in C.WEARER_ROOT, the
    -- character its root's DataContext names (s047: CharacterPanel)

    -- a character's EntityUUID and Equipment, when `vm` reads as a character's view model. An item's
    -- (the Helmet slot's own DataContext) has no Equipment
    local function entityUuid(o) return tostring(o.EntityUUID) end

    -- the once-key `base.a[.b]`, built once per name (wearerOf and slotKeyOf run on every poll)
    local onceKeys = {}
    local function onceKeyOf(base, a, b)
        local t = onceKeys[base]
        if t == nil then t = {}; onceKeys[base] = t end
        local ka = t[a]
        if ka == nil then ka = { key = base .. "." .. a }; t[a] = ka end
        if b == nil then return ka.key end
        local k = ka[b]
        if k == nil then k = ka.key .. "." .. b; ka[b] = k end
        return k
    end

    local function charVm(vm)
        if vm == nil then return nil end
        local eq = read(vm, "Equipment")
        if eq == nil then return nil end
        local who = U.FindUuid(U.Get(entityUuid, vm))
        if who == nil then return nil end
        return who, eq
    end

    -- the wearer whose view model is the DataContext of the node at path[1..d]: { who, eq, panel },
    -- or false. Read once per callback per node
    local function wearerAt(ctx, p, memo, path, d)
        local ck = p.pid .. "|" .. table.concat(path, ".", 1, d)
        local e = ctx.wear[ck]
        if e ~= nil then return e end
        local node = nodeAt(memo, path, d)
        local who, eq = charVm(node ~= nil and read(node, "DataContext") or nil)
        e = who ~= nil and { who = who, eq = eq, panel = p.name } or false
        ctx.wear[ck] = e
        return e
    end

    -- whose a host's or pin's slots are (D27): { who, eq, panel }, or false when no wearer reads or
    -- the host spansDolls (its slots show no mark). `u.path` holds every node above a host's slots,
    -- or a pin's slot. The depth the wearer was found at is kept on `u` (wd); once it stops reading,
    -- the path is searched again, at most every WEARER_RETRY ticks
    local function wearerOf(ctx, p, memo, u)
        local steps = C.WEARER_ROOT[p.name]
        local e, mode, depth
        if steps ~= nil then
            local ck = p.pid .. "|root"
            e = ctx.wear[ck]
            if e == nil then
                local vm = read(memo[""], "DataContext")
                for _, s in ipairs(steps) do
                    if vm == nil then break end
                    vm = read(vm, s)
                end
                local who, eq = charVm(vm)
                e = who ~= nil and { who = who, eq = eq, panel = p.name } or false
                ctx.wear[ck] = e
            end
            mode, depth = "root", 0
        elseif u.spansDolls then
            local once = onceKeyOf("probe.slot_spans_dolls", p.name)
            if fresh(once) then
                dlog(once, "write", K.Probe, "slot_spans_dolls", { panel = p.name, depth = #u.path })
            end
            return false
        else
            if u.wd ~= nil then
                e = wearerAt(ctx, p, memo, u.path, u.wd)
                if not e then u.wd = nil end
            end
            if u.wd == nil then
                local now = U.Ticks()
                if now - (u.wdAt or -1e9) < C.WEARER_RETRY then return false end
                u.wdAt = now
                for d = #u.path, 0, -1 do
                    e = wearerAt(ctx, p, memo, u.path, d)
                    if e then u.wd = d; break end
                end
            end
            mode, depth = "node", u.wd
        end
        if not e then
            local once = onceKeyOf("probe.slot_no_wearer", p.name)
            if fresh(once) then
                dlog(once, "write", K.Probe, "slot_no_wearer", { panel = p.name, mode = mode, depth = #u.path })
            end
            return false
        end
        -- once per panel name and wearer: which character each doll reads as, and how
        if u.logged ~= e.who then
            u.logged = e.who
            local once = onceKeyOf("probe.slot_wearer", p.name, e.who)
            if fresh(once) then
                dlog(once, "write", K.Probe, "slot_wearer",
                    { panel = p.name, mode = mode, depth = depth, char = e.who, observed = obsWho })
            end
        end
        return e
    end

    -- an equipment slot's key and the character it is judged for (D27): the item its wearer's
    -- Equipment holds in its place, and its wearer. `at` is the node named for the slot. "" and false
    -- (no mark) when there is no wearer, no slot name, or the wearer's Equipment does not read there;
    -- "" for an empty slot. The first time per panel and slot, the slot's own item is read too where it
    -- reads (the Helmet's) and logged against the wearer's (slot_check)
    local function slotKeyOf(cellRoot, parent, wear, at)
        if not wear then return "", false end
        local prop = at ~= nil and C.SLOT_PROPS[nameOf(at)] or nil
        if prop == nil then
            local once = onceKeyOf("probe.slot_no_prop", wear.panel)
            if fresh(once) then
                dlog(once, "write", K.Probe, "slot_no_prop", { panel = wear.panel })
            end
            return "", false
        end
        local s = read(wear.eq, prop)
        if s == nil then
            local once = onceKeyOf("probe.slot_prop_unread", wear.panel, prop)
            if fresh(once) then
                dlog(once, "write", K.Probe, "slot_prop_unread", { panel = wear.panel, prop = prop })
            end
            return "", false
        end
        local item = read(s, "Item")
        local key = ""
        if item ~= nil then
            local raw = U.Get(entityUuid, item)
            key = U.FindUuid(raw) or ""
            if key == "" and fresh("probe.key_unparsed.slot") then
                dlog("probe.key_unparsed.slot", "write", K.Probe, "key_unparsed", { kind = "slot", raw = tostring(raw) })
            end
        end
        local once = onceKeyOf("probe.slot_check", wear.panel, prop)
        if fresh(once) then
            local dc = read(cellRoot, "DataContext")
            if dc == nil and parent ~= nil then dc = read(parent, "DataContext") end
            local ownItem = dc ~= nil and read(dc, "Item") or nil
            local own = ownItem ~= nil and U.FindUuid(U.Get(entityUuid, ownItem)) or nil
            local match = nil
            if own ~= nil then match = own == key end
            dlog(once, "write", K.Probe, "slot_check", { panel = wear.panel, prop = prop, char = wear.who,
                item = key, own = own, match = match })
        end
        return key, wear.who
    end

    -- ===== one cell (callback only) =====

    -- a cell or slot root's parts and id: { root, map, get, parts, writes, r, id }, or nil when its
    -- parts are not where the template puts them
    local function cellAt(cellRoot, kind)
        local parts = U.Get(visualChild, cellRoot, kind.i)
        if parts == nil or nameOf(parts) ~= kind.parts then
            if fresh("probe.parts_missing." .. kind.kind) then
                dlog("probe.parts_missing." .. kind.kind, "write", K.Probe, "parts_missing",
                    { kind = kind.kind, root = describe(cellRoot), got = parts ~= nil and nameOf(parts) or "nil" })
            end
            return nil
        end
        local lay = layoutFor(kind, parts)
        if not lay then return nil end
        local c = { root = parts, map = kind.map, get = lay.get, parts = {}, writes = 0, r = toTick.r }
        local idNode = part(c, "id")
        local idText = idNode ~= nil and read(idNode, "Text") or nil
        if idText == nil then
            dlog("probe.id_unread." .. kind.kind, "write", K.Probe, "id_unread", { kind = kind.kind })
            return nil
        end
        idText = tostring(idText)
        if idText ~= "-" then c.id = idText end
        return c
    end

    -- hides what a cell shows: everything when what it shows is not known
    local function hideCell(c, kind, have)
        if kind.slot then return setVisible(c, "badge", false) end
        return render(c, nil, lookCfg, have or C.UNKNOWN) ~= nil
    end

    local unitC, unitKey = nil, nil   -- the unit in progress, for unitFailed

    -- `wear` and `at`, for a slot: its wearer (wearerOf) and the node named for it
    local function pollUnit(cellRoot, parent, kind, pid, wear, at)
        unitC, unitKey = nil, nil
        local c = cellAt(cellRoot, kind)
        if c == nil then return end
        unitC = c
        local key, who
        if kind.slot then
            key, who = slotKeyOf(cellRoot, parent, wear, at)
        else
            key, who = keyOf(cellRoot, parent, kind), obsWho
        end
        if key == nil then return end
        unitKey = key
        diff(c, kind, key, pid, who)
    end

    -- a unit raised: the cell is hidden if it can be, and left alone until its key changes. Never latches
    local function unitFailed(err, kind, pid)
        totals.unitErrors = totals.unitErrors + 1
        local c = unitC
        local s = c ~= nil and c.id ~= nil and shown[c.id] or nil
        if c ~= nil and c.id ~= nil and not (s ~= nil and s.stuck and s.key == unitKey) then
            -- hidden once: a cell that raises on every poll is not written on every poll
            pcall(hideCell, c, kind, C.UNKNOWN)
            forget(c.id)
            remember(c.id, { key = unitKey, stuck = true, pid = pid })
        end
        noteError("hub.poll", err)
    end

    local function unit(cellRoot, parent, kind, pid, wear, at)
        local ok, err = pcall(pollUnit, cellRoot, parent, kind, pid, wear, at)
        if not ok then unitFailed(err, kind, pid) end
    end

    -- a host's or pin's wearer when its kind is slot (nil for cells); false when wearerOf raised
    local function unitWearer(ctx, p, memo, u)
        if not C.KINDS[u.kind].slot then return nil end
        local ok, e = pcall(wearerOf, ctx, p, memo, u)
        if ok then return e end
        noteError("hub.wearer", e)
        return false
    end

    -- ===== stage 2: ContentRoot's children (callback only) =====

    -- a show of a panel with cells (p.open: markStage, or a walk that found its first cells) writes one
    -- panel_open row: ticks from the show to the first diff with a verdict (diff), the callbacks that
    -- ran (cbs, the show's included) and the longest wait among those after the show. Written at that
    -- verdict (end of uiBody), or at hide or drop with first = nil; `ended` says which
    local function openRow(p, ctx, ended)
        local o = p.open
        if o == nil then return end
        p.open = nil
        -- clearAll's terminal mark stage has no serial: nothing to time, and the compare would raise
        if ctx.serial == nil then return end
        if o.serial < ctx.serial and ctx.wait > o.maxWait then o.maxWait = ctx.wait end
        dlog(nil, "write", K.Probe, "panel_open", { panel = p.pid, ticks = (o.first or U.Ticks()) - o.at,
            first = o.first, cbs = ctx.serial - o.serial + 1, maxWait = o.maxWait, ended = ended })
    end

    local function dropPanel(pid, ctx)
        local p = panels[pid]
        -- a window closed by removal never flips its visibility, so panel_vis does not see it
        if p ~= nil and #p.cells > 0 then
            dlog(nil, "write", K.Probe, "panel_drop", { panel = pid, state = p.state, cells = #p.cells })
        end
        if p ~= nil then openRow(p, ctx, "drop") end
        panels[pid] = nil
        for id, s in pairs(shown) do
            if s.pid == pid then shown[id] = nil; shownN = shownN - 1 end
        end
        if pollCur ~= nil and pollCur.pid == pid then pollCur.h, pollCur.i = 1, 1 end
    end

    -- reads ContentRoot's children: their names (seenAt, for observe), which panels opened and closed
    -- (a child named in C.UNMARKED_PANELS is never one), and each panel's visibility. False when the
    -- children could not be read in full (unknown: nothing changes on this callback)
    local function markStage(ctx)
        local n = read(ctx.content, "VisualChildrenCount")
        if type(n) ~= "number" or n <= 0 or n >= C.GATE_CHILDREN then
            seenAt = nil
            return false
        end
        local present, at, ord = {}, {}, {}
        for i = 1, n do
            local node = U.Get(visualChild, ctx.content, i)
            if node ~= nil then
                local name = nameOf(node)
                if at[name] == nil then at[name] = i end
                if not C.UNMARKED_PANELS[name] then
                    ord[name] = (ord[name] or 0) + 1
                    present[#present + 1] = { pid = name .. "#" .. ord[name], name = name, idx = i, node = node }
                end
            end
        end
        seenAt = at
        local live = {}
        for _, e in ipairs(present) do live[e.pid] = true end
        for pid in pairs(panels) do
            if not live[pid] then
                dropPanel(pid, ctx)
                ctx.changed = true
            end
        end
        order = {}
        for _, e in ipairs(present) do
            local p = panels[e.pid]
            if p == nil then
                p = newPanel(e.pid, e.name, e.idx)
                local l = learned[e.name]
                local slots = 0
                if l ~= nil then
                    for _, cell in ipairs(l.cells) do if cell.kind == C.SLOT.kind then slots = slots + 1 end end
                end
                -- an entry of slots alone is never reused (planPanels does not keep one): it would
                -- stand for a page whose item cells came later
                if l ~= nil and slots < #l.cells then
                    p.cells, p.slots, p.lists = slice(l.cells, 1, #l.cells), slots, PanelPlan.CopyLists(l.lists)
                    for _, cell in ipairs(p.cells) do p.cellSet[cell.pstr] = true end
                    p.state, p.needHosts = "verify", true
                end
                if barrenNames[e.name] then p.why = "barren" end
                panels[e.pid] = p
                ctx.changed = true
            end
            p.idx = e.idx
            ctx.roots[e.pid] = e.node
            local vis = visibleOf(e.node) ~= false
            if vis ~= p.visible then
                local was = p.visible
                if vis and p.visible == false then
                    if p.state == "live" then
                        p.verify = p.verify or { k = 1 }
                    elseif p.state == "empty" or p.state == "barren" or p.state == "stuck" then
                        p.state, p.emptyN = "discover", 0
                        p.restarts = { n = 0, since = U.Ticks() }
                        p.why = barrenNames[p.name] and "barren" or "shown"
                    end
                end
                if p.visible ~= nil then ctx.changed = true end
                p.visible = vis
                -- shown with cells (a known panel, or a new one from learned): Tick re-reads its
                -- characters and items (rereadDirty), and panel_open times it (openRow)
                if vis and #p.cells > 0 then
                    toTick.show = true
                    if ctx.serial ~= nil then p.open = p.open or { at = U.Ticks(), serial = ctx.serial, maxWait = 0 } end
                elseif not vis then
                    openRow(p, ctx, "hide")
                end
                -- panels that hold or held cells only: the cell-less HUD flips often and would fill rows
                if (was ~= nil or vis) and (#p.cells > 0 or learned[p.name] ~= nil or p.slotOnly)
                    and (ctx.visRows or 0) < C.VIS_ROWS then
                    ctx.visRows = (ctx.visRows or 0) + 1
                    dlog(nil, "write", K.Probe, "panel_vis", { panel = p.pid, vis = vis,
                        was = was == nil and "new" or was, state = p.state, cells = #p.cells, slots = p.slots })
                end
            end
            order[#order + 1] = e.pid
        end
        if ctx.changed then heat() end
        computePollable()
        return true
    end

    -- ===== stage 3: whose cells these are (callback only) =====

    local function selectedOf(w)
        return U.FindUuid(U.Get(function()
            return tostring(w.DataContext.CurrentPlayer.SelectedCharacter.EntityUUID)
        end))
    end

    -- the ContentRoot child with this name, where this callback's mark stage saw it; nil when it was
    -- not there or the children could not be read
    local function widgetAt(content, name)
        local i = seenAt and seenAt[name]
        if i == nil then return nil end
        local w = U.Get(visualChild, content, i)
        if w == nil or nameOf(w) ~= name then return nil end
        return w
    end

    -- the one character every cell is judged for (user rule 1): the trading character while the Trade
    -- widget is shown, else the selected one; never the merchant. Only this callback's reads count:
    -- when the read that applies fails, or whether Trade is shown cannot be read, nobody is judged
    -- (false: every mark is hidden, see diff), never the selected character in a trade and never a
    -- value from an earlier callback. A change is handed to Tick (toTick), which judges for it
    local function observeUi(ctx)
        local content = ctx.content
        local sel, via = nil, nil
        local hb = widgetAt(content, "HotBar")
        if hb ~= nil then sel, via = selectedOf(hb), "HotBar" end
        if sel == nil then
            for _, pid in ipairs(order) do
                local p = panels[pid]
                if p ~= nil and p.visible ~= false and (#p.hosts > 0 or #p.pins > 0) then
                    local w = panelRoot(ctx, p)
                    sel = w ~= nil and selectedOf(w) or nil
                    if sel ~= nil then via = p.name; break end
                end
            end
        end
        if sel ~= nil then
            dlog("probe.selected_read." .. tostring(via), "write", K.Probe, "selected_read", { via = via, char = sel })
        end

        -- whether the Trade widget is shown: nil while unknown
        local trade, tw = nil, nil
        if seenAt ~= nil then
            if seenAt.Trade == nil then
                trade = false
            else
                tw = widgetAt(content, "Trade")
                if tw ~= nil then
                    trade = visibleOf(tw)
                    dlog("probe.trade_widget." .. tostring(trade), "write", K.Probe, "trade_widget", { shown = trade, unknown = trade == nil or nil })
                end
            end
        end
        local who, wvia = sel or false, "selected"
        if trade == nil then
            who, wvia = false, "unknown"
            dlog("probe.trade_unknown", "write", K.Probe, "trade_unknown", { seen = seenAt ~= nil })
        elseif trade then
            wvia = "trading"
            who = U.FindUuid(U.Get(function()
                return tostring(tw.DataContext.CurrentTradingCharacter.EntityUUID)
            end)) or false
            dlog("probe.trading_read." .. tostring(who ~= false), "write", K.Probe, "trading_read", { char = tostring(who) })
        end
        if who ~= obsWho then
            dlog(nil, "write", K.Char, "observed", { from = obsWho, to = who, via = wvia })
            obsWho = who
            toTick.who, toTick.via, toTick.whoChanged = who, wvia, true
            heat()
            burstMode = true
            ctx.changed = true
        end
        obsVia = wvia
    end

    -- ===== stage 4: the poll (callback only) =====

    -- one pass over every cell of every visible panel that has cells, in ContentRoot order, resumed
    -- across callbacks by a cursor of plain data (pollCur: panel, host or pin, child). True when the pass
    -- completed on this callback. A pass that found nothing rests: the next starts at pollNext, at once
    -- while hot or when a render is asked for
    -- one cell at least per callback once a pass is under way, however much of the budget the stages
    -- before it used: a slow engine paints later, never not at all
    local function pollStage(ctx, t0, limit)
        local did = false
        local cur = pollCur
        if cur == nil then
            local now = U.Ticks()
            if now < pollNext and hot == 0 and not want.render then return false end
            cur = { k = 1, pid = order[1], h = 1, i = 1, r0 = totals.renders, at = now }
            pollCur = cur
            want.render = nil
        end
        while cur.k <= #order do
            if order[cur.k] ~= cur.pid then
                -- the panel list changed since the cursor was made: find its panel again, or go on
                local found = nil
                for k, pid in ipairs(order) do
                    if pid == cur.pid then found = k; break end
                end
                if found ~= nil then cur.k = found else cur.pid, cur.h, cur.i = order[cur.k], 1, 1 end
            end
            local p = panels[cur.pid]
            local root = (p ~= nil and p.visible ~= false and (#p.hosts > 0 or #p.pins > 0)) and panelRoot(ctx, p) or nil
            if root ~= nil then
                local memo = memoFor(ctx, p, root)
                local nh = #p.hosts
                while cur.h <= nh + #p.pins do
                    if cur.h <= nh then
                        local host = p.hosts[cur.h]
                        local hn, n = hostNode(ctx, memo, host)
                        if hn == nil then
                            requestVerify(p)
                            cur.h, cur.i = cur.h + 1, 1
                        else
                            local wear, wearRead = nil, false
                            while cur.i <= n do
                                if did and Ext.Timer.MicrosecTime() - t0 >= limit then return false end
                                did = true
                                local i = cur.i
                                cur.i = i + 1
                                local cell, parent, at = hostCell(hn, host, i)
                                if cell ~= nil then
                                    if not wearRead then wear, wearRead = unitWearer(ctx, p, memo, host), true end
                                    unit(cell, parent, C.KINDS[host.kind], p.pid, wear, at)
                                else
                                    hostMissed(p, host, i)
                                end
                            end
                            cur.h, cur.i = cur.h + 1, 1
                        end
                    else
                        if did and Ext.Timer.MicrosecTime() - t0 >= limit then return false end
                        did = true
                        local pin = p.pins[cur.h - nh]
                        cur.h = cur.h + 1
                        local cell = nodeAt(memo, pin.path)
                        if cell ~= nil and nameOf(cell) == pin.rootName then
                            local at = pin.propDepth ~= nil and nodeAt(memo, pin.path, pin.propDepth) or nil
                            unit(cell, nodeAt(memo, pin.path, #pin.path - 1), C.KINDS[pin.kind], p.pid,
                                unitWearer(ctx, p, memo, pin), at)
                        else
                            requestVerify(p)
                        end
                    end
                end
            end
            cur.k = cur.k + 1
            cur.pid, cur.h, cur.i = order[cur.k], 1, 1
        end
        pollCur = nil
        local quiet = totals.renders == cur.r0 and wantedHead > #wantedList
        if quiet then burstMode = false end
        pollNext = quiet and cur.at + C.POLL_PERIOD or 0
        return true
    end

    -- ===== stage 5: walks (callback only) =====

    -- a walk's place is a stack of frames, plain data: { i (index in its parent), name, count, next,
    -- stop, inList (the innermost item list it is in) }. A callback follows the frames down again from
    -- the panel root, checking each name, and carries on; a name that no longer matches ends the walk (nil)
    local function walkResume(memo, w)
        local live = { memo[""] }
        for k = 2, #w.frames do
            local f = w.frames[k]
            local node = U.Get(visualChild, live[k - 1], f.i)
            if node == nil or nameOf(node) ~= f.name then return nil end
            live[k] = node
        end
        return live
    end

    -- a walk of the base node at `base` (child indexes below the panel root), visiting its children
    -- from..to (all when to is nil). Its ancestors are frames already done, so cells found carry their
    -- full path and the counts along it. nil when the base cannot be read. us: the callback clock's
    -- time spent on it (here and in walkStep), summed over the callbacks it spans
    local function startWalk(memo, p, base, from, to, full)
        local t1 = Ext.Timer.MicrosecTime()
        local root = memo[""]
        local n0 = read(root, "VisualChildrenCount")
        if type(n0) ~= "number" then return nil end
        local frames = { { name = p.name, count = n0, next = n0 + 1 } }
        local node = root
        for k, idx in ipairs(base) do
            node = U.Get(visualChild, node, idx)
            if node == nil then return nil end
            local n = read(node, "VisualChildrenCount")
            if type(n) ~= "number" then return nil end
            frames[k + 1] = { i = idx, name = nameOf(node), count = n, next = n + 1 }
        end
        local top = frames[#frames]
        top.next, top.stop = from or 1, to
        local listNames = C.LIST_ROOTS[p.name]
        return { frames = frames, cells = {}, seen = {}, visits = 0, capped = false, full = full,
                 listNames = listNames, lists = listNames and {} or nil,
                 callbacks = 0, deepest = 0, why = full and p.why or nil, us = Ext.Timer.MicrosecTime() - t1 }
    end

    -- visits up to the budget, WALK_UNIT visits between clock reads. Each visit reads one child's Name;
    -- a cell root (PaGRoot, PaGSlotRoot) is recorded and not entered, any other node with children is
    -- entered. An item list (w.listNames) is noted in w.lists, { path, pstr, name, parent (the list it
    -- is in), hasCell }; a cell marks the lists it is in. True when the walk is done
    local function walkStep(w, live, t0, limit)
        local frames = w.frames
        local visits = 0
        while #frames > 0 do
            if visits >= C.WALK_UNIT then
                visits = 0
                if Ext.Timer.MicrosecTime() - t0 >= limit then return false end
            end
            if w.visits >= C.WALK_MAX then
                w.capped = true
                return true
            end
            local top = frames[#frames]
            if top.next > (top.stop or top.count) then
                frames[#frames] = nil
                live[#live] = nil
            else
                local i = top.next
                top.next = i + 1
                visits = visits + 1
                w.visits = w.visits + 1
                local child = U.Get(visualChild, live[#live], i)
                if child ~= nil then
                    local name = nameOf(child)
                    local kind = C.KIND_OF_ROOT[name]
                    if kind ~= nil then
                        local path, names, counts = {}, {}, {}
                        for k = 2, #frames do
                            path[#path + 1] = frames[k].i
                            names[#names + 1] = frames[k].name
                        end
                        path[#path + 1] = i
                        names[#names + 1] = name
                        for k = 1, #frames do counts[k] = frames[k].count end
                        local pstr = table.concat(path, ".")
                        if not w.seen[pstr] then
                            w.seen[pstr] = true
                            w.cells[#w.cells + 1] = { kind = kind.kind, path = path, names = names,
                                                      counts = counts, pstr = pstr }
                            -- a list marked has its outer lists marked already
                            local e = top.inList
                            while e ~= nil and not e.hasCell do
                                e.hasCell = true
                                e = e.parent
                            end
                            if w.deep then
                                local top2 = frames[2] and frames[2].name or "-"
                                w.byPanel[top2] = (w.byPanel[top2] or 0) + 1
                                if w.sample == nil then w.sample = sampleCell(child) end
                            end
                        end
                    elseif #frames >= C.WALK_DEPTH then
                        w.capped = true
                    else
                        local n = read(child, "VisualChildrenCount")
                        -- a list is noted even with no children: its items may not be built yet
                        local inList = top.inList
                        if w.listNames ~= nil and w.listNames[name] then
                            local path = {}
                            for k = 2, #frames do path[#path + 1] = frames[k].i end
                            path[#path + 1] = i
                            inList = { path = path, pstr = table.concat(path, "."), name = name,
                                       parent = top.inList, hasCell = false }
                            w.lists[#w.lists + 1] = inList
                        end
                        if type(n) == "number" and n > 0 then
                            frames[#frames + 1] = { i = i, name = name, count = n, next = 1, inList = inList }
                            live[#live + 1] = child
                            if #frames > w.deepest then w.deepest = #frames end
                        end
                    end
                end
            end
        end
        return true
    end

    -- the lists a walk found no cell in, the outermost only: a walk of a list covers those inside it
    local function emptyLists(w)
        local out = {}
        for _, e in ipairs(w.lists or {}) do
            if not e.hasCell and (e.parent == nil or e.parent.hasCell) then
                out[#out + 1] = { path = e.path, pstr = e.pstr, name = e.name }
            end
        end
        return out
    end

    -- a full walk replaces a panel's cells (and the counts a verify kept: its cells carry fresh ones);
    -- a sub-walk adds the new ones, and so does a slots walk that found no item cell. A cell node found
    -- again keeps its mark: a mark is kept by the PaGId on the node (shown, diff), not by p.cells, and
    -- the old hosts are polled until Tick plans the new ones (needHosts). Lists: a full walk replaces
    -- p.lists; any other walk drops each kept list it found a cell in, and adds the empty lists it found
    local function finishWalk(p, w)
        p.walk = nil
        local slots = 0
        for _, cell in ipairs(w.cells) do if cell.kind == C.SLOT.kind then slots = slots + 1 end end
        if #w.cells > 0 then hadCells[p.name], barrenNames[p.name] = true, nil end
        if w.full then
            dlog(nil, "write", K.Probe, "walk", { panel = p.pid, why = w.why, visits = w.visits, cells = #w.cells,
                slots = slots, us = math.floor(w.us), callbacks = w.callbacks, deepest = w.deepest,
                capped = w.capped or nil })
        end
        if w.full and not (w.why == "slots" and slots == #w.cells) then
            p.cells, p.cellSet, p.subQ, p.counts, p.slots = w.cells, w.seen, {}, {}, slots
            p.slotOnly = slots > 0 and slots == #w.cells
            p.lists = emptyLists(w)
            if #w.cells == 0 then
                p.hosts, p.pins, p.nodeList = {}, {}, {}
                if p.emptyN == 0 then p.chainVisits = 0 end
                p.chainVisits = p.chainVisits + w.visits
                p.emptyN = p.emptyN + 1
                if barrenNames[p.name] and (w.visits > 0 or p.emptyN > #C.EMPTY_REWALKS) then
                    -- a name known to hold no cells: one walk that reads nodes settles this show
                    p.state = "barren"
                elseif barrenNames[p.name] then
                    -- an empty root does not count (the page may not be built yet): soon again, at most
                    -- EMPTY_REWALKS' count of times
                    p.state, p.nextRewalk = "empty", U.Ticks() + C.EMPTY_REWALKS[1]
                elseif p.emptyN <= #C.EMPTY_REWALKS then
                    p.state = "empty"
                    p.nextRewalk = U.Ticks() + C.EMPTY_REWALKS[p.emptyN]
                else
                    p.state = "barren"
                    if p.chainVisits > 0 and not hadCells[p.name] and not C.CELL_PAGES[p.name] then
                        barrenNames[p.name] = true
                        dlog(nil, "write", K.Probe, "panel_barren_learned", { panel = p.pid, visits = p.chainVisits })
                    end
                end
                computePollable()
                return
            end
            p.state, p.emptyN, p.verifyAt, p.needHosts = "live", 0, U.Ticks(), true
            -- slots alone: live now, so they are marked, and walked again until item cells show
            if p.slotOnly and C.SLOT_REWALK_PAGES[p.name] then p.slotTries, p.slotAt = 0, U.Ticks() + C.SLOT_REWALK_TICKS end
            heat()
            return
        end
        if not w.full then p.subWalks = p.subWalks + 1 end
        local added = 0
        for _, cell in ipairs(w.cells) do
            if not p.cellSet[cell.pstr] then
                p.cellSet[cell.pstr] = true
                p.cells[#p.cells + 1] = cell
                added = added + 1
                if cell.kind == C.SLOT.kind then p.slots = p.slots + 1 else p.slotOnly = false end
            end
        end
        if w.lists ~= nil then
            for _, e in ipairs(w.lists) do
                if e.hasCell then
                    for k = #p.lists, 1, -1 do
                        if p.lists[k].pstr == e.pstr then
                            table.remove(p.lists, k)
                            dlog(nil, "write", K.Probe, "list_filled", { panel = p.pid, list = e.name,
                                cells = added, visits = w.visits })
                        end
                    end
                end
            end
            for _, e in ipairs(emptyLists(w)) do
                local known = false
                for _, q in ipairs(p.lists) do
                    if q.pstr == e.pstr then known = true; break end
                end
                if not known then p.lists[#p.lists + 1] = e end
            end
        end
        if added > 0 then
            p.needHosts = true
            heat()
        end
    end

    -- checks a panel's nodes against what its cells were found under (resumable, at most REWALK_US of
    -- a callback). A name that changed, or a count that dropped where items do not come and go, means
    -- the panel is walked again; a count that grew is walked at its new children only. A pass that
    -- holds queues a walk of each list with no cell yet (p.lists), so a list that fills at any time is
    -- found by the next pass: on every show, then every SAFETY_REWALK ticks
    local function verifyStep(p, memo, t0, limit)
        local v = p.verify
        local list = p.nodeList
        local first = v.k
        while v.k <= #list do
            -- one node at least per call, so a pass always moves on
            if v.k > first and Ext.Timer.MicrosecTime() - t0 >= limit then return false end
            local nd = list[v.k]
            local node = nodeAt(memo, nd.path)
            if node == nil or nameOf(node) ~= nd.name then
                restart(p, "verify: name at " .. nd.pstr)
                return true
            end
            if not nd.host then
                local n = read(node, "VisualChildrenCount")
                if type(n) ~= "number" or n < nd.count then
                    restart(p, "verify: count at " .. nd.pstr)
                    return true
                end
                if n > nd.count then
                    p.subQ[#p.subQ + 1] = { path = nd.path, from = nd.count + 1, to = n }
                    nd.count = n
                    p.counts[nd.pstr] = n
                end
            end
            v.k = v.k + 1
        end
        p.verify = nil
        p.verifyAt = U.Ticks()
        if p.state == "verify" then p.state = "live" end
        for _, e in ipairs(p.lists) do
            local queued = false
            for _, s in ipairs(p.subQ) do
                if s.list == e then queued = true; break end
            end
            if not queued then p.subQ[#p.subQ + 1] = { path = e.path, from = 1, list = e } end
        end
        return true
    end

    -- one panel's walk work, until the budget runs out (false) or it has none left now (true). The
    -- first piece of walk work in a callback (ctx.walked) runs whatever the clock says, as in pollStage
    local function panelStep(ctx, p, t0, limit)
        local root = panelRoot(ctx, p)
        if root == nil then return true end
        local memo = memoFor(ctx, p, root)
        while true do
            if ctx.walked and Ext.Timer.MicrosecTime() - t0 >= limit then return false end
            local now = U.Ticks()
            if p.walk ~= nil then
                ctx.walked = true
                local w = p.walk
                local t1 = Ext.Timer.MicrosecTime()
                local live = walkResume(memo, w)
                if live == nil then
                    -- a slots walk is dropped (its next is already set), never restarted: a page that
                    -- fills late is not a tree that keeps changing, and its slots are still live
                    if w.why == "slots" then p.walk = nil
                    elseif w.full then restart(p, "walk: a name moved") else p.walk = nil; requestVerify(p) end
                else
                    if w.cb ~= ctx.serial then w.cb, w.callbacks = ctx.serial, w.callbacks + 1 end
                    local done = walkStep(w, live, t0, limit)
                    w.us = w.us + (Ext.Timer.MicrosecTime() - t1)
                    if not done then return false end
                    local had = #p.cells
                    finishWalk(p, w)
                    -- the first cells of a visible panel: shown, as in markStage
                    if had == 0 and #p.cells > 0 and p.visible then
                        toTick.show = true
                        p.open = p.open or { at = U.Ticks(), serial = ctx.serial, maxWait = 0 }
                    end
                end
            elseif p.state == "discover" then
                ctx.walked = true
                p.walk = startWalk(memo, p, {}, 1, nil, true)
                if p.walk == nil then restart(p, "walk: root unreadable") end
                if p.state == "stuck" then return true end
            elseif p.verify ~= nil and not p.needHosts then
                ctx.walked = true
                if ctx.verifyUntil == nil then ctx.verifyUntil = Ext.Timer.MicrosecTime() - t0 + C.REWALK_US end
                if not verifyStep(p, memo, t0, math.min(limit, ctx.verifyUntil)) then return false end
            elseif p.subQ[1] ~= nil and (p.state == "live" or p.state == "verify") and not p.needHosts then
                ctx.walked = true
                local s = table.remove(p.subQ, 1)
                p.walk = startWalk(memo, p, s.path, s.from, s.to, false)
                if s.list ~= nil then
                    -- a list's walk. Its node is named in the page: gone or renamed, the page moved
                    -- under the panel's lists, as a verify name check finds it
                    local w = p.walk
                    if w ~= nil and w.frames[#w.frames].name == s.list.name then
                        local e = { path = s.list.path, pstr = s.list.pstr, name = s.list.name, hasCell = false }
                        w.frames[#w.frames].inList = e
                        w.lists = w.lists or {}
                        w.lists[#w.lists + 1] = e
                    else
                        restart(p, "walk: list " .. s.list.name .. " at " .. s.list.pstr)
                        if p.state == "stuck" then return true end
                    end
                elseif p.walk == nil then requestVerify(p) end
            elseif p.state == "empty" and now >= p.nextRewalk then
                p.state, p.why = "discover", barrenNames[p.name] and "barren" or "rewalk"
            elseif p.slotOnly and p.state == "live" and not p.needHosts and now >= p.slotAt then
                -- a full walk of a live panel, for item cells (SLOT_REWALK_*). The next is set as it
                -- starts, so one that cannot start or is dropped waits its turn too
                ctx.walked = true
                p.slotTries = p.slotTries + 1
                p.slotAt = now + (p.slotTries < C.SLOT_REWALK_FAST and C.SLOT_REWALK_TICKS or C.SAFETY_REWALK)
                p.walk = startWalk(memo, p, {}, 1, nil, true)
                if p.walk ~= nil then p.walk.why = "slots" end
            elseif p.state == "live" and p.verify == nil and not p.needHosts and now - p.verifyAt >= C.SAFETY_REWALK then
                p.verify = { k = 1 }
            else
                return true
            end
        end
    end

    -- the tick from which some visible panel has walk work (now, if it has some already)
    local function dueAt()
        local now, due = U.Ticks(), math.huge
        if want.deep then return now end
        for _, pid in ipairs(order) do
            local p = panels[pid]
            if p ~= nil and p.visible ~= false then
                if p.walk ~= nil or p.state == "discover" or (p.verify ~= nil and not p.needHosts)
                    or (p.subQ[1] ~= nil and not p.needHosts and (p.state == "live" or p.state == "verify")) then
                    return now
                elseif p.state == "empty" then
                    due = math.min(due, p.nextRewalk)
                elseif p.state == "live" and not p.needHosts then
                    -- a slot-only panel's next walk for item cells, or its next verify, whichever is first
                    due = math.min(due, p.verifyAt + C.SAFETY_REWALK, p.slotOnly and p.slotAt or math.huge)
                end
            end
        end
        return due
    end

    -- !pag_walk: every node under ContentRoot, resumable like a panel's walk. Reports nodes, depth,
    -- cells and slots, and which ContentRoot child each was under
    local function deepStep(ctx, t0, limit)
        local w = deepWalk
        if w == nil then
            local n = read(ctx.content, "VisualChildrenCount")
            if type(n) ~= "number" then
                want.deep = nil
                dlog(nil, "print", "!pag_walk: ContentRoot's children could not be read")
                return true
            end
            w = { frames = { { name = "ContentRoot", count = n, next = 1 } }, cells = {}, seen = {},
                  visits = 0, capped = false, full = true, callbacks = 0, deepest = 0, deep = true,
                  byPanel = {}, us = 0 }
            deepWalk = w
        end
        local live = walkResume({ [""] = ctx.content }, w)
        if live == nil then
            deepRestarts = deepRestarts + 1
            deepWalk = nil
            if deepRestarts > C.RESTARTS_MAX then
                want.deep = nil
                dlog(nil, "print", "!pag_walk: the tree kept changing under the walk; try again")
            end
            return true
        end
        w.callbacks = w.callbacks + 1
        local t1 = Ext.Timer.MicrosecTime()
        local done = walkStep(w, live, t0, limit)
        w.us = w.us + (Ext.Timer.MicrosecTime() - t1)
        if not done then return false end
        deepWalk, want.deep = nil, nil
        local cells, slots = 0, 0
        for _, c in ipairs(w.cells) do
            if c.kind == "slot" then slots = slots + 1 else cells = cells + 1 end
        end
        local np = 0
        for _ in pairs(w.byPanel) do np = np + 1 end
        dlog(nil, "write", K.Probe, "deep_walk", { visits = w.visits, deepest = w.deepest, cells = cells,
            slots = slots, byPanel = w.byPanel, callbacks = w.callbacks, ms = w.us / 1000,
            capped = w.capped or nil, sample = w.sample })
        dlog(nil, "print", string.format("!pag_walk: %d nodes, depth %d: %d cells and %d slots under %d panels; "
            .. "%d callbacks, %.1f ms%s", w.visits, w.deepest, cells, slots, np, w.callbacks, w.us / 1000,
            w.capped and " (capped)" or ""))
        return true
    end

    local function walkStage(ctx, t0, limit)
        if want.deep and not deepStep(ctx, t0, limit) then return end
        for _, pid in ipairs(order) do
            local p = panels[pid]
            if p ~= nil and p.visible ~= false and p.state ~= "barren" and p.state ~= "stuck" then
                if not panelStep(ctx, p, t0, limit) then return end
            end
        end
    end

    -- ===== the terminal clear (callback only) =====

    -- after FAULTS_MAX faults: hides the marks of every cell PaG knows, with no budget, once. Cells in
    -- the template's state ("-") carry no marks. With no ContentRoot to clear on, the request stands
    -- and the next tick asks again (schedTick serves want.clear while latched). The mark stage runs
    -- first, so a panel that moved under ContentRoot since the last callback is still found
    local function clearAll()
        local root = uiRoot()
        local content = root ~= nil and contentOf(root) or nil
        if content == nil then
            dlog("probe.clear_no_root", "write", K.Probe, "clear_waits", { root = root ~= nil })
            return
        end
        terminal, want.clear = false, nil
        local n, failed = 0, 0
        do
            local ctx = { content = content, roots = {}, memo = {}, hostAt = {}, changed = false }
            pcall(markStage, ctx)
            local function clearOne(cellRoot, kind)
                local c = cellAt(cellRoot, kind)
                if c == nil or c.id == nil then return end
                local s = shown[c.id]
                local have = (s ~= nil and not s.err and not s.stuck) and s or C.UNKNOWN
                if pcall(hideCell, c, kind, have) then n = n + 1 else failed = failed + 1 end
            end
            for _, pid in ipairs(order) do
                local p = panels[pid]
                local proot = p ~= nil and panelRoot(ctx, p) or nil
                if proot ~= nil then
                    local memo = memoFor(ctx, p, proot)
                    for _, host in ipairs(p.hosts) do
                        local hn, cnt = hostNode(ctx, memo, host)
                        if hn ~= nil then
                            for i = 1, cnt do
                                local cell = hostCell(hn, host, i)
                                if cell ~= nil then pcall(clearOne, cell, C.KINDS[host.kind]) end
                            end
                        end
                    end
                    for _, pin in ipairs(p.pins) do
                        local cell = nodeAt(memo, pin.path)
                        if cell ~= nil and nameOf(cell) == pin.rootName then pcall(clearOne, cell, C.KINDS[pin.kind]) end
                    end
                end
            end
        end
        shown, shownN = {}, 0
        dlog(nil, "write", K.Milestone, "cleared", { cells = n, failed = failed })
    end

    -- ===== console jobs (callback only) =====

    -- each job runs in its own pcall and gets the UI root and the callback's readers. It returns a line
    -- to print and rows to log ({ kind, name, data }); it never calls L.*
    local function runJobs()
        local root, content = nil, nil
        local n = 0
        while jobs[1] ~= nil and n < C.RUNUI_MAX do
            local job = table.remove(jobs, 1)
            n = n + 1
            if root == nil then
                root = uiRoot()
                content = root ~= nil and contentOf(root) or nil
            end
            local api = { root = root, content = content, read = read, describe = describe, nameOf = nameOf,
                          child = function(node, i) return U.Get(visualChild, node, i) end }
            local ok, msg, out = pcall(job.fn, api)
            if not ok then
                dlog(nil, "print", job.name .. " failed: " .. tostring(msg))
            else
                if msg ~= nil then dlog(nil, "print", tostring(msg)) end
                if type(out) == "table" then
                    for _, r in ipairs(out) do dlog(nil, "write", r.kind or K.Probe, r.name or job.name, r.data) end
                end
            end
        end
        if jobs[1] == nil then want.console = nil end
    end

    -- ===== the callback =====

    local cbSerial = 0

    -- one callback's work, in stages, within its budget (design §8.3). Returns its stage split (us)
    -- when it ran C.SLOW_US or more, for ui's cost/cb row
    local function uiBody()
        local t0 = Ext.Timer.MicrosecTime()
        local budget = burstMode and C.BURST_US or C.BUDGET_US
        local r0 = totals.renders
        if jobs[1] ~= nil then runJobs() end
        local tJobs = Ext.Timer.MicrosecTime()
        local root = uiRoot()
        local content = root ~= nil and contentOf(root) or nil
        if content == nil then
            -- nothing to draw on: what was asked of this callback is dropped, not retried every tick
            dlog(root == nil and "probe.no_root" or "probe.no_content", "write", K.Probe,
                root == nil and "no_root" or "no_content", {})
            want.render, want.discover = nil, nil
            if want.deep then
                want.deep, deepWalk = nil, nil
                dlog(nil, "print", "!pag_walk: the UI root could not be read; try again")
            end
            return
        end
        cbSerial = cbSerial + 1
        -- wait: ticks since this callback was queued (ui's armWait), for panel_open
        local ctx = { content = content, roots = {}, memo = {}, hostAt = {}, wear = {}, changed = false, serial = cbSerial,
                      wait = U.Ticks() - armedAt }
        local tRoot = Ext.Timer.MicrosecTime()
        markStage(ctx)
        local tMark = Ext.Timer.MicrosecTime()
        observeUi(ctx)
        local tObserve = Ext.Timer.MicrosecTime()
        local walkPending = dueAt() <= U.Ticks()
        pollStage(ctx, t0, budget - (walkPending and C.WALK_RESERVE_US or 0))
        local tPoll = Ext.Timer.MicrosecTime()
        walkStage(ctx, t0, budget)
        local tWalk = Ext.Timer.MicrosecTime()
        for _, pid in ipairs(order) do
            local p = panels[pid]
            local o = p ~= nil and p.open or nil
            if o ~= nil then
                if o.first ~= nil then openRow(p, ctx, nil)
                elseif o.serial < ctx.serial and ctx.wait > o.maxWait then o.maxWait = ctx.wait end
            end
        end
        local now = U.Ticks()
        walkDueAt = dueAt()
        want.discover = (walkDueAt <= now) or nil
        -- the idle probe backs off while nothing happens
        if not ctx.changed and totals.renders == r0 and walkDueAt > now and pollCur == nil
            and wantedHead > #wantedList and hot == 0 then
            idleQuiet = idleQuiet + 1
            if idleQuiet >= C.IDLE_QUIET then
                idleQuiet = 0
                idleK = math.min(idleK * 2, C.IDLE_MAX)
            end
        end
        local tEnd = Ext.Timer.MicrosecTime()
        if tEnd - t0 >= C.SLOW_US then
            local f = math.floor
            return { budget = budget, jobs = f(tJobs - t0), root = f(tRoot - tJobs), mark = f(tMark - tRoot),
                     observe = f(tObserve - tMark), poll = f(tPoll - tObserve), walk = f(tWalk - tPoll),
                     rest = f(tEnd - tWalk) }
        end
    end

    function trace(err)
        if debug ~= nil and debug.traceback ~= nil then return debug.traceback(tostring(err), 2) end
        return tostring(err)
    end

    -- the Defer callback. `s` is the seq it was queued under: a callback queued before an Invalidate
    -- does nothing. A fault outside the per-unit pcalls counts; at FAULTS_MAX PaG clears its marks
    -- (terminal) and runs only console jobs until !pag_bump or the next world load
    function ui(s)
        if s ~= seq then
            totals.stale = totals.stale + 1
            return
        end
        -- SE times the whole callback against its line (C.SLOW_US), so the cost/cb test starts here
        local t0 = U.Get(Ext.Timer.MicrosecTime)
        armed = false
        local now = U.Ticks()
        local wait = now - armedAt
        ring(metrics.armWait, "armI", wait)
        lastRan = now
        if not attached then return end
        -- a callback that ran late: one row each, C.COST_ROWS per world load, the rest counted
        if wait >= C.DEFER_WAIT_TICKS then
            totals.slowDefer = totals.slowDefer + 1
            if totals.slowDefer > C.COST_ROWS then
                totals.slowDeferOver = totals.slowDeferOver + 1
            elseif L.Basic() then
                dlog(nil, "write", K.Cost, "defer_wait", { ticks = wait, armedFor = metrics.armedFor })
            end
        end
        -- the scheduler asked GetGameState on the tick that queued this; asked again here, so a state
        -- change between the two cannot let a walk run during teardown. Unreadable: the tick's answer stands
        local st = U.Get(Ext.Utils.GetGameState)
        if st ~= nil and not C.TREE_SAFE[tostring(st)] then
            totals.unsafe = totals.unsafe + 1
            return
        end
        inDefer, PaG.InDefer = true, true
        local body, what = uiBody, "ui"
        if terminal then body, what = clearAll, "clear" elseif latched then body, what = runJobs, "jobs" end
        local ok, err = xpcall(body, trace)
        local t1 = U.Get(Ext.Timer.MicrosecTime)
        if t0 ~= nil and t1 ~= nil then
            ring(metrics.cbUs, "cbI", t1 - t0)
            -- a slow callback: one row each with uiBody's stage split (when uiBody alone ran that long),
            -- C.COST_ROWS per world load, the rest counted
            if t1 - t0 >= C.SLOW_US then
                totals.slowCb = totals.slowCb + 1
                if totals.slowCb > C.COST_ROWS then
                    totals.slowCbOver = totals.slowCbOver + 1
                elseif L.Basic() then
                    dlog(nil, "write", K.Cost, "cb", { us = math.floor(t1 - t0), body = what, ok = ok,
                        split = ok and type(err) == "table" and err or nil })
                end
            end
        end
        totals.callbacks = totals.callbacks + 1
        -- still the callback: the error and latch rows are queued (dlog) for Tick. pcall'd, so the
        -- flags below are cleared whatever happens here
        if not ok then
            faults = faults + 1
            pcall(noteError, "hub.ui", err)
            if faults >= C.FAULTS_MAX and not latched then
                latched, terminal, want.clear = true, true, true
                pcall(dropDeep, "marks are off after errors")
                pcall(dlog, "warn.hub.latched", "warnonce", "hub.latched",
                    "PaG hit " .. C.FAULTS_MAX .. " errors drawing marks and has turned them off. "
                    .. "!pag_bump turns them back on; please send the log")
            end
        end
        inDefer, PaG.InDefer = false, false
    end
end

-- ===== the scheduler (Tick) =====

-- what a console command prints when PaG cannot draw on this Script Extender
local function v32Line()
    return "PaG needs Script Extender v33 (Ext.UI.Defer); marks are off. Script Extender "
        .. tostring(U.Get(Ext.Utils.Version))
end
Hub.V32Line = v32Line

-- the one place a callback is queued (design §8.3), after the tick's own work. At most one is queued
-- at a time; it runs at the start of the next UI update. Queued every tick while something changed
-- (hot) or something is asked for (want), every POLL_EVERY ticks while a visible panel holds cells,
-- else every idleK ticks. After a latch, only for a console job or the terminal clear
local function schedTick()
    if not attached or diag == "inert" then return end
    local st = U.Get(Ext.Utils.GetGameState)
    treeSafe = st ~= nil and C.TREE_SAFE[tostring(st)] == true
    if not treeSafe then return end
    local now = U.Ticks()
    if armed then
        -- diagnostic only (design §8.3): SE keeps the queue until the Lua state ends, so a callback
        -- that has not run is still coming. !pag_bump queues afresh
        metrics.armedFor = metrics.armedFor + 1
        if metrics.armedFor == C.STALL_DEFER_TICKS then
            totals.stalls = totals.stalls + 1
            L.Once("probe.defer_stall", K.Warn, "defer_stall", { ticks = metrics.armedFor, seq = seq, armedAt = armedAt })
        end
        return
    end
    local due
    if latched then
        due = want.console or want.clear
    else
        due = hot > 0 or next(want) ~= nil or now >= walkDueAt
            or (pollable and now - lastRan >= C.POLL_EVERY) or now - lastRan >= idleK
    end
    if not due then return end
    local s = seq
    local ok, err = pcall(Ext.UI.Defer, function() ui(s) end)
    if ok then
        armed, armedAt, metrics.armedFor = true, now, 0
    else
        totals.deferRaises = totals.deferRaises + 1
        L.WarnOnce("hub.defer_raise", "Ext.UI.Defer refused a callback, so marks are paused: "
            .. tostring(err) .. ". Please send the log", { err = tostring(err) })
    end
end

-- forgets everything the callbacks found, and any callback still queued (its seq no longer
-- matches). What a panel's walk learned is kept by name (`learned`); Rebuild drops it too
local function invalidate(why)
    seq = seq + 1
    armed, metrics.armedFor = false, 0
    dropDeep(why)
    want = {}
    pollCur, pollNext, deepWalk = nil, 0, nil
    panels, order = {}, {}
    markSig, seenAt = nil, nil
    shown, shownN = {}, 0
    clearWanted()
    if jobs[1] ~= nil then
        L.Write(K.Probe, "jobs_dropped", { n = #jobs, why = why })
        L.Banner("dropped " .. #jobs .. " console command(s) (" .. why .. "); run them again")
    end
    jobs = {}
    pollable = false
    walkDueAt = math.huge
    obsWho, obsVia = nil, nil
end

-- after FAULTS_MAX faults on Tick: the next callback clears every mark, then only console jobs run
local function latch(where)
    latched, terminal, want.clear = true, true, true
    dropDeep("marks are off after errors")
    L.WarnOnce("hub.latched", "PaG hit " .. C.FAULTS_MAX .. " errors (" .. where .. ") and has turned its "
        .. "marks off. !pag_bump turns them back on; please send the log")
end

-- ===== Tick =====

-- one tick's own work: no Noesis. Returns true when it judged or merged renders (a burst goes on).
-- Each step's end goes in metrics.tick, for a cost/tick row (Hub.NoteTick)
local function tickBody()
    local s, clock = metrics.tick, Ext.Timer.MicrosecTime
    if hot > 0 then hot = hot - 1 end
    local j0 = totals.judged
    planPanels()
    s.plan = clock()
    takeWho()
    s.who = clock()
    rereadDirty()
    s.reread = clock()
    checkItems()
    s.items = clock()
    judgeWanted()
    s.judge = clock()
    local r = toTick.r
    local active = totals.judged > j0
    if r.n > 0 then
        local b = theBurst()
        b.n, b.writes, b.fresh = b.n + r.n, b.writes + r.writes, b.fresh + r.fresh
        b.cells, b.slots = b.cells + r.cells, b.slots + r.slots
        toTick.r = newRenders()
        active = true
    end
    return active
end

local function tickAll()
    local s, clock = metrics.tick, Ext.Timer.MicrosecTime
    local t0 = clock()
    -- when each step ended this tick (us), for Hub.NoteTick; a step not reached stays nil
    s.t0, s.flush, s.plan, s.who, s.reread, s.items, s.judge, s.body, s.sched, s.burst =
        t0, nil, nil, nil, nil, nil, nil, nil, nil, nil
    local now = U.Now()
    -- a long gap since the last tick began is logged while attached: ms runs from that tick's start,
    -- outside from its end (the engine's own work, the UI update and its callback counted here)
    if attached and lastTickAt ~= nil and now - lastTickAt >= C.STALL_MS then
        L.Write(K.Cost, "stall", { ms = now - lastTickAt,
            outside = lastTickEnd ~= nil and now - lastTickEnd or nil })
    end
    lastTickAt, lastTickEnd = now, nil
    flushRows()
    s.flush = clock()

    local active = false
    if attached and not latched then
        local ok, res = xpcall(tickBody, trace)
        if ok then
            active = res == true
        else
            tickFaults = tickFaults + 1
            noteError("hub.tick", res)
            if tickFaults >= C.FAULTS_MAX then latch("tick") end
        end
    end
    s.body = clock()
    schedTick()
    s.sched = clock()

    if burst ~= nil and (not active or burst.n >= C.BURST_MAX_N or now - burst.start >= C.BURST_MAX_MS) then
        flushBurst()
    end
    s.burst = clock()
    ring(metrics.tickUs, "tickI", s.burst - t0)
    if attached and U.Ticks() % C.HEAP_EVERY == 0 then
        local kb, at = collectgarbage("count"), U.Now()
        if metrics.heapAt ~= nil and at > metrics.heapAt then
            local rate = (kb - metrics.heapKB) * 1000 / (at - metrics.heapAt)
            metrics.heapRate = rate
            if metrics.heapMax == nil or rate > metrics.heapMax then metrics.heapMax = rate end
        end
        metrics.heapAt, metrics.heapKB = at, kb
    end
    lastTickEnd = U.Now()
end

-- a fault anywhere in the tick counts toward the latch, and the scheduler is asked again so the
-- terminal clear is queued. Raised instead, U.Guard would switch the tick off after two and leave
-- every mark on screen, judged for whoever was selected then
function Hub.OnTick()
    if not HAS_DEFER then return end
    local ok, err = xpcall(tickAll, trace)
    if ok then return end
    tickFaults = tickFaults + 1
    noteError("hub.tick", err)
    if tickFaults >= C.FAULTS_MAX and not latched then latch("tick") end
    if not armed then pcall(schedTick) end
end

-- called by _Init after its whole Tick handler, which SE times against its line (C.SLOW_US): a tick
-- that long in a running game writes a cost/tick row with each step's share (us), C.COST_ROWS per
-- world load, the rest counted. split is Hub's own steps, when Hub.OnTick ran them this tick. SE
-- holds a loading tick (not Running or Paused) to 50000 us, so a slow tick then writes no row
function Hub.NoteTick(t0, tAttach, tHub, tSettings, tLog)
    if tLog - t0 < C.SLOW_US then return end
    local st = tostring(U.Get(Ext.Utils.GetGameState))
    if st ~= "Running" and st ~= "Paused" then return end
    totals.slowTick = totals.slowTick + 1
    if totals.slowTick > C.COST_ROWS then
        totals.slowTickOver = totals.slowTickOver + 1
        return
    end
    if not L.Basic() then return end
    local function d(a, b)
        if a ~= nil and b ~= nil then return math.floor(b - a) end
    end
    local s, split = metrics.tick, nil
    if s.t0 ~= nil and s.t0 >= tAttach then
        split = { flush = d(s.t0, s.flush), body = d(s.flush, s.body), plan = d(s.flush, s.plan),
                  who = d(s.plan, s.who), reread = d(s.who, s.reread), items = d(s.reread, s.items),
                  judge = d(s.items, s.judge), merge = d(s.judge, s.body), sched = d(s.body, s.sched),
                  burst = d(s.sched, s.burst), rest = d(s.burst, tHub) }
    end
    L.Write(K.Cost, "tick", { us = d(t0, tLog), attach = d(t0, tAttach), hub = d(tAttach, tHub),
        settings = d(tHub, tSettings), log = d(tSettings, tLog), split = split })
end

-- ===== lifecycle =====

-- the crash test's stored mode, from DIAG_FILE; anything but a known mode reads as full. _Init reads
-- it in the main menu too, where it is the next load's mode
function Hub.StoredDiag()
    local text = tostring(U.Get(Ext.IO.LoadFile, C.DIAG_FILE) or ""):match("^%s*(%a+)")
    return C.DIAG_MODES[text] and text or "full"
end

-- the crash test's mode for this world
function Hub.ReadDiag()
    diag = Hub.StoredDiag()
    return diag
end

-- !pag_diag: stores the crash test's mode, which the next attach reads
function Hub.SetDiag(mode)
    if not C.DIAG_MODES[mode] then return false, "usage: !pag_diag full|nowrite|inert" end
    local ok, res = pcall(Ext.IO.SaveFile, C.DIAG_FILE, mode)
    if not ok or res == false then
        return false, "could not write Script Extender/" .. C.DIAG_FILE .. ": " .. tostring(res)
    end
    L.Write(K.Milestone, "diag_set", { mode = mode })
    return true
end

-- what a world load and !pag_bump both start from: no faults, no latch, layouts decided afresh
local function freshStart()
    dOnce = {}
    faults, tickFaults, latched, terminal = 0, 0, false, false
    layout, slotLayout = nil, nil
    claimOk, claimBad = 0, 0
    -- renders a callback counted that no tick merged (the world ended, or a latch stopped the merge)
    toTick.r = newRenders()
end

-- every transition to Running from outside the world (design §8.9)
function Hub.Attach()
    attached, inWorld = false, true
    dropSubscriptions()
    L.ForgetOnce()
    local restarted = U.ResetGuards()
    Settings.Load()
    R.Reset()
    resetCounters()
    local env = U.Environment()
    if restarted[1] ~= nil then env.guardsRestarted = restarted end
    env.diag = Hub.ReadDiag()
    env.defer = HAS_DEFER
    diagSkipped = 0
    L.Write(K.Milestone, "attach", env)
    if not HAS_DEFER then
        L.WarnOnce("hub.no_defer", v32Line())
        return false
    end
    local saveChannel = Settings.Watch(onSettingsChange)
    Settings.Settle(onSettingsSettle)
    L.Write(K.Probe, "settings_watch", { saveChannel = saveChannel, source = Settings.Source() })
    if not saveChannel and Settings.Source() == E.SettingsSource.MCM then
        L.WarnOnce("settings.no_channel",
            "MCM is installed but its save event was not found: menu changes apply on the next load")
    end
    buildLooks()
    freshStart()
    invalidate("attach")
    moveG("attach")
    attached = true
    if diag == "inert" then
        L.Banner("CRASH TEST: inert. No marks and no UI calls this session. !pag_diag full restores "
            .. "PaG from the next load")
        return false
    end
    want.discover = true
    L.Banner("attached. " .. Settings.Describe() .. (diag ~= "full" and (" CRASH TEST: " .. diag) or ""))
    return true
end

-- leaving the world: every entity id and every cell id is about to go stale
-- (flushRows writes the OnChange counters' first fires before their subscriptions go; the counters
-- ride in totals)
function Hub.Reset(reason)
    flushRows()
    flushBurst()
    dropSubscriptions()
    if inWorld then
        -- lastCallbacks: percentiles of the rings, the last C.RING callbacks only, not the world load
        local function pf(t, q) local v = percentile(t, q); return v and math.floor(v) end
        L.Write(K.Milestone, "detach", { reason = reason, attached = attached, totals = totals,
            lastCallbacks = { of = "last " .. C.RING .. " callbacks", n = U.Count(metrics.cbUs),
                usP50 = pf(metrics.cbUs, 0.5), usP95 = pf(metrics.cbUs, 0.95),
                waitTicksP50 = pf(metrics.armWait, 0.5), waitTicksP95 = pf(metrics.armWait, 0.95) } })
    end
    attached, inWorld = false, false
    invalidate("reset")
    -- a load can end this Lua state a tick or two from now, before the throttled flush would run
    L.Flush(true)
end

-- !pag_bump: restarts stopped guards, clears a latch, forgets every panel and what panels of each
-- name looked like, and judges every item again; the probes and examples are logged afresh
function Hub.Rebuild()
    local restarted = U.ResetGuards()
    local note = restarted[1] and ("; restarted " .. table.concat(restarted, ", ")) or ""
    if not HAS_DEFER then return v32Line() .. note end
    if not inWorld then return "not in a loaded game: load a save first" .. note end
    L.ForgetOnce()
    freshStart()
    R.Reset()
    dirty = {}
    buildLooks()
    invalidate("rebuild")
    -- a panel's slot-only state went with the panels (invalidate)
    learned, hadCells, barrenNames = {}, {}, {}
    moveG("rebuild")
    attached = true
    if diag == "inert" then return "crash test inert: no UI calls this session" .. note end
    want.discover = true
    return "finding every cell again and judging every item again" .. note
end

-- !pag_walk: walks every node under ContentRoot over as many callbacks as it takes
function Hub.Deep()
    if not HAS_DEFER then return v32Line() end
    if not inWorld or not attached then return "not in a loaded game: load a save first" end
    if diag == "inert" then return "crash test inert: no UI calls this session" end
    if latched then return "marks are off after errors: !pag_bump first" end
    if want.deep then return "already walking; the result prints when it is done" end
    want.deep, deepRestarts = true, 0
    return "walking every node under ContentRoot; the result prints when it is done"
end

-- a console command's UI work, run inside a callback. fn(api) gets { root, content, read,
-- describe, nameOf, child } and returns a line to print and rows to log ({ kind, name, data });
-- it must not call L.* (Log.lua raises inside a callback). Runs also while marks are latched off
function Hub.RunUi(name, fn)
    if not HAS_DEFER then return v32Line() end
    if not inWorld or not attached then return "not in a loaded game: load a save first" end
    if diag == "inert" then return "crash test inert: no UI calls this session" end
    if #jobs >= C.RUNUI_MAX then return name .. ": " .. C.RUNUI_MAX .. " commands already waiting; try again in a moment" end
    jobs[#jobs + 1] = { name = name, fn = fn }
    want.console = true
    return name .. ": queued"
end

-- Lua-only: what PaG knows, for !pag_status. Never touches the UI
function Hub.Status()
    local kinds = {}
    for msg, n in pairs(errors) do kinds[#kinds + 1] = string.format("%dx %s", n, msg) end
    local states, cells, hosts, pins = {}, 0, 0, 0
    for _, p in pairs(panels) do
        states[p.state] = (states[p.state] or 0) + 1
        cells, hosts, pins = cells + #p.cells, hosts + #p.hosts, pins + #p.pins
    end
    local nLearned = 0
    for _ in pairs(learned) do nLearned = nLearned + 1 end
    local function pct(t, p)
        local v = percentile(t, p)
        return v ~= nil and math.floor(v) or nil
    end
    return {
        defer = HAS_DEFER, inWorld = inWorld, attached = attached, diag = diag, diagSkipped = diagSkipped,
        G = G, looksGen = looksGen, judged = judged, judgedVia = judgedVia,
        observed = obsWho, observedVia = obsVia,
        panels = #order, panelStates = states, cells = cells, hosts = hosts, pins = pins, learned = nLearned,
        pollable = pollable, shown = shownN, wanted = #wantedList - wantedHead + 1,
        layout = layout and layout.how or tostring(layout),
        slotLayout = slotLayout and slotLayout.how or tostring(slotLayout),
        claims = { ok = claimOk, failed = claimBad },
        latched = latched, terminal = terminal, faults = faults, tickFaults = tickFaults,
        hot = hot, idleK = idleK, armed = armed, seq = seq,
        callbacks = totals.callbacks, renders = totals.renders, judgedTotal = totals.judged,
        stale = totals.stale, stalls = totals.stalls, unitErrors = totals.unitErrors,
        deferRaises = totals.deferRaises, unsafe = totals.unsafe,
        bursts = totals.bursts, lastBurst = totals.lastBurst, errors = kinds,
        callbackUs = { p50 = pct(metrics.cbUs, 0.5), p95 = pct(metrics.cbUs, 0.95) },
        tickUs = { p50 = pct(metrics.tickUs, 0.5), p95 = pct(metrics.tickUs, 0.95) },
        armWaitTicks = { p50 = pct(metrics.armWait, 0.5), p95 = pct(metrics.armWait, 0.95) },
        heap = { kb = metrics.heapKB and math.floor(metrics.heapKB) or nil,
                 kbPerSec = metrics.heapRate and math.floor(metrics.heapRate) or nil,
                 maxKbPerSec = metrics.heapMax and math.floor(metrics.heapMax) or nil },
        guards = U.Latched(), watched = nWatched, characters = R.KnownCharacters(), subscriptions = #subs,
    }
end
