--- Unit tests that need no pane server: key spellings, style → group names,
--- and layout pruning. Run: nvim --headless --clean -u NONE -l tests/unit_spec.lua
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
      { kind = "stack", activeIndex = 2, weight = 10, children = {
        { kind = "pane", pane = "agentActivity" },
        { kind = "pane", pane = "state" },
        { kind = "pane", pane = "calltrace" },
      } },
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

t.run()
