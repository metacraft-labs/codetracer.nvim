--- A neotest strategy that records the test instead of only running it
--- (Editor-Hosted-Front-Ends §E10, Q5): for Neovim users who already run
--- their tests with neotest (https://github.com/nvim-neotest/neotest).
---
---   require("neotest").run.run({ strategy = require("codetracer.neotest").strategy })
---
--- neotest calls a strategy as `strategy(spec, context)` and expects a
--- process back (`neotest.Process`: `result`, `output`, `output_stream`,
--- `is_complete`, `attach`, `stop`; `neotest.client.strategies`).
---
--- A test CodeTracer's own catalog knows — the session's Test Results, the
--- tests `source/tests` puts in the file — is recorded the way every
--- CodeTracer surface records it (the Test Results pane's ⏵, `ct
--- record-test`), and the process completes when its recording opens in a
--- tab page of its own. Any other test is the adapter's command recorded by
--- `ct record -o <folder> <program> -- <args>` through neotest's own
--- integrated strategy, and the folder is opened when it holds a
--- recording. Either way neotest reads the run's verdict through its
--- adapter, as for any strategy.
local state = require("codetracer.state")

local M = {}

local function norm(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

--- The session and the CodeTracer test (`source/tests`) for neotest's
--- `position`: by name in the position's file, else the test whose line is
--- in the position's range (rows are 0-based; an attribute line just above
--- the definition counts).
function M.control_for(position)
  if position == nil or position.path == nil then
    return nil
  end
  local file = norm(position.path)
  local by_range
  for _, s in pairs(state.sessions) do
    for _, c in ipairs((s.source_tests or {})[file] or {}) do
      if c.name == position.name then
        return s, c
      end
      local r = position.range
      if by_range == nil and r and c.line - 1 >= r[1] - 1 and c.line - 1 <= r[3] then
        by_range = { s, c }
      end
    end
  end
  if by_range then
    return by_range[1], by_range[2]
  end
end

--- The process for a test recorded through CodeTracer's catalog: complete
--- when the recording opens (`session/opened`), 0; 1 if it is stopped first.
function M.record_process(session, control)
  local nio = require("nio")
  local done = nio.control.future()
  local message = "recording " .. control.name .. " with CodeTracer…"
  local au
  au = vim.api.nvim_create_autocmd("User", {
    pattern = "CodeTracerNotification",
    callback = function(ev)
      if ev.data and ev.data.method == "session/opened" and not done.is_set() then
        message = "recorded " .. control.name .. ": " .. tostring(ev.data.params.trace)
        done.set(0)
        return true
      end
    end,
  })
  vim.schedule(function()
    require("codetracer.tests").record(session, control)
  end)
  local output_path = nio.fn.tempname()
  return {
    is_complete = function()
      return done.is_set()
    end,
    output = function()
      vim.fn.writefile({ message }, output_path)
      return output_path
    end,
    output_stream = function()
      return function()
        done.wait()
        return nil
      end
    end,
    attach = function() end,
    stop = function()
      if not done.is_set() then
        pcall(vim.api.nvim_del_autocmd, au)
        done.set(1)
      end
    end,
    result = function()
      return done.wait()
    end,
  }
end

--- The neotest strategy.
function M.strategy(spec, context)
  local session, control = M.control_for(context and context.position)
  if control then
    return M.record_process(session, control)
  end
  local nio = require("nio")
  local folder = nio.fn.tempname()
  local ct = vim.env.CT_BIN or "ct"
  local cmd = spec.command
  local wrapped = vim.deepcopy(spec)
  wrapped.command = { ct, "record", "-o", folder, cmd[1], "--" }
  vim.list_extend(wrapped.command, cmd, 2)
  wrapped.strategy = type(spec.strategy) == "table" and spec.strategy or {}
  local proc = require("neotest.client.strategies.integrated")(wrapped)
  local result = proc.result
  proc.result = function()
    local code = result()
    if
      #vim.fn.glob(folder .. "/*.ct", false, true) > 0 or vim.fn.filereadable(folder .. "/trace_metadata.json") == 1
    then
      vim.schedule(function()
        require("codetracer").open(folder)
      end)
    end
    return code
  end
  return proc
end

return M
