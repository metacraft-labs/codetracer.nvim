--- Edit-mode services through the plugin (Editor-Hosted-Front-Ends §E9): a
--- test recorded from CodeTracer's Test Results pane opens its recording as
--- a session of its own, in a tab page of its own (`session/opened`), and an
--- operation the session refuses says why.
---
--- Nothing is mocked. The server is `codetracer-tui --pane-server`
--- ($CODETRACER_TUI) over CodeTracer's `calc` recording
--- ($CODETRACER_TEST_TRACE); the project is the two-test Noir crate
--- CodeTracer's own Test Results suites run (`plat53_noir_project.nim`, byte
--- for byte), written to a temporary directory that Neovim starts the server
--- in — the server's Edit-mode project is the directory it starts in, as
--- `ct replay`'s is. Recording the test runs the real `ct record-test`, which
--- needs `ct` (`$CT_BIN`, or on `PATH`) and `nargo` on `PATH`.
---
--- Run: just test-integration-edit (see the Justfile for the variables).
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60

local t = require("harness")

local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_TRACE
local ct_bin = vim.env.CT_BIN ~= nil and vim.env.CT_BIN or vim.fn.exepath("ct")
local missing = {}
if server == nil or vim.fn.executable(server) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TUI"
end
if trace == nil or vim.fn.isdirectory(trace) ~= 1 then
  missing[#missing + 1] = "$CODETRACER_TEST_TRACE"
end
if ct_bin == "" or vim.fn.executable(ct_bin) ~= 1 then
  missing[#missing + 1] = "ct ($CT_BIN or PATH)"
end
if vim.fn.executable("nargo") ~= 1 then
  missing[#missing + 1] = "nargo (PATH)"
end
if #missing > 0 then
  io.stdout:write("the edit-mode suite needs " .. table.concat(missing, ", ") .. "\n")
  vim.cmd("cquit 2")
end

-- The crate, and the server started in it.
local project = vim.fn.tempname()
vim.fn.mkdir(project .. "/src", "p")
vim.fn.writefile(
  { "[package]", 'name = "plat53_suite"', 'type = "bin"', 'authors = [""]', "", "[dependencies]" },
  project .. "/Nargo.toml"
)
vim.fn.writefile({
  "fn main(x: Field, y: pub Field) {",
  "    assert(x != y);",
  "}",
  "",
  "#[test]",
  "fn test_passes() {",
  "    main(1, 2);",
  "}",
  "",
  "#[test]",
  "fn test_fails() {",
  "    main(1, 1);",
  "}",
}, project .. "/src/main.nr")
vim.env.TEST_CERTIFICATES_DIR = vim.fn.tempname()
vim.cmd.cd(project)

vim.cmd("runtime plugin/codetracer.lua")
local ct = require("codetracer")
ct.setup({ cmd = { server, "--pane-server" } })
local state = require("codetracer.state")
local layout = require("codetracer.layout")
local panes = require("codetracer.panes")

local first

t.case("a session opens on the recording, in the crate's directory", function()
  ct.open(trace, function(x)
    first = x
  end)
  t.check(
    t.wait_for(function()
      return first and first.position ~= nil
    end, 60000, "the session"),
    "opened"
  )
end)

t.case("an operation the session refuses says why", function()
  local said
  local notify = vim.notify
  vim.notify = function(msg, level)
    said = { msg = msg, level = level }
  end
  panes.run(first, "testResults", "tests.open-test", { args = { path = "no-such-test" } })
  t.wait_for(function()
    return said ~= nil
  end, 15000, "the refusal")
  vim.notify = notify
  t.check(
    said and said.level == vim.log.levels.WARN and said.msg:find("tests.open-test", 1, true) ~= nil,
    "refused with its reason: " .. vim.inspect(said)
  )
end)

t.case("a test recorded from Test Results opens in a tab page of its own", function()
  -- Show the Test Results pane: a tab of the stack it is placed in.
  local shown = false
  for win, info in pairs(first.windows) do
    if info.node and info.node.kind == "stack" then
      for i, child in ipairs(info.node.children) do
        if child.pane == "testResults" then
          layout.stack_select(first, win, i)
          shown = true
        end
      end
    end
  end
  t.check(shown, "the layout places the Test Results pane in a stack")
  local p = state.pane(first, "testResults")
  local spot
  t.wait_for(function()
    for _, row in pairs(p.rows or {}) do
      if (row.text or ""):find("test_fails", 1, true) then
        for _, h in ipairs(row.hotspots or {}) do
          if h.operation == "tests.open-test" then
            spot = h
            return true
          end
        end
      end
    end
    return false
  end, 60000, "the failing test's ⏵ in Test Results")
  if spot == nil then
    return
  end
  local tabs = #vim.api.nvim_list_tabpages()
  -- What a click on the ⏵ sends (`panes.activate`).
  panes.run(first, "testResults", spot.operation, { args = spot.args })
  local opened
  t.wait_for(function()
    for id, s in pairs(state.sessions) do
      if id ~= first.id then
        opened = s
      end
    end
    return opened ~= nil and opened.tab ~= nil
  end, 240000, "the recording's session")
  if opened == nil then
    return
  end
  t.check(#vim.api.nvim_list_tabpages() == tabs + 1, "a new tab page")
  t.check(opened.tab ~= first.tab, "not the first session's")
  t.check(vim.fn.isdirectory(opened.trace) == 1, "a recording folder: " .. tostring(opened.trace))
  t.check(
    t.wait_for(function()
      return opened.position ~= nil
    end, 60000, "the recording's position"),
    "positioned"
  )
end)

--- Sessions other than `first`, by id.
local function others()
  local out = {}
  for id in pairs(state.sessions) do
    if id ~= first.id then
      out[id] = true
    end
  end
  return out
end

--- Wait for a session that is not in `known` to open in its own tab page.
local function new_session(known, what)
  local found
  t.wait_for(function()
    for id, s in pairs(state.sessions) do
      if id ~= first.id and not known[id] and s.tab then
        found = s
        return true
      end
    end
    return false
  end, 240000, what)
  return found
end

t.case("the source's tests are signs on their lines; the sign and the command record them", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  vim.api.nvim_set_current_win(first.editor_win)
  vim.cmd.edit(project .. "/src/main.nr")
  local buf = vim.api.nvim_get_current_buf()
  local tests = require("codetracer.tests")
  local marks
  t.wait_for(function()
    marks = vim.api.nvim_buf_get_extmarks(buf, tests.namespace, 0, -1, { details = true })
    return #marks == 2
  end, 30000, "the two tests' signs")
  local lines = {}
  for _, m in ipairs(marks or {}) do
    lines[#lines + 1] = m[2] + 1
    t.check(m[4].sign_text ~= nil, "a sign on line " .. (m[2] + 1))
  end
  table.sort(lines)
  t.eq(lines, { 5, 10 }, "on each test's line (its #[test])")
  local press = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("<LeftMouse>", "n", false, true)
  end)
  t.check(press.buffer == 1, "a press in the sign column is CodeTracer's: " .. vim.inspect(press))
  -- The source window follows the debugger's position, so the file is read
  -- in a window of the user's own, as one browses a project: a real press
  -- there on test_fails' sign (line 10, the window's first cells).
  vim.cmd("vsplit")
  local mine = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(mine, buf)
  vim.api.nvim_win_set_cursor(mine, { 1, 0 })
  vim.cmd("redraw")
  local known = others()
  local winpos = vim.api.nvim_win_get_position(mine)
  vim.api.nvim_input_mouse("left", "press", "", 0, winpos[1] + 9, winpos[2])
  vim.api.nvim_input_mouse("left", "release", "", 0, winpos[1] + 9, winpos[2])
  local clicked = new_session(known, "the clicked test's recording")
  t.check(clicked ~= nil, "a click on the sign recorded the test")
  -- The command, from the cursor inside test_passes' body.
  vim.api.nvim_set_current_tabpage(first.tab)
  vim.api.nvim_set_current_win(mine)
  vim.api.nvim_win_set_cursor(mine, { 7, 4 })
  known = others()
  vim.cmd("CodeTracer test-at-cursor")
  t.check(new_session(known, "the command's recording") ~= nil, ":CodeTracer test-at-cursor recorded the test")
end)

t.case("the neotest strategy records a test CodeTracer knows", function()
  local paths = vim.env.CODETRACER_TEST_NEOTEST
  t.check(paths ~= nil, "$CODETRACER_TEST_NEOTEST (the dev shell sets it)")
  if paths == nil then
    return
  end
  for _, p in ipairs(vim.split(paths, ":", { trimempty = true })) do
    vim.opt.runtimepath:append(p)
  end
  local nio = require("nio")
  local known = others()
  local code
  nio.run(function()
    -- What neotest hands a strategy for test_passes (rows are 0-based).
    local proc = require("codetracer.neotest").strategy({ command = { "nargo", "test", "test_passes" } }, {
      position = { path = project .. "/src/main.nr", name = "test_passes", range = { 5, 0, 7, 1 } },
    })
    code = proc.result()
  end)
  t.check(new_session(known, "the strategy's recording") ~= nil, "recorded through CodeTracer")
  t.wait_for(function()
    return code ~= nil
  end, 10000, "the process to complete")
  t.eq(code, 0, "the process succeeded")
end)

t.case("a test recorded 'here' takes the place of the session it was started from", function()
  vim.api.nvim_set_current_tabpage(first.tab)
  local buf = vim.fn.bufnr(project .. "/src/main.nr")
  local win = vim.fn.bufwinid(buf)
  t.check(win ~= -1, "main.nr is shown in the first session's tab page")
  if win == -1 then
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 11, 4 })
  local known = others()
  local replaced = first.id
  vim.cmd("CodeTracer test-at-cursor here")
  local opened = new_session(known, "the recording that replaces the session")
  t.check(opened ~= nil, "a session opened")
  t.check(
    t.wait_for(function()
      return state.sessions[replaced] == nil
    end, 15000, "the replaced session to close"),
    "the session it was started from is closed"
  )
  t.eq(opened and opened.title, "test_fails", "named by the test")
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
