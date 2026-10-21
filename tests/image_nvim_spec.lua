--- The frame viewer through the REAL image.nvim, in `nvim --headless`, over a
--- real pane server and a recording given graphics (the variables of
--- `integration_roles_spec.lua`, plus):
---
---   CODETRACER_TEST_IMAGE_NVIM  an image.nvim checkout (its runtime path)
---
--- image.nvim's kitty backend writes its escape sequences to stdout, which is
--- all a headless Neovim has; ImageMagick (`magick`) must be on PATH for its
--- processor, and TMUX must be unset (inside tmux the backend insists on
--- passthrough). `just test-image-nvim` sets this up.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path
vim.o.columns = 200
vim.o.lines = 60

local t = require("harness")

local server = vim.env.CODETRACER_TUI
local trace = vim.env.CODETRACER_TEST_TRACE
local image_nvim = vim.env.CODETRACER_TEST_IMAGE_NVIM
local stream = vim.env.CODETRACER_TEST_GFX_STREAM
if not (server and trace and image_nvim and stream and vim.env.CODETRACER_CT_GFX_PLAYER_CMD) then
  io.stdout:write("needs CODETRACER_TUI, CODETRACER_TEST_TRACE, CODETRACER_TEST_IMAGE_NVIM,\n")
  io.stdout:write("CODETRACER_TEST_GFX_STREAM and CODETRACER_CT_GFX_PLAYER_CMD\n")
  vim.cmd("cquit 2")
end
vim.opt.runtimepath:prepend(image_nvim)

local ct = require("codetracer")
ct.setup({ cmd = { server, "--pane-server" } })
local images = require("codetracer.images")
local state = require("codetracer.state")

t.case("image.nvim installed but not set up: text only", function()
  t.eq(images.media(), { "text" }, "an image.nvim that cannot draw is not declared")
end)

t.case("image.nvim set up: the image medium is declared", function()
  require("image").setup({ backend = "kitty", processor = "magick_cli" })
  t.eq(images.media(), { "text", "image" }, "declared")
end)

local dir = vim.fn.tempname()
vim.fn.system({ "cp", "-r", trace, dir })
vim.fn.system({ "cp", "-r", stream, dir .. "/gfx_stream" })

t.case("the frame viewer's frames are drawn by image.nvim", function()
  local s
  ct.open(dir, function(x)
    s = x
  end)
  t.wait_for(function()
    return s and s.position
  end, 60000, "the session")
  t.eq(state.conn.info.capabilities.media, { "text", "image" }, "the server will send images")
  images.open_frames(s)
  local pane
  t.wait_for(function()
    pane = s.panes[images.PANE]
    return pane and pane.image_obj ~= nil
  end, 60000, "an image.nvim image")
  if pane and pane.image_obj then
    local function drawn()
      return #require("image").get_images({ window = s.frames_win })
    end
    t.wait_for(function()
      return drawn() == 1
    end, 10000, "image.nvim to draw it")
    t.eq(drawn(), 1, "one image in the frame viewer's window")
    t.check(pane.image_obj.path == pane.image_path, "image.nvim holds the frame the server sent")
    local first = pane.image_path
    local f = io.open(first, "rb")
    t.eq(f and f:read(8), "\137PNG\r\n\26\n", "a PNG")
    if f then
      f:close()
    end
    ct.run("frame-viewer.next-frame", nil, s)
    t.wait_for(function()
      return pane.image_path ~= first and pane.image_obj ~= nil
    end, 60000, "the next frame")
    t.wait_for(function()
      return drawn() == 1 and pane.image_obj.is_rendered
    end, 10000, "image.nvim to draw the next frame")
    t.eq(drawn(), 1, "the previous frame was cleared")
  end
  local done = false
  ct.stop(function()
    done = true
  end)
  t.wait_for(function()
    return done
  end, 10000, "shutdown")
  vim.fn.delete(dir, "rf")
end)

t.run()
