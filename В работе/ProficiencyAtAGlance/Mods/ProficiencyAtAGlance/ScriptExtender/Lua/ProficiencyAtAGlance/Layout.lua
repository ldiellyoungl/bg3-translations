-- the Looks tab as a grid (design G20). One table holds the looks: a header row (Glow, Badge, Dot,
-- Dim, Gray), then one row per tier (Bad, Not Ideal, Good), so each look keeps its column and each
-- look name shows once. Good has no Dim or Gray (D23): those cells show "-". A second table holds
-- Color and Badge icon, one row per tier. The Placement section follows, as MCM built it
--
-- nothing is copied: the cells hold MCM's own setting groups, moved there with DetachChild and
-- AttachChild (MCM moves a mod's page into its pop-out window the same way, RightPane.lua:303), so
-- every checkbox, reset button, list and radio button is still MCM's. In the grid PaG hides each
-- look's label (its name is in the header, so clicking a name no longer toggles the box), each
-- setting's title and each setting's 10 px spacer, and hides the three tier sections, whose names
-- become the tables' first column. All the text PaG shows is read from MCM's own labels, so it is
-- already translated. A hidden element draws nothing (SE IMGUI.cpp Render)
--
-- the columns fit their widest cell each frame (WidthFixed with no width), and a last row of
-- zero-height struts sets that width: a look column is 2F + LOOK_EXTRA wide and the Color column
-- 7F + 32, where F is the reset icon's size. A strut is wider than the checkbox and the reset
-- button together (and the list and its reset button), so a reset button that comes and goes no
-- longer moves the columns. A fixed width would be exact but clips. SE scales a Dummy, an image and
-- an ItemWidth by the window's scale, but not style values like FramePadding: the docked window has
-- that scale and the pop-out has none (1), and the struts cover both from scale 0.5 up
--
-- PaG's group turns text wrapping off (TextWrapPos -1; ImGui: below 0, no wrapping). MCM sets the
-- Looks tab's TextWrapPos to 0 for its description (MCMRendering.lua:475-477) and SE pushes it over
-- the whole subtree, so a text would wrap at its column's edge, and a column that fits its content,
-- like the tier names', would shrink to a letter or two
--
-- a tier's name lines up with its row's text in MCM's main window: ImGui puts a cell's text on its
-- row's text baseline, which the first cell starts at 0, so the name sits under a zero-height Dummy
-- whose spacing is that window's FramePadding.y (PAD_Y). MCM's pop-out window keeps ImGui's
-- default, scaled (2 below 4K), so there the name sits 2 px low. No widget can take the live value:
-- a button is a keyboard and gamepad stop (SE turns both on), and no mod uses a progress bar. The
-- "-" cells come after a checkbox in their row, so ImGui aligns them in either window
-- (imgui_tables.cpp TableBeginCell and TableEndCell)
--
-- the Class & feats and Item drawbacks tabs as tables: one row per section, which holds one family.
-- The first column is the section's name, the second the family's radio buttons (Mark as) and the
-- third its checkboxes, stacked, which takes the rest of the width. Rows alternate their background
-- (RowBg, as MCM's list widgets do, in dark gray and slightly blue rather than MCM's green and brown).
-- As in the Looks grid, the groups are MCM's own: PaG hides each section, the spacer before it and
-- the radio's title, and stashes each group's 10 px spacer (a checkbox's carries its VisibleIf, so
-- MCM would show it again). What each setting marks is in its tooltip
--
-- the tabs come from MCM's public MCM.InsertModMenuTab, which passes an existing blueprint tab to a
-- callback. Right after that callback MCM gives the tab's text and inputs its custom-tab styles
-- wherever none are set (IMGUIHelpers.ApplyCustomTabStyles). MCM's own widgets set their input
-- styles when built, but not every text color, so the callback first sets every color that pass
-- would set, to the color the element already draws with: the pass then changes nothing
--
-- in the main menu and in game: _Init calls Start on entering the main menu and after each attach.
-- On v32 and in the inert crash test it calls Stop instead, so the tab keeps MCM's layout: the groups
-- go back to their sections in the blueprint's order and the tables are hidden (on every PaG tab). SE ends the client's
-- Lua state when a session unloads and starts a new one when the next loads or the main menu returns
-- (ScriptExtenderClient.cpp:197-198, :223-226, :248-250; the runtime log says "LUA VM reset"), so on
-- the way into a game and back PaG and MCM start afresh: MCM builds a new window and calls back
--
-- these are IMGUI tree edits from Lua, on the client's main thread like MCM's own, which is also the
-- thread SE draws the tree on. Each pass finds every element afresh by its IDContext and changes
-- only what differs, so running it again, in either direction, ends in the same tree
local U, L = PaG.Util, PaG.Log

local Y = {}
PaG.Layout = Y

-- the blueprint's ids (MCM_blueprint.json, the Looks tab): keep the two in sync by hand. A setting's
-- group is "<ModuleUUID>_<tier>_<key>_Group", its reset button "<ModuleUUID>_ResetButton_<tier>_<key>"
-- and a section's group "<ModuleUUID>_<section>_Group" (MCMRendering.lua, IMGUIWidget.lua)
local TAB = "looks"
local TIERS = {
    { section = "bad_marks",       tier = "bad" },
    { section = "not_ideal_marks", tier = "not_ideal" },
    { section = "good_marks",      tier = "good" },
}
local AFTER = "placement"                               -- the section shown after the tables
local LOOKS = { "glow", "badge", "dot", "dim", "gray" } -- the grid's columns, in the blueprint's order
local STYLE = { "color_preset", "badge_icon" }          -- the second table's columns, likewise
local ID = ModuleUUID .. "_PaGLooks"                    -- PaG's group in the tab

-- the penalty tabs (the blueprint's Class & feats and Item drawbacks): each section and its family's
-- radio. A row's settings are the family's, in PaG.Settings.FAMILIES' order, which is the blueprint's
-- (settings_ids_test.py checks each section holds one family, radio first)
local ROW_TABS = {
    { tab = "class_feats", rows = {
        { section = "class_armor",  family = "class_armor_tier" },
        { section = "class_weapon", family = "class_weapon_tier" },
        { section = "feat_weapon",  family = "feat_tier" },
        { section = "hands",        family = "hands_tier" },
    } },
    { tab = "item_drawbacks", rows = {
        { section = "ac",        family = "ac_tier" },
        { section = "movement",  family = "movement_tier" },
        { section = "ability",   family = "ability_tier" },
        { section = "combat",    family = "combat_tier" },
        { section = "universal", family = "universal_tier" },
    } },
}
local ROWS_ID = ModuleUUID .. "_PaGRows_"               -- .. the tab id: PaG's group in that tab

local PAD_Y = 4        -- MCM's main window's FramePadding.y (UIStyle.Styles: 4.0, which SE applies as 4,4)
local LOOK_EXTRA = 48  -- see the header: covers a window scale from 0.5 up
local ICON = 32        -- the reset icon's size when no reset button has an image
local LIST_ICONS = 6   -- the Color list's width, in reset icons
local ROW_ICONS = 12   -- the Mark as column's width, in reset icons: Off, Not ideal, Bad and a reset
                       -- button (F is MCM's font size, and the three choices are about 7.5F of text)
local ROW_EXTRA = 48   -- as LOOK_EXTRA
local ROW_BG = { 0.17, 0.17, 0.17, 1.0 }     -- a penalty table's rows: dark gray,
local ROW_BG_ALT = { 0.16, 0.19, 0.25, 1.0 } -- then a slightly blue one (MCM's are green and brown)

local live = false     -- after Start, until Stop: the grid is wanted
local registered = false
local tabs = {}        -- MCM's tab for each tab id, once its callback has run
local tab = nil        -- the tab the pass at hand works on, one of tabs

local function kind(el) return Ext.Types.GetObjectType(el) end

local function childById(parent, id)
    for _, c in ipairs(parent.Children) do
        if c.IDContext == id then return c end
    end
    return nil
end

local function firstOf(parent, ty)
    for _, c in ipairs(parent.Children) do
        if kind(c) == ty then return c end
    end
    return nil
end

local function lastChild(parent)
    local last = nil
    for _, c in ipairs(parent.Children) do last = c end
    return last
end

local function nth(parent, n)
    local i = 0
    for _, c in ipairs(parent.Children) do
        i = i + 1
        if i == n then return c end
    end
    return nil
end

local function indexOf(parent, el)
    if el == nil then return nil end
    local i = 0
    for _, c in ipairs(parent.Children) do
        i = i + 1
        if c.IDContext == el.IDContext and kind(c) == kind(el) then return i end
    end
    return nil
end

-- the sibling MCM put before a section: the 5 px Dummy it adds before every section but the first
local function spacerBefore(sec)
    if sec == nil then return nil end
    local prev = nil
    for _, c in ipairs(tab.Children) do
        if c.IDContext == sec.IDContext then
            if prev ~= nil and kind(prev) == "Dummy" then return prev end
            return nil
        end
        prev = c
    end
    return nil
end

local function sectionOf(id) return childById(tab, ModuleUUID .. "_" .. id .. "_Group") end
local function settingGroupId(id) return ModuleUUID .. "_" .. id .. "_Group" end

-- a setting's group, wherever it is now: its section or its cell
local function findSetting(id, places)
    id = settingGroupId(id)
    for _, p in ipairs(places) do
        local g = childById(p, id)
        if g ~= nil then return g, p end
    end
    return nil
end

local function findGroup(tier, key, places) return findSetting(tier .. "_" .. key, places) end

local function move(g, from, to)
    if from.IDContext == to.IDContext then return end
    -- DetachChild leaves the group alive with no parent, which is all AttachChild asks
    -- (SE IMGUI.cpp, TreeParent::DetachChild and AttachChild)
    from:DetachChild(g)
    to:AttachChild(g)
end

-- the cell for a tier's key: row 1 is the header, then one row per tier in TIERS' order
local GRID, STYLE_TABLE = 2, 4 -- their places in PaG's group: Separator, grid, Dummy, style table

local function cellOf(box, tbl, ti, col)
    local row = nth(nth(box, tbl), 1 + ti)
    return row and nth(row, 1 + col)
end

-- the reset icon's size, read from the first reset button that has an image, in its section or
-- (once PaG's group exists) its cell
local function iconSize(box)
    for ti, s in ipairs(TIERS) do
        local sec = sectionOf(s.section)
        for i, key in ipairs(LOOKS) do
            local places = { sec, box and cellOf(box, GRID, ti, i) }
            local g = findGroup(s.tier, key, places[1] and places or { places[2] })
            local btn = g and childById(g, ModuleUUID .. "_ResetButton_" .. s.tier .. "_" .. key)
            local size = U.Field(U.Field(btn, "Image"), "Size")
            local w = type(size) == "table" and tonumber(size[1]) or nil
            if w ~= nil and w > 0 then return w end
        end
    end
    return ICON
end

-- a tier's name in a table's first column: PAD_Y below the cell's top, like a checkbox's text in
-- MCM's main window (see the header)
local function addTierLabel(cell, id)
    local g = cell:AddGroup(id)
    g.IDContext = id
    g:SetStyle("ItemSpacing", 0, PAD_Y)
    g:AddDummy(0, 0)
    g:AddText("").IDContext = id .. "_Text"
end

local function addRow(tbl, id, n)
    local row = tbl:AddRow()
    row.IDContext = id
    for i = 1, n do row:AddCell().IDContext = id .. "_" .. i end
    return row
end

-- stretchLast: the last column takes the rest of the tab's width
local function addTable(box, id, columns, stretchLast)
    local tbl = box:AddTable("##" .. id, columns)
    tbl.IDContext = id
    tbl:SetStyle("CellPadding", 4, 2)
    for i = 1, columns do
        tbl:AddColumn("", (stretchLast and i == columns) and "WidthStretch" or "WidthFixed")
    end
    return tbl
end

-- PaG's group, made the first time the layout goes on and kept (hidden when off) after that
local function build()
    local f = iconSize()
    local box = tab:AddGroup(ID)
    box.IDContext = ID
    box.TextWrapPos = -1 -- see the header: the tab's 0 would wrap the tier names
    box:AddSeparator().IDContext = ID .. "_Separator"

    local grid = addTable(box, ID .. "_Grid", 1 + #LOOKS)
    local head = addRow(grid, ID .. "_Grid_Head", 1 + #LOOKS)
    for i = 1, #LOOKS do nth(head, 1 + i):AddText("").IDContext = ID .. "_Grid_Head_Text_" .. i end
    for _, s in ipairs(TIERS) do
        local row = addRow(grid, ID .. "_Grid_" .. s.tier, 1 + #LOOKS)
        addTierLabel(nth(row, 1), ID .. "_Grid_" .. s.tier .. "_Name")
        for i, key in ipairs(LOOKS) do
            if PaG.Settings.NOT_OFFERED[s.tier .. "_" .. key] then
                nth(row, 1 + i):AddText("-").IDContext = ID .. "_Grid_" .. s.tier .. "_None_" .. i
            end
        end
    end
    local struts = addRow(grid, ID .. "_Grid_Struts", 1 + #LOOKS)
    for i = 1, #LOOKS do nth(struts, 1 + i):AddDummy(2 * f + LOOK_EXTRA, 0) end

    box:AddDummy(0, 10).IDContext = ID .. "_Spacer"

    local style = addTable(box, ID .. "_Style", 1 + #STYLE)
    head = addRow(style, ID .. "_Style_Head", 1 + #STYLE)
    for i = 1, #STYLE do nth(head, 1 + i):AddText("").IDContext = ID .. "_Style_Head_Text_" .. i end
    for _, s in ipairs(TIERS) do
        local row = addRow(style, ID .. "_Style_" .. s.tier, 1 + #STYLE)
        addTierLabel(nth(row, 1), ID .. "_Style_" .. s.tier .. "_Name")
    end
    struts = addRow(style, ID .. "_Style_Struts", 1 + #STYLE)
    nth(struts, 2):AddDummy((LIST_ICONS + 1) * f + 32, 0)

    -- where each Color group's 10 px spacer waits while laid out: MCM shows and hides that spacer
    -- with Color itself (it carries Color's VisibleIf), so hiding it would not last
    for _, s in ipairs(TIERS) do
        local stash = box:AddGroup(ID .. "_Stash_" .. s.tier)
        stash.IDContext = ID .. "_Stash_" .. s.tier
        stash.Visible = false
    end
    return box
end

-- a label of PaG's takes MCM's text, and its color when MCM set one
local function copyText(to, from)
    if to == nil or from == nil then return end
    to.Label = from.Label
    local c = from:GetColor("Text")
    if c ~= nil then to:SetColor("Text", c) end
end

local function headText(box, tbl, i)
    local cell = nth(nth(nth(box, tbl), 1), 1 + i)
    return cell and childById(cell, ID .. (tbl == GRID and "_Grid_Head_Text_" or "_Style_Head_Text_") .. i)
end

local function layOut()
    local box = childById(tab, ID) or build()
    -- shown before anything moves, so a pass that stops partway still gets put back by Stop
    box.Visible = true
    local headed = {}
    local missing = nil
    local function miss(tier, key)
        if not PaG.Settings.NOT_OFFERED[tier .. "_" .. key] then
            missing = missing or {}
            missing[#missing + 1] = tier .. "_" .. key
        end
    end
    local bad = sectionOf(TIERS[1].section)
    if bad ~= nil then
        local sepText = firstOf(bad, "SeparatorText")
        local c = sepText and sepText:GetColor("Separator")
        if c ~= nil then childById(box, ID .. "_Separator"):SetColor("Separator", c) end
    end

    for ti, s in ipairs(TIERS) do
        local sec = sectionOf(s.section)
        local name = sec and firstOf(sec, "SeparatorText")
        for t, tbl in ipairs({ GRID, STYLE_TABLE }) do
            local label = childById(cellOf(box, tbl, ti, 0), ID .. (t == 1 and "_Grid_" or "_Style_") .. s.tier .. "_Name")
            copyText(label and childById(label, label.IDContext .. "_Text"), name)
        end

        for i, key in ipairs(LOOKS) do
            local cell = cellOf(box, GRID, ti, i)
            local g, from = findGroup(s.tier, key, sec and { sec, cell } or { cell })
            if g == nil then
                miss(s.tier, key)
                -- a "-" cell in its column's color (the tiers above it set the header)
                local none = cell and childById(cell, ID .. "_Grid_" .. s.tier .. "_None_" .. i)
                local head = headText(box, GRID, i)
                local c = head and head:GetColor("Text")
                if none ~= nil and c ~= nil then none:SetColor("Text", c) end
            else
                move(g, from, cell)
                local text = firstOf(g, "Text")
                if text ~= nil then
                    text.Visible = false
                    if not headed[key] then
                        headed[key] = true
                        copyText(headText(box, GRID, i), text)
                    end
                end
                local last = lastChild(g)
                if last ~= nil and kind(last) == "Dummy" then last.Visible = false end
            end
        end

        local f = nil
        for i, key in ipairs(STYLE) do
            local cell = cellOf(box, STYLE_TABLE, ti, i)
            local g, from = findGroup(s.tier, key, sec and { sec, cell } or { cell })
            if g == nil then
                miss(s.tier, key)
            else
                move(g, from, cell)
                local title = firstOf(g, "Text")
                if title ~= nil then
                    title.Visible = false
                    if not headed[key] then
                        headed[key] = true
                        copyText(headText(box, STYLE_TABLE, i), title)
                    end
                end
                if key == "color_preset" then
                    local list = firstOf(g, "Combo")
                    if list ~= nil then
                        f = f or iconSize(box)
                        list.ItemWidth = LIST_ICONS * f
                    end
                    local last = lastChild(g)
                    if last ~= nil and kind(last) == "Dummy" then
                        g:DetachChild(last)
                        childById(box, ID .. "_Stash_" .. s.tier):AttachChild(last)
                    end
                end
            end
        end
        if sec ~= nil then sec.Visible = false end
        if ti > 1 then
            local d = spacerBefore(sec)
            if d ~= nil then d.Visible = false end
        end
    end

    -- the Placement section (and the spacer before it) after PaG's group, so it shows under the tables
    local after = sectionOf(AFTER)
    if after ~= nil and indexOf(tab, after) < indexOf(tab, box) then
        local d = spacerBefore(after)
        if d ~= nil then
            tab:DetachChild(d)
            tab:AttachChild(d)
        end
        tab:DetachChild(after)
        tab:AttachChild(after)
    end
    box.Visible = true
    return missing
end

-- back to MCM's layout: each group returns to its section in the blueprint's order, then PaG's group
-- is hidden. Placement stays after that hidden group, which is where MCM put it
local function putBack()
    local box = childById(tab, ID)
    if box == nil or not box.Visible then return end
    for ti, s in ipairs(TIERS) do
        local sec = sectionOf(s.section)
        if sec ~= nil then
            for i, key in ipairs(LOOKS) do
                local cell = cellOf(box, GRID, ti, i)
                local g, from = findGroup(s.tier, key, { sec, cell })
                if g ~= nil then
                    from:DetachChild(g)
                    sec:AttachChild(g)
                    local text = firstOf(g, "Text")
                    if text ~= nil then text.Visible = true end
                    local last = lastChild(g)
                    if last ~= nil and kind(last) == "Dummy" then last.Visible = true end
                end
            end
            for i, key in ipairs(STYLE) do
                local cell = cellOf(box, STYLE_TABLE, ti, i)
                local g, from = findGroup(s.tier, key, { sec, cell })
                if g ~= nil then
                    from:DetachChild(g)
                    sec:AttachChild(g)
                    local title = firstOf(g, "Text")
                    if title ~= nil then title.Visible = true end
                    if key == "color_preset" then
                        local list = firstOf(g, "Combo")
                        if list ~= nil then list.ItemWidth = nil end
                        local stash = childById(box, ID .. "_Stash_" .. s.tier)
                        for _, d in ipairs(stash and stash.Children or {}) do
                            stash:DetachChild(d)
                            g:AttachChild(d)
                        end
                    end
                end
            end
            sec.Visible = true
            if ti > 1 then
                local d = spacerBefore(sec)
                if d ~= nil then d.Visible = true end
            end
        end
    end
    box.Visible = false
end

-- a row's settings: the family's radio, its checkboxes, and for AC the shield badge (Settings.lua SPEC)
local function rowKeys(r)
    for _, fam in ipairs(PaG.Settings.FAMILIES) do
        if fam.key == r.family then
            local keys = { fam.key }
            for _, c in ipairs(fam.causes) do
                if c.key ~= nil then keys[#keys + 1] = c.key end
            end
            if fam.ac then keys[#keys + 1] = "ac_shield_badge" end
            return keys
        end
    end
    return { r.family }
end

-- the reset icon's size, read from the first Mark as reset button that has an image, while the
-- sections still hold them
local function rowIconSize(rows)
    for _, r in ipairs(rows) do
        local sec = sectionOf(r.section)
        local g = sec and findSetting(r.family, { sec })
        local btn = g and childById(g, ModuleUUID .. "_ResetButton_" .. r.family)
        local size = U.Field(U.Field(btn, "Image"), "Size")
        local w = type(size) == "table" and tonumber(size[1]) or nil
        if w ~= nil and w > 0 then return w end
    end
    return ICON
end

-- a penalty tab's group: one table, then a hidden group per setting where its spacer waits. The
-- table's last row is a strut, as in the Looks grid, so a Mark as reset button that comes and goes
-- doesn't move the columns; the causes' column takes the rest of the width
local function buildRows(tid, rows)
    local id = ROWS_ID .. tid
    local f = rowIconSize(rows)
    local box = tab:AddGroup(id)
    box.IDContext = id
    box.TextWrapPos = -1 -- as in the Looks grid: the tab's 0 would wrap the section names
    local tbl = addTable(box, id .. "_Table", 3, true)
    tbl.RowBg = true
    tbl:SetColor("TableRowBg", ROW_BG)
    tbl:SetColor("TableRowBgAlt", ROW_BG_ALT)
    tbl:SetStyle("CellPadding", 6, 6)
    for _, r in ipairs(rows) do
        local row = addRow(tbl, id .. "_" .. r.section, 3)
        addTierLabel(nth(row, 1), id .. "_" .. r.section .. "_Name")
        for _, key in ipairs(rowKeys(r)) do
            local stash = box:AddGroup(id .. "_Stash_" .. key)
            stash.IDContext = id .. "_Stash_" .. key
            stash.Visible = false
        end
    end
    local struts = addRow(tbl, id .. "_Struts", 3)
    struts:SetColor("TableRowBg", { 0, 0, 0, 0 })
    struts:SetColor("TableRowBgAlt", { 0, 0, 0, 0 })
    nth(struts, 2):AddDummy(ROW_ICONS * f + ROW_EXTRA, 0)
    return box
end

local function layOutRows(tid, rows)
    local id = ROWS_ID .. tid
    local box = childById(tab, id) or buildRows(tid, rows)
    box.Visible = true -- before anything moves, as in layOut
    local tbl = childById(box, id .. "_Table")
    local missing = nil
    for ri, r in ipairs(rows) do
        local sec = sectionOf(r.section)
        local row = nth(tbl, ri)
        local label = childById(nth(row, 1), id .. "_" .. r.section .. "_Name")
        copyText(label and childById(label, label.IDContext .. "_Text"), sec and firstOf(sec, "SeparatorText"))
        for ki, key in ipairs(rowKeys(r)) do
            local cell = nth(row, ki == 1 and 2 or 3)
            local g, from = findSetting(key, sec and { sec, cell } or { cell })
            if g == nil then
                missing = missing or {}
                missing[#missing + 1] = key
            else
                move(g, from, cell)
                if ki == 1 then
                    local title = firstOf(g, "Text")
                    if title ~= nil then title.Visible = false end
                end
                local last = lastChild(g)
                if last ~= nil and kind(last) == "Dummy" then
                    g:DetachChild(last)
                    childById(box, id .. "_Stash_" .. key):AttachChild(last)
                end
            end
        end
        if sec ~= nil then
            sec.Visible = false
            local d = spacerBefore(sec)
            if d ~= nil then d.Visible = false end
        end
    end
    return missing
end

local function putBackRows(tid, rows)
    local id = ROWS_ID .. tid
    local box = childById(tab, id)
    if box == nil or not box.Visible then return end
    local tbl = childById(box, id .. "_Table")
    for ri, r in ipairs(rows) do
        local sec = sectionOf(r.section)
        if sec ~= nil then
            local row = nth(tbl, ri)
            for ki, key in ipairs(rowKeys(r)) do
                local g, from = findSetting(key, { sec, nth(row, ki == 1 and 2 or 3) })
                if g ~= nil then
                    from:DetachChild(g)
                    sec:AttachChild(g)
                    if ki == 1 then
                        local title = firstOf(g, "Text")
                        if title ~= nil then title.Visible = true end
                    end
                    local stash = childById(box, id .. "_Stash_" .. key)
                    local held = {}
                    for _, d in ipairs(stash and stash.Children or {}) do held[#held + 1] = d end
                    for _, d in ipairs(held) do
                        stash:DetachChild(d)
                        g:AttachChild(d)
                    end
                end
            end
            sec.Visible = true
            local d = spacerBefore(sec)
            if d ~= nil then d.Visible = true end
        end
    end
    box.Visible = false
end

local function rowsOf(tid)
    for _, t in ipairs(ROW_TABS) do
        if t.tab == tid then return t.rows end
    end
    return nil
end

-- one tab's pass, the layout on or off as live says
local function apply(tid)
    tab = tabs[tid]
    if tab == nil then return end
    local rows = rowsOf(tid)
    if not live then
        if rows then return putBackRows(tid, rows) end
        return putBack()
    end
    local missing
    if rows then missing = layOutRows(tid, rows) else missing = layOut() end
    if missing ~= nil then
        L.WarnOnce("layout.missing." .. tid, "the " .. tid .. " tab's layout did not find these settings, "
            .. "which stay where MCM put them", { missing = missing })
    end
end

local function applyAll()
    U.Try("layout.apply", apply, TAB)
    for _, t in ipairs(ROW_TABS) do U.Try("layout.apply", apply, t.tab) end
end

-- MCM's custom-tab pass (IMGUIHelpers.ApplyCustomTabStyles, MCM 1.41): which elements it gives a
-- text color when none is set, and which it walks into. Kept the same, so the pin below sets a color
-- on exactly the elements that pass would
local STYLED = {
    Text = true, TextLink = true, BulletText = true, Button = true, RadioButton = true,
    Selectable = true, CollapsingHeader = true, SeparatorText = true, TabItem = true,
    Checkbox = true, Combo = true, InputText = true, InputInt = true, InputScalar = true,
    DragInt = true, DragScalar = true, SliderInt = true, SliderScalar = true, ColorEdit = true,
    ColorPicker = true,
}
local PARENTS = {
    Window = true, ChildWindow = true, Group = true, CollapsingHeader = true, TabBar = true,
    TabItem = true, Tree = true, Table = true, TableRow = true, TableCell = true, Popup = true,
    MenuBar = true, Menu = true, Tooltip = true,
}

-- each element of the tab that pass would color gets the color it draws with now: its nearest
-- colored ancestor's. Hidden elements too, since the pass walks them
local function pin()
    local inherited = nil
    local p = U.Field(tab, "ParentElement")
    for _ = 1, 64 do
        if p == nil then break end
        inherited = p:GetColor("Text")
        if inherited ~= nil then break end
        p = U.Field(p, "ParentElement")
    end
    if inherited == nil then
        L.WarnOnce("layout.no_color", "found no text color above a PaG tab: MCM may recolor its text")
        return
    end
    local function walk(el, inh)
        local ty = kind(el) or ""
        local own = el:GetColor("Text")
        if own == nil and STYLED[ty] then
            el:SetColor("Text", inh)
            own = inh
        end
        if PARENTS[ty] then
            for _, c in ipairs(el.Children) do walk(c, own or inh) end
        end
    end
    walk(tab, inherited)
end

-- MCM's callback for one tab id. MCM may run it again, with the same tab or a new one, so the tab is
-- checked afresh. One closure per tab: MCM drops a callback it already holds (IMGUIAPI.lua:44-48)
local function onTab(tid)
    return function(t)
        tabs[tid] = t
        U.Try("layout.apply", apply, tid)
        tab = t
        U.Try("layout.pin", pin)
    end
end

-- MCM's public tab call, MCM.InsertModMenuTab. MCM injects MCM into mods that load after it, and
-- Mods.BG3MCM carries the same call for the rest (TableInjector.lua), as in Settings.lua. Its
-- modUUID defaults to the mod it was made for, which for Mods.BG3MCM is MCM, so PaG passes its own.
-- Not Mods.BG3MCM.IMGUIAPI, which some mods use: MCM calls that internal and prints a warning naming
-- the mod (InternalAPIGuard.lua). True once asked: MCM calls back when its window is built. Without
-- MCM there is no menu to lay out
local function register()
    local insert = U.Field(MCM, "InsertModMenuTab")
    if type(insert) ~= "function" then insert = U.Field(U.Field(Mods, "BG3MCM"), "InsertModMenuTab") end
    if type(insert) ~= "function" then
        if U.Field(Mods, "BG3MCM") ~= nil then
            L.WarnOnce("layout.no_api", "MCM has no InsertModMenuTab: PaG's tabs keep MCM's layout")
        end
        return false
    end
    insert(TAB, onTab(TAB), ModuleUUID, true)
    for _, t in ipairs(ROW_TABS) do insert(t.tab, onTab(t.tab), ModuleUUID, true) end
    return true
end

-- the main menu is shown or a world is loaded, on v33 with PaG's UI on (_Init)
function Y.Start()
    live = true
    if not registered then registered = register() end
    applyAll()
end

-- v32, or the inert crash test (_Init): the tabs go back to MCM's layout
function Y.Stop()
    live = false
    applyAll()
end
