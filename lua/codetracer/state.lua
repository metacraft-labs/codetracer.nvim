--- The plugin's state: the connection, its sessions, and per session the tab
--- page that shows it and the pane buffers in it. Everything CodeTracer knows
--- (positions, values, layouts, keymaps) is the server's; this is only what
--- the editor needs to draw it.
local M = {}

---@class codetracer.Pane
---@field name string the wire name (`calltrace`, `state`, …)
---@field buf integer|nil
---@field rows table[] the last content, one entry per row (index 0-based)
---@field width integer
---@field height integer
---@field opened boolean `pane/open` sent and not closed
---@field bindings table[] the last `pane/keymap` bindings
---@field shadowed_sent string|nil the keys last reported shadowed, joined

---@class codetracer.Session
---@field id integer
---@field trace string
---@field mode string
---@field layout table the current mode's layout, as the server last sent it
---@field tab integer|nil
---@field panes table<string, codetracer.Pane>
---@field editor_win integer|nil the window the `editor` leaf became
---@field source_buf integer|nil the buffer shown there
---@field position table|nil the last `session/position`
---@field windows table<integer, table> window → realised leaf info
---@field expected_sizes table<integer, {integer, integer}>
---@field realising boolean

M.conn = nil
M.starting = false
M.waiting = {} -- callbacks waiting for the connection
M.sessions = {} ---@type table<integer, codetracer.Session>
M.operations = nil -- `operations/list`, once asked
M.opts = {}

function M.session_of_tab(tab)
  for _, s in pairs(M.sessions) do
    if s.tab == tab then
      return s
    end
  end
  return nil
end

function M.current_session()
  return M.session_of_tab(vim.api.nvim_get_current_tabpage())
end

function M.pane(session, name)
  local p = session.panes[name]
  if p == nil then
    p = { name = name, rows = {}, width = 0, height = 0, opened = false, bindings = {} }
    session.panes[name] = p
  end
  return p
end

--- The session and pane a buffer shows, if it is a pane buffer.
function M.pane_of_buf(buf)
  local ok, info = pcall(vim.api.nvim_buf_get_var, buf, "codetracer_pane")
  if not ok or type(info) ~= "table" then
    return nil, nil
  end
  local s = M.sessions[info.session]
  if s == nil then
    return nil, nil
  end
  return s, s.panes[info.pane]
end

return M
