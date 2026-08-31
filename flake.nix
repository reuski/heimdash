{
  description = "heimdash — NixOS home-server dashboard (Zig + Datastar)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        let
          inherit (pkgs) zig zls;
        in
        {
          packages = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            default = pkgs.stdenv.mkDerivation {
              pname = "heimdash";
              version = "0.0.0";
              src = ./.;

              nativeBuildInputs = [ zig ];

              dontConfigure = true;
              dontInstall = true;

              buildPhase = ''
                runHook preBuild
                export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
                zig build install --prefix $out -Doptimize=ReleaseSafe -Dcpu=baseline
                runHook postBuild
              '';

              meta = {
                description = "NixOS home-server dashboard (Zig + Datastar)";
                homepage = "https://github.com/reuski/heimdash";
                license = pkgs.lib.licenses.agpl3Only;
                mainProgram = "heimdash";
                platforms = pkgs.lib.platforms.linux;
              };
            };
          };

          checks = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            unit-tests = pkgs.stdenv.mkDerivation {
              name = "heimdash-unit-tests";
              src = ./.;
              nativeBuildInputs = [ zig ];
              dontConfigure = true;
              dontInstall = true;
              buildPhase = ''
                runHook preBuild
                export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
                zig build test -Dcpu=baseline
                touch $out
                runHook postBuild
              '';
            };
          };

          apps = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            default = {
              type = "app";
              program = "${config.packages.default}/bin/heimdash";
            };
          };

          devShells.default = pkgs.mkShellNoCC {
            packages = [
              zig
              zls
              pkgs.nixd
              config.treefmt.build.wrapper
            ]
            ++ (builtins.attrValues config.treefmt.build.programs);
          };

          treefmt = {
            projectRootFile = "flake.nix";

            programs.nixfmt.enable = true;
            programs.prettier.enable = true;

            settings.formatter = {
              zig-fmt = {
                command = "${zig}/bin/zig";
                options = [ "fmt" ];
                includes = [
                  "*.zig"
                  "*.zon"
                ];
              };
              prettier = {
                includes = [
                  "*.html"
                  "*.css"
                  "*.md"
                  "*.yml"
                  "*.yaml"
                  "*.json"
                ];
                excludes = [
                  "assets/datastar.js"
                  "LICENSE"
                  "flake.lock"
                ];
              };
            };
          };
        };

      flake.nixosModules.default = import ./module.nix self;
    };
}
