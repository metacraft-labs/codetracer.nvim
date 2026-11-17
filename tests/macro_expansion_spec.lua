--- Toggle Macro Expansion (Editor-Hosted-Front-Ends §E15): `:CodeTracer
--- macro-expansion` on a Nim macro call shows the code it expanded to in the
--- Macro Expansion pane, which the server places beside the source and the
--- plugin opens; a step into the expansion stops inside it, the source window
--- staying on the call's line and the pane marking the row; the pane's
--- heading closes it.
---
--- Nothing is mocked. The server is `codetracer-tui --pane-server`
--- ($CODETRACER_TUI) over the `ct record` recording of CodeTracer's
--- `test-programs/nim_macro_steps/main.nim`
--- ($CODETRACER_TEST_NIM_MACRO_TRACE): `addTwice(counter, 3)` on line 17
--- expands to the compiler's `expanded.nim` lines 1–4. It is replayed by the
--- native backend ($CODETRACER_CT_NATIVE_REPLAY_CMD, and ct-mcr through
--- $CODETRACER_CT_MCR_CMD).
---
--- Run: just test-integration-macro (see the Justfile).
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60

local t = require("harness")

local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_NIM_MACRO_TRACE
local native = vim.env.CODETRACER_CT_NATIVE_REPLAY_CMD
local missing = {}
if server == nil or vim.fn.executable(server) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TUI"
end
if trace == nil or vim.fn.isdirectory(trace) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TEST_NIM_MACRO_TRACE (`ct record` of test-programs/nim_macro_steps/main.nim)"
end
if native == nil or vim.fn.executable(native) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_CT_NATIVE_REPLAY_CMD (ct-native-replay)"
end
if #missing > 0 then
  io.stdout:write("the macro expansion suite needs " .. table.concat(missing, ", ") .. "\n")
  vim.cmd("cquit 2")
end

vim.cmd("runtime plugin/codetracer.lua")
local ct = require("codetracer")
ct.setup({ cmd = { server, "--pane-server" } })

local BEFORE_CALL = 16 -- `var counter = 0`
local MACRO_CALL = 17 -- `addTwice(counter, 3)`

local first

--- The window showing `pane` in `session`, if any.
local function window_of(session, pane)
  for win, info in pairs(session.windows) do
    if info.pane == pane and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
end

local function pane_text(win)
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

--- Run `operation` and wait for the server's answer (and the position it
--- sends first): one move at a time, as a user presses them. A move of this
--- recording's replay can take twenty seconds on a busy host.
local function run_and_wait(operation)
  local state = require("codetracer.state")
  local done = false
  require("codetracer.rpc").request(
    state.conn,
    "operation/run",
    { session = first.id, operation = operation },
    function()
      done = true
    end
  )
  return t.wait_for(function()
    return done
  end, 120000, "the answer to " .. operation)
end

local function at_main(line)
  return first.position ~= nil and first.position.file:match("/main%.nim$") ~= nil and first.position.line == line
end

t.case("the recording opens, and steps to the line before the macro call", function()
  ct.open(trace, function(x)
    first = x
  end)
  t.check(
    t.wait_for(function()
      return first and first.position ~= nil
    end, 120000, "the session"),
    "opened"
  )
  -- To the line before the call by a breakpoint there and Continue: one
  -- move, where stepping through the program's start takes twenty.
  vim.api.nvim_set_current_tabpage(first.tab)
  vim.api.nvim_set_current_win(first.editor_win)
  t.wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first.editor_win)):match("main%.nim$") ~= nil
  end, 30000, "the source window showing main.nim")
  vim.api.nvim_win_set_cursor(first.editor_win, { BEFORE_CALL, 0 })
  require("codetracer.source").report_cursor(first, first.editor_win)
  run_and_wait("editor.toggle-breakpoint")
  run_and_wait("debugger.continue")
  t.check(at_main(BEFORE_CALL), "at main.nim:" .. BEFORE_CALL .. ": " .. vim.inspect(first.position))
end)

t.case("the right-click menu offers Toggle macro expansion in a Nim file", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  vim.api.nvim_set_current_win(first.editor_win)
  t.wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first.editor_win)):match("main%.nim$") ~= nil
  end, 30000, "the source window showing main.nim")
  local menu = require("codetracer.menu")
  menu.on_popup()
  local items = vim.fn.menu_get("PopUp.CodeTracer")
  local names = {}
  for _, sub in ipairs((items[1] or {}).submenus or {}) do
    names[#names + 1] = sub.name
  end
  t.check(vim.tbl_contains(names, "Toggle macro expansion"), "the submenu: " .. vim.inspect(names))
end)

local pane_win

t.case(":CodeTracer macro-expansion shows the call's expansion beside the source", function()
  vim.api.nvim_set_current_win(first.editor_win)
  vim.api.nvim_win_set_cursor(first.editor_win, { MACRO_CALL, 2 })
  t.check(window_of(first, "macroExpansion") == nil, "no Macro Expansion window before")
  vim.cmd("CodeTracer macro-expansion")
  t.wait_for(function()
    pane_win = window_of(first, "macroExpansion")
    return pane_win ~= nil
  end, 60000, "the Macro Expansion window the layout now places")
  if pane_win == nil then
    t.check(false, "no Macro Expansion window")
    return
  end
  local text
  t.check(
    t.wait_for(function()
      text = pane_text(pane_win)
      return text:find("main.nim:17 · expanded.nim 1–4", 1, true) ~= nil
        and text:find("counter += 3", 1, true) ~= nil
    end, 60000, "the expansion's heading and lines"),
    "the pane shows the expansion:\n" .. tostring(text)
  )
  t.check(text:find("addTwice expansion", 1, true) ~= nil, "the compiler's own line")
end)

t.case("a step into the expansion stays on the call and marks the row", function()
  if pane_win == nil then
    t.check(false, "no Macro Expansion window")
    return
  end
  run_and_wait("debugger.step-into")
  t.check(at_main(MACRO_CALL), "the source stays on the call: " .. vim.inspect(first.position))
  local text
  t.check(
    t.wait_for(function()
      text = pane_text(pane_win)
      for _, l in ipairs(vim.split(text, "\n")) do
        if l:find("▸", 1, true) and l:find("counter += 3", 1, true) then
          return true
        end
      end
      return false
    end, 30000, "the execution row in the pane"),
    "the pane marks the row:\n" .. tostring(text)
  )
end)

t.case("<CR> on the pane's heading closes the expansion", function()
  if pane_win == nil then
    t.check(false, "no Macro Expansion window")
    return
  end
  local pane = first.panes.macroExpansion
  vim.api.nvim_set_current_win(pane_win)
  vim.api.nvim_win_set_cursor(pane_win, { 1, 0 })
  require("codetracer.panes").activate(pane.buf, false)
  local text
  t.check(
    t.wait_for(function()
      text = pane_text(pane_win)
      return text:find("Toggle Macro Expansion on a macro call", 1, true) ~= nil
    end, 30000, "the pane with no expansion open"),
    "closed:\n" .. tostring(text)
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
