--- Tests from the source (Editor-Hosted-Front-Ends §E10): each test of the
--- file the source window shows is a sign on its line — `▶`, or its last
--- verdict — and a click on the sign records the test and opens its
--- recording in a tab page of its own. `:CodeTracer test-at-cursor` does the
--- same for the test the cursor is in.
---
--- The tests are CodeTracer's own (`ct test discover`, the session's Test
--- Results catalog), sent by the server as `source/tests` for the shown
--- file; a press is the Test Results pane's ⏵ (`tests.open-test`), so the
--- sign and the pane cannot disagree about what a test is or what it did.
---
--- The click: a buffer-local `<LeftMouse>` mapping in a buffer that has
--- tests, which acts when the press is in the sign column of a test's line
--- and passes every other press through unchanged. A buffer where the user
--- maps `<LeftMouse>` themselves keeps their mapping; the command still
--- works there.
local state = require("codetracer.state")

local M = {}

M.namespace = vim.api.nvim_create_namespace("codetracer.tests")

--- buffer → true while CodeTracer's `<LeftMouse>` is mapped there.
local clicking = {}

local function norm(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local SIGN = { passed = "✓", failed = "✗", running = "⟳" }
local HL = { passed = "CodeTracerTestPassed", failed = "CodeTracerTestFailed" }

--- The test controls `session` holds for `buf`'s file, by line.
local function controls_of(session, buf)
  local tests = session and session.source_tests
  if tests == nil or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return tests[norm(vim.api.nvim_buf_get_name(buf))]
end

--- The session whose tests `buf` shows, if any.
local function session_of_buf(buf)
  local current = state.current_session()
  if current and controls_of(current, buf) then
    return current
  end
  for _, s in pairs(state.sessions) do
    if controls_of(s, buf) then
      return s
    end
  end
end

--- Record the test `control` names and open its recording.
function M.record(session, control)
  if not (control.open and control.open.enabled == false) then
    require("codetracer.panes").run(session, "testResults", "tests.open-test", { args = { path = control.testId } })
  else
    vim.notify("codetracer: " .. (control.open.title or "this test cannot be recorded now"), vim.log.levels.WARN)
  end
end

--- The control on `line` (1-based) of `buf`, or nil.
local function control_on(session, buf, line)
  for _, c in ipairs(controls_of(session, buf) or {}) do
    if c.line == line then
      return c
    end
  end
end

local function unmap_click(buf)
  if clicking[buf] then
    pcall(vim.keymap.del, "n", "<LeftMouse>", { buffer = buf })
    clicking[buf] = nil
  end
end

--- The sign-column click in `buf`: a press on a test's sign records it;
--- any other press is Neovim's own.
local function map_click(buf)
  if clicking[buf] then
    return
  end
  local theirs = vim.fn.maparg("<LeftMouse>", "n", false, true)
  if not vim.tbl_isempty(theirs) then
    return
  end
  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= 0 and vim.api.nvim_win_get_buf(pos.winid) == buf then
      local info = vim.fn.getwininfo(pos.winid)[1]
      if pos.wincol <= info.textoff then
        local session = session_of_buf(buf)
        local control = session and control_on(session, buf, pos.line)
        if control then
          vim.schedule(function()
            M.record(session, control)
          end)
          return "<Ignore>"
        end
      end
    end
    return "<LeftMouse>"
  end, { buffer = buf, expr = true, desc = "codetracer: record the test on this line" })
  clicking[buf] = true
end

--- Draw `session`'s tests in `buf`: a sign per test, the click.
function M.render(session, buf)
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  local controls = controls_of(session, buf)
  if controls == nil or #controls == 0 then
    unmap_click(buf)
    return
  end
  local above = state.opts.tests_placement == "above-line" or state.opts.tests_placement == "both"
  local signs = state.opts.tests_placement ~= "above-line"
  local lines = vim.api.nvim_buf_line_count(buf)
  for _, c in ipairs(controls) do
    if c.line >= 1 and c.line <= lines then
      local opts = {}
      if signs then
        opts.sign_text = SIGN[c.state] or "▶"
        opts.sign_hl_group = HL[c.state] or "CodeTracerTestSign"
      end
      if above then
        opts.virt_lines = { { { ("▶ Record %s"):format(c.name), "CodeTracerTestSign" } } }
        opts.virt_lines_above = true
      end
      vim.api.nvim_buf_set_extmark(buf, M.namespace, c.line - 1, 0, opts)
    end
  end
  map_click(buf)
end

--- Draw the tests in every loaded buffer of `file`.
local function render_file(session, file)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and norm(vim.api.nvim_buf_get_name(buf)) == file then
      M.render(session, buf)
    end
  end
end

--- Apply `source/tests`.
function M.apply(session, params)
  session.source_tests = session.source_tests or {}
  local file = norm(params.file)
  session.source_tests[file] = params.controls or {}
  render_file(session, file)
end

--- A buffer shown in a window: its tests, if a session holds them.
function M.on_buf(buf)
  local session = session_of_buf(buf)
  if session then
    M.render(session, buf)
  end
end

--- `:CodeTracer test-at-cursor`: the test the cursor is in — the last test
--- whose line is at or above the cursor.
function M.at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local session = session_of_buf(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, c in ipairs(session and controls_of(session, buf) or {}) do
    if c.line <= line and (best == nil or c.line > best.line) then
      best = c
    end
  end
  if best == nil then
    vim.notify("codetracer: no test of CodeTracer's at the cursor", vim.log.levels.WARN)
    return
  end
  M.record(session, best)
end

return M
