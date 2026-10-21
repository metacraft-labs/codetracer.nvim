--- `:checkhealth codetracer`: the Neovim version, the pane server binary, and
--- whether it speaks a protocol this plugin understands.
local M = {}

function M.check()
  local health = vim.health
  health.start("codetracer.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required (vim.lsp.rpc.start, nvim_open_win splits)")
  end

  local ct = require("codetracer")
  local cmd = ct.server_cmd()
  local exe = cmd[1]
  if vim.fn.executable(exe) ~= 1 then
    health.error(
      ("pane server not found: %s"):format(exe),
      { "Install CodeTracer, or set $CODETRACER_TUI / setup({ cmd = { '/path/to/codetracer-tui', '--pane-server' } })" }
    )
    return
  end
  health.ok("pane server: " .. vim.fn.exepath(exe))

  local state = require("codetracer.state")
  if state.conn and state.conn.info then
    local info = state.conn.info
    health.ok(("running: %s, protocol %d"):format(info.serverInfo and info.serverInfo.version or "?", info.protocolVersion))
    return
  end

  -- Ask a fresh server for its protocol version, then stop it.
  local rpc = require("codetracer.rpc")
  local done, result, failure = false, nil, nil
  rpc.start({
    cmd = cmd,
    env = state.opts.env,
    capabilities = { media = { "text" }, tabs = true, mouseResize = true },
    on_notification = function() end,
  }, function(conn, err)
    if conn == nil then
      failure = err
      done = true
      return
    end
    result = conn.info
    rpc.stop(conn, function()
      done = true
    end)
  end)
  vim.wait(10000, function()
    return done
  end, 20)
  if failure then
    health.error("the pane server did not initialize: " .. failure)
  elseif result then
    health.ok(("protocol %d (%s)"):format(result.protocolVersion, result.serverInfo and result.serverInfo.version or "?"))
    local dap = result.capabilities and result.capabilities.dap
    if dap and dap ~= vim.NIL then
      health.ok("DAP endpoint available (require('codetracer').dap_adapter() for nvim-dap)")
    else
      health.info("this server offers no DAP endpoint")
    end
  else
    health.warn("the pane server did not answer within 10 s")
  end
end

return M
