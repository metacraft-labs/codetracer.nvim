--- Nim's compile-time tracing from the editor (Editor-Hosted-Front-Ends
--- §E12): with a Nim project in Edit mode, tracing the static block under
--- the cursor — from the right-click menu's CodeTracer submenu — opens what
--- the trace records as a session of its own, in a tab page of its own.
---
--- Nothing is mocked. The server is `codetracer-tui --pane-server`
--- ($CODETRACER_TUI) over CodeTracer's `calc` recording
--- ($CODETRACER_TEST_TRACE), started in the project's directory, which is its
--- Edit-mode project. The project is PLAT-65's `tracing.nim`, byte for byte
--- (`plat65_nim_project.nim`); the trace is codetracer-nim's trace-enabled
--- nimsuggest ($CODETRACER_NIMSUGGEST) and compiler (`nim` on PATH).
---
--- Run: just test-integration-nim (see the Justfile for the variables).
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60

local t = require("harness")

local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_TRACE
local missing = {}
if server == nil or vim.fn.executable(server) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TUI"
end
if trace == nil or vim.fn.isdirectory(trace) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TEST_TRACE"
end
if vim.env.CODETRACER_NIMSUGGEST == nil or vim.fn.executable(vim.env.CODETRACER_NIMSUGGEST) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_NIMSUGGEST (codetracer-nim's trace-enabled nimsuggest)"
end
if vim.fn.executable("nim") ~= 1 then
  missing[#missing + 1] = "nim (codetracer-nim's, on PATH)"
end
if #missing > 0 then
  io.stdout:write("the Nim tracing suite needs " .. table.concat(missing, ", ") .. "\n")
  vim.cmd("cquit 2")
end

-- PLAT-65's project: a macro, consts, a static block.
local TRACING_NIM = {
  "import std/macros",
  "",
  "macro twice(body: untyped): untyped =",
  "  result = newStmtList(body, body)",
  "",
  "proc compute(n: int): int =",
  "  result = 0",
  "  for i in 1..n:",
  "    result += i * i",
  "",
  "const squares = compute(3)",
  "",
  "const",
  "  limit = 4",
  "  cubes = compute(limit)",
  "",
  "static:",
  "  var acc = 0",
  "  for i in 0..<limit:",
  "    acc += i",
  '  echo "acc=", acc',
  "",
  'echo "after"',
  "let folded = static(compute(5))",
  "",
  "twice:",
  "  echo squares",
}
local STATIC_LINE = 18 -- inside `static:`
local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
vim.fn.writefile(TRACING_NIM, project .. "/tracing.nim")
vim.cmd.cd(project)

vim.cmd("runtime plugin/codetracer.lua")
local ct = require("codetracer")
ct.setup({ cmd = { server, "--pane-server" } })
local state = require("codetracer.state")

local first

t.case("a session opens, in Edit mode on the project", function()
  ct.open(trace, function(x)
    first = x
  end)
  t.check(
    t.wait_for(function()
      return first and first.position ~= nil
    end, 60000, "the session"),
    "opened"
  )
  ct.run("session.toggle-product-mode", nil, first)
  t.check(
    t.wait_for(function()
      return first.mode == "edit"
    end, 30000, "Edit mode"),
    "in Edit mode"
  )
end)

t.case("the right-click menu traces the static block; its recording opens in its own tab", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  vim.cmd("vsplit " .. vim.fn.fnameescape(project .. "/tracing.nim"))
  vim.api.nvim_win_set_cursor(0, { STATIC_LINE, 4 })
  local menu = require("codetracer.menu")
  menu.on_popup()
  local items = vim.fn.menu_get("PopUp.CodeTracer")
  t.check(#items == 1 and #(items[1].submenus or {}) == #menu.ITEMS, "the CodeTracer submenu: " .. vim.inspect(items))
  local before = {}
  for id in pairs(state.sessions) do
    before[id] = true
  end
  -- What the menu item runs.
  menu.run("editor.trace-static-block-at-cursor")
  local opened
  t.wait_for(function()
    for id, s in pairs(state.sessions) do
      if not before[id] and s.tab then
        opened = s
        return true
      end
    end
    return false
  end, 300000, "the trace's recording")
  t.check(opened ~= nil, "the trace opened a session")
  t.check(opened and opened.tab ~= first.tab, "in a tab page of its own")
  t.check(opened and vim.fn.isdirectory(opened.trace) == 1, "a recording folder: " .. tostring(opened and opened.trace))
end)

t.case("outside a Nim file the menu offers nothing", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  vim.cmd("enew")
  require("codetracer.menu").on_popup()
  -- `menu_get` raises E329 for a menu that does not exist.
  local ok, items = pcall(vim.fn.menu_get, "PopUp.CodeTracer")
  t.check(not ok or #items == 0, "no CodeTracer submenu: " .. vim.inspect(items))
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
