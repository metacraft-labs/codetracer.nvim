--- codetracer.nvim — CodeTracer's panes in Neovim.
---
--- The plugin is a view over CodeTracer's pane server (`codetracer-tui
--- --pane-server`): the server owns the recording, the debugging session,
--- what is loaded, the layout of each mode and the key bindings; Neovim owns
--- the windows, the source buffers and the user's own configuration. See
--- `:help codetracer`.
local state = require("codetracer.state")
local rpc = require("codetracer.rpc")
local panes = require("codetracer.panes")
local layout = require("codetracer.layout")
local source = require("codetracer.source")
local hl = require("codetracer.highlights")

local M = {}

M.defaults = {
  --- The pane server: a command line, or nil to find `codetracer-tui` on PATH.
  cmd = nil,
  --- Extra environment for the server process.
  env = nil,
  --- Your own bindings in CodeTracer panes, which win over CodeTracer's
  --- keymap: `{ calltrace = { ["<Down>"] = fn_or_rhs }, ["*"] = { … } }`.
  mappings = {},
  --- `j`/`k` do what Down/Up do in a pane, unless you bind them yourself.
  vim_motions = true,
}

local function server_cmd()
  if state.opts.cmd then
    return state.opts.cmd
  end
  local exe = vim.env.CODETRACER_TUI or "codetracer-tui"
  return { exe, "--pane-server" }
end
M.server_cmd = server_cmd

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

local function on_notification(method, params)
  local session = params.session and state.sessions[params.session]
  if method == "pane/content" then
    if session then
      panes.apply_content(session, params)
    end
  elseif method == "pane/keymap" then
    if session then
      panes.apply_keymap(session, params)
    end
  elseif method == "layout/changed" then
    if session then
      local same = session.mode == params.mode and vim.deep_equal(session.layout, params.layout)
      session.mode = params.mode
      if not same or session.tab == nil or not vim.api.nvim_tabpage_is_valid(session.tab) then
        layout.realise(session, params.layout)
      end
    end
  elseif method == "session/position" then
    if session then
      source.apply_position(session, params)
    end
  elseif method == "source/decorations" then
    if session then
      source.apply_decorations(session, params)
    end
  end
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "CodeTracerNotification", data = { method = method, params = params } }
  )
end

-- ---------------------------------------------------------------------------
-- The connection
-- ---------------------------------------------------------------------------

--- Run `fn(conn)` once the server is up, starting it if needed.
function M.with_server(fn)
  if state.conn and not state.conn.closed then
    fn(state.conn)
    return
  end
  table.insert(state.waiting, fn)
  if state.starting then
    return
  end
  state.starting = true
  rpc.start({
    cmd = server_cmd(),
    env = state.opts.env,
    capabilities = { media = { "text" }, tabs = true, mouseResize = true },
    on_notification = on_notification,
    on_exit = function(code)
      state.conn = nil
      state.sessions = {}
      if code ~= 0 and not M._stopping then
        vim.notify("codetracer: the pane server exited with status " .. tostring(code), vim.log.levels.WARN)
      end
      M._stopping = false
    end,
  }, function(conn, err)
    state.starting = false
    local waiting = state.waiting
    state.waiting = {}
    if conn == nil then
      vim.notify("codetracer: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    state.conn = conn
    for _, f in ipairs(waiting) do
      f(conn)
    end
  end)
end

--- Stop the server (and with it every session).
function M.stop(on_done)
  M._stopping = true
  for _, s in pairs(state.sessions) do
    if s.tab and vim.api.nvim_tabpage_is_valid(s.tab) and #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(s.tab))
    end
  end
  state.sessions = {}
  rpc.stop(state.conn, on_done)
end

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

--- Open a recording in a new session, in its own tab page.
---@param trace string the recording's folder
---@param cb fun(session: codetracer.Session|nil, err: string|nil)|nil
function M.open(trace, cb)
  trace = vim.fn.fnamemodify(vim.fn.expand(trace), ":p"):gsub("/$", "")
  M.with_server(function(conn)
    rpc.request(conn, "session/open", { trace = trace }, function(err, result)
      if err then
        vim.notify(
          "codetracer: cannot open " .. trace .. ": " .. (err.message or vim.inspect(err)),
          vim.log.levels.ERROR
        )
        if cb then
          cb(nil, err.message)
        end
        return
      end
      local session = {
        id = result.session,
        trace = trace,
        mode = result.mode,
        layout = result.layout,
        panes = {},
        windows = {},
        expected_sizes = {},
        realising = false,
      }
      state.sessions[session.id] = session
      M.operations(function() end)
      layout.realise(session, result.layout)
      if cb then
        cb(session, nil)
      end
    end)
  end)
end

--- Make `session` the one the server acts on and show its tab page.
function M.activate(session)
  if session.tab and vim.api.nvim_tabpage_is_valid(session.tab) then
    if vim.api.nvim_get_current_tabpage() ~= session.tab then
      vim.api.nvim_set_current_tabpage(session.tab)
      return -- TabEnter activates it
    end
  end
  rpc.request(state.conn, "session/activate", { session = session.id })
end

--- Close a session and its tab page.
function M.close(session)
  session = session or state.current_session()
  if session == nil then
    return
  end
  rpc.request(state.conn, "session/close", { session = session.id })
  state.sessions[session.id] = nil
  if session.tab and vim.api.nvim_tabpage_is_valid(session.tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(session.tab))
  end
end

--- Pick a session to show (`vim.ui.select`).
function M.pick_session()
  rpc.request(state.conn, "session/list", nil, function(err, list)
    if err or list == nil or #list == 0 then
      vim.notify("codetracer: no sessions", vim.log.levels.INFO)
      return
    end
    vim.ui.select(list, {
      prompt = "CodeTracer session",
      format_item = function(s)
        return ("%s%s [%s]"):format(s.active and "* " or "  ", s.title ~= "" and s.title or s.trace, s.mode)
      end,
    }, function(choice)
      if choice and state.sessions[choice.session] then
        M.activate(state.sessions[choice.session])
      end
    end)
  end)
end

--- Run a catalogued operation on the current session (`:CodeTracer
--- step-over`), or a pane operation with its arguments.
function M.run(operation, argument, session)
  session = session or state.current_session()
  if session == nil then
    vim.notify("codetracer: this tab page shows no CodeTracer session", vim.log.levels.WARN)
    return
  end
  local _, pane = state.pane_of_buf(vim.api.nvim_get_current_buf())
  local params = { session = session.id, operation = M.resolve_operation(operation) }
  if argument and argument ~= "" then
    params.argument = argument
  end
  if pane then
    params.pane = pane.name
  end
  rpc.request(state.conn, "operation/run", params, function(err, result)
    if err then
      vim.notify("codetracer: " .. operation .. ": " .. (err.message or vim.inspect(err)), vim.log.levels.WARN)
    elseif result and result.detail and result.detail ~= "" then
      vim.notify("codetracer: " .. result.detail, vim.log.levels.INFO)
    end
  end)
end

--- `step-over` → `debugger.step-over`: a short name is the catalogue entry it
--- uniquely ends.
function M.resolve_operation(name)
  local ops = state.operations or {}
  for _, o in ipairs(ops) do
    if o.name == name then
      return name
    end
  end
  local found = nil
  for _, o in ipairs(ops) do
    if o.name:sub(-#name - 1) == "." .. name then
      if found then
        return name -- ambiguous: let the server say so
      end
      found = o.name
    end
  end
  return found or name
end

--- The operation catalogue, asked once.
function M.operations(cb)
  if state.operations then
    cb(state.operations)
    return
  end
  M.with_server(function(conn)
    rpc.request(conn, "operations/list", nil, function(err, result)
      if not err then
        state.operations = result
      end
      cb(state.operations or {})
    end)
  end)
end

--- An nvim-dap adapter for the active session (§Q3): the server's DAP
--- endpoint drives the same session the panes show.
function M.dap_adapter()
  local info = state.conn and state.conn.info
  local dap = info and info.capabilities and info.capabilities.dap
  if dap == nil or dap == vim.NIL then
    return nil
  end
  return { type = "server", host = dap.host, port = dap.port }
end

-- ---------------------------------------------------------------------------
-- The command
-- ---------------------------------------------------------------------------

local SUBCOMMANDS = {
  open = function(args)
    M.open(args[1] or vim.fn.getcwd())
  end,
  close = function()
    M.close()
  end,
  sessions = function()
    M.pick_session()
  end,
  mode = function()
    M.run("session.toggle-product-mode")
  end,
  ["stack-next"] = function()
    local s = state.current_session()
    if s then
      layout.stack_next(s, vim.api.nvim_get_current_win(), 1)
    end
  end,
  ["stack-previous"] = function()
    local s = state.current_session()
    if s then
      layout.stack_next(s, vim.api.nvim_get_current_win(), -1)
    end
  end,
  stop = function()
    M.stop()
  end,
}

function M.command(opts)
  local args = opts.fargs
  local sub = table.remove(args, 1)
  if sub == nil then
    M.pick_session()
    return
  end
  local f = SUBCOMMANDS[sub]
  if f then
    f(args)
    return
  end
  M.run(sub, table.concat(args, " "))
end

function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  if #words > 2 or (#words == 2 and arglead == "") then
    if words[2] == "open" then
      return vim.fn.getcompletion(arglead, "dir")
    end
    return {}
  end
  local out = vim.tbl_keys(SUBCOMMANDS)
  for _, o in ipairs(state.operations or {}) do
    out[#out + 1] = o.name
    local short = o.name:match("%.([^%.]+)$")
    if short then
      out[#out + 1] = short
    end
  end
  table.sort(out)
  return vim.tbl_filter(function(c)
    return c:sub(1, #arglead) == arglead
  end, vim.fn.uniq(out))
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local group = nil

function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  hl.setup()
  group = vim.api.nvim_create_augroup("codetracer", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = hl.setup })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      local s = state.current_session()
      if s then
        layout.check_sizes(s)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      for _, s in pairs(state.sessions) do
        if s.windows and s.windows[win] then
          layout.window_closed(s, win)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      local s = state.current_session()
      if s and state.conn then
        rpc.request(state.conn, "session/activate", { session = s.id })
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved", "BufWinEnter" }, {
    group = group,
    callback = function()
      local s = state.current_session()
      if s and s.editor_win == vim.api.nvim_get_current_win() then
        source.report_viewport(s)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if state.conn then
        M._stopping = true
        rpc.stop(state.conn)
      end
    end,
  })
end

return M
