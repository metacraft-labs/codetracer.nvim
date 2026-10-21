--- A small test harness for `nvim --headless`: named cases, assertions that
--- record rather than abort, and an exit status the shell sees. No dependency
--- beyond Neovim itself.
---
--- THE CASES RUN IN A COROUTINE, AND WAITING YIELDS TO NEOVIM'S MAIN LOOP.
--- `vim.wait` would block it, and the main loop is where Neovim fires the
--- autocommands a user's actions cause (`WinResized`, `WinScrolled`): a suite
--- that waited with `vim.wait` would only ever see the plugin's behaviour with
--- those events missing. Start a suite with `nvim --headless -c "luafile …"`
--- so the main loop runs after the file is loaded.
local M = { cases = {}, failures = 0, checks = 0 }

function M.case(name, fn)
  M.cases[#M.cases + 1] = { name = name, fn = fn }
end

function M.check(cond, message)
  M.checks = M.checks + 1
  if not cond then
    M.current.failed = true
    local info = debug.getinfo(2, "Sl")
    if info.short_src:match("harness%.lua$") then
      info = debug.getinfo(3, "Sl")
    end
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

--- Let Neovim's main loop run for about `ms` milliseconds.
function M.sleep(ms)
  local co = coroutine.running()
  vim.defer_fn(function()
    coroutine.resume(co)
  end, ms or 0)
  coroutine.yield()
end

--- Wait, with the main loop running, until `pred()` is true; false on
--- timeout (recorded as a failure when `what` names the wait).
function M.wait_for(pred, timeout, what)
  local deadline = vim.uv.now() + (timeout or 20000)
  while true do
    local ok, v = pcall(pred)
    if ok and v then
      return true
    end
    if vim.uv.now() >= deadline then
      if what then
        M.check(false, "timed out waiting for " .. what)
      end
      return false
    end
    M.sleep(20)
  end
end

local function finish()
  io.stdout:write(("%d case(s), %d failed, %d check(s)\n"):format(#M.cases, M.failures, M.checks))
  io.stdout:flush()
  vim.cmd((M.failures > 0 or #M.cases == 0) and "cquit 1" or "qall!")
end

function M.run()
  local co = coroutine.create(function()
    for _, c in ipairs(M.cases) do
      M.current = c
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
      io.stdout:flush()
    end
    finish()
  end)
  -- Started from the main loop, so the file that defined the cases has
  -- finished loading first.
  vim.schedule(function()
    local ok, err = coroutine.resume(co)
    if not ok then
      io.stdout:write("harness: " .. tostring(err) .. "\n")
      vim.cmd("cquit 1")
    end
  end)
end

return M
