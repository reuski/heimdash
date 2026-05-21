{
  description = "heimdash — NixOS home-server dashboard (Zig + Datastar)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    systems.url = "github:nix-systems/default-linux";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-overlay.follows = "zig-overlay";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        let
          zig = inputs.zig-overlay.packages.${system}.master;
          zls = inputs.zls.packages.${system}.zls;
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "heimdash";
            version = "0.0.0";
            src = ./.;

            nativeBuildInputs = [ zig ];

            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              runHook preBuild
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig build install --prefix $out -Doptimize=ReleaseSafe
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

          apps.default = {
            type = "app";
            program = "${config.packages.default}/bin/heimdash";
          };

          devShells.default = pkgs.mkShell {
            packages = [
              zig
              zls
              pkgs.gh
              config.treefmt.build.wrapper
            ];
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
