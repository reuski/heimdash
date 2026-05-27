# Agent Instructions

## Source Of Truth

- `PLAN.md`: current progress, scope, and next implementation steps.
- `README.md`: user-facing commands, config, routes, and module usage.
- `AGENTS.md`: repo rules for AI agents.
- If docs conflict, follow `PLAN.md` for implementation scope.

## Hard Rules

- Zig stdlib only.
- Keep `build.zig.zon` `.dependencies` empty.
- Embed every file under `assets/` with `@embedFile`.
- No runtime asset paths.
- Treat JSON config as the Nix-to-Zig contract.
- Add config fields only; never rename or reorder existing fields.
- Generated JSON may contain credential names, never credential paths or values.
- Resolve systemd credentials from `$CREDENTIALS_DIRECTORY`.
- Keep reachability state separate from summary state.
- Dynamic responses use `text/event-stream` and `datastar-patch-elements`.
- Never rename a Datastar morph target without updating every emitter.
- Keep one arena per request and use `defer arena.deinit()`.
- Keep one binary and one process. No sidecars or separate frontend service.

## Layout

| Path           | Purpose                           |
| -------------- | --------------------------------- |
| `PLAN.md`      | current progress and future scope |
| `README.md`    | commands, config, routes, module  |
| `flake.nix`    | Zig, ZLS, treefmt, package, shell |
| `module.nix`   | NixOS module and generated config |
| `build.zig`    | executable and test targets       |
| `src/main.zig` | HTTP, IO, wiring                  |
| `src/*.zig`    | pure helpers with colocated tests |
| `assets/`      | embedded HTML, CSS, JS            |

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

No local Nix requirement. CI is the canonical Nix check.

## Testing

- Pure logic belongs in modules such as `src/health.zig`, `src/format.zig`, and `src/credential.zig`.
- New pure modules must be added to the `inline for` test list in `build.zig`.
- Keep unit tests out of `src/main.zig`.
- Keep side-effecting readers thin; test the parser, formatter, or classifier they feed.
- After code edits, run `zig build test`, `zig build`, and `git diff --check`.

## Code Style

- Isolate side effects to IO edges: `/proc`, `statfs`, sockets, HTTP, and credentials.
- Prefer immutable values and small pure helpers.
- Use precise names.
- No comments unless algorithmic rationale is not obvious.
- No premature abstraction, compatibility shims, unused placeholders, or dead code.

## UI Rules

- Retro mainframe CRT terminal.
- Monospace only.
- One accent channel on near-black.
- Colors live in `:root` custom properties.
- No hard-coded rule colors, depth shadows, glass, emoji, or decorative gradients except scanlines, meters, and sweep.
- Sharp chrome: 1px borders, hairline radius, labelled-rule section headers.
- Sparse motion behind `prefers-reduced-motion`.
- Preserve server morph hooks.
- Visual restyles touch only `assets/index.html` and `assets/style.css`.

## Scope Control

- New features land in `PLAN.md` first.
- Keep repo docs host agnostic; consuming flakes own hostnames, domains, ports, mounts, and inventory.
- Anything outside `PLAN.md` is out of scope unless the user explicitly expands scope.
