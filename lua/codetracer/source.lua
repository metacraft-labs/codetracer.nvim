--- Source buffers (§E7). The source is the user's own file buffer in the
--- window the layout's `editor` leaf became. The server says where the
--- debugger is (`session/position`); the plugin moves there, marks the
--- execution line, reports which lines are visible (`source/viewport`) and
--- draws what the server computes for them (`source/decorations`): inline and
--- flow values as virtual text, breakpoints and tracepoints as signs.
local state = require("codetracer.state")
local rpc = require("codetracer.rpc")

local M = {}

M.namespace = vim.api.nvim_create_namespace("codetracer.source")
M.position_namespace = vim.api.nvim_create_namespace("codetracer.position")

local SIGNS = {
  breakpoint = { text = "●", hl = "CodeTracerBreakpointSign" },
  ["breakpoint-disabled"] = { text = "○", hl = "CodeTracerBreakpointDisabledSign" },
  tracepoint = { text = "◆", hl = "CodeTracerTracepointSign" },
}

local function editor_win(session)
  local win = session.editor_win
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  return nil
end

--- The buffer for `file`, loaded.
local function file_buf(file)
  local buf = vim.fn.bufadd(file)
  vim.bo[buf].buflisted = true
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  return buf
end

local function mark_position(session)
  local pos = session.position
  local buf = session.source_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      vim.api.nvim_buf_clear_namespace(b, M.position_namespace, 0, -1)
    end
  end
  if pos == nil or buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line = (pos.line or 1) - 1
  if line < 0 or line >= vim.api.nvim_buf_line_count(buf) then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, M.position_namespace, line, 0, {
    sign_text = "▶",
    sign_hl_group = "CodeTracerExecutionSign",
    line_hl_group = "CodeTracerExecutionLine",
    priority = 200,
  })
end

--- Apply `session/position`: show the file in the source window, the cursor
--- on the line, the line marked.
function M.apply_position(session, params)
  session.position = params
  local win = editor_win(session)
  if params.file and params.file ~= "" then
    local ok, buf = pcall(file_buf, params.file)
    if ok then
      session.source_buf = buf
      if win then
        vim.api.nvim_win_set_buf(win, buf)
        local line = math.max(1, math.min(params.line or 1, vim.api.nvim_buf_line_count(buf)))
        local col = math.max(0, (params.column or 1) - 1)
        pcall(vim.api.nvim_win_set_cursor, win, { line, col })
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zz")
        end)
      end
    end
  end
  mark_position(session)
  M.report_viewport(session)
end

--- Report the source window's visible lines, if they changed.
function M.report_viewport(session)
  local win = editor_win(session)
  if win == nil then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    return
  end
  local range = vim.api.nvim_win_call(win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  local first, last = range[1], range[2]
  local key = ("%s:%d:%d"):format(file, first, last)
  if session.viewport_sent == key then
    return
  end
  session.viewport_sent = key
  rpc.notify(state.conn, "source/viewport", { session = session.id, file = file, firstLine = first, lastLine = last })
end

local function value_text(list)
  local parts = {}
  for _, v in ipairs(list or {}) do
    parts[#parts + 1] = ("%s = %s"):format(v.name, v.value)
  end
  return table.concat(parts, ", ")
end

--- Apply `source/decorations` to the file's buffer, over its line range.
function M.apply_decorations(session, params)
  if params.file == nil or params.file == "" then
    return
  end
  local buf = vim.fn.bufnr(params.file)
  if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  session.decorations = session.decorations or {}
  session.decorations[params.file] = params
  local count = vim.api.nvim_buf_line_count(buf)
  local first = math.max(0, (params.firstLine or 1) - 1)
  local last = math.min(count, params.lastLine or count)
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, first, last)
  for _, row in ipairs(params.rows or {}) do
    local line = (row.line or 0) - 1
    if line >= 0 and line < count then
      local opts = { priority = 150 }
      local sign = row.mark and SIGNS[row.mark]
      if sign then
        opts.sign_text = sign.text
        opts.sign_hl_group = sign.hl
      end
      local chunks = {}
      if row.values and #row.values > 0 then
        chunks[#chunks + 1] = { "  " .. value_text(row.values), "CodeTracerInlineValue" }
      end
      if row.flow and #row.flow > 0 then
        chunks[#chunks + 1] = { "  " .. value_text(row.flow), "CodeTracerFlowValue" }
      end
      if #chunks > 0 then
        opts.virt_text = chunks
        opts.virt_text_pos = "eol"
      end
      if opts.sign_text or opts.virt_text then
        vim.api.nvim_buf_set_extmark(buf, M.namespace, line, 0, opts)
      end
    end
  end
end

--- After a rebuild: the source window shows the position again.
function M.refresh(session)
  if session.position then
    M.apply_position(session, session.position)
  else
    M.report_viewport(session)
  end
end

return M
