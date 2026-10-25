--- Integration tests for the editor's side of the roles (§E7, §E8) and the
--- image medium (E0 row 4c), against a real pane server over a real
--- recording, as `integration_spec.lua` is (same variables). This suite cedes
--- the file tree role to the editor, which changes every layout, so it runs
--- in its own Neovim.
---
--- The image plugin is a stand-in recording what it is asked to draw.
--- Justified: a real image.nvim draws through a terminal graphics protocol a
--- headless Neovim does not have; what this suite checks is that the frames
--- the server sends reach the image plugin, decoded, in the frame viewer's
--- window. The frames themselves are real: with
--- $CODETRACER_CT_GFX_PLAYER_CMD (the visual replay player) and
--- $CODETRACER_TEST_GFX_STREAM (a gfx stream) the recording is given
--- graphics and the server renders them; without both, the image case is
--- reported as not run, and the suite fails, rather than passing silently.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60
vim.cmd("runtime plugin/codetracer.lua")

local t = require("harness")

local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_TRACE
if server == nil or vim.fn.executable(server) ~= 1 or trace == nil or vim.fn.isdirectory(trace) ~= 1 then
  io.stdout:write("integration tests need $CODETRACER_TUI and $CODETRACER_TEST_TRACE\n")
  vim.cmd("cquit 2")
end

-- The stand-in image plugin (see the header).
local drawn = {}
package.preload["image"] = function()
  return {
    clear = function() end,
    from_file = function(path, opts)
      local f = io.open(path, "rb")
      local bytes = f and f:read("*a") or ""
      if f then
        f:close()
      end
      local img = { path = path, opts = opts, bytes = bytes }
      function img.render() end
      function img.clear() end
      drawn[#drawn + 1] = img
      return img
    end,
  }
end

--- The recording with a gfx stream in it, when one is available.
local function graphics_trace()
  local stream = vim.env.CODETRACER_TEST_GFX_STREAM
  if not (vim.env.CODETRACER_CT_GFX_PLAYER_CMD and stream and vim.fn.isdirectory(stream) == 1) then
    return nil
  end
  local dir = vim.fn.tempname()
  vim.fn.system({ "cp", "-r", trace, dir })
  vim.fn.system({ "cp", "-r", stream, dir .. "/gfx_stream" })
  return dir
end
local gfx_trace = graphics_trace()

local ct = require("codetracer")
ct.setup({ cmd = { server, "--pane-server" }, panels = { fileTree = "editor" } })
local state = require("codetracer.state")
local rpc = require("codetracer.rpc")

-- What the plugin tells the server, for the cases that check a report.
local sent = {}
local notify = rpc.notify
rpc.notify = function(conn, method, params)
  sent[#sent + 1] = { method = method, params = params }
  return notify(conn, method, params)
end

local function open_session(path)
  local s
  ct.open(path, function(x)
    s = x
  end)
  t.wait_for(function()
    return s and s.position and s.panes.calltrace and s.panes.calltrace.rows[0] ~= nil
  end, 60000, "the session")
  return s
end

local session

t.case("the image medium is declared when an image plugin is installed", function()
  session = open_session(gfx_trace or trace)
  t.check(session ~= nil, "a session")
  t.eq(state.conn.info.capabilities.media, { "text", "image" }, "the server will send images")
end)

t.case("with the file tree role ceded, CodeTracer's file pane is not shown", function()
  local shown = {}
  for _, info in pairs(session.windows) do
    shown[info.pane] = true
  end
  t.check(not shown.fileTree, "no file pane")
  t.check(shown.editor and shown.calltrace, "the rest of the layout")
end)

t.case("a file the editor creates is reported to the server", function()
  local path = vim.fn.tempname() .. ".py"
  sent = {}
  vim.api.nvim_set_current_win(session.editor_win)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print('hi')" })
  vim.cmd("write")
  local report
  t.wait_for(function()
    for _, m in ipairs(sent) do
      if m.method == "files/changed" then
        report = m.params
        return true
      end
    end
    return false
  end, 5000, "files/changed")
  t.eq(report and report.created, { path }, "the created file")
  local scratch = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(session.editor_win, session.source_buf)
  vim.api.nvim_buf_delete(scratch, { force = true })
  os.remove(path)
end)

t.case("a breakpoint goes on the line the editor's cursor is on", function()
  vim.api.nvim_set_current_win(session.editor_win)
  require("codetracer.source").refresh(session)
  t.wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(session.editor_win)) == session.position.file
  end, 10000, "the source window on the stopped-in file")
  local target = session.position.line + 2
  vim.api.nvim_win_set_cursor(session.editor_win, { target, 0 })
  t.sleep(100) -- CursorMoved, from the main loop
  ct.run("editor.toggle-breakpoint", nil, session)
  local buf = vim.api.nvim_win_get_buf(session.editor_win)
  local ns = require("codetracer.source").namespace
  t.wait_for(function()
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[2] + 1 == target and m[4].sign_text and m[4].sign_text:match("●") then
        return true
      end
    end
    return false
  end, 15000, "a breakpoint sign on the cursor's line " .. target)
end)

t.case("the recording's sources open, recorded ones read-only", function()
  local listed
  rpc.request(state.conn, "session/files", { session = session.id }, function(_, files)
    listed = files
  end)
  t.wait_for(function()
    return listed ~= nil
  end, 10000, "session/files")
  local paths = vim.tbl_map(function(f)
    return f.path
  end, listed or {})
  t.check(vim.tbl_contains(paths, session.position.file), "the stopped-in file is listed")
  local buf
  require("codetracer.files").recorded_buffer(session, session.position.file, function(b)
    buf = b
  end)
  t.wait_for(function()
    return buf ~= nil
  end, 10000, "the recorded buffer")
  if buf then
    local disk = vim.fn.readfile(session.position.file)
    t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), disk, "the recorded text")
    t.check(vim.bo[buf].readonly and not vim.bo[buf].modifiable, "read-only")
    t.eq(vim.bo[buf].filetype, "python", "its filetype")
  end
end)

--- The `files/selected` notifications sent since `from`.
local function selections(from)
  local out = {}
  for i = from + 1, #sent do
    if sent[i].method == "files/selected" then
      out[#out + 1] = sent[i].params.path
    end
  end
  return out
end

--- Put `win`'s cursor on the line showing `name`, from the main loop, so
--- the tree's CursorMoved runs as it does for a user.
local function cursor_on(win, name)
  local buf = vim.api.nvim_win_get_buf(win)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(name, 1, true) then
      vim.api.nvim_win_set_cursor(win, { i, (line:find(name, 1, true)) - 1 })
      return true
    end
  end
  return false
end

--- Whether CodeTracer's own file tree has `path` selected: its pane, opened
--- for the check, draws the selected row on the selection surface.
local function tree_selects(path)
  local name = vim.fs.basename(path)
  local selected = nil
  local au = vim.api.nvim_create_autocmd("User", {
    pattern = "CodeTracerNotification",
    callback = function(ev)
      local p = ev.data.params
      if ev.data.method == "pane/content" and p.pane == "fileTree" then
        for _, row in ipairs(p.rows or {}) do
          if row.text:find(name, 1, true) then
            selected = false
            for _, span in ipairs(row.spans or {}) do
              if (span.surface or ""):match("selection") or (span.surface or ""):match("active") then
                selected = true
              end
            end
          end
        end
      end
    end,
  })
  rpc.request(state.conn, "pane/open", { session = session.id, pane = "fileTree", width = 40, height = 12 })
  t.wait_for(function()
    return selected ~= nil
  end, 10000, "the file pane's rows")
  vim.api.nvim_del_autocmd(au)
  rpc.request(state.conn, "pane/close", { session = session.id, pane = "fileTree" })
  return selected
end

t.case("a file selected in netrw is reported, and CodeTracer's tree follows", function()
  vim.cmd("runtime plugin/netrwPlugin.vim")
  local file = session.position.file
  local dir = vim.fs.dirname(file)
  vim.api.nvim_set_current_tabpage(session.tab)
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.cmd("Explore " .. vim.fn.fnameescape(dir))
  t.wait_for(function()
    return vim.bo.filetype == "netrw"
  end, 5000, "netrw")
  local from = #sent
  t.check(cursor_on(win, vim.fs.basename(file)), "netrw lists the file")
  t.wait_for(function()
    return vim.tbl_contains(selections(from), file)
  end, 5000, "files/selected for " .. file)
  t.check(tree_selects(file), "CodeTracer's file tree selects it")
  vim.api.nvim_win_close(win, true)
end)

t.case("a file selected in oil.nvim is reported", function()
  local oil_path = vim.env.CODETRACER_TEST_OIL
  if oil_path == nil then
    t.check(false, "NOT RUN: set CODETRACER_TEST_OIL to an oil.nvim checkout (the dev shell does)")
    return
  end
  vim.opt.runtimepath:prepend(oil_path)
  require("oil").setup({ default_file_explorer = false })
  local file = session.position.file
  vim.api.nvim_set_current_tabpage(session.tab)
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  local from = #sent
  require("oil").open(vim.fs.dirname(file))
  t.wait_for(function()
    return vim.bo.filetype == "oil" and cursor_on(win, vim.fs.basename(file))
  end, 10000, "oil to list the file")
  t.wait_for(function()
    return vim.tbl_contains(selections(from), file)
  end, 5000, "files/selected for " .. file)
  vim.api.nvim_win_close(win, true)
end)

--- Put the plugin directories `var` names (a `:`-separated list, the tree
--- first and its dependencies after it) on the runtime path; false, with a
--- NOT RUN failure, when the dev shell did not provide them.
local function provide(var, what)
  local dirs = vim.env[var]
  if dirs == nil or dirs == "" then
    t.check(false, "NOT RUN: set " .. var .. " to " .. what .. " (the dev shell does)")
    return false
  end
  for _, dir in ipairs(vim.split(dirs, ":", { plain = true, trimempty = true })) do
    vim.opt.runtimepath:prepend(dir)
  end
  return true
end

--- The window showing a buffer of `filetype`, once one exists.
local function window_of(filetype)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == filetype then
      return w
    end
  end
  return nil
end

-- Each tree is driven as a user drives it: opened on the recording's
-- directory through its own command, its cursor put on the file's line from
-- the main loop. What is checked is what the plugin reads through the tree's
-- own API (`files.SELECTION`), arriving at the server as `files/selected`.
t.case("a file selected in nvim-tree is reported", function()
  if not provide("CODETRACER_TEST_NVIM_TREE", "nvim-tree.lua") then
    return
  end
  require("nvim-tree").setup({ hijack_netrw = false, disable_netrw = false })
  local file = session.position.file
  vim.api.nvim_set_current_tabpage(session.tab)
  local from = #sent
  require("nvim-tree.api").tree.open({ path = vim.fs.dirname(file) })
  local win = nil
  t.wait_for(function()
    win = window_of("NvimTree")
    return win ~= nil
  end, 10000, "nvim-tree's window")
  if win == nil then
    return
  end
  vim.api.nvim_set_current_win(win)
  t.wait_for(function()
    return cursor_on(win, vim.fs.basename(file))
  end, 10000, "nvim-tree to list the file")
  t.wait_for(function()
    return vim.tbl_contains(selections(from), file)
  end, 5000, "files/selected for " .. file)
  require("nvim-tree.api").tree.close()
end)

t.case("a file selected in neo-tree is reported", function()
  if not provide("CODETRACER_TEST_NEO_TREE", "neo-tree.nvim and its dependencies") then
    return
  end
  require("neo-tree").setup({
    filesystem = { hijack_netrw_behavior = "disabled" },
    default_component_configs = { icon = { enabled = false } },
  })
  local file = session.position.file
  vim.api.nvim_set_current_tabpage(session.tab)
  local from = #sent
  -- Through neo-tree's command module: `:Neotree` is defined by its plugin/
  -- file, which a runtime path extended after start-up does not source.
  local neo_command = require("neo-tree.command")
  neo_command.execute({ source = "filesystem", position = "left", dir = vim.fs.dirname(file) })
  local win = nil
  t.wait_for(function()
    win = window_of("neo-tree")
    return win ~= nil
  end, 10000, "neo-tree's window")
  if win == nil then
    return
  end
  vim.api.nvim_set_current_win(win)
  t.wait_for(function()
    return cursor_on(win, vim.fs.basename(file))
  end, 10000, "neo-tree to list the file")
  t.wait_for(function()
    return vim.tbl_contains(selections(from), file)
  end, 5000, "files/selected for " .. file)
  neo_command.execute({ action = "close" })
end)

t.case("the frame viewer's frames are drawn through the image plugin", function()
  if gfx_trace == nil then
    t.check(false, "NOT RUN: set CODETRACER_CT_GFX_PLAYER_CMD and CODETRACER_TEST_GFX_STREAM to run the image case")
    return
  end
  t.check(
    session.graphics and session.graphics.available,
    "the recording has graphics: " .. vim.inspect(session.graphics)
  )
  vim.api.nvim_set_current_tabpage(session.tab)
  vim.cmd("CodeTracer frames")
  t.wait_for(function()
    return #drawn >= 1
  end, 60000, "a frame")
  local img = drawn[1]
  if img then
    t.eq(img.bytes:sub(1, 8), "\137PNG\r\n\26\n", "a PNG")
    t.eq(img.opts.window, session.frames_win, "in the frame viewer's window")
  end
  local before = #drawn
  ct.run("frame-viewer.next-frame", nil, session)
  t.wait_for(function()
    return #drawn > before
  end, 60000, "the next frame")
  t.check(drawn[#drawn].path ~= img.path, "a new image")
end)

t.case("the server stops cleanly", function()
  local done = false
  ct.stop(function()
    done = true
  end)
  t.wait_for(function()
    return done
  end, 10000, "shutdown")
  if gfx_trace then
    vim.fn.delete(gfx_trace, "rf")
  end
end)

t.run()
