--- The generated C of a Nim line (Editor-Hosted-Front-Ends §E13,
--- Generated-Code-Listing §13.4): `:CodeTracer generated-c` in the source
--- window shows the C the line compiled to in the Low Level Code pane, which
--- the server places beside the source and the plugin opens.
---
--- Nothing is mocked. The server is `codetracer-tui --pane-server`
--- ($CODETRACER_TUI) over CodeTracer's native Nim example recording
--- ($CODETRACER_TEST_NATIVE_NIM_TRACE, an rr recording of
--- `nim_flow_test.nim` that bundles its generated C), replayed by the native
--- backend ($CODETRACER_CT_NATIVE_REPLAY_CMD).
---
--- The last cases open a project folder (no recording) in edit mode and
--- compile its Nim file with the real `nim` on PATH (HSF-E11).
---
--- Run: just test-integration-generated-c (see the Justfile).
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60

local t = require("harness")

local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_NATIVE_NIM_TRACE
local native = vim.env.CODETRACER_CT_NATIVE_REPLAY_CMD
local missing = {}
if server == nil or vim.fn.executable(server) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TUI"
end
if trace == nil or vim.fn.isdirectory(trace) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TEST_NATIVE_NIM_TRACE (codetracer-example-recordings/nim/flow_test)"
end
if native == nil or vim.fn.executable(native) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_CT_NATIVE_REPLAY_CMD (ct-native-replay)"
end
if #missing > 0 then
  io.stdout:write("the generated-C suite needs " .. table.concat(missing, ", ") .. "\n")
  vim.cmd("cquit 2")
end

vim.cmd("runtime plugin/codetracer.lua")
local ct = require("codetracer")
ct.setup({ cmd = { server, "--pane-server" } })

local first

--- The window showing `pane` in `session`, if any.
local function window_of(session, pane)
  for win, info in pairs(session.windows) do
    if info.pane == pane and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
end

t.case("the recording opens, stopped in its Nim module", function()
  ct.open(trace, function(x)
    first = x
  end)
  t.check(
    t.wait_for(function()
      return first and first.position ~= nil
    end, 120000, "the session"),
    "opened"
  )
  t.check(
    first.position.file:match("nim_flow_test%.nim$") ~= nil,
    "stopped in nim_flow_test.nim: " .. vim.inspect(first.position)
  )
end)

t.case(":CodeTracer generated-c shows the line's C in the Low Level Code pane", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  vim.api.nvim_set_current_win(first.editor_win)
  t.wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first.editor_win)):match("nim_flow_test%.nim$") ~= nil
  end, 30000, "the source window showing the stop's file")
  vim.api.nvim_win_set_cursor(first.editor_win, { first.position.line, 0 })
  t.check(window_of(first, "lowLevelCode") == nil, "no Low Level Code window before")
  vim.cmd("CodeTracer generated-c")
  local win
  t.wait_for(function()
    win = window_of(first, "lowLevelCode")
    return win ~= nil
  end, 60000, "the Low Level Code window the layout now places")
  if win == nil then
    return
  end
  local text
  t.check(
    t.wait_for(function()
      text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
      return text:find("#line", 1, true) ~= nil
    end, 60000, "the generated C's line directives in the pane"),
    "the pane shows the generated C:\n" .. tostring(text)
  )
end)

-- Editor-Hosted-Front-Ends §E9 and HSF-E11: a folder that holds no
-- recording opens as a PROJECT, in edit mode, and `:CodeTracer generated-c`
-- there compiles the edited file with the real `nim` (on PATH) and shows the
-- C of the cursor's line — below forty procs' C, so "shown" means scrolled to.
local project
local zebra_line = 42

t.case(":CodeTracer open on a project folder opens an edit-mode session", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local lines = {}
  for i = 1, 40 do
    lines[#lines + 1] = ("proc filler%d(): int = %d"):format(i, i)
  end
  vim.list_extend(lines, {
    "proc triple(n: int): int =",
    "  let zebraCount = n * 3",
    "  result = zebraCount + 1",
    "",
    "echo triple(14)",
  })
  vim.fn.writefile(lines, dir .. "/tiny.nim")
  ct.open(dir, function(x)
    project = x
  end)
  t.check(
    t.wait_for(function()
      return project ~= nil and project.tab ~= nil
    end, 60000, "the project session"),
    "opened"
  )
  if project == nil then
    return
  end
  t.eq(project.mode, "edit", "a project opens in edit mode")
  project.dir = dir
end)

t.case(":CodeTracer generated-c in edit mode shows the compiled C of the cursor's line", function()
  if project == nil or project.editor_win == nil then
    t.check(false, "no project session to run in")
    return
  end
  vim.api.nvim_set_current_tabpage(project.tab)
  vim.api.nvim_set_current_win(project.editor_win)
  vim.cmd("edit " .. vim.fn.fnameescape(project.dir .. "/tiny.nim"))
  vim.api.nvim_win_set_cursor(project.editor_win, { zebra_line, 2 })
  vim.cmd("CodeTracer generated-c")
  local win
  t.wait_for(function()
    win = window_of(project, "lowLevelCode")
    return win ~= nil
  end, 60000, "the Low Level Code window the layout now places")
  if win == nil then
    t.check(false, "no Low Level Code window")
    return
  end
  local text
  t.check(
    t.wait_for(function()
      text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
      return text:find("zebraCount", 1, true) ~= nil
      -- The pane holds only the rows its window shows, and the line's C is
      -- far below the file's top: found means scrolled to.
    end, 120000, "the compiled C of the cursor's line in view"),
    "the pane shows the line's C:\n" .. tostring(text)
  )
end)

-- Editor-Hosted §E7: a press on an instruction of the compiled C moves the
-- source window's cursor to the Nim line it came from — `source/show`
-- carries the position.
t.case("a press on the compiled C puts the source window's cursor on its Nim line", function()
  local lowlevel = project and project.panes.lowLevelCode
  local win = lowlevel and window_of(project, "lowLevelCode")
  if win == nil then
    t.check(false, "no Low Level Code pane to press in")
    return
  end
  local target, at
  for i = 0, lowlevel.height - 1 do
    local row = lowlevel.rows[i] or {}
    if (row.text or ""):find("nimlf_(" .. zebra_line, 1, true) then
      for _, h in ipairs(row.hotspots or {}) do
        if h.operation == "low-level.go-to-source-line" then
          target, at = h, i
        end
      end
    end
  end
  t.check(target ~= nil, "the C of line " .. zebra_line .. " offers a press")
  if target == nil then
    return
  end
  -- The cursor is elsewhere first, so the move is the press's.
  vim.api.nvim_win_set_cursor(project.editor_win, { 1, 0 })
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { at + 1, target.start })
  require("codetracer.panes").activate(lowlevel.buf, false)
  t.check(
    t.wait_for(function()
      return vim.api.nvim_win_get_cursor(project.editor_win)[1] == zebra_line
    end, 15000, "the source window's cursor on line " .. zebra_line),
    "cursor at " .. vim.inspect(vim.api.nvim_win_get_cursor(project.editor_win))
  )
  t.check(
    vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(project.editor_win)):match("tiny%.nim$") ~= nil,
    "the source window shows tiny.nim"
  )
end)

t.case("the server stops cleanly", function()
  local done = false
  ct.stop(function()
    done = true
  end)
  t.check(
    t.wait_for(function()
      return done
    end, 20000, "the stop"),
    "stopped"
  )
end)

t.run()
