# heimdash

A single‑binary NixOS home‑server dashboard. Zig stdlib backend, [Datastar](https://data-star.dev) on the wire, configured by a JSON file the NixOS module writes.

## Develop

```sh
nix develop                              # dev shell: zig, zls, treefmt
zig build run -- --config config.json    # build & run against a local config
nix flake check                          # build + formatting (canonical check)
```

`config.json` mirrors the module options below — `listen`, `mounts`, `services`.

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
