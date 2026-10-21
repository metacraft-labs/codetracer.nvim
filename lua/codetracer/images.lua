--- The image medium (§E7, E0 row 4c): best effort. Neovim draws no images
--- itself; when a graphics-protocol plugin is installed — image.nvim — the
--- plugin declares `image` at `initialize`, and the frame viewer's frames,
--- which the server then sends as PNG beside the pane's text rows, are drawn
--- through it. Without one the plugin stays text-only and the server's rows
--- say the frame is an image instead.
local state = require("codetracer.state")

local M = {}

--- The image plugin, if one usable is installed and images are not turned
--- off (`setup({ images = false })`).
function M.backend()
  if state.opts.images == false then
    return nil
  end
  local ok, image = pcall(require, "image")
  if not ok or type(image) ~= "table" or type(image.from_file) ~= "function" then
    return nil
  end
  -- Installed is not enough: image.nvim draws only once the user has set it
  -- up with a backend for their terminal, and refuses every call before
  -- that. Its `clear` of an image that does not exist is the cheapest call
  -- that says which; and a user who turned it off (`is_enabled`) gets text.
  if type(image.clear) == "function" and not pcall(image.clear, "codetracer.nvim-probe") then
    return nil
  end
  if type(image.is_enabled) == "function" and image.is_enabled() == false then
    return nil
  end
  return image
end

--- The media to declare at `initialize`.
function M.media()
  if M.backend() then
    return { "text", "image" }
  end
  return { "text" }
end

--- Whether the server said it will send images (its answer to `initialize`).
function M.server_sends_images()
  local info = state.conn and state.conn.info
  local media = info and info.capabilities and info.capabilities.media or {}
  return vim.tbl_contains(media, "image")
end

local function decode(data)
  if vim.base64 and vim.base64.decode then
    return vim.base64.decode(data)
  end
  return nil
end

--- Draw a pane's `image` (from `pane/content`) below its text rows, in the
--- pane's window. A frame already shown is not drawn again.
function M.show(session, pane, image)
  local backend = M.backend()
  if backend == nil or image == nil or image.data == nil then
    return
  end
  if pane.image_frame == image.frame and pane.image_obj then
    return
  end
  local bytes = decode(image.data)
  if bytes == nil then
    return
  end
  local path = vim.fn.tempname() .. ".png"
  local f = io.open(path, "wb")
  if f == nil then
    return
  end
  f:write(bytes)
  f:close()
  M.clear(pane)
  pane.image_frame = image.frame
  pane.image_path = path
  local win = pane.buf and vim.fn.bufwinid(pane.buf) or -1
  if win == -1 then
    return
  end
  local rows = 0
  for i in pairs(pane.rows) do
    if pane.rows[i].text ~= "" then
      rows = math.max(rows, i + 1)
    end
  end
  local ok, img = pcall(backend.from_file, path, {
    window = win,
    buffer = pane.buf,
    x = 0,
    y = rows,
    width = vim.api.nvim_win_get_width(win),
    height = math.max(1, vim.api.nvim_win_get_height(win) - rows),
  })
  if ok and img then
    pane.image_obj = img
    if type(img.render) == "function" then
      pcall(img.render, img)
      -- A window opened in this same turn has no screen position yet, and
      -- image.nvim declines to draw into it: once more after a redraw.
      if img.is_rendered == false then
        vim.schedule(function()
          if pane.image_obj == img then
            vim.cmd("redraw")
            pcall(img.render, img)
          end
        end)
      end
    end
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeTracerImage",
    data = { session = session.id, pane = pane.name, frame = image.frame, path = path },
  })
end

--- Remove the image a pane shows.
function M.clear(pane)
  if pane.image_obj and type(pane.image_obj.clear) == "function" then
    pcall(pane.image_obj.clear, pane.image_obj)
  end
  pane.image_obj = nil
  if pane.image_path then
    os.remove(pane.image_path)
    pane.image_path = nil
  end
end

-- ---------------------------------------------------------------------------
-- The frame viewer
-- ---------------------------------------------------------------------------

M.PANE = "frameViewer"

--- Show the frame viewer under the session's source window (it is not a
--- pane of the layout: the server offers it for a recording with graphics).
function M.open_frames(session)
  if session.graphics == nil or not session.graphics.available then
    local why = session.graphics and session.graphics.error
    vim.notify(
      "codetracer: this recording has no graphics to show" .. (why and (": " .. why) or ""),
      vim.log.levels.INFO
    )
    return
  end
  local panes = require("codetracer.panes")
  local pane = state.pane(session, M.PANE)
  local buf = panes.ensure_buf(session, pane)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    local anchor = session.editor_win
    if anchor == nil or not vim.api.nvim_win_is_valid(anchor) then
      anchor = vim.api.nvim_get_current_win()
    end
    win = vim.api.nvim_open_win(buf, false, {
      split = "below",
      win = anchor,
      height = math.max(8, math.floor(vim.api.nvim_win_get_height(anchor) / 2)),
    })
    panes.style_window(win)
  end
  session.frames_open = true
  session.frames_win = win
  panes.report_size(session, pane, win)
end

function M.close_frames(session)
  local pane = session.panes[M.PANE]
  session.frames_open = false
  if pane == nil then
    return
  end
  M.clear(pane)
  require("codetracer.panes").close(session, pane)
  if session.frames_win and vim.api.nvim_win_is_valid(session.frames_win) then
    pcall(vim.api.nvim_win_close, session.frames_win, true)
  end
  session.frames_win = nil
end

function M.toggle_frames(session)
  if session.frames_open and session.frames_win and vim.api.nvim_win_is_valid(session.frames_win) then
    M.close_frames(session)
  else
    M.open_frames(session)
  end
end

return M
