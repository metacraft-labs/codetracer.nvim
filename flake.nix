{
  description = "codetracer.nvim — Neovim front-end for CodeTracer, over the CodeTracer pane server";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{ flake-parts, nixos-modules, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        nixos-modules.modules.flake.git-hooks
      ];

      # The Apache-2.0 text's fixed indentation is not ours to reformat.
      mcl.gitHooks.editorconfigExcludes = [ "^LICENSE$" ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        {
          # The mcl-standard-hooks set is installed by the imported git-hooks
          # module. The entries below are this repository's own: `just lint`
          # and the license check.
          pre-commit.settings.hooks = {
            lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
            check-license = {
              enable = true;
              name = "Check License File";
              entry = "bash -c 'test -f LICENSE || { echo \"Error: no LICENSE file in the repository root\"; exit 1; }'";
              files = "^$";
              pass_filenames = false;
              always_run = true;
            };
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
            packages = with pkgs; [
              neovim
              just
              git
              stylua
              lua51Packages.luacheck
              nixfmt
              # `just test-image-nvim`: image.nvim's ImageMagick processor,
              # and a pseudo-terminal (`script`) for its terminal size query.
              imagemagick
              util-linux
            ];
            # The image.nvim that `just test-image-nvim` draws frames through.
            CODETRACER_TEST_IMAGE_NVIM = "${pkgs.vimPlugins.image-nvim}";
            # The oil.nvim the roles suite selects files in (the file tree
            # role's `files/selected`).
            CODETRACER_TEST_OIL = "${pkgs.vimPlugins.oil-nvim}";
            # The nvim-tree and neo-tree the roles suite selects files in, each a
            # `:`-separated list: the tree, then the plugins it requires.
            CODETRACER_TEST_NVIM_TREE = "${pkgs.vimPlugins.nvim-tree-lua}";
            CODETRACER_TEST_NEO_TREE = lib.concatStringsSep ":" (
              with pkgs.vimPlugins;
              [
                neo-tree-nvim
                nui-nvim
                plenary-nvim
              ]
            );
            shellHook = ''
              echo "codetracer.nvim dev shell — $(nvim --version | head -1)"
            ''
            + config.mcl.gitHooks.installationScript;
          };

          # The plugin as a Neovim package (`programs.neovim.plugins`,
          # `vimPlugins`-style), its Lua modules checked to load.
          packages.default = pkgs.vimUtils.buildVimPlugin {
            pname = "codetracer.nvim";
            version = "0.1.0";
            src = ./.;
            nvimSkipModules = [ "codetracer.health" ];
          };
        };
    };
}
