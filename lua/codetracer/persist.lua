--- Taking part in Neovim's own session persistence (§E4, ED-AREQ9).
---
--- `:mksession` keeps the windows of a tab page — their arrangement and
--- sizes, the user's own windows among them — but a pane buffer (`nofile`)
--- comes back as an empty window. So when a session file is written, this
--- module writes its "extra" file beside it (`<session>x.vim`, which Neovim
--- sources at the end of loading the session): which recording each tab page
--- showed, in which mode, and which pane each window held. When the session
--- is loaded (`SessionLoadPost`), each recording is opened again and its tab
--- page ADOPTED: the panes go back into the windows they were in, at the
--- sizes the editor kept, and the editor's arrangement is reported to the
--- server as that mode's layout. The server's layout is only the fallback,
--- for a tab page the session file did not keep.
local state = require("codetracer.state")

local M = {}

local MARKER = '" codetracer.nvim: restores CodeTracer sessions (written on :mksession)'

--- What to remember of each session, by tab page and window number.
function M.snapshot()
  local out = {}
  for _, s in pairs(state.sessions) do
    if s.tab and vim.api.nvim_tabpage_is_valid(s.tab) then
      local windows = {}
      for nr, win in ipairs(vim.api.nvim_tabpage_list_wins(s.tab)) do
        local info = s.windows[win]
        if info then
          windows[tostring(nr)] = info.pane
        elseif win == s.frames_win then
          windows[tostring(nr)] = require("codetracer.images").PANE
        end
      end
      out[#out + 1] = {
        trace = s.trace,
        mode = s.mode,
        tab = vim.api.nvim_tabpage_get_number(s.tab),
        windows = windows,
      }
    end
  end
  return out
end

--- The extra file Neovim sources after the session file `session_file`.
function M.extra_file(session_file)
  return vim.fn.fnamemodify(session_file, ":r") .. "x.vim"
end

--- `SessionWritePost`: write (or remove) the extra file. A user's own extra
--- file, one this plugin did not write, is left alone.
function M.write(session_file)
  if session_file == nil or session_file == "" then
    return
  end
  local path = M.extra_file(session_file)
  local existing = io.open(path, "r")
  if existing then
    local first = existing:read("*l")
    existing:close()
    if first ~= MARKER then
      vim.notify(
        "codetracer: " .. path .. " is not this plugin's; CodeTracer sessions are not saved with this session",
        vim.log.levels.WARN
      )
      return
    end
  end
  local data = M.snapshot()
  if #data == 0 then
    if existing then
      os.remove(path)
    end
    return
  end
  local f = io.open(path, "w")
  if f == nil then
    return
  end
  f:write(MARKER, "\n")
  f:write("lua vim.g.codetracer_restore = vim.json.decode([==[", vim.json.encode(data), "]==])\n")
  f:close()
end

--- `SessionLoadPost`: reopen what the extra file named.
function M.on_session_load()
  local data = vim.g.codetracer_restore
  if data == nil or data == vim.NIL then
    return
  end
  vim.g.codetracer_restore = nil
  local ct = require("codetracer")
  local tabs = vim.api.nvim_list_tabpages()
  for _, saved in ipairs(data) do
    local tab = tabs[saved.tab]
    local map = {}
    if tab then
      local wins = vim.api.nvim_tabpage_list_wins(tab)
      for nr, pane in pairs(saved.windows or {}) do
        local win = wins[tonumber(nr)]
        if win then
          map[win] = pane
        end
      end
    end
    ct.open(saved.trace, nil, tab and { tab = tab, windows = map, mode = saved.mode } or nil)
  end
end

--- Put the session's panes back into the windows the editor restored.
function M.adopt(session, adopt)
  local layout = require("codetracer.layout")
  local panes = require("codetracer.panes")
  local images = require("codetracer.images")
  session.tab = adopt.tab
  vim.t[adopt.tab].codetracer_session = session.id
  session.windows = {}
  session.editor_win = nil
  local tree = layout.prune(session.layout)
  -- Each leaf of the mode's layout, by the pane it shows.
  local leaves = {}
  local function walk(node)
    if node.kind == "pane" or node.kind == "stack" then
      leaves[layout.shown_pane(node)] = node
      return
    end
    for _, c in ipairs(node.children or {}) do
      walk(c)
    end
  end
  if tree then
    walk(tree)
  end

  session.realising = true
  local complete = tree ~= nil
  local found = {}
  for win, name in pairs(adopt.windows) do
    if vim.api.nvim_win_is_valid(win) then
      if name == images.PANE then
        session.frames_open = true
        session.frames_win = win
        local pane = state.pane(session, name)
        vim.api.nvim_win_set_buf(win, panes.ensure_buf(session, pane))
        panes.style_window(win)
      else
        local node = leaves[name] or { kind = "pane", pane = name }
        node.win = win
        found[name] = true
        session.windows[win] = { pane = name, node = node }
        if name == "editor" then
          session.editor_win = win
        else
          local pane = state.pane(session, name)
          vim.api.nvim_win_set_buf(win, panes.ensure_buf(session, pane))
          panes.style_window(win)
        end
      end
    end
  end
  for name in pairs(leaves) do
    if not found[name] then
      complete = false
    end
  end
  session.realised = complete and tree or nil
  session.realising = false

  -- Every adopted pane is shown at its window's size; the arrangement the
  -- editor kept becomes the mode's layout.
  for win, info in pairs(session.windows) do
    if info.pane ~= "editor" then
      panes.report_size(session, state.pane(session, info.pane), win)
    end
  end
  if session.frames_win then
    panes.report_size(session, state.pane(session, images.PANE), session.frames_win)
  end
  session.expected_sizes = {}
  for win in pairs(session.windows) do
    session.expected_sizes[win] = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
  end
  if session.realised then
    layout.report_edit(session, layout.measured(session.realised), {})
  end
  require("codetracer.source").refresh(session)
end

return M
