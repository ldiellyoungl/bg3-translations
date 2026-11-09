-- Pure-data panel host, pin and verify-node planning. No Noesis access: Hub builds and copies plans
-- on Tick, and copies list paths in the mark callback too.
local Plan = {}
PaG.PanelPlan = Plan

local function slice(t, i, j)
    local out = {}
    for k = i, j do out[#out + 1] = t[k] end
    return out
end

-- the depth on a slot's path of the node named for its slot (slotProps); nil when none is
local function propDepth(cell, slotProps)
    for d = #cell.names, 1, -1 do
        if slotProps[cell.names[d]] ~= nil then return d end
    end
    return nil
end

-- hosts, pins and the nodes a verify checks, from a panel's cells. A cell's path, with its index at
-- depth k replaced by *, names a group; a group of two or more cells makes the node at depth k-1 a
-- host, whose children all lead to a cell root along the same suffix. Each cell joins its largest
-- group (the deeper on a tie); a cell in no group is a pin, followed by its full path. The nodes
-- are the hosts and every node above a host or a pin: a verify checks their names, and their child
-- counts except at hosts (a host's children come and go with the items it shows). A slot host's
-- propStep is where, along a child and its suffix (0: the child), the node named for its slot is;
-- a slot pin's propDepth is that node's depth on its path. A slot whose name is above its host's
-- children, or nowhere on its path, has none and shows no mark. A doll names each slot once, so
-- two of a host's slots with one name are two dolls': that host spansDolls, and its slots get no
-- wearer (wearerOf), since one wearer read above them would judge every doll's slots alike
--
-- each distinct path prefix is joined once, in a trie keyed by child index: joining every prefix
-- of every cell afresh is cells x depth^2 joins. A cell's pre[d] is its path joined through depth
-- d as table.concat joins it ("" at 0), the key of p.counts and of a node's pstr
function Plan.Build(p, hostSpan, slotProps)
    local trie = { pstr = "" }
    local groups, keysOf, presOf = {}, {}, {}
    for ci, cell in ipairs(p.cells) do
        local path, m = cell.path, #cell.path
        local pre, t = { [0] = "" }, trie
        for d = 1, m do
            local kid = t[path[d]]
            if kid == nil then
                kid = { pstr = d == 1 and tostring(path[1]) or t.pstr .. "." .. path[d] }
                t[path[d]] = kid
            end
            pre[d], t = kid.pstr, kid
        end
        -- a group's key: the kind, the path above depth k, and the path below it (suf, built
        -- from the cell's end)
        local ks, suf = {}, ""
        for k = m, math.max(1, m - hostSpan + 1), -1 do
            local g = cell.kind .. "|" .. pre[k - 1] .. "|" .. suf
            ks[k] = g
            local e = groups[g]
            if e == nil then e = { n = 0, k = k }; groups[g] = e end
            e.n = e.n + 1
            suf = suf == "" and tostring(path[k]) or path[k] .. "." .. suf
        end
        keysOf[ci], presOf[ci] = ks, pre
    end
    local hosts, hostBy, pins, nodes = {}, {}, {}, {}
    local function addNode(cell, pre, upto, isHost)
        local pstr = pre[upto]
        local nd = nodes[pstr]
        if nd == nil then
            nd = { path = slice(cell.path, 1, upto), pstr = pstr,
                   name = upto == 0 and p.name or cell.names[upto],
                   count = p.counts[pstr] or cell.counts[upto + 1], host = false }
            nodes[pstr] = nd
        end
        if isHost then nd.host = true end
    end
    for ci, cell in ipairs(p.cells) do
        local m = #cell.path
        local best, bestG = nil, nil
        for k = math.max(1, m - hostSpan + 1), m do
            local g = keysOf[ci][k]
            local e = groups[g]
            if e.n >= 2 and (best == nil or e.n > best.n or (e.n == best.n and e.k > best.k)) then
                best, bestG = e, g
            end
        end
        if best ~= nil then
            local k = best.k
            local h = hostBy[bestG]
            if h == nil then
                h = { kind = cell.kind, rootName = cell.names[m], path = slice(cell.path, 1, k - 1),
                      name = k == 1 and p.name or cell.names[k - 1],
                      suffix = slice(cell.path, k + 1, m), missed = {}, lastN = nil }
                hostBy[bestG] = h
                hosts[#hosts + 1] = h
            end
            if cell.kind == "slot" then
                local d = propDepth(cell, slotProps)
                if d ~= nil and d >= k then
                    h.propStep = h.propStep or (d - k)
                    local nm = cell.names[d]
                    h.props = h.props or {}
                    if h.props[nm] then h.spansDolls = true end
                    h.props[nm] = true
                end
            end
            for d = 0, k - 1 do addNode(cell, presOf[ci], d, d == k - 1) end
        else
            pins[#pins + 1] = { kind = cell.kind, rootName = cell.names[m], path = cell.path,
                                propDepth = cell.kind == "slot" and propDepth(cell, slotProps) or nil }
            for d = 0, m - 1 do addNode(cell, presOf[ci], d, false) end
        end
    end
    local list = {}
    for _, nd in pairs(nodes) do list[#list + 1] = nd end
    table.sort(list, function(a, b)
        if #a.path ~= #b.path then return #a.path < #b.path end
        return a.pstr < b.pstr
    end)
    p.hosts, p.pins, p.nodeList = hosts, pins, list
end

local function shallow(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- a panel's own copy of a kept plan. Polls and verifies write to its hosts, pins and nodes (lastN,
-- missed, wd, wdAt, logged, count), so each panel gets fresh ones, as Build gives it. Paths,
-- suffixes and props are never written after Build and are shared, as a pin already shares
-- its cell's path
function Plan.Copy(plan)
    local hosts, pins, list = {}, {}, {}
    for i, h in ipairs(plan.hosts) do
        hosts[i] = shallow(h)
        hosts[i].missed = {}
    end
    for i, pin in ipairs(plan.pins) do pins[i] = shallow(pin) end
    for i, nd in ipairs(plan.nodeList) do list[i] = shallow(nd) end
    return hosts, pins, list
end

-- a panel's own copy of kept lists (p.lists); paths are shared, as in Copy
function Plan.CopyLists(lists)
    local out = {}
    for i, e in ipairs(lists) do out[i] = { path = e.path, pstr = e.pstr, name = e.name } end
    return out
end
