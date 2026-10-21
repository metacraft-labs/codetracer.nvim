--- Pane buffers. A pane buffer is a screen, not a document: it holds exactly
--- the rows the server painted for the window's size, styled by semantic
--- highlight groups, with the server's hotspots and key bindings on it.
--- Scrolling, paging and searching are operations the server runs.
local state = require("codetracer.state")
local rpc = require("codetracer.rpc")
local keys = require("codetracer.keys")
local hl = require("codetracer.highlights")

local M = {}

--- Keys the plugin never takes from the editor in a pane buffer, whatever
--- the CodeTracer keymap binds: the command line and the window commands are
--- how the user drives the editor itself. They are reported shadowed, so the
--- server's keymap help shows them as the editor's.
M.RESERVED = { ":", "<C-w>" }

local function buf_name(session, pane)
  return ("codetracer://%d/%s"):format(session.id, pane.name)
end

--- The buffer for `pane`, created on first use.
function M.ensure_buf(session, pane)
  if pane.buf and vim.api.nvim_buf_is_valid(pane.buf) then
    return pane.buf
  end
  -- A buffer of that name already exists when a session file (`:mksession`)
  -- restored the windows a pane was in: it is taken over, not duplicated.
  local name = buf_name(session, pane)
  local buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      buf = b
    end
  end
  if buf == nil then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.b[buf].codetracer_pane = { session = session.id, pane = pane.name }
  pane.buf = buf
  -- `FileType codetracer` is where a user writes their own pane bindings; it
  -- runs before ours are installed, so theirs are seen and kept (§E6).
  vim.bo[buf].filetype = "codetracer"
  M.render(session, pane, true)
  M.install_keymap(session, pane)
  return buf
end

--- Window options a pane window gets: no gutter, no wrapping — the server
--- drew the row to the window's exact width.
function M.style_window(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.list = false
  wo.cursorline = false
  wo.spell = false
  wo.colorcolumn = ""
  wo.statuscolumn = ""
  wo.winfixbuf = false
end

--- The size a pane window offers its content, in cells.
function M.window_size(win)
  return vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
end

--- Apply a `pane/content` notification to the pane's model and buffer.
function M.apply_content(session, params)
  local pane = state.pane(session, params.pane)
  pane.width = params.width or pane.width
  pane.height = params.height or pane.height
  if params.full then
    pane.rows = {}
  end
  for i, row in ipairs(params.rows or {}) do
    local index = row.index or (i - 1)
    pane.rows[index] = row
  end
  -- A full update is exactly `height` rows; drop any beyond it.
  if params.full then
    for index in pairs(pane.rows) do
      if index >= pane.height then
        pane.rows[index] = nil
      end
    end
  end
  M.render(session, pane, params.full, params.rows)
  if params.image then
    require("codetracer.images").show(session, pane, params.image)
  end
end

local function set_row_marks(buf, index, row)
  for _, span in ipairs(row.spans or {}) do
    local len = #(row.text or "")
    local s = math.min(span.start or 0, len)
    local e = math.min(span["end"] or s, len)
    if e > s then
      if span.surface then
        vim.api.nvim_buf_set_extmark(buf, hl.namespace, index, s, {
          end_col = e,
          hl_group = hl.group(span.surface),
          priority = 100,
        })
      end
      if span.style then
        vim.api.nvim_buf_set_extmark(buf, hl.namespace, index, s, {
          end_col = e,
          hl_group = hl.group(span.style),
          priority = 110,
        })
      end
      for attr, group in pairs({
        bold = "CodeTracerBold",
        italic = "CodeTracerItalic",
        underline = "CodeTracerUnderline",
      }) do
        if span[attr] then
          vim.api.nvim_buf_set_extmark(buf, hl.namespace, index, s, {
            end_col = e,
            hl_group = group,
            priority = 120,
          })
        end
      end
    end
  end
end

--- Draw the model into the buffer: every row when `full`, else only `changed`.
function M.render(_, pane, full, changed)
  local buf = pane.buf
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  if full or changed == nil then
    local lines = {}
    for i = 0, math.max(pane.height, 0) - 1 do
      local row = pane.rows[i]
      lines[#lines + 1] = row and row.text or ""
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, hl.namespace, 0, -1)
    for i = 0, #lines - 1 do
      local row = pane.rows[i]
      if row then
        set_row_marks(buf, i, row)
      end
    end
  else
    local count = vim.api.nvim_buf_line_count(buf)
    for i, row in ipairs(changed) do
      local index = row.index or (i - 1)
      if index >= count then
        -- Grow with blank rows up to it (a resize reaches here first).
        local pad = {}
        for _ = count, index - 1 do
          pad[#pad + 1] = ""
        end
        vim.api.nvim_buf_set_lines(buf, count, count, false, pad)
        vim.api.nvim_buf_set_lines(buf, index, index, false, { row.text or "" })
        count = index + 1
      else
        vim.api.nvim_buf_set_lines(buf, index, index + 1, false, { row.text or "" })
      end
      vim.api.nvim_buf_clear_namespace(buf, hl.namespace, index, index + 1)
      set_row_marks(buf, index, row)
    end
  end
  vim.bo[buf].modifiable = false
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

--- Run an operation on the session, with `pane` focused first.
function M.run(session, pane_name, operation, extra)
  local params = { session = session.id, operation = operation, pane = pane_name }
  for k, v in pairs(extra or {}) do
    params[k] = v
  end
  rpc.request(state.conn, "operation/run", params, function(err, result)
    if err then
      vim.notify("codetracer: " .. operation .. ": " .. (err.message or vim.inspect(err)), vim.log.levels.WARN)
    elseif result and result.ok == false then
      vim.notify("codetracer: " .. operation .. ": " .. tostring(result.detail), vim.log.levels.WARN)
    end
  end)
end

--- The hotspot under the cursor of `win`, if any.
function M.hotspot_at(pane, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = pane.rows[cursor[1] - 1]
  if row == nil then
    return nil
  end
  local col = cursor[2]
  for _, h in ipairs(row.hotspots or {}) do
    if col >= (h.start or 0) and col < (h["end"] or 0) then
      return h
    end
  end
  return nil
end

--- `<CR>` / a click: the hotspot under the cursor; otherwise what the pane
--- binds to Enter.
function M.activate(buf, from_click)
  local session, pane = state.pane_of_buf(buf)
  if session == nil then
    return
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end
  local h = M.hotspot_at(pane, win)
  if h then
    M.run(session, pane.name, h.operation, { args = h.args })
    return
  end
  if from_click then
    return
  end
  for _, b in ipairs(pane.bindings) do
    if b.key == "Enter" and not b.shadowedBy then
      M.run(session, pane.name, b.operation)
      return
    end
  end
end

-- The mappings this plugin installed, per buffer, so a later keymap replaces
-- them and a user's own mapping is never mistaken for one of ours.
local ours = {}

local function user_maps(buf)
  local mine = ours[buf] or {}
  local found = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    local c = keys.canonical(m.lhs)
    if not mine[c] then
      found[c] = true
    end
  end
  return found
end

--- The user's own bindings for `pane` from `setup({ mappings = … })`:
--- `mappings[pane]` and `mappings["*"]` (every pane).
local function configured(pane_name)
  local out = {}
  local m = state.opts.mappings or {}
  for _, scope in ipairs({ "*", pane_name }) do
    for lhs, rhs in pairs(m[scope] or {}) do
      out[keys.canonical(lhs)] = { lhs = lhs, rhs = rhs }
    end
  end
  return out
end

--- Install the pane's bindings as buffer-local mappings, in the precedence of
--- §E6: the editor's own bindings for the pane first (from `setup` and from
--- `FileType codetracer` autocommands), then the CodeTracer keymap. The keys
--- left to the editor are reported (`keymap/shadowed`).
function M.install_keymap(session, pane)
  local buf = pane.buf
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local mine = ours[buf] or {}
  for c, lhs in pairs(mine) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    mine[c] = nil
  end
  ours[buf] = mine

  local user = user_maps(buf)
  local conf = configured(pane.name)
  for c, m in pairs(conf) do
    if not user[c] then
      vim.keymap.set("n", m.lhs, m.rhs, { buffer = buf, desc = "codetracer: user binding" })
      user[c] = true
    end
  end
  for _, r in ipairs(M.RESERVED) do
    user[keys.canonical(r)] = true
  end

  local function map(lhs, fn, desc)
    local c = keys.canonical(lhs)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
    mine[c] = lhs
  end

  -- `<CR>` and the mouse always reach the hotspots (§E6).
  if not user[keys.canonical("<CR>")] then
    map("<CR>", function()
      M.activate(buf, false)
    end, "codetracer: activate")
  end
  if not user[keys.canonical("<LeftRelease>")] then
    map("<LeftRelease>", function()
      M.activate(buf, true)
    end, "codetracer: click")
  end

  local shadowed = {}
  local taken = {}
  for _, b in ipairs(pane.bindings) do
    local lhs = keys.to_lhs(b.key)
    if lhs then
      local c = keys.canonical(lhs)
      if user[c] then
        shadowed[#shadowed + 1] = b.key
      elseif not taken[c] and not b.shadowedBy and c ~= keys.canonical("<CR>") then
        taken[c] = true
        local op = b.operation
        map(lhs, function()
          M.run(session, pane.name, op)
        end, "codetracer: " .. op)
      end
    end
  end

  -- Vim motions for the list keys, unless the user turned them off or bound
  -- the keys themselves.
  if state.opts.vim_motions ~= false then
    for alias, key in pairs({ j = "Down", k = "Up" }) do
      local c = keys.canonical(alias)
      if not user[c] and not taken[c] then
        for _, b in ipairs(pane.bindings) do
          if b.key == key and not b.shadowedBy then
            local op = b.operation
            map(alias, function()
              M.run(session, pane.name, op)
            end, "codetracer: " .. op)
            break
          end
        end
      end
    end
  end

  table.sort(shadowed)
  local joined = table.concat(shadowed, "\n")
  if pane.shadowed_sent ~= joined then
    pane.shadowed_sent = joined
    rpc.notify(state.conn, "keymap/shadowed", { pane = pane.name, keys = shadowed })
  end
end

--- Apply a `pane/keymap` notification.
function M.apply_keymap(session, params)
  local pane = state.pane(session, params.pane)
  pane.bindings = params.bindings or {}
  M.install_keymap(session, pane)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Tell the server the pane is shown at `win`'s size (`pane/open` the first
--- time, `pane/resize` after) — the size its viewport becomes.
function M.report_size(session, pane, win)
  local w, h = M.window_size(win)
  if w <= 0 or h <= 0 then
    return
  end
  if pane.opened and pane.width == w and pane.height == h then
    return
  end
  local method = pane.opened and "pane/resize" or "pane/open"
  pane.opened = true
  pane.width, pane.height = w, h
  rpc.request(state.conn, method, { session = session.id, pane = pane.name, width = w, height = h })
end

function M.close(session, pane)
  if pane.opened then
    pane.opened = false
    rpc.request(state.conn, "pane/close", { session = session.id, pane = pane.name })
  end
end

return M
