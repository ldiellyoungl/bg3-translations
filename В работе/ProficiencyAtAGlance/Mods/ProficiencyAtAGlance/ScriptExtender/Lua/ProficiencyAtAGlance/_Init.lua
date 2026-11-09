-- Proficiency at a Glance: inventory, container and trade cells show whether the selected character
-- can use an item without penalty, so a bag of loot can be sorted without hovering every tooltip.
-- Three tiers (Bad, Not Ideal, Good), each with its own marks: dim, grayscale, inward glow, badge,
-- dot. The defaults are in Settings.lua (SPEC). Design: docs/ProficiencyAtAGlance_DESIGN.md
--
-- Proficiency at a Glance by InfiniteGeek, 2026-10-05. Licensed under GPLv3 (see LICENSE);
-- no warranty.
--
-- the pieces: GUI/Library/Lib_Keyboard.xaml replaces the game's inventory cell and equipment slot
-- templates with ones that carry PaG's mark parts. Hub.lua finds those cells and sets their marks,
-- only ever from an Ext.UI.Defer callback (Script Extender v33). On v32 PaG makes no UI calls and
-- says so once per load. Rules.lua decides, Why.lua words the equipped badge's tooltip, Read.lua
-- reads the character and the item, Settings.lua holds the marks (MCM optional), Layout.lua lays
-- out MCM's Looks tab as a grid, Log.lua writes the JSONL log when logging is on. HubConstants.lua
-- holds Hub's constants and the template part maps, and PanelPlan.lua plans each panel's hosts,
-- pins and verify nodes. CondParse.lua, CondEval.lua and BoostClass.lua read a passive's own boosts
-- and conditions, for detected drawbacks. Console.lua has the console commands a player needs;
-- Dev.lua loads the testing ones and their probes from Dev/, which a release build leaves out
--
-- load order is dependency order: each file reads the modules above it at load
PaG = PaG or {}

Ext.Require("ProficiencyAtAGlance/Util.lua")
Ext.Require("ProficiencyAtAGlance/Enums.lua")
Ext.Require("ProficiencyAtAGlance/Log.lua")
Ext.Require("ProficiencyAtAGlance/Layout.lua")
Ext.Require("ProficiencyAtAGlance/Settings.lua")
Ext.Require("ProficiencyAtAGlance/CondParse.lua")
Ext.Require("ProficiencyAtAGlance/CondEval.lua")
Ext.Require("ProficiencyAtAGlance/BoostClass.lua")
Ext.Require("ProficiencyAtAGlance/Read.lua")
Ext.Require("ProficiencyAtAGlance/Rules.lua")
Ext.Require("ProficiencyAtAGlance/Why.lua")
Ext.Require("ProficiencyAtAGlance/PanelPlan.lua")
Ext.Require("ProficiencyAtAGlance/HubConstants.lua")
Ext.Require("ProficiencyAtAGlance/Hub.lua")
Ext.Require("ProficiencyAtAGlance/Console.lua")

local U, L = PaG.Util, PaG.Log
local Settings, Hub = PaG.Settings, PaG.Hub

-- early read, just so the log level is right for anything before the first world loads. Hub.Attach
-- reads again at Running, when MCM has surely finished loading
U.Try("settings.load", Settings.Load, true)
U.Try("console.register", PaG.Console.Register)

local attachPending = false
local layoutPending = false

-- states the game leaves Running for and comes back from in the same world: a save goes Running ->
-- Save -> Running, and a pause returns where it was. Any other exit from Running (load, quit, main
-- menu) ends the world, so every entity id goes stale, and coming back from one attaches again
local KEEPS_WORLD = { Save = true, Paused = true }

Ext.Events.GameStateChanged:Subscribe(function(e)
    local from, to = tostring(e.FromState), tostring(e.ToState)
    if to == "Running" then
        if not KEEPS_WORLD[from] then attachPending = true end
    elseif not KEEPS_WORLD[to] then
        U.Guard("hub.reset", Hub.Reset, "gamestate:" .. to)
        if to == "Menu" then layoutPending = true end
    end
end)

-- the Looks tab's grid (Layout.lua), in the main menu and in game. On v32 and in the inert crash test
-- PaG makes no UI calls, so the tab keeps MCM's layout: Stop puts back a grid that an earlier mode
-- laid out, and does nothing when there is none. In the main menu the stored mode is the next load's
local function layout()
    if Hub.HAS_DEFER and Hub.StoredDiag() ~= "inert" then
        U.Try("layout.start", PaG.Layout.Start)
    else
        U.Try("layout.stop", PaG.Layout.Stop)
    end
end

-- attach on the next tick, not inside the state change, so the character and item reads see the
-- loaded world. The layout follows each attach too: a load from in game never passes the main menu,
-- and !pag_diag may have changed the mode. The other calls return at once when there is nothing to
-- do. SE times this whole handler, so each step's end is stamped for Hub.NoteTick's cost/tick row
local clock = Ext.Timer.MicrosecTime
Ext.Events.Tick:Subscribe(function()
    local t0 = clock()
    U.Tick()
    if attachPending then
        attachPending = false
        U.Try("hub.attach", Hub.Attach)
        layoutPending = true
    end
    if layoutPending then
        layoutPending = false
        layout()
    end
    local tAttach = clock()
    U.Guard("hub.tick", Hub.OnTick)
    local tHub = clock()
    U.Guard("settings.tick", Settings.OnTick)
    local tSettings = clock()
    U.Guard("log.tick", L.OnTick)
    U.Guard("hub.note_tick", Hub.NoteTick, t0, tAttach, tHub, tSettings, clock())
end)

-- a Lua reset (or this mod loading mid-game) while the world is already running, or in the main
-- menu: no state change will come, so attach or lay out now
local state = tostring(U.Get(Ext.Utils.GetGameState))
if state == "Running" then attachPending = true elseif state == "Menu" then layoutPending = true end

-- development tools; a release build empties Dev.lua
Ext.Require("ProficiencyAtAGlance/Dev.lua")
