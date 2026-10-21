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
