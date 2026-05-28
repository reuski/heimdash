# Agent Instructions

## Source

- `README.md`: commands, config, routes, NixOS module.
- `AGENTS.md`: repo rules.

## Invariants

- Zig stdlib only.
- `build.zig.zon` `.dependencies` stays empty.
- One binary, one process.
- No sidecars.
- No separate frontend service.
- Assets under `assets/` use `@embedFile`.
- No runtime asset paths.
- JSON config is the Nix-to-Zig contract.
- Add config fields only.
- Never rename or reorder existing config fields.
- Generated JSON may contain credential names only.
- Generated JSON must not contain credential paths or values.
- Resolve credentials from `$CREDENTIALS_DIRECTORY`.

## Runtime

- Dynamic responses: `text/event-stream`.
- Datastar event: `datastar-patch-elements`.
- Live route: `GET /stream`.
- Preserve morph targets:
  - `section#metrics`
  - `ul#system`
  - `ul#disks`
  - `ul#services`
- Keep reachability state separate from summary state.
- One arena per request.
- Request arenas use `defer arena.deinit()`.

## Layout

| Path              | Owner                                  |
| ----------------- | -------------------------------------- |
| `README.md`       | user reference                         |
| `flake.nix`       | package, shell, checks                 |
| `module.nix`      | NixOS module, generated config         |
| `build.zig`       | executable and test targets            |
| `src/main.zig`    | HTTP, SSE, sockets, credentials, glue  |
| `src/host.zig`    | Linux host readers: `/proc`, `/sys`, `statfs` |
| `src/metric.zig`  | metric rows, sections, pure math       |
| `src/sampler.zig` | in-memory history, rate deltas         |
| `src/summary.zig` | service summary adapters and parsers   |
| `src/render.zig`  | HTML emitters                          |
| `assets/`         | embedded HTML, CSS, JS                 |

## Commands

```sh
zig build test
zig build
zig build run -- --config /path/to/config.json
git diff --check
nix flake check
nix build .#default
nix fmt
```

- Local Nix optional.
- CI owns canonical Nix validation.

## Testing

- Pure logic: `src/health.zig`, `src/format.zig`, `src/credential.zig`, `src/metric.zig`, parsers.
- Side-effect readers stay thin.
- Parser, formatter, classifier tests live next to source.
- Unit tests stay out of `src/main.zig`.
- New pure modules must be added to the `inline for` test list in `build.zig`.
- After code edits: `zig build test`, `zig build`, `git diff --check`.

## Style

- Isolate side effects to IO edges.
- Prefer immutable values.
- Prefer small pure helpers.
- Use precise names.
- No comments except non-obvious algorithmic rationale.
- No compatibility shims.
- No dead code.
- No unused placeholders.
- No premature abstraction.

## UI

- Retro mainframe CRT terminal.
- Monospace only.
- One accent channel on near-black.
- Colors in `:root` custom properties.
- No hard-coded rule colors.
- No depth shadows.
- No glass.
- No emoji.
- No decorative gradients except scanlines, meters, sweep.
- Sharp chrome: 1px borders, hairline radius, labelled-rule headers.
- Sparse motion behind `prefers-reduced-motion`.
- Visual restyles touch only `assets/index.html` and `assets/style.css`.

## Docs

- Host agnostic.
- Consuming flakes own hostnames, domains, ports, mounts, inventory.
- Command-reference style.
- Current behavior only.
- No roadmap sections.
- No stale planning references.
