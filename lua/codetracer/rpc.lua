--- The connection to CodeTracer's pane server: `codetracer-tui --pane-server`
--- as a child process, spoken to with JSON-RPC 2.0 in the LSP base protocol's
--- framing through Neovim's own client for it, `vim.lsp.rpc`. Nothing here
--- frames, correlates or supervises by hand.
local M = {}

--- The protocol versions this plugin understands (the server's
--- `initialize` answer names its own; any other is refused).
M.SUPPORTED_PROTOCOLS = { [1] = true }

---@class codetracer.Connection
---@field client table the `vim.lsp.rpc` client
---@field info table|nil the server's `initialize` result
---@field closed boolean

--- Start the server and initialize it.
---@param opts {cmd: string[], env: table|nil, capabilities: table, on_notification: fun(method: string, params: table), on_exit: fun(code: integer, signal: integer)|nil}
---@param on_ready fun(conn: codetracer.Connection|nil, err: string|nil)
function M.start(opts, on_ready)
  local conn = { closed = false }
  local dispatchers = {
    notification = function(method, params)
      -- Delivered in arrival order: a request's answer is scheduled before
      -- the notifications the server sends after it.
      vim.schedule(function()
        opts.on_notification(method, params or {})
      end)
    end,
    server_request = function(method, _)
      return nil, { code = -32601, message = "codetracer.nvim answers no requests: " .. method }
    end,
    on_exit = function(code, signal)
      conn.closed = true
      if opts.on_exit then
        vim.schedule(function()
          opts.on_exit(code, signal)
        end)
      end
    end,
    on_error = function(code, err)
      vim.schedule(function()
        vim.notify(("codetracer: transport error %s: %s"):format(code, vim.inspect(err)), vim.log.levels.ERROR)
      end)
    end,
  }
  local ok, client = pcall(vim.lsp.rpc.start, opts.cmd, dispatchers, { env = opts.env })
  if not ok or client == nil then
    on_ready(nil, "could not start " .. table.concat(opts.cmd, " ") .. ": " .. tostring(client))
    return
  end
  conn.client = client

  client.request("initialize", {
    capabilities = opts.capabilities,
    keymapOverrides = {},
  }, function(err, result)
    if err then
      on_ready(nil, "initialize failed: " .. (err.message or vim.inspect(err)))
      return
    end
    if not M.SUPPORTED_PROTOCOLS[result.protocolVersion] then
      on_ready(
        nil,
        ("the server speaks protocol %s; this codetracer.nvim understands %s"):format(
          tostring(result.protocolVersion),
          table.concat(vim.tbl_keys(M.SUPPORTED_PROTOCOLS), ", ")
        )
      )
      M.stop(conn)
      return
    end
    conn.info = result
    on_ready(conn, nil)
  end)
  return conn
end

--- A request; `cb(err, result)` runs on the main loop.
function M.request(conn, method, params, cb)
  if conn == nil or conn.closed then
    if cb then
      cb({ message = "the CodeTracer pane server is not running" }, nil)
    end
    return
  end
  conn.client.request(method, params or vim.empty_dict(), function(err, result)
    if cb then
      cb(err, result)
    end
  end)
end

--- A notification (no answer).
function M.notify(conn, method, params)
  if conn == nil or conn.closed then
    return
  end
  conn.client.notify(method, params or vim.empty_dict())
end

--- `shutdown`, then `exit` — the LSP convention the server follows.
function M.stop(conn, on_done)
  if conn == nil or conn.closed then
    if on_done then
      on_done()
    end
    return
  end
  conn.client.request("shutdown", vim.NIL, function()
    conn.client.notify("exit", vim.NIL)
    if on_done then
      on_done()
    end
  end)
end

return M
