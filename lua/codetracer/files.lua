--- Panel roles (§E8). The source editor role is always Neovim's own buffers.
--- The file tree role is CodeTracer's file pane by default and may be ceded
--- to the editor (`setup({ panels = { fileTree = "editor" } })`): the pane is
--- then left out of every layout, and this module is the role adapter —
--- it reports what the editor's tree does (files created, renamed, deleted;
--- a file opened is the source window's own `source/viewport`), and it shows
--- the recording's sources, including those that are not on disk, as
--- read-only buffers.
local state = require("codetracer.state")
local rpc = require("codetracer.rpc")

local M = {}

M.RECORDED_SCHEME = "codetracer-source://"

--- Whether the editor fills the file tree role.
function M.ceded()
  local panels = state.opts.panels or {}
  return panels.fileTree == "editor"
end

-- ---------------------------------------------------------------------------
-- Recorded sources
-- ---------------------------------------------------------------------------

--- A read-only buffer holding `file` as the recording has it: for a source
--- that is not on disk (recorded elsewhere, or since deleted).
function M.recorded_buffer(session, file, cb)
  local name = M.RECORDED_SCHEME .. session.id .. file
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name and vim.api.nvim_buf_is_loaded(b) then
      cb(b)
      return
    end
  end
  rpc.request(state.conn, "source/read", { session = session.id, file = file }, function(err, result)
    if err or result == nil then
      vim.notify(
        "codetracer: cannot read " .. file .. " from the recording: " .. ((err and err.message) or "no answer"),
        vim.log.levels.WARN
      )
      cb(nil)
      return
    end
    local buf = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == name then
        buf = b
      end
    end
    if buf == nil then
      buf = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(buf, name)
    end
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    local lines = vim.split(result.text or "", "\n", { plain = true })
    if lines[#lines] == "" then
      table.remove(lines)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.b[buf].codetracer_recorded = { session = session.id, file = file }
    local ft = vim.filetype.match({ filename = file, buf = buf })
    if ft then
      vim.bo[buf].filetype = ft
    end
    cb(buf)
  end)
end

--- The buffer to show `file` in: the file on disk, or the recording's copy.
function M.source_buffer(session, file, cb)
  if vim.fn.filereadable(file) == 1 then
    local buf = vim.fn.bufadd(file)
    vim.bo[buf].buflisted = true
    if not vim.api.nvim_buf_is_loaded(buf) then
      vim.fn.bufload(buf)
    end
    cb(buf)
    return
  end
  M.recorded_buffer(session, file, cb)
end

--- The recording's file a buffer shows: its path on disk, or the recorded
--- file a `codetracer-source://` buffer holds.
function M.file_of(buf)
  local ok, rec = pcall(vim.api.nvim_buf_get_var, buf, "codetracer_recorded")
  if ok and type(rec) == "table" then
    return rec.file
  end
  return vim.api.nvim_buf_get_name(buf)
end

--- Pick one of the recording's sources and show it in the source window
--- (`:CodeTracer sources`).
function M.pick_source(session)
  rpc.request(state.conn, "session/files", { session = session.id }, function(err, files)
    if err or files == nil or #files == 0 then
      vim.notify("codetracer: the recording lists no source files", vim.log.levels.INFO)
      return
    end
    vim.ui.select(files, {
      prompt = "Recorded source",
      format_item = function(f)
        local on_disk = vim.fn.filereadable(f.path) == 1
        return f.path .. (on_disk and "" or "  (recorded only)")
      end,
    }, function(choice)
      if choice then
        M.source_buffer(session, choice.path, function(buf)
          if buf and session.editor_win and vim.api.nvim_win_is_valid(session.editor_win) then
            vim.api.nvim_win_set_buf(session.editor_win, buf)
          end
        end)
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- The editor's file tree, reported
-- ---------------------------------------------------------------------------

--- Report files the editor created, deleted or renamed (`files/changed`).
function M.report(changes)
  if not M.ceded() or state.conn == nil then
    return
  end
  for _, s in pairs(state.sessions) do
    rpc.notify(state.conn, "files/changed", {
      session = s.id,
      created = changes.created or {},
      deleted = changes.deleted or {},
      renamed = changes.renamed or {},
    })
  end
end

local new_files = {}

--- Hook the editor's file events: a buffer written to a file that did not
--- exist (any tree, or `:edit new.py` then `:write`), and the events of the
--- trees that publish them — nvim-tree, neo-tree and oil.nvim.
function M.attach(group)
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    callback = function(ev)
      if vim.fn.filereadable(ev.match) == 0 then
        new_files[ev.match] = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if new_files[ev.match] then
        new_files[ev.match] = nil
        M.report({ created = { vim.fn.fnamemodify(ev.match, ":p") } })
      end
    end,
  })
  -- oil.nvim: one event per batch of actions.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OilActionsPost",
    callback = function(ev)
      local changes = { created = {}, deleted = {}, renamed = {} }
      for _, a in ipairs((ev.data and ev.data.actions) or {}) do
        local url = (a.url or ""):gsub("^oil://", "")
        if a.type == "create" then
          table.insert(changes.created, url)
        elseif a.type == "delete" then
          table.insert(changes.deleted, url)
        elseif a.type == "move" then
          table.insert(changes.renamed, {
            from = (a.src_url or ""):gsub("^oil://", ""),
            to = (a.dest_url or ""):gsub("^oil://", ""),
          })
        end
      end
      M.report(changes)
    end,
  })
  -- nvim-tree and neo-tree publish through their own APIs, when installed.
  local ok_tree, tree_api = pcall(require, "nvim-tree.api")
  if ok_tree and tree_api.events then
    local E = tree_api.events.Event
    tree_api.events.subscribe(E.FileCreated, function(d)
      M.report({ created = { d.fname } })
    end)
    tree_api.events.subscribe(E.FileRemoved, function(d)
      M.report({ deleted = { d.fname } })
    end)
    tree_api.events.subscribe(E.NodeRenamed, function(d)
      M.report({ renamed = { { from = d.old_name, to = d.new_name } } })
    end)
  end
  local ok_neo, neo = pcall(require, "neo-tree.events")
  if ok_neo and neo.subscribe then
    neo.subscribe({
      event = neo.FILE_ADDED,
      handler = function(path)
        M.report({ created = { path } })
      end,
    })
    neo.subscribe({
      event = neo.FILE_DELETED,
      handler = function(path)
        M.report({ deleted = { path } })
      end,
    })
    neo.subscribe({
      event = neo.FILE_RENAMED,
      handler = function(args)
        M.report({ renamed = { { from = args.source, to = args.destination } } })
      end,
    })
  end
end

return M
