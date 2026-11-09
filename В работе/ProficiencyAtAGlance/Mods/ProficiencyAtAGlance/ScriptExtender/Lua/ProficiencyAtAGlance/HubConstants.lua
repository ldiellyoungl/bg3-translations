-- Hub constants and template descriptors. Settings and Enums must be loaded first.
local E, Settings = PaG.Enums, PaG.Settings
local C = {}
PaG.HubConstants = C

C.ROOT_NAME = "PaGRoot"
C.SLOT_ROOT_NAME = "PaGSlotRoot"
C.SAMPLES_PER_BURST = 10
C.BURST_MAX_N = 2000          -- a burst row is written at least this often...
C.BURST_MAX_MS = 5000         -- ...and at least this often, even if renders never stop
C.CAUSE_TICKS = 3             -- a generation move names the burst that starts within this many ticks of it
C.ERROR_KINDS = 20            -- distinct error messages printed; later ones only counted
C.WALK_DEPTH = 200            -- runaway backstop only
C.SHOWN_MAX = 4096            -- cells remembered; past it the memory starts again (full writes)
-- the game states in which the visual tree is touched. A whitelist, not a blacklist: a state not
-- named here is a state the tree is not touched in. MoveWithWorldMap carries the same gate for the
-- same reason (BootstrapClient.lua:152-163): a tree walk during teardown is "a NATIVE crash that no
-- pcall catches". GetGameState is asked on the tick that queues the callback
C.TREE_SAFE = { Running = true, Paused = true }
C.WATCH_MAX = 16              -- bound items watched for losing their binding, per world load
C.STALL_MS = 200              -- a gap this long between ticks, while attached, writes a stall row
C.SLOW_US = 2000              -- a Tick or callback this long writes a cost/tick or cost/cb row with its
                                  -- stage split: SE's line for a client call in a running game
                                  -- (ProfilerClientCallbackThreshold)
C.DEFER_WAIT_TICKS = 10       -- a callback that ran this many ticks after it was queued writes a defer_wait row
C.COST_ROWS = 64              -- cb, tick and defer_wait rows per world load, each; the rest are counted (detach)
C.REREAD_ROWS = 256           -- reread rows (nothing changed) per world load; the rest are counted (detach)
C.GATE_CHILDREN = 240         -- ContentRoot children read in one go. At the cap the list is
                                  -- truncated, so it reads as unknown, not unchanged
-- ContentRoot children that are never panels, so never walked and their cells never marked: the
-- pickpocket window (Pickpocket.xaml:1, Pickpocket_c.xaml:1). A pickpocket wants an item's value,
-- not whether they could wear it (D28)
C.UNMARKED_PANELS = { Pickpocket = true, Pickpocket_c = true }
-- ContentRoot children whose pages use PaG's cell templates (the s046-s052 XAML census). Fail-safe:
-- a name here only keeps the full rewalk schedule when a show finds no cells (never barrenNames);
-- it never blocks a walk
C.CELL_PAGES = { PartyPanel = true, PartyPanel_c = true, CharacterPanel = true, CharacterPanel_c = true,
    CompanionsPanel = true, CompanionsPanel_c = true, ContainerWidget = true, ContainerWidget_c = true,
    Trade = true, Trade_c = true }
C.CHAR_COMPONENTS = { "Proficiency", "PassiveContainer", "Classes", "StatusContainer",
    "ClientEquipmentVisuals" }

-- the callback's budget, checked between units (a unit: one cell or WALK_UNIT walk visits; console
-- jobs are capped by count, RUNUI_MAX). Poll and walk each do one unit before they first check it,
-- and in s070 a steady callback ended about 0.7 ms past its budget, so BUDGET_US stays at least
-- that far under SLOW_US. BURST_US while renders are pending after a character, rules or looks change, or
-- a first paint
C.BUDGET_US = 1000
C.BURST_US = 3000
C.JUDGE_BUDGET_US = 1500      -- Tick: judging wanted keys
C.WALK_RESERVE_US = 300       -- kept for the walk whenever one is pending
C.REWALK_US = 400             -- a verify pass's share of one callback
C.WALK_UNIT = 16
-- cadence: every tick while hot or while anything is wanted; every POLL_EVERY ticks while a visible
-- panel holds cells (mark and observe run on each; after a pass that found nothing the poll rests
-- until POLL_PERIOD ticks after that pass began, unless hot or a render is asked for); otherwise an
-- idle probe (mark and observe) every IDLE_FIRST ticks, doubling after each IDLE_QUIET quiet probes
-- up to IDLE_MAX
C.POLL_EVERY = 2
C.POLL_PERIOD = 8
C.IDLE_FIRST = 4
C.IDLE_MAX = 16
C.IDLE_QUIET = 8
C.HOT_TICKS = 30
C.REREAD_GAP_TICKS = 10       -- a character is re-read at most this often; changes between merge
C.STALL_DEFER_TICKS = 188     -- a callback queued this long ago that has not run: logged once
C.SAFETY_REWALK = 47          -- ticks between verify passes of a live panel
C.RESTARTS_MAX = 3            -- walk restarts per panel per SAFETY_REWALK ticks
C.EMPTY_REWALKS = { 4, 8, 16, 32, 64 }
-- the trade pages. Their item cells (both sides; never the doll's slots) take trade_marks' looks
-- (buildLooks, looksFor); Subtle shows the glow, badge and dot at TRADE_FAINT
C.TRADE_PAGES = { Trade = true, Trade_c = true }
C.TRADE_FAINT = 0.65
-- a live trade page whose cells are all slots (before its item lists fill) is walked again for its
-- item cells: SLOT_REWALK_TICKS apart for SLOT_REWALK_FAST walks, then SAFETY_REWALK apart while shown.
-- Trade only: CharacterPanel can hide its inventory column (CharacterPanel.xaml InventoryColumn), may
-- then hold slots alone, and would be walked every SAFETY_REWALK for as long as it stayed open. Any
-- other slot-only panel is just never learned
C.SLOT_REWALK_PAGES = C.TRADE_PAGES
C.SLOT_REWALK_TICKS = 12
C.SLOT_REWALK_FAST = 10
-- a trade page's item lists, by Name (Trade.xaml, which Better Trade Menu's copy keeps; Trade_c.xaml).
-- A walk notes each list it passes; one it found no cell in is walked again after every verify pass
-- while the page is shown (p.lists): one side's list can fill after the walk that found the other's
-- Better Trade Menu's Camp Storage pages (its Trade.xaml:760, 782) are lists too: collapsed until the
-- tab is turned on, so their cells are built after the page's walk, under nodes whose child counts
-- the verify pass never sees change
C.LIST_ROOTS = {
    Trade = { PlayerInventory = true, SingleInventoryRoot = true, PlayerBarterOffer = true,
              TraderBarterOffer = true, TraderInventory = true,
              BTMChestInvPage = true, BTMCompanionInvPage = true },
    Trade_c = { PanelsContainer = true, SingleInventoryRoot = true, PlayerOffer = true,
                TraderOffer = true, TraderInventoryContainer = true },
}
C.VIS_ROWS = 8                -- panel_vis rows one callback may queue
C.RETRY_TICKS = { 8, 16, 32, 64, 128, 256, 512, 1024 }  -- re-judging a verdict from a failed read (Rules.Retry); the last repeats
C.HOST_SPAN = 8               -- a host is found among a cell path's last HOST_SPAN levels
C.DLOG_MAX = 64               -- log rows a callback can queue for Tick
C.RUNUI_MAX = 4               -- console jobs queued at once
-- characters whose verdicts are kept: the judged one and every equipped slot's wearer (D27), so at
-- least one per paper doll the party panel shows. Past it the least recently judged one's go
C.VC_CHARS = 32
C.VC_KEYS = 4096              -- verdicts kept per character; past it that character's start again
C.WANTED_MAX = 4096
C.FAULTS_MAX = 2              -- callback or tick faults before PaG clears its marks and stops
C.RING = 256                  -- timings kept for the percentiles in !pag_status

C.DIAG_FILE = "ProficiencyAtAGlance/diag.txt"
C.DIAG_MODES = { full = true, nowrite = true, inert = true }

-- rule keys: a change to one judges every verdict again (onSettingsSettle, Hub.lua).
-- ac_shield_badge is a display key: it sits with the Armor vs AC bonuses family in MCM, but
-- changes only which icon a mark shows. equipped_tooltips is a rule key: the badge's tooltip is
-- built when the slot is judged, and kept with its verdict. cell_tooltips is one for the same
-- reason: a cell's tooltip is part of its verdict, so a change judges every cell again
C.RULE_KEYS = { enabled = true, equipped_marks = true, equipped_tooltips = true, cell_tooltips = true }
for _, f in ipairs(Settings.FAMILIES) do
    C.RULE_KEYS[f.key] = true
    for _, cause in ipairs(f.causes) do
        if cause.key ~= nil then C.RULE_KEYS[cause.key] = true end
    end
end

-- where each part sits under PaGParts, as child indexes (the template is ours, so the positions are
-- fixed), and the name each must carry. The first cell decides whether Child or VisualChild reaches
-- them and checks every name once; a mismatch means no marks rather than wrong ones (D10)
C.PART = {
    shade = { 1 },
    marks = { 2 },
    glow = { 2, 1 }, glowSides = { 2, 1, 1 }, glowEnds = { 2, 1, 2 },
    badge = { 2, 2 },
    badgeCheck = { 2, 2, 1, 2 }, badgeCheckThin = { 2, 2, 1, 3 }, badgeCheckGlow = { 2, 2, 1, 4 },
    badgeStar = { 2, 2, 1, 5 }, badgeWarning = { 2, 2, 1, 6 }, badgeExclamation = { 2, 2, 1, 7 },
    badgeMinus = { 2, 2, 1, 8 }, badgeCross = { 2, 2, 1, 9 }, badgeCrossThin = { 2, 2, 1, 10 },
    badgeSkull = { 2, 2, 1, 11 }, badgeShield = { 2, 2, 1, 12 },
    dot = { 2, 3 }, dotShape = { 2, 3, 1 },
    id = { 3, 1 }, gray = { 3, 2 },
    colors = { 3, 3 }, colorRed = { 3, 3, 1 }, colorOrange = { 3, 3, 2 }, colorYellow = { 3, 3, 3 },
    colorGreen = { 3, 3, 4 }, colorBlue = { 3, 3, 5 }, colorPurple = { 3, 3, 6 },
    swap = { 3, 4 },
    glowColors = { 3, 5 },
    glowSidesRed = { 3, 5, 1 }, glowEndsRed = { 3, 5, 2 }, glowSidesOrange = { 3, 5, 3 },
    glowEndsOrange = { 3, 5, 4 }, glowSidesYellow = { 3, 5, 5 }, glowEndsYellow = { 3, 5, 6 },
    glowSidesGreen = { 3, 5, 7 }, glowEndsGreen = { 3, 5, 8 }, glowSidesBlue = { 3, 5, 9 },
    glowEndsBlue = { 3, 5, 10 }, glowSidesPurple = { 3, 5, 11 }, glowEndsPurple = { 3, 5, 12 },
    -- the badge and dot's tooltip text (Why.Text), then the same split for the tooltip's layout:
    -- its title and one cause per part (WHY_LINE_PARTS)
    why = { 3, 6 },
    whyTitle = { 3, 7 }, why1 = { 3, 8 }, why2 = { 3, 9 }, why3 = { 3, 10 }, why4 = { 3, 11 },
    why5 = { 3, 12 }, why6 = { 3, 13 }, why7 = { 3, 14 },
}
C.PART_NAME = {
    shade = "PaGShade",
    marks = "PaGMarks",
    glow = "PaGGlow", glowSides = "PaGGlowSides", glowEnds = "PaGGlowEnds",
    badge = "PaGBadge",
    badgeCheck = "PaGBadgeCheck", badgeCheckThin = "PaGBadgeCheckThin", badgeCheckGlow = "PaGBadgeCheckGlow",
    badgeStar = "PaGBadgeStar", badgeWarning = "PaGBadgeWarning", badgeExclamation = "PaGBadgeExclamation",
    badgeMinus = "PaGBadgeMinus", badgeCross = "PaGBadgeCross", badgeCrossThin = "PaGBadgeCrossThin",
    badgeSkull = "PaGBadgeSkull", badgeShield = "PaGBadgeShield",
    dot = "PaGDot", dotShape = "PaGDotShape",
    id = "PaGId", gray = "PaGGray",
    colors = "PaGColors", colorRed = "PaGColorRed", colorOrange = "PaGColorOrange", colorYellow = "PaGColorYellow",
    colorGreen = "PaGColorGreen", colorBlue = "PaGColorBlue", colorPurple = "PaGColorPurple",
    swap = "PaGSwap",
    glowColors = "PaGGlowColors",
    glowSidesRed = "PaGGlowSidesRed", glowEndsRed = "PaGGlowEndsRed",
    glowSidesOrange = "PaGGlowSidesOrange", glowEndsOrange = "PaGGlowEndsOrange",
    glowSidesYellow = "PaGGlowSidesYellow", glowEndsYellow = "PaGGlowEndsYellow",
    glowSidesGreen = "PaGGlowSidesGreen", glowEndsGreen = "PaGGlowEndsGreen",
    glowSidesBlue = "PaGGlowSidesBlue", glowEndsBlue = "PaGGlowEndsBlue",
    glowSidesPurple = "PaGGlowSidesPurple", glowEndsPurple = "PaGGlowEndsPurple",
    why = "PaGWhy",
    whyTitle = "PaGWhyTitle", why1 = "PaGWhy1", why2 = "PaGWhy2", why3 = "PaGWhy3", why4 = "PaGWhy4",
    why5 = "PaGWhy5", why6 = "PaGWhy6", why7 = "PaGWhy7",
}
-- the same for an equipment slot's overlay, under PaGSlotParts (Q13): the badge holds the plate,
-- the six Not Ideal and Bad icons and the AC shield; PaGSlotIO the label, the palette, the corner
-- switch, the badge's tooltip text and its layout parts, as a cell's
C.SLOT_PART = { badge = { 1 },
    warning = { 1, 2 }, exclamation = { 1, 3 }, minus = { 1, 4 },
    cross = { 1, 5 }, crossThin = { 1, 6 }, skull = { 1, 7 }, shield = { 1, 8 },
    id = { 2, 1 },
    colors = { 2, 2 }, colorRed = { 2, 2, 1 }, colorOrange = { 2, 2, 2 }, colorYellow = { 2, 2, 3 },
    colorGreen = { 2, 2, 4 }, colorBlue = { 2, 2, 5 }, colorPurple = { 2, 2, 6 },
    swap = { 2, 3 }, why = { 2, 4 },
    whyTitle = { 2, 5 }, why1 = { 2, 6 }, why2 = { 2, 7 }, why3 = { 2, 8 }, why4 = { 2, 9 },
    why5 = { 2, 10 }, why6 = { 2, 11 }, why7 = { 2, 12 } }
C.SLOT_PART_NAME = { badge = "PaGSlotBadge",
    warning = "PaGSlotWarning", exclamation = "PaGSlotExclamation", minus = "PaGSlotMinus",
    cross = "PaGSlotCross", crossThin = "PaGSlotCrossThin", skull = "PaGSlotSkull",
    shield = "PaGSlotShield",
    id = "PaGSlotId",
    colors = "PaGSlotColors", colorRed = "PaGSlotColorRed", colorOrange = "PaGSlotColorOrange",
    colorYellow = "PaGSlotColorYellow", colorGreen = "PaGSlotColorGreen", colorBlue = "PaGSlotColorBlue",
    colorPurple = "PaGSlotColorPurple",
    swap = "PaGSlotSwap", why = "PaGSlotWhy",
    whyTitle = "PaGSlotWhyTitle", why1 = "PaGSlotWhy1", why2 = "PaGSlotWhy2", why3 = "PaGSlotWhy3",
    why4 = "PaGSlotWhy4", why5 = "PaGSlotWhy5", why6 = "PaGSlotWhy6", why7 = "PaGSlotWhy7" }
-- the tooltip's layout parts in a cell and a slot, in order: the title (Why.Text's first line),
-- then one cause each
C.WHY_LINE_PARTS = { "whyTitle", "why1", "why2", "why3", "why4", "why5", "why6", "why7" }

-- the two kinds of root a walk stops at. `i` is the visual child of the root that holds every part
-- Lua touches (`parts`, Name-checked); a cell's first child is its item's ContentPresenter
C.CELL = { kind = "cell", slot = false, i = 2, parts = "PaGParts", map = C.PART, names = C.PART_NAME }
C.SLOT = { kind = "slot", slot = true, i = 1, parts = "PaGSlotParts", map = C.SLOT_PART, names = C.SLOT_PART_NAME }
C.KIND_OF_ROOT = { [C.ROOT_NAME] = C.CELL, [C.SLOT_ROOT_NAME] = C.SLOT }

-- the glow's two rectangles (D29), and for each palette color the holders of its two fades, in
-- the same order
C.GLOW_PARTS = { "glowSides", "glowEnds" }
C.GLOW_COLOR_PART = {
    [E.Color.Red] = { "glowSidesRed", "glowEndsRed" },
    [E.Color.Orange] = { "glowSidesOrange", "glowEndsOrange" },
    [E.Color.Yellow] = { "glowSidesYellow", "glowEndsYellow" },
    [E.Color.Green] = { "glowSidesGreen", "glowEndsGreen" },
    [E.Color.Blue] = { "glowSidesBlue", "glowEndsBlue" },
    [E.Color.Purple] = { "glowSidesPurple", "glowEndsPurple" },
}
-- the badge icon part for each E.Icon member, and the icon parts in template order
C.GLYPH_PART = {
    [E.Icon.Check] = "badgeCheck", [E.Icon.CheckThin] = "badgeCheckThin", [E.Icon.CheckGlow] = "badgeCheckGlow",
    [E.Icon.Star] = "badgeStar", [E.Icon.Warning] = "badgeWarning", [E.Icon.Exclamation] = "badgeExclamation",
    [E.Icon.Minus] = "badgeMinus", [E.Icon.Cross] = "badgeCross", [E.Icon.CrossThin] = "badgeCrossThin",
    [E.Icon.Skull] = "badgeSkull", [E.Icon.Shield] = "badgeShield",
}
C.GLYPHS = { "badgeCheck", "badgeCheckThin", "badgeCheckGlow", "badgeStar", "badgeWarning",
    "badgeExclamation", "badgeMinus", "badgeCross", "badgeCrossThin", "badgeSkull", "badgeShield" }
-- the parts whose Opacity is a cell's state, in the order they are hidden or shown. The corner
-- switch comes first, so a badge or dot never shows in the corner it is leaving
C.MARK_PARTS = { "swap", "shade", "gray", "glow", "badge", "dot" }
-- the same for a slot, which shows only Not Ideal and Bad (Q13)
C.SLOT_GLYPH_PART = {
    [E.Icon.Warning] = "warning", [E.Icon.Exclamation] = "exclamation", [E.Icon.Minus] = "minus",
    [E.Icon.Cross] = "cross", [E.Icon.CrossThin] = "crossThin", [E.Icon.Skull] = "skull",
    [E.Icon.Shield] = "shield",
}
C.SLOT_GLYPHS = { "warning", "exclamation", "minus", "cross", "crossThin", "skull", "shield" }
-- the part that holds each palette color's brush, the same key in a cell and a slot
C.COLOR_PART = {
    [E.Color.Red] = "colorRed", [E.Color.Orange] = "colorOrange", [E.Color.Yellow] = "colorYellow",
    [E.Color.Green] = "colorGreen", [E.Color.Blue] = "colorBlue", [E.Color.Purple] = "colorPurple",
}

C.OPA = { [true] = 1, [false] = 0 }

C.LEVEL_EPS = 1e-3

C.NONE = { swap = false, shade = false, gray = false, glow = false, badge = false, dot = false, marks = 1 }
C.UNKNOWN = { unknown = true }

C.CLAIM_GIVE_UP = 32

C.KINDS = { cell = C.CELL, slot = C.SLOT }
-- an equipment slot's x:Name (CharacterEquipmentTemplate, Lib_Keyboard.xaml) and the property of
-- its wearer's Equipment that it shows
C.SLOT_PROPS = {
    EquipmentHelmetSlot = "Helmet", EquipmentBreastSlot = "Breast", EquipmentGlovesSlot = "Gloves",
    EquipmentBootsSlot = "Boots", EquipmentMeleeMainSlot = "MeleeMainHand",
    EquipmentMeleeOffSlot = "MeleeOffHand", EquipmentRangedMainSlot = "RangedMainHand",
    EquipmentRangedOffSlot = "RangedOffHand",
}
-- panels whose paper doll's wearer is bound, so reads nil on every node above the slots (SE reads
-- only a node's own stored values), and is read instead off the panel root's DataContext along
-- these properties: CharacterPanel.xaml:435 (EquipmentHolder DataContext="{Binding
-- CurrentPlayer.SelectedCharacter}"), Trade.xaml:559 (DataContext="{Binding CurrentTradingCharacter}")
C.WEARER_ROOT = {
    CharacterPanel = { "CurrentPlayer", "SelectedCharacter" },
    Trade = { "CurrentTradingCharacter" },
}
C.WEARER_RETRY = 32           -- ticks between searches for a host's or pin's wearer while none reads
C.WALK_MAX = 50000            -- visits one walk may make; past it the walk ends, capped
C.MISS_RETRY_TICKS = C.SAFETY_REWALK * 8   -- a host child that led to no cell is walked again after this

-- the suffix of a cell's key when its item is a Ware and ware_marks is off. diff judges such a key
-- for nobody, so the cell shows no mark; turning ware_marks on changes the key back to the item's
-- and the cell is judged as any other. Only `true` counts: an IsWare that does not read takes no
-- mark away (probe ware_unread)
C.WARE = "@ware"

C.HEAP_EVERY = 94   -- ticks between heap samples (~1 s)
