# codetracer.nvim

Neovim front-end for [CodeTracer](https://github.com/metacraft-labs/codetracer),
the time-traveling debugger. It shows CodeTracer's panes (call trace, state,
event log, terminal output and the rest) in Neovim windows, binds CodeTracer's
keymaps in them, and marks the debugger's position and recorded values in your
source buffers.

The plugin is a view: the panes, their contents and the debugging session live
in CodeTracer's pane server (`codetracer-tui --pane-server`), which the plugin
starts and talks to over JSON-RPC on stdio. A DAP client such as nvim-dap can
drive the same session through the server's DAP endpoint.

## Requirements

- Neovim 0.10 or newer.
- A CodeTracer build providing `codetracer-tui` (pane-server protocol
  version 1), on `PATH` or named by `$CODETRACER_TUI`.

## Installation

With any plugin manager, e.g. lazy.nvim:

```lua
{ "metacraft-labs/codetracer.nvim", cmd = "CodeTracer", opts = {} }
```

or as a Nix package: `packages.<system>.default` of this repository's flake.

## Use

```vim
:CodeTracer open path/to/recording
:CodeTracer step-over
:CodeTracer mode
```

Each session is a tab page laid out like CodeTracer's debug (or edit) mode;
pane windows show the server's panes at their size, with CodeTracer's key
bindings. See `:help codetracer` for commands, key-binding precedence,
highlight groups and the nvim-dap adapter, and `:checkhealth codetracer`.

## Development

`nix develop` (or `direnv allow`) gives Neovim, stylua, luacheck and the
commit hooks. `just lint`, `just build`, `just test-unit`; `just
test-integration` drives a real pane server and needs `CODETRACER_TUI` and
`CODETRACER_TEST_TRACE` (see the Justfile).

## License

Apache-2.0. See [LICENSE](LICENSE).
