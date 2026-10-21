--- Layouts, realised by Neovim's own window manager (§E4).
---
--- The server sends the logical layout of a session's current mode — rows and
--- columns with relative weights, stacks with an active child, leaves naming a
--- pane. A session is a tab page; its windows are built from that tree, the
--- `editor` leaf becoming the source window. The user's resizes and closed
--- panes go back to the server (`layout/edited`), which records them in that
--- mode's layout, so a return to the mode restores them.
local state = require("codetracer.state")
local rpc = require("codetracer.rpc")
local panes = require("codetracer.panes")

local M = {}

--- Whether `name` is a pane this server draws (or the source window).
local function drawable(name)
  if name == "editor" then
    return true
  end
  -- A role ceded to the editor (§E8) is not CodeTracer's pane any more.
  if name == "fileTree" and require("codetracer.files").ceded() then
    return false
  end
  local info = state.conn and state.conn.info
  local list = info and info.capabilities and info.capabilities.panes or {}
  return vim.tbl_contains(list, name)
end

--- The tree without what cannot be shown: panes this server does not draw,
--- and containers left empty by their removal. A stack keeps its drawable
--- children and an active one among them.
local function prune(node)
  if node == nil then
    return nil
  end
  if node.kind == "pane" then
    return drawable(node.pane) and node or nil
  end
  local kids = {}
  local active = nil
  for i, child in ipairs(node.children or {}) do
    local p = prune(child)
    if p then
      kids[#kids + 1] = p
      if node.activeIndex and node.activeIndex == i - 1 then
        active = #kids
      end
    end
  end
  if #kids == 0 then
    return nil
  end
  local out = vim.deepcopy(node)
  out.children = kids
  if node.kind == "stack" then
    out.active = active or 1
  elseif #kids == 1 then
    -- A row or column of one is that one, at the container's weight.
    local only = vim.deepcopy(kids[1])
    only.weight = node.weight
    return only
  end
  return out
end
M.prune = prune

--- The pane a leaf or stack shows.
local function shown_pane(node)
  if node.kind == "pane" then
    return node.pane
  end
  if node.kind == "stack" then
    return shown_pane(node.children[node.active])
  end
  return nil
end
M.shown_pane = shown_pane

local function stack_winbar(node)
  local parts = {}
  for i, child in ipairs(node.children) do
    local name = child.kind == "pane" and child.pane or child.kind
    local group = i == node.active and "CodeTracerStackTabActive" or "CodeTracerStackTab"
    parts[#parts + 1] = ("%%#%s# %s %%*"):format(group, name)
  end
  return table.concat(parts, "")
end

local function show_leaf(session, node, win, parent_kind)
  local name = shown_pane(node)
  local info = { pane = name, parent = parent_kind, node = node }
  if name == "editor" then
    session.editor_win = win
    local buf = session.source_buf
    if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
      buf = vim.api.nvim_create_buf(true, false)
      session.source_buf = buf
    end
    vim.api.nvim_win_set_buf(win, buf)
  else
    local pane = state.pane(session, name)
    local buf = panes.ensure_buf(session, pane)
    vim.api.nvim_win_set_buf(win, buf)
    panes.style_window(win)
    if node.kind == "stack" and #node.children > 1 then
      vim.wo[win].winbar = stack_winbar(node)
    else
      vim.wo[win].winbar = ""
    end
  end
  session.windows[win] = info
end

--- Each child's share of `total` cells, by weight; the rounding remainder
--- goes to the last.
local function shares(node, total)
  local weights = 0
  for _, c in ipairs(node.children) do
    weights = weights + math.max(c.weight or 1, 0.0001)
  end
  local out, used = {}, 0
  for i, c in ipairs(node.children) do
    if i == #node.children then
      out[i] = math.max(1, total - used)
    else
      out[i] = math.max(1, math.floor(total * math.max(c.weight or 1, 0.0001) / weights + 0.5))
      used = used + out[i]
    end
  end
  return out
end

--- Build `node` into `win`, which it owns, splitting it for containers.
local function build(session, node, win, parent_kind)
  if node.kind == "pane" or node.kind == "stack" then
    node.win = win
    show_leaf(session, node, win, parent_kind)
    return
  end
  local wins = { win }
  local prev = win
  for i = 2, #node.children do
    wins[i] = vim.api.nvim_open_win(
      vim.api.nvim_win_get_buf(win),
      false,
      { split = node.kind == "row" and "right" or "below", win = prev }
    )
    prev = wins[i]
  end
  for i, child in ipairs(node.children) do
    build(session, child, wins[i], node.kind)
  end
end

--- The windows a subtree became.
local function leaves(node, out)
  out = out or {}
  if node.win then
    out[#out + 1] = node.win
  end
  for _, c in ipairs(node.children or {}) do
    if node.kind ~= "stack" then
      leaves(c, out)
    end
  end
  return out
end

--- A window whose resizing resizes the whole of `node` along `axis`: Vim
--- applies a width change to the frame just below the window's nearest row
--- ancestor (a height change, column), so the window must be reached from
--- `node` without passing through a container of that same kind.
local function handle(node, kind)
  if node.win then
    return node.win
  end
  if node.kind == kind then
    return nil
  end
  for _, c in ipairs(node.children or {}) do
    local w = handle(c, kind)
    if w then
      return w
    end
  end
  return nil
end

--- How many cells `node` spans along its parent's axis.
local function extent(node, horizontal)
  local lo, hi = math.huge, -math.huge
  for _, w in ipairs(leaves(node)) do
    local pos = vim.api.nvim_win_get_position(w)
    local start = horizontal and pos[2] or pos[1]
    local len = horizontal and vim.api.nvim_win_get_width(w) or vim.api.nvim_win_get_height(w)
    lo = math.min(lo, start)
    hi = math.max(hi, start + len)
  end
  return hi > lo and (hi - lo) or 0
end

--- Give each container's children their shares of the space, top-down.
local function size(node)
  if node.kind ~= "row" and node.kind ~= "column" then
    return
  end
  local horizontal = node.kind == "row"
  local n = #node.children
  local total = 0
  for _, c in ipairs(node.children) do
    total = total + extent(c, horizontal)
  end
  local cells = shares(node, total)
  for i = 1, n - 1 do
    local w = handle(node.children[i], node.kind)
    if w then
      if horizontal then
        vim.api.nvim_win_set_width(w, cells[i])
      else
        vim.api.nvim_win_set_height(w, cells[i])
      end
    end
  end
  for _, c in ipairs(node.children) do
    size(c)
  end
end

--- The windows of `tab` this plugin did not make: windows the user opened
--- beside ours. Their buffers are shown again after a rebuild.
local function foreign_buffers(session)
  local out = {}
  -- Only a rebuild has the user's windows to keep: a new tab page's own
  -- first window is not one.
  if session.realised == nil or session.tab == nil or not vim.api.nvim_tabpage_is_valid(session.tab) then
    return out
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
    if session.windows[win] == nil and vim.api.nvim_win_get_config(win).relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local empty = vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
      if not empty and not state.pane_of_buf(buf) then
        out[#out + 1] = buf
      end
    end
  end
  return out
end

--- Record every window's size, so a later difference is the user's.
local function remember_sizes(session)
  session.expected_sizes = {}
  for win in pairs(session.windows) do
    if vim.api.nvim_win_is_valid(win) then
      session.expected_sizes[win] = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
    end
  end
end

--- Make the session's tab page show `layout`. Panes no longer shown are
--- closed; the shown ones are opened or resized at their window's size.
function M.realise(session, layout)
  session.layout = layout
  local tree = prune(layout)
  if tree == nil then
    return
  end

  local previous_tab = vim.api.nvim_get_current_tabpage()
  local previous_win = vim.api.nvim_get_current_win()
  if session.tab == nil or not vim.api.nvim_tabpage_is_valid(session.tab) then
    vim.cmd("tabnew")
    session.tab = vim.api.nvim_get_current_tabpage()
    vim.t[session.tab].codetracer_session = session.id
  else
    vim.api.nvim_set_current_tabpage(session.tab)
  end

  local keep = foreign_buffers(session)
  session.realised = tree
  local before = {}
  for _, info in pairs(session.windows or {}) do
    if info.pane and info.pane ~= "editor" then
      before[info.pane] = true
    end
  end

  -- 'equalalways' is left alone: turning it back on equalises every window,
  -- which would undo the sizes set below.
  session.realising = true

  -- One window, then the tree out of it.
  local root = vim.api.nvim_tabpage_get_win(session.tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
    if win ~= root and vim.api.nvim_win_get_config(win).relative == "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  session.windows = {}
  session.editor_win = nil
  build(session, tree, root, nil)
  size(tree)

  -- The user's own windows come back beside the source window.
  if session.editor_win then
    for _, buf in ipairs(keep) do
      if vim.api.nvim_buf_is_valid(buf) and buf ~= session.source_buf then
        vim.api.nvim_open_win(buf, false, { split = "right", win = session.editor_win })
      end
    end
  end

  session.realising = false
  remember_sizes(session)

  -- Pane lifecycle: open or resize what is shown, close what is gone.
  local now = {}
  for win, info in pairs(session.windows) do
    if info.pane ~= "editor" then
      now[info.pane] = true
      panes.report_size(session, state.pane(session, info.pane), win)
    end
  end
  for name in pairs(before) do
    if not now[name] then
      panes.close(session, state.pane(session, name))
    end
  end

  if session.editor_win and vim.api.nvim_win_is_valid(session.editor_win) then
    vim.api.nvim_set_current_win(session.editor_win)
  end
  if previous_tab ~= session.tab and vim.api.nvim_tabpage_is_valid(previous_tab) and session.keep_focus then
    vim.api.nvim_set_current_tabpage(previous_tab)
    if vim.api.nvim_win_is_valid(previous_win) then
      vim.api.nvim_set_current_win(previous_win)
    end
  end
  -- The frame viewer is not a layout pane; it comes back where it was.
  if session.frames_open then
    session.frames_win = nil
    require("codetracer.images").open_frames(session)
  end
  require("codetracer.source").refresh(session)
end

-- ---------------------------------------------------------------------------
-- The user's edits
-- ---------------------------------------------------------------------------

--- The weights the realised tree's leaves now have, in the units their
--- siblings' weights were in: each container's children share its total
--- weight in proportion to the cells they now occupy.
local function measured_weights(node, out)
  if node.kind ~= "row" and node.kind ~= "column" then
    return out
  end
  local horizontal = node.kind == "row"
  local cells, total_cells, total_weight = {}, 0, 0
  for i, c in ipairs(node.children) do
    -- The whole subtree's span, not its first window's: a nested container
    -- is as wide as all of its windows together.
    local n = extent(c, horizontal)
    cells[i] = n
    total_cells = total_cells + n
    total_weight = total_weight + (c.weight or 1)
  end
  for i, c in ipairs(node.children) do
    local name = shown_pane(c)
    if name and total_cells > 0 then
      out[name] = cells[i] * total_weight / total_cells
    end
    measured_weights(c, out)
  end
  return out
end

--- Report the user's resizes, if the window sizes differ from what was
--- built or last reported, and the panes' new sizes.
function M.check_sizes(session)
  if session.realising or session.realised == nil then
    return
  end
  local changed = false
  for win, info in pairs(session.windows) do
    if vim.api.nvim_win_is_valid(win) then
      local w, h = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
      local e = session.expected_sizes[win]
      if e == nil or e[1] ~= w or e[2] ~= h then
        changed = true
        if info.pane ~= "editor" then
          panes.report_size(session, state.pane(session, info.pane), win)
        end
      end
    end
  end
  local fw = session.frames_win
  if fw and vim.api.nvim_win_is_valid(fw) and session.panes.frameViewer then
    panes.report_size(session, session.panes.frameViewer, fw)
  end
  if not changed then
    return
  end
  remember_sizes(session)
  M.report_edit(session, measured_weights(session.realised, {}), {})
end

function M.report_edit(session, sizes, closed)
  rpc.request(state.conn, "layout/edited", {
    session = session.id,
    mode = session.mode,
    sizes = next(sizes) and sizes or vim.empty_dict(),
    closed = closed,
  }, function(err, result)
    if not err and result and result.layout then
      session.layout = result.layout
    end
  end)
end

--- A window of the session closed. A pane the user closed is recorded as
--- closed in the mode's layout; a rebuild's own closings are not edits.
function M.window_closed(session, win)
  local info = session.windows[win]
  if info == nil or session.realising then
    return
  end
  session.windows[win] = nil
  if info.pane == "editor" then
    session.editor_win = nil
    return
  end
  panes.close(session, state.pane(session, info.pane))
  M.report_edit(session, vim.empty_dict(), { info.pane })
end

--- Show the next child of the stack the current window shows.
function M.stack_next(session, win, delta)
  local info = session.windows[win]
  if info == nil or info.node.kind ~= "stack" then
    return
  end
  local node = info.node
  local before = shown_pane(node)
  node.active = (node.active - 1 + (delta or 1)) % #node.children + 1
  panes.close(session, state.pane(session, before))
  session.realising = true
  show_leaf(session, node, win, info.parent)
  session.realising = false
  local name = shown_pane(node)
  if name ~= "editor" then
    panes.report_size(session, state.pane(session, name), win)
  end
end

--- The weights the realised tree's leaves now have (`layout/edited`'s
--- `sizes`).
function M.measured(tree)
  return measured_weights(tree, {})
end

return M
