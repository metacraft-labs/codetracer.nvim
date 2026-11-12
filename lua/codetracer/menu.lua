--- Nim's compile-time tracing from the editor (Editor-Hosted-Front-Ends
--- §E12): a CodeTracer submenu in Neovim's right-click menu (|popup-menu|)
--- on a Nim file while a session is open — trace the macro, the static
--- block or the constant under the cursor, or evaluate the NimScript — and
--- the same operations as `:CodeTracer` commands.
---
--- A trace runs codetracer-nim's nimsuggest (or `nim e --trace`) over the
--- saved file at the cursor; its recording opens in a tab page of its own.
--- Neovim moves the cursor to the clicked position before it shows the menu
--- (|'mousemodel'| `popup_setpos`, the default), so the item acts where it
--- was opened.
local state = require("codetracer.state")

local M = {}

--- Label, operation: what the submenu offers.
M.ITEMS = {
  { "Trace macro", "editor.trace-macro-at-cursor" },
  { "Trace static block", "editor.trace-static-block-at-cursor" },
  { "Trace constant", "editor.trace-constant-at-cursor" },
  { "Evaluate with nim e", "editor.trace-eval" },
  -- Generated-Code-Listing §13.4: what the line compiled to, in the Low
  -- Level Code pane beside the source.
  { "View generated C", "view.generated-c-source" },
  { "View disassembly", "view.disassembly" },
}

local function is_nim(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.bo[buf].filetype == "nim" or name:match("%.nim$") ~= nil or name:match("%.nims$") ~= nil
end

--- Run `operation` at the current window's cursor: the window is reported
--- first, since the server acts at the cursor it was last told of.
function M.run(operation)
  local session = state.current_session()
  if session == nil then
    vim.notify("codetracer: this tab page shows no CodeTracer session", vim.log.levels.WARN)
    return
  end
  require("codetracer.source").report_cursor(session, vim.api.nvim_get_current_win())
  require("codetracer").run(operation, nil, session)
end

--- `MenuPopup`: the submenu, for a Nim file in a session's tab page.
function M.on_popup()
  pcall(vim.cmd, "aunmenu PopUp.CodeTracer")
  if state.current_session() == nil or not is_nim(vim.api.nvim_get_current_buf()) then
    return
  end
  for _, item in ipairs(M.ITEMS) do
    local label = item[1]:gsub(" ", "\\ ")
    vim.cmd(("anoremenu PopUp.CodeTracer.%s <Cmd>lua require('codetracer.menu').run(%q)<CR>"):format(label, item[2]))
  end
end

return M
