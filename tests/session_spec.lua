--- CodeTracer sessions saved with `:mksession` and restored with `nvim -S`
--- (§E4, ED-AREQ9), against a real pane server over a real recording (the
--- variables of `integration_spec.lua`). Two Neovims:
---
---   CT_SESSION_PHASE=save  opens the recording, widens the State pane, opens
---                          a window of the user's own beside the source, and
---                          writes $CT_SESSION_FILE with :mksession;
---   CT_SESSION_PHASE=load  is started with `-S $CT_SESSION_FILE` and checks
---                          that the panes came back in the windows the
---                          session kept, connected to a new server.
---
--- `just test-integration` runs both.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path

local t = require("harness")
local phase = vim.env.CT_SESSION_PHASE
local file = vim.env.CT_SESSION_FILE
local expect_file = file and (file .. ".expect.json")
local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_TRACE
if not (phase and file and server and trace) then
  io.stdout:write("needs CT_SESSION_PHASE, CT_SESSION_FILE, CODETRACER_TUI and CODETRACER_TEST_TRACE\n")
  vim.cmd("cquit 2")
end

local ct = require("codetracer")
ct.setup({ cmd = { server, "--pane-server" } })
local state = require("codetracer.state")

local function window_of(session, pane)
  for win, info in pairs(session.windows) do
    if info.pane == pane and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  return nil
end

local function shown(session)
  local out = {}
  for _, info in pairs(session.windows) do
    out[#out + 1] = info.pane
  end
  table.sort(out)
  return out
end

if phase == "save" then
  vim.o.columns = 200
  vim.o.lines = 60
  t.case("a CodeTracer session is written with :mksession", function()
    local s
    ct.open(trace, function(x)
      s = x
    end)
    t.wait_for(function()
      return s and s.position and s.panes.state and s.panes.state.rows[0] ~= nil
    end, 60000, "the session")
    local win = window_of(s, "state")
    vim.api.nvim_win_set_width(win, vim.api.nvim_win_get_width(win) + 10)
    -- A window of the user's own, beside the source window.
    local own = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "the user's own file" }, own)
    vim.api.nvim_set_current_win(s.editor_win)
    vim.cmd("vsplit " .. vim.fn.fnameescape(own))
    t.sleep(200) -- WinResized, from the main loop
    vim.cmd("mksession! " .. vim.fn.fnameescape(file))
    local extra = require("codetracer.persist").extra_file(file)
    t.check(vim.fn.filereadable(extra) == 1, "the extra file is written beside the session")
    vim.fn.writefile({
      vim.json.encode({
        state_width = vim.api.nvim_win_get_width(window_of(s, "state")),
        panes = shown(s),
        own = own,
        trace = s.trace,
      }),
    }, expect_file)
    local done = false
    ct.stop(function()
      done = true
    end)
    t.wait_for(function()
      return done
    end, 10000, "shutdown")
  end)
else
  t.case("the session comes back connected, in the windows it was saved in", function()
    local expect = vim.json.decode(table.concat(vim.fn.readfile(expect_file), "\n"))
    local s
    t.wait_for(function()
      for _, x in pairs(state.sessions) do
        s = x
      end
      return s and s.position and s.panes.state and s.panes.state.rows[0] ~= nil
    end, 60000, "the restored session")
    if s == nil then
      return
    end
    t.eq(s.trace, expect.trace, "the same recording")
    t.eq(shown(s), expect.panes, "the same panes")
    local win = window_of(s, "state")
    t.check(win ~= nil, "the state pane has its window")
    if win then
      t.eq(vim.api.nvim_win_get_width(win), expect.state_width, "at the width the session kept")
      t.eq(vim.api.nvim_buf_line_count(s.panes.state.buf), vim.api.nvim_win_get_height(win), "painted for its window")
      t.check(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match("^codetracer://") ~= nil, "a pane buffer")
    end
    -- The user's own window is still there, beside the panes.
    local own = false
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(s.tab)) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) == expect.own then
        own = true
      end
    end
    t.check(own, "the user's own window is kept")
    -- Connected: a step moves the restored session.
    local tick = s.position.tick
    ct.run("step-over", nil, s)
    t.wait_for(function()
      return s.position.tick ~= tick
    end, 30000, "a step to move the restored session")
    local done = false
    ct.stop(function()
      done = true
    end)
    t.wait_for(function()
      return done
    end, 10000, "shutdown")
    os.remove(expect.own)
  end)
end

t.run()
