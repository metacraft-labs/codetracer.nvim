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

# The plugin against a real pane server and recording (see above). The image
# cases also need CODETRACER_CT_GFX_PLAYER_CMD (the visual replay player, with
# a licence that allows Visual Replay in its environment) and
# CODETRACER_TEST_GFX_STREAM (a gfx stream, e.g. codetracer-visual-replay's
# tests/corpus_phase1/mpv, to give the recording graphics); they report NOT
# RUN, failing, without them.
test-integration: test-integration-panes test-integration-roles test-integration-sessions test-integration-edit test-integration-nim test-image-nvim

test-integration-panes:
    {{nvim}} -c "luafile tests/integration_spec.lua"

test-integration-roles:
    {{nvim}} -c "luafile tests/integration_roles_spec.lua"

# Edit-mode services: a test recorded from Test Results opens as a session of
# its own. Also needs `ct` ($CT_BIN, or on PATH) and `nargo` on PATH — the
# real `ct record-test` records CodeTracer's two-test Noir crate.
test-integration-edit:
    {{nvim}} -c "luafile tests/edit_mode_spec.lua"

# Nim's compile-time tracing from the right-click menu. Also needs
# codetracer-nim's trace-enabled nimsuggest ($CODETRACER_NIMSUGGEST) and its
# `nim` on PATH — CodeTracer's dev shell provides both.
test-integration-nim:
    {{nvim}} -c "luafile tests/nim_trace_spec.lua"

# :mksession in one Neovim, `nvim -S` in another.
test-integration-sessions:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' EXIT
    export CT_SESSION_FILE="$dir/Session.vim"
    CT_SESSION_PHASE=save {{nvim}} -c "luafile tests/session_spec.lua"
    CT_SESSION_PHASE=load {{nvim}} --cmd "set rtp^=." --cmd "runtime plugin/codetracer.lua" \
        --cmd "set columns=200 lines=60" -S "$CT_SESSION_FILE" -c "luafile tests/session_spec.lua"

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

# The frame viewer through the real image.nvim (from the dev shell), which
# draws with the kitty graphics protocol: run under a pseudo-terminal of a
# known size, outside tmux (where image.nvim insists on passthrough).
test-image-nvim:
    env -u TMUX TERM=xterm-kitty script -qfec 'stty cols 200 rows 60; {{nvim}} -c "luafile tests/image_nvim_spec.lua"' /dev/null
