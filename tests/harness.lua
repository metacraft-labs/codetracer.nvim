--- A small test harness for `nvim --headless`: named cases, assertions that
--- record rather than abort, `wait_for` over Neovim's event loop, and an exit
--- status the shell sees. No dependency beyond Neovim itself.
local M = { cases = {}, failures = 0, checks = 0 }

function M.case(name, fn)
  M.cases[#M.cases + 1] = { name = name, fn = fn }
end

local current = nil

function M.check(cond, message)
  M.checks = M.checks + 1
  if not cond then
    current.failed = true
    local info = debug.getinfo(2, "Sl")
    io.stdout:write(("    FAIL %s:%d: %s\n"):format(info.short_src, info.currentline, message or "check failed"))
  end
  return cond
end

function M.eq(actual, expected, message)
  return M.check(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(message or "eq", vim.inspect(expected), vim.inspect(actual))
  )
end

--- Wait (running the event loop) until `pred()` is true; false on timeout.
function M.wait_for(pred, timeout, what)
  local ok = vim.wait(timeout or 20000, function()
    local ok2, v = pcall(pred)
    return ok2 and v
  end, 20)
  if not ok and what then
    M.check(false, "timed out waiting for " .. what)
  end
  return ok
end

function M.run()
  for _, c in ipairs(M.cases) do
    current = c
    io.stdout:write("  " .. c.name .. "\n")
    local ok, err = xpcall(c.fn, debug.traceback)
    if not ok then
      c.failed = true
      io.stdout:write("    ERROR " .. tostring(err) .. "\n")
    end
    if c.failed then
      M.failures = M.failures + 1
      io.stdout:write("  [FAILED] " .. c.name .. "\n")
    else
      io.stdout:write("  [OK] " .. c.name .. "\n")
    end
  end
  io.stdout:write(("%d case(s), %d failed, %d check(s)\n"):format(#M.cases, M.failures, M.checks))
  io.stdout:flush()
  vim.cmd((M.failures > 0 or #M.cases == 0) and "cquit 1" or "qall!")
end

return M
