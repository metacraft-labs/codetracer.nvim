--- Integration tests: the plugin against a real pane server over a real
--- recording, in `nvim --headless`. Nothing is mocked — the server is
--- `codetracer-tui --pane-server` ($CODETRACER_TUI) and the recording is
--- $CODETRACER_TEST_TRACE (CodeTracer's `calc` test program). Both are
--- required: without them the suite fails rather than skips, because a suite
--- that skipped would pass with no server at all.
---
--- Run: just test-integration (see the Justfile for the variables), or
--- nvim --headless --clean -u NONE -c "luafile tests/integration_spec.lua".
vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60

local t = require("harness")

local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_TRACE
if server == nil or vim.fn.executable(server) ~= 1 or trace == nil or vim.fn.isdirectory(trace) ~= 1 then
  io.stdout:write("integration tests need $CODETRACER_TUI (the codetracer-tui binary) and\n")
  io.stdout:write("$CODETRACER_TEST_TRACE (a recording's folder); got " .. vim.inspect({ server, trace }) .. "\n")
  vim.cmd("cquit 2")
end

local user_down = 0
local ct = require("codetracer")
ct.setup({
  cmd = { server, "--pane-server" },
  mappings = {
    -- The user's own binding for a key CodeTracer's keymap binds in the call
    -- trace (Down → list.focus-next): theirs wins (§E6).
    calltrace = {
      ["<Down>"] = function()
        user_down = user_down + 1
      end,
    },
  },
})
local state = require("codetracer.state")
local layout = require("codetracer.layout")

--- Open the recording; the session once its call trace has content.
local function open_session()
  local s
  ct.open(trace, function(x)
    s = x
  end)
  t.wait_for(function()
    if not (s and s.position) then
      return false
    end
    -- Every shown pane holds a window's worth of rows.
    for win, info in pairs(s.windows) do
      if info.pane ~= "editor" then
        local p = s.panes[info.pane]
        if p.buf == nil or vim.api.nvim_buf_line_count(p.buf) ~= vim.api.nvim_win_get_height(win) then
          return false
        end
      end
    end
    return s.panes.calltrace and s.panes.calltrace.rows[0] ~= nil
  end, 60000, "the session's panes and position")
  return s
end

--- The panes the session's tab page shows, sorted.
local function shown(session)
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
    local info = session.windows[win]
    if info then
      out[#out + 1] = info.pane
    end
  end
  table.sort(out)
  return out
end

--- The panes `layout` shows, as the plugin realises it, sorted.
local function expected(lay)
  local out = {}
  local function walk(node)
    if node.kind == "pane" or node.kind == "stack" then
      out[#out + 1] = layout.shown_pane(node)
      return
    end
    for _, c in ipairs(node.children) do
      walk(c)
    end
  end
  walk(layout.prune(lay))
  table.sort(out)
  return out
end

local function window_of(session, pane)
  for win, info in pairs(session.windows) do
    if info.pane == pane and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  return nil
end

--- Toggle the session's product mode and wait for the new layout.
local function toggle_mode(session)
  local before = session.mode
  vim.api.nvim_set_current_tabpage(session.tab)
  ct.run("session.toggle-product-mode", nil, session)
  return t.wait_for(function()
    return session.mode ~= before and not session.realising
  end, 30000, "the mode to change from " .. before)
end

local function pane_text(session, pane)
  local p = session.panes[pane]
  local lines = {}
  for i = 0, (p and p.height or 0) - 1 do
    lines[#lines + 1] = p.rows[i] and p.rows[i].text or ""
  end
  return table.concat(lines, "\n")
end

local first

t.case("a session opens as a tab page laid out like the debug mode", function()
  first = open_session()
  t.check(first ~= nil, "a session")
  t.eq(first.mode, "debug", "the opening mode")
  t.eq(vim.api.nvim_get_current_tabpage(), first.tab, "its tab page is shown")
  t.eq(shown(first), expected(first.layout), "the windows are the debug layout's panes")
  t.check(vim.tbl_contains(shown(first), "editor"), "a source window")
  local src = vim.api.nvim_win_get_buf(first.editor_win)
  t.check(vim.api.nvim_buf_get_name(src):match("main%.py$") ~= nil, "the source window shows the stopped-in file")
  -- Each pane buffer holds exactly its window's rows.
  for _, name in ipairs({ "calltrace", "state", "eventLog" }) do
    local win = window_of(first, name)
    local p = first.panes[name]
    t.check(win ~= nil, name .. " has a window")
    if win then
      t.eq(vim.api.nvim_buf_line_count(p.buf), vim.api.nvim_win_get_height(win), name .. ": one row per window line")
      t.eq(p.width, vim.api.nvim_win_get_width(win), name .. ": painted at the window's width")
    end
  end
  -- Spans became highlight groups named after the semantic styles.
  local marks = vim.api.nvim_buf_get_extmarks(first.panes.calltrace.buf, -1, 0, -1, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do
    if m[4].hl_group then
      groups[m[4].hl_group] = true
    end
  end
  t.check(next(groups) ~= nil, "styled spans")
  for g in pairs(groups) do
    t.check(g:match("^CodeTracer") ~= nil, "group " .. g .. " is a CodeTracer group")
  end
end)

t.case("a mode change re-arranges the tab page; returning restores the debug layout", function()
  local debug_panes = shown(first)
  t.check(toggle_mode(first), "switched")
  t.eq(first.mode, "edit", "now editing")
  t.eq(shown(first), expected(first.layout), "the windows are the edit layout's panes")
  t.check(not vim.deep_equal(shown(first), debug_panes), "the edit layout differs from the debug one")
  t.check(toggle_mode(first), "switched back")
  t.eq(first.mode, "debug", "debugging again")
  t.eq(shown(first), debug_panes, "the debug layout's panes again")
end)

t.case("a step moves the position and updates the panes", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  local tick = first.position.tick
  local line = first.position.line
  local state_before = pane_text(first, "state")
  ct.run("step-over", nil, first)
  t.wait_for(function()
    return first.position.tick ~= tick
  end, 30000, "the position to move")
  t.check(first.position.line ~= line or first.position.tick ~= tick, "a new position")
  t.wait_for(function()
    return pane_text(first, "state") ~= state_before
  end, 15000, "the state pane to show the new stop")
  -- The execution line is marked where the position now is.
  local src = vim.api.nvim_win_get_buf(first.editor_win)
  local ns = require("codetracer.source").position_namespace
  local marks = vim.api.nvim_buf_get_extmarks(src, ns, 0, -1, { details = true })
  t.eq(#marks, 1, "one execution mark")
  if marks[1] then
    t.eq(marks[1][2] + 1, first.position.line, "on the position's line")
  end
  t.eq(vim.api.nvim_win_get_cursor(first.editor_win)[1], first.position.line, "the cursor follows")
end)

t.case("a file CodeTracer's file pane opens is shown in the source window", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  local tree = first.panes.fileTree
  local open
  for i = 0, tree.height - 1 do
    for _, h in ipairs((tree.rows[i] or {}).hotspots or {}) do
      if h.operation == "file-tree.open" then
        open = h
      end
    end
  end
  t.check(open ~= nil, "the file pane offers a file to open")
  if open == nil then
    return
  end
  -- The source window shows something else first.
  local other = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(first.editor_win, other)
  -- The row's own hotspot, as <CR> on it runs it.
  local win = window_of(first, "fileTree")
  vim.api.nvim_set_current_win(win)
  for i = 0, tree.height - 1 do
    for _, h in ipairs((tree.rows[i] or {}).hotspots or {}) do
      if h == open then
        vim.api.nvim_win_set_cursor(win, { i + 1, h.start })
      end
    end
  end
  require("codetracer.panes").activate(tree.buf, false)
  t.wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first.editor_win)) == open.args.path
  end, 15000, "source/show to put " .. open.args.path .. " in the source window")
  vim.api.nvim_buf_delete(other, { force = true })
end)

t.case("resizing a pane's window changes the window the server paints", function()
  local win = window_of(first, "calltrace")
  local p = first.panes.calltrace
  local h = vim.api.nvim_win_get_height(win)
  vim.api.nvim_win_set_height(win, h - 6)
  t.wait_for(function()
    return p.height == h - 6 and vim.api.nvim_buf_line_count(p.buf) == h - 6
  end, 15000, "content at the new height")
  t.eq(p.height, vim.api.nvim_win_get_height(win), "the pane is painted for the window's new height")
  vim.api.nvim_win_set_height(win, h)
  t.wait_for(function()
    return p.height == h
  end, 15000, "content at the old height again")
end)

t.case("the user's own binding in a pane wins over CodeTracer's", function()
  local buf = first.panes.calltrace.buf
  vim.api.nvim_set_current_win(window_of(first, "calltrace"))
  local m = vim.fn.maparg("<Down>", "n", false, true)
  t.eq(m.buffer, 1, "a buffer-local <Down>")
  t.eq(m.desc, "codetracer: user binding", "the user's")
  vim.api.nvim_feedkeys(vim.keycode("<Down>"), "x", false)
  t.eq(user_down, 1, "pressing it runs the user's function")
  -- The server is told, and marks the key as the editor's in the keymap.
  t.wait_for(function()
    for _, b in ipairs(first.panes.calltrace.bindings) do
      if b.key == "Down" and b.shadowedBy == "editor" then
        return true
      end
    end
    return false
  end, 15000, "the server's keymap to mark Down as the editor's")
  -- The other keys are CodeTracer's.
  local up = vim.fn.maparg("<Up>", "n", false, true)
  t.check(up.desc and up.desc:match("^codetracer: list%.") ~= nil, "<Up> is CodeTracer's: " .. tostring(up.desc))
  t.eq(vim.api.nvim_get_current_buf(), buf, "still in the call trace")
end)

t.case("a resize survives a round trip through another mode", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  local win = window_of(first, "state")
  local w = vim.api.nvim_win_get_width(win)
  local target = w + 12
  vim.api.nvim_win_set_width(win, target)
  t.wait_for(function()
    -- The plugin reports the edit when Neovim says a window was resized.
    return first.expected_sizes[win] and first.expected_sizes[win][1] == target
  end, 15000, "the resize to be recorded")
  t.check(first.expected_sizes[win][1] == target, "reported")
  t.sleep(300)
  t.check(toggle_mode(first), "to edit")
  t.check(toggle_mode(first), "back to debug")
  local again = window_of(first, "state")
  t.check(again ~= nil, "the state pane is shown again")
  if again then
    t.check(
      math.abs(vim.api.nvim_win_get_width(again) - target) <= 1,
      ("the state pane keeps its width: %d, resized to %d"):format(vim.api.nvim_win_get_width(again), target)
    )
  end
end)

t.case("switching sessions shows the other session's layout", function()
  local second = open_session()
  t.check(second ~= nil and second.id ~= first.id, "a second session")
  t.check(second.tab ~= first.tab, "in its own tab page")
  t.check(toggle_mode(second), "the second session to edit mode")
  t.eq(second.mode, "edit", "edit")
  -- To the first session's tab page: it is activated and shows its own layout.
  vim.api.nvim_set_current_tabpage(first.tab)
  local active
  t.wait_for(function()
    require("codetracer.rpc").request(state.conn, "session/list", nil, function(_, list)
      for _, s in ipairs(list or {}) do
        if s.active then
          active = s.session
        end
      end
    end)
    t.sleep(100)
    return active == first.id
  end, 15000, "the first session to be the active one")
  t.eq(first.mode, "debug", "the first session is still debugging")
  t.eq(shown(first), expected(first.layout), "its tab page shows its debug layout")
  vim.api.nvim_set_current_tabpage(second.tab)
  t.eq(shown(second), expected(second.layout), "the second shows its edit layout")
  t.check(not vim.deep_equal(shown(first), shown(second)), "the two differ")
end)

t.case(":checkhealth codetracer reports the server and its protocol", function()
  vim.cmd("checkhealth codetracer")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  t.check(text:match("protocol 1") ~= nil, "the protocol version: " .. text:sub(1, 400))
  t.check(text:match("ERROR") == nil, "no errors")
end)

t.case("the server stops cleanly", function()
  local done = false
  ct.stop(function()
    done = true
  end)
  t.wait_for(function()
    return done
  end, 10000, "shutdown")
end)

t.run()
