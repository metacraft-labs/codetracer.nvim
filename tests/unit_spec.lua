--- Unit tests that need no pane server: key spellings, style → group names,
--- and layout pruning. Run: nvim --headless --clean -u NONE -c "luafile tests/unit_spec.lua"
vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path
local t = require("harness")
local keys = require("codetracer.keys")
local hl = require("codetracer.highlights")

t.case("CodeTracer key spellings become Neovim keys", function()
  local cases = {
    ["Ctrl+F5"] = "<C-F5>",
    ["Alt+Left"] = "<M-Left>",
    ["Shift+G"] = "G",
    ["g g"] = "gg",
    ["r c"] = "rc",
    ["Up"] = "<Up>",
    ["Enter"] = "<CR>",
    ["Escape"] = "<Esc>",
    ["PageDown"] = "<PageDown>",
    ["Ctrl+B"] = "<C-b>",
    ["Alt+Shift+I"] = "<M-S-i>",
    ["Ctrl+K Ctrl+Down"] = "<C-k><C-Down>",
    ["Shift+F10"] = "<S-F10>",
    ["/"] = "/",
    ["["] = "[",
    ["Ctrl+,"] = "<C-,>",
    ["Alt+`"] = "<M-`>",
    ["Ctrl+Tab"] = "<C-Tab>",
  }
  for from, to in pairs(cases) do
    t.eq(keys.to_lhs(from), to, from)
  end
  -- Keys Neovim cannot express are not installed rather than mistranslated.
  t.eq(keys.to_lhs("Alt"), nil, "a lone modifier")
  t.eq(keys.to_lhs("Ctrl+Shift+-"), nil, "Shift on a symbol")
  t.eq(keys.to_lhs(""), nil, "empty")
end)

t.case("a key is the same key however it is written", function()
  t.eq(keys.canonical("<c-f5>"), keys.canonical("<C-F5>"), "case of a key name")
  t.eq(keys.canonical(keys.to_lhs("Enter")), keys.canonical("<cr>"), "Enter is <CR>")
end)

t.case("a semantic style names a CodeTracer highlight group", function()
  t.eq((hl.group_of("ct.value-modified")), "CodeTracerValueModified", "group name")
  t.eq((hl.group_of("ct.surface-active-row")), "CodeTracerSurfaceActiveRow", "group name")
  t.eq(hl.default_link("value-modified"), "DiffChange", "exact rule")
  t.eq(hl.default_link("syntax-keyword-type"), "Keyword", "prefix rule")
  t.eq(hl.default_link("never-heard-of-it"), "Normal", "fallback")
  -- The group links by default, so a colour scheme can restyle it.
  local g = hl.group("ct.call-return")
  local def = vim.api.nvim_get_hl(0, { name = g })
  t.eq(def.link, "Type", "default link")
end)

t.case("a layout keeps only what the editor can show", function()
  local state = require("codetracer.state")
  state.conn = { info = { capabilities = { panes = { "calltrace", "state", "eventLog" } } } }
  local layout = require("codetracer.layout")
  local tree = layout.prune({
    kind = "row",
    children = {
      {
        kind = "stack",
        activeIndex = 2,
        weight = 10,
        children = {
          { kind = "pane", pane = "agentActivity" },
          { kind = "pane", pane = "state" },
          { kind = "pane", pane = "calltrace" },
        },
      },
      { kind = "pane", pane = "editor", weight = 30 },
      { kind = "pane", pane = "testResults", weight = 5 },
    },
  })
  t.eq(#tree.children, 2, "the undrawable leaf is dropped")
  t.eq(layout.shown_pane(tree.children[1]), "calltrace", "the stack's active child, counted among the kept")
  t.eq(#tree.children[1].children, 2, "the stack keeps its drawable children")
  local single = layout.prune({ kind = "column", weight = 7, children = { { kind = "pane", pane = "state" } } })
  t.eq(single.kind, "pane", "a container of one is that one")
  t.eq(single.weight, 7, "at the container's weight")
  state.conn = nil
end)

-- A stand-in for image.nvim, recording what the plugin asks of it. Justified:
-- the question here is the plugin's own logic (when to declare the image
-- medium, what to hand the image plugin), which a real image.nvim would
-- answer only through a terminal graphics protocol a headless Neovim lacks.
local function stub_image()
  local calls = {}
  package.loaded["image"] = nil
  package.preload["image"] = function()
    return {
      clear = function() end,
      from_file = function(path, opts)
        local f = io.open(path, "rb")
        local bytes = f and f:read("*a") or nil
        if f then
          f:close()
        end
        local img = { path = path, opts = opts, bytes = bytes, rendered = false, cleared = false }
        function img.render(self)
          self.rendered = true
        end
        function img.clear(self)
          self.cleared = true
        end
        calls[#calls + 1] = img
        return img
      end,
    }
  end
  return calls
end

local function no_image()
  package.loaded["image"] = nil
  package.preload["image"] = nil
end

t.case("the image medium is declared only with an image plugin installed", function()
  local state = require("codetracer.state")
  local images = require("codetracer.images")
  state.opts = {}
  no_image()
  t.eq(images.media(), { "text" }, "no image plugin: text only")
  stub_image()
  t.eq(images.media(), { "text", "image" }, "image.nvim installed: text and image")
  state.opts = { images = false }
  t.eq(images.media(), { "text" }, "images turned off: text only")
  state.opts = {}
  no_image()
end)

t.case("a frame is drawn through the image plugin, once per frame", function()
  local state = require("codetracer.state")
  local images = require("codetracer.images")
  state.opts = {}
  local calls = stub_image()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Frame 1 of 3", "", "", "" })
  vim.api.nvim_win_set_buf(0, buf)
  local pane = { name = "frameViewer", buf = buf, rows = { [0] = { text = "Frame 1 of 3" } } }
  local png = "\137PNG\r\n\26\n-not-really-a-png"
  local image = { mediaType = "image/png", encoding = "base64", data = vim.base64.encode(png), frame = 0 }
  images.show({ id = 1 }, pane, image)
  t.eq(#calls, 1, "one image")
  t.eq(calls[1].bytes, png, "the decoded PNG bytes")
  t.eq(calls[1].opts.buffer, buf, "in the pane's buffer")
  t.eq(calls[1].opts.window, vim.api.nvim_get_current_win(), "in its window")
  t.eq(calls[1].opts.y, 1, "below the pane's text rows")
  t.check(calls[1].rendered, "rendered")
  images.show({ id = 1 }, pane, image)
  t.eq(#calls, 1, "the same frame is not drawn twice")
  images.show({ id = 1 }, pane, vim.tbl_extend("force", image, { frame = 1 }))
  t.eq(#calls, 2, "a new frame is drawn")
  t.check(calls[1].cleared, "the previous frame is cleared")
  images.clear(pane)
  t.check(calls[2].cleared, "and the last one on close")
  no_image()
end)

t.case("ceding the file tree role leaves CodeTracer's file pane out", function()
  local state = require("codetracer.state")
  local layout = require("codetracer.layout")
  state.conn = { info = { capabilities = { panes = { "calltrace", "fileTree" } } } }
  local lay = {
    kind = "row",
    children = {
      { kind = "pane", pane = "fileTree", weight = 1 },
      { kind = "pane", pane = "editor", weight = 3 },
      { kind = "pane", pane = "calltrace", weight = 2 },
    },
  }
  state.opts = { panels = { fileTree = "codetracer" } }
  t.eq(#layout.prune(lay).children, 3, "CodeTracer's file pane by default")
  state.opts = { panels = { fileTree = "editor" } }
  local pruned = layout.prune(lay)
  t.eq(#pruned.children, 2, "ceded: no file pane")
  t.eq(layout.shown_pane(pruned.children[1]), "editor", "the editor takes its place")
  state.opts = {}
  state.conn = nil
end)

t.run()
