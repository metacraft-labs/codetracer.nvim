--- CodeTracer's debugger keys in the session's source buffers
--- (Editor-Hosted-Front-Ends §E11, Q6): F10 steps over where you read the
--- code, not only in CodeTracer's panes.
---
--- The keys are the server's — the `editor` pane's bindings in the user's
--- CodeTracer keymap (`pane/keymap`) — narrowed to what is safe to bind in a
--- buffer the user edits:
---   * only the debugger's operations and the breakpoint and tracepoint
---     toggles (`debugger.*`, `editor.toggle-breakpoint`,
---     `editor.toggle-tracepoint`) — never CodeTracer's own text editing;
---   * only function-key chords (`<F10>`, `<S-F11>`, `<C-F5>`), which no
---     normal-mode command uses: a printable key or a Ctrl chord is one of
---     Neovim's own commands, and binding it would take that from the user.
--- A key the user maps themselves — buffer-local or global — wins and is
--- left alone (ED-AREQ6).
---
--- Bound buffer-locally while the session's tab page is current, in the
--- buffer its source window shows; unbound when the tab page is left or the
--- window shows another buffer. `setup({ source_keys = false })` binds none.
local state = require("codetracer.state")
local keys = require("codetracer.keys")

local M = {}

--- buffer → { canonical lhs → lhs } of the keys bound here.
local bound = {}

local function wanted(operation)
  return operation:match("^debugger%.") ~= nil
    or operation == "editor.toggle-breakpoint"
    or operation == "editor.toggle-tracepoint"
end

local function function_key(lhs)
  return lhs:match("^<[%a%-]*[Ff]%d+>$") ~= nil
end

--- The bindings of `session`'s `pane/keymap` for the editor that are safe to
--- bind in a source buffer: `{ {lhs, operation}, … }`, the first binding of
--- a key winning.
function M.bindings(session)
  local out, seen = {}, {}
  for _, b in ipairs(session.source_bindings or {}) do
    local lhs = keys.to_lhs(b.key)
    if lhs and function_key(lhs) and wanted(b.operation or "") and not b.shadowedBy then
      local c = keys.canonical(lhs)
      if not seen[c] then
        seen[c] = true
        out[#out + 1] = { lhs = lhs, operation = b.operation }
      end
    end
  end
  return out
end

--- Whether the user maps `lhs` in normal mode themselves, in `buf` or
--- globally (not one of CodeTracer's own).
local function users(buf, lhs)
  local m = vim.fn.maparg(lhs, "n", false, true)
  if vim.tbl_isempty(m) then
    return false
  end
  local mine = bound[buf]
  if m.buffer == 1 and mine and mine[keys.canonical(lhs)] then
    return false
  end
  return true
end

--- Remove CodeTracer's keys from `buf`.
function M.unbind(buf)
  local mine = bound[buf]
  if mine == nil then
    return
  end
  if vim.api.nvim_buf_is_valid(buf) then
    for _, lhs in pairs(mine) do
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  bound[buf] = nil
end

--- Bind `session`'s keys in `buf`.
function M.bind(session, buf)
  if state.opts.source_keys == false or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M.unbind(buf)
  local mine = {}
  vim.api.nvim_buf_call(buf, function()
    for _, b in ipairs(M.bindings(session)) do
      if not users(buf, b.lhs) then
        local op = b.operation
        vim.keymap.set("n", b.lhs, function()
          require("codetracer").run(op, nil, session)
        end, { buffer = buf, desc = "codetracer: " .. op })
        mine[keys.canonical(b.lhs)] = b.lhs
      end
    end
  end)
  bound[buf] = mine
end

--- Follow what the current tab page shows: the keys in the buffer of the
--- current session's source window, and in no other buffer.
function M.sync()
  local session = state.current_session()
  local keep
  if session and session.editor_win and vim.api.nvim_win_is_valid(session.editor_win) then
    keep = vim.api.nvim_win_get_buf(session.editor_win)
  end
  for buf in pairs(bound) do
    if buf ~= keep then
      M.unbind(buf)
    end
  end
  if keep and bound[keep] == nil then
    M.bind(session, keep)
  end
end

--- Apply the editor's `pane/keymap`.
function M.apply(session, params)
  session.source_bindings = params.bindings or {}
  if session.editor_win and vim.api.nvim_win_is_valid(session.editor_win) then
    local buf = vim.api.nvim_win_get_buf(session.editor_win)
    if state.current_session() == session then
      M.bind(session, buf)
    end
  end
end

--- Which buffers carry CodeTracer's keys (for the tests).
function M.bound()
  return bound
end

return M
