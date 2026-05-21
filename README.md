# heimdash

A single‑binary NixOS home‑server dashboard. Zig stdlib backend, [Datastar](https://data-star.dev) on the wire, configured by a JSON file the NixOS module writes.

Status: **v1 in progress.** See [`PLAN.md`](./PLAN.md) for scope and rationale.

## Quick start

```sh
nix develop          # zig + zls + treefmt
zig build run        # build & run the stub
nix run              # same, via the flake
nix flake check      # eval + formatting
```

## NixOS module

```nix
{
  inputs.heimdash.url = "github:reuski/heimdash";

  outputs = { self, nixpkgs, heimdash, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        heimdash.nixosModules.default
        {
          services.heimdash = {
            enable = true;
            listen = "127.0.0.1:8080";
            mounts = [ "/" "/home" "/mnt/data" ];
            services = [
              { name = "Jellyfin";  url = "http://media.lan:8096"; }
              { name = "Nextcloud"; url = "https://cloud.lan";    }
            ];
          };
        }
      ];
    };
  };
}
```

## License

[AGPL‑3.0‑only](./LICENSE).
