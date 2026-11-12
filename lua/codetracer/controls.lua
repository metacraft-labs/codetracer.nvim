--- The debugger controls' strip (Editor-Hosted-Front-Ends §E11): the
--- terminal's top-bar controls — reverse and forward next, step in, step out
--- and continue, run to entry, Stop — as the server sends them
--- (`controls/state`), drawn at the right of the tab line while a session's
--- tab page is current, one click region per control.
---
--- The tab line is the row Neovim already shows for CodeTracer's session tab
--- pages, so the strip costs no window row and does not repeat in every
--- source window (Q7; VS Code's `debug.toolBarLocation: commandCenter`). A
--- tab line the user (or a plugin: bufferline, lualine, heirline) owns is
--- left alone: `controls()` returns the same strip as a component to place.
---
--- Statusline click regions: `:help 'statusline'`, items `@` and `X`.
local state = require("codetracer.state")

local M = {}

--- The `'tabline'` and `'showtabline'` the user had when CodeTracer took the
--- tab line, restored when the last session closes; nil while not taken.
local saved = nil

--- The tab line expression CodeTracer sets.
M.EXPR = "%!v:lua.require'codetracer.controls'.tabline()"

local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

--- The strip for `session`, in statusline syntax: each control's glyph in a
--- click region; a disabled control dimmed and without one.
function M.strip(session)
  if session == nil or session.controls == nil then
    return ""
  end
  local glyphs = state.opts.controls_glyphs or "unicode"
  local parts = {}
  for i, b in ipairs(session.controls) do
    local glyph = (b.glyphs and b.glyphs[glyphs]) or b.label
    if b.enabled then
      parts[#parts + 1] = ("%%#CodeTracerControl#%%%d@v:lua.CodeTracerControlClick@ %s %%X"):format(i, escape(glyph))
    else
      parts[#parts + 1] = ("%%#CodeTracerControlDisabled# %s "):format(escape(glyph))
    end
  end
  return table.concat(parts) .. "%#TabLineFill#"
end

--- The current tab page's strip, for a tab line or status line component the
--- user owns (`require("codetracer").controls()`).
function M.component()
  return M.strip(state.current_session())
end

--- A tab page's label as Neovim's own tab line writes it: the current
--- window's buffer name, shortened, with `+` when it is modified.
local function tab_label(tab)
  local win = vim.api.nvim_tabpage_get_win(tab)
  local buf = vim.api.nvim_win_get_buf(win)
  local session = state.session_of_tab(tab)
  local name
  if session and session.title and session.title ~= "" then
    name = session.title
  else
    name = vim.fn.pathshorten(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:."))
    if name == "" then
      name = "[No Name]"
    end
  end
  local modified = vim.bo[buf].modified and " +" or ""
  return name .. modified
end

--- The tab line CodeTracer draws: the tab pages on the left (click to
--- switch, as Neovim's own), the current session's controls on the right.
function M.tabline()
  local current = vim.api.nvim_get_current_tabpage()
  local out = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local hl = tab == current and "%#TabLineSel#" or "%#TabLine#"
    out[#out + 1] = ("%s%%%dT %s %%T"):format(hl, i, escape(tab_label(tab)))
  end
  out[#out + 1] = "%#TabLineFill#%="
  out[#out + 1] = M.strip(state.current_session())
  return table.concat(out)
end

--- Whether the strip goes in the tab line: the setting, and a tab line the
--- user has not set.
local function wants_tabline()
  local mode = state.opts.controls or "tabline"
  return mode == "tabline" and (vim.o.tabline == "" or vim.o.tabline == M.EXPR)
end

--- Take the tab line for the strip (the first session), or give it back
--- (the last session closed).
function M.sync()
  if next(state.sessions) ~= nil then
    if saved == nil and wants_tabline() then
      saved = { tabline = vim.o.tabline, showtabline = vim.o.showtabline }
      vim.o.tabline = M.EXPR
      vim.o.showtabline = 2
    end
  elseif saved ~= nil then
    if vim.o.tabline == M.EXPR then
      vim.o.tabline = saved.tabline
      vim.o.showtabline = saved.showtabline
    end
    saved = nil
  end
end

--- Apply `controls/state`.
function M.apply(session, params)
  session.controls = params.buttons or {}
  M.sync()
  vim.cmd.redrawtabline()
end

--- A click on a control: its operation, on the current tab page's session.
--- Global, because a click region can only name a global function.
function _G.CodeTracerControlClick(minwid, _, button)
  if button ~= "l" then
    return
  end
  local session = state.current_session()
  local b = session and session.controls and session.controls[minwid]
  if b and b.enabled then
    require("codetracer").run(b.operation, nil, session)
  end
end

return M
