# codetracer.nvim — task entry points.
#
# Every recipe assumes the dev shell (`nix develop`, or `direnv allow`), which
# provides Neovim, stylua, luacheck and nixfmt.
#
# The integration suite drives a real CodeTracer pane server over a real
# recording, and needs both:
#   CODETRACER_TUI         the `codetracer-tui` binary (a CodeTracer build)
#   CODETRACER_TEST_TRACE  a recording's folder (CodeTracer's `calc` test
#                          program is the one the suite is written against)
#   REPLAY_SERVER_BIN      the replay server, when it is not where
#                          `codetracer-tui` looks for it by default
# Without them `test-integration` fails, by design: a suite that skipped would
# pass with no server at all.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

nvim := "nvim --headless --clean -u NONE"

# Check that every Lua module loads (the plugin has no other build step).
build:
    {{nvim}} -c "lua for _, f in ipairs(vim.fn.globpath('lua,plugin', '**/*.lua', false, true)) do assert(loadfile(f)) end" -c "qall!"

# Every suite.
test: test-unit test-integration

# The suites that need no pane server.
test-unit:
    {{nvim}} -c "luafile tests/unit_spec.lua"

# The plugin against a real pane server and recording (see above).
test-integration:
    {{nvim}} -c "luafile tests/integration_spec.lua"

lint: lint-lua lint-nix

lint-lua:
    stylua --check lua plugin tests
    luacheck lua plugin tests

lint-nix:
    nixfmt --check flake.nix

format: format-lua format-nix

format-lua:
    stylua lua plugin tests

format-nix:
    nixfmt flake.nix
