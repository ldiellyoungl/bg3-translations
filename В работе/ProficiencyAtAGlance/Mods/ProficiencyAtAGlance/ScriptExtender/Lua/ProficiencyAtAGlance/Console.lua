-- SE console commands. PaG runs on the client. The SE console opens on the server (`S >>`), and
-- the first `client` is swallowed getting there, so type `client` once more until the prompt reads
-- `C >>`. Then:
--   !pag_status             settings, attach state, this world's counts and timings, errors, the
--                           log file. Reads only what PaG already holds: no UI calls
--   !pag_set [name value]   changes a setting now, in this session, and stores it in MCM if MCM
--                           is installed; with no arguments, lists them all
--   !pag_bump               restarts stopped guards, turns marks back on after errors, finds every
--                           cell again and judges every item again, with the probes and verdict
--                           examples logged again
--   !pag_diag [mode]        the crash test: full, nowrite or inert. Stored in a file and applied
--                           when a save is next loaded; with no mode, prints this session's mode
--                           and the usage
-- Dev/Console.lua adds the testing commands, which a release build leaves out.
--
-- MCM is where settings really get changed; !pag_set exists so a player without it can still turn
-- logging on to report a problem
local U, L = PaG.Util, PaG.Log
local Settings, Hub = PaG.Settings, PaG.Hub
local M = {}
PaG.Console = M

-- console output answers whoever typed the command, so it ignores the log level. Never called from
-- inside a UI callback: a job returns its line and Hub prints it on Tick
local function say(msg) Ext.Utils.Print("[PaG] " .. msg) end
M.Say = say

-- !name runs fn; a fault in it is logged, not raised into the console
local function command(name, fn)
    Ext.RegisterConsoleCommand(name, function(_, ...) U.Try("console." .. name, fn, ...) end)
end
M.Command = command

-- "name n, name n" for a { name = n } table, sorted
local function tally(t)
    local out = {}
    for k, n in pairs(t or {}) do out[#out + 1] = tostring(k) .. " " .. tostring(n) end
    table.sort(out)
    return out[1] ~= nil and table.concat(out, ", ") or "none"
end
M.Tally = tally

-- a { p50, p95 } pair; "-" before the first sample
local function pair(t)
    return string.format("p50 %s, p95 %s", tostring(t.p50 or "-"), tostring(t.p95 or "-"))
end

local function status()
    local s = Hub.Status()
    say(Settings.Describe())
    if not s.defer then say("  " .. Hub.V32Line()) end
    if s.diag ~= "full" then
        say(string.format("  CRASH TEST: %s this session (%d mark writes skipped)", tostring(s.diag),
            s.diagSkipped or 0))
    end
    if not s.inWorld then
        say("  not in a loaded game")
    elseif s.defer then
        say(string.format("  attached: %s; judging for %s (%s); the UI shows %s (%s); rules generation %d, looks %d",
            tostring(s.attached), tostring(s.judged), tostring(s.judgedVia), tostring(s.observed),
            tostring(s.observedVia), s.G, s.looksGen))
        say(string.format("  %d panels (%s): %d cells, %d remembered, %d items waiting to be judged; "
            .. "cell layout %s, slot layout %s; %d labels refused; %d panel layouts learned",
            s.panels, tally(s.panelStates), s.cells, s.shown, s.wanted, tostring(s.layout),
            tostring(s.slotLayout), s.claims.failed, s.learned))
        if s.latched then
            say(string.format("  MARKS OFF after %d errors in UI callbacks and %d on Tick%s; !pag_bump turns them back on",
                s.faults, s.tickFaults, s.terminal and " (still clearing them)" or ""))
        end
    end
    if #s.guards > 0 then
        say("  stopped after errors: " .. table.concat(s.guards, ", ") .. " (!pag_bump restarts them)")
    end
    if s.inWorld and s.defer then
        say(string.format("  this world: %d UI callbacks, %d cell renders, %d judged in %d bursts, %d cell errors; "
            .. "%d callbacks dropped as stale, %d skipped outside play, %d slow to run, %d Defer refusals",
            s.callbacks, s.renders, s.judgedTotal, s.bursts, s.unitErrors, s.stale, s.unsafe, s.stalls,
            s.deferRaises))
        say(string.format("  callback us %s; tick us %s; ticks from queue to callback %s", pair(s.callbackUs),
            pair(s.tickUs), pair(s.armWaitTicks)))
        say(string.format("  Lua heap %s KB, growing %s KB/s (max %s); %d characters read, %d watched items, "
            .. "%d subscriptions", tostring(s.heap.kb or "-"), tostring(s.heap.kbPerSec or "-"),
            tostring(s.heap.maxKbPerSec or "-"), #s.characters, s.watched, s.subscriptions))
    end
    local b = s.lastBurst
    if b then
        say(string.format("  last burst (%s): %d renders, %d judged over %d items (%s); %s ms judging; %d errors",
            tostring(b.cause), b.n, b.judged, b.items, tally(b.byTier), tostring(b.luaMs), b.errors))
    end
    for _, e in ipairs(s.errors) do say("  error: " .. e) end
    local file = L.File()
    say("  log file: " .. (file and ("Script Extender/" .. file) or "none yet (!pag_set debug_level basic)"))
end

-- "true"/"false" -> booleans, anything else stays text; Settings.Set rejects what doesn't fit
local function parse(text)
    if text == "true" then return true end
    if text == "false" then return false end
    return text
end

-- !pag_set with missing args lists the settings, which doubles as the list of names it accepts. The
-- console splits on spaces, so the value is the rest of the line
local function set(key, ...)
    local c = Settings.Get()
    if key == nil or select("#", ...) == 0 then
        for _, k in ipairs(Settings.KEYS) do
            say(string.format("  %-28s %s", k, Settings.Show(c[k])))
        end
        say("usage: !pag_set <name> <value>, for example !pag_set debug_level basic or !pag_set good_color_preset blue")
        return
    end
    local stored, note = Settings.Set(key, parse(table.concat({ ... }, " ")))
    if stored == nil then
        say("not changed: " .. tostring(note))
        return
    end
    say(string.format("%s = %s (%s)", key, Settings.Show(stored), note))
end

-- !pag_diag [full|nowrite|inert]: the crash test. The mode is stored and applies from the next load
local function diagCmd(mode)
    if mode == nil then
        say("crash test this session: " .. tostring(Hub.Status().diag)
            .. ". Usage: !pag_diag full|nowrite|inert (applies from the next load)")
        return
    end
    local ok, why = Hub.SetDiag(mode)
    say(ok and ("crash test set to " .. mode .. ". It applies from the next load") or why)
end

function M.Register()
    command("pag_status", status)
    command("pag_set", set)
    command("pag_bump", function() say(Hub.Rebuild()) end)
    command("pag_diag", diagCmd)
end
