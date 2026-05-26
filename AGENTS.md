# Agent Instructions

## Source of Truth

- `PLAN.md`: implementation status, scope, next steps.
- `README.md`: user-facing commands, config, module usage.
- `AGENTS.md`: agent rules.
- If files conflict, prefer `PLAN.md` for implementation scope.

## Hard Rules

- Zig stdlib only.
- Keep `build.zig.zon` `.dependencies` empty.
- Embed every file under `assets/` with `@embedFile`.
- No runtime asset paths.
- Treat JSON config as the Nix-to-Zig contract.
- Add config fields only.
- Never rename or reorder existing config fields.
- Never rename a Datastar morph target without updating every emitter.
- Use `text/event-stream` and `datastar-patch-elements` for dynamic responses.
- Keep one arena per request.
- Use `defer arena.deinit()`.
- Keep one binary and one process.
- No sidecars.
- No separate frontend service.

## Layout

| Path                 | Purpose                               |
| -------------------- | ------------------------------------- |
| `PLAN.md`            | status, scope, implementation plan    |
| `README.md`          | commands, config, module usage        |
| `flake.nix`          | Zig, ZLS, treefmt, package, dev shell |
| `module.nix`         | NixOS module                          |
| `build.zig`          | executable target                     |
| `build.zig.zon`      | manifest                              |
| `src/`               | Zig source                            |
| `assets/`            | embedded HTML/CSS/JS                  |
| `.github/workflows/` | CI                                    |

## Commands

```sh
nix develop
zig build
zig build run -- --config /path/to/config.json
nix flake check
nix build .#default
nix fmt
```

No local Nix requirement in this workspace. CI is the canonical Nix check.

## Code Style

- Isolate side effects to edges: `/proc`, `statfs`, sockets, HTTP.
- Prefer immutable values and small pure helpers.
- Use precise names.
- No comments unless algorithmic rationale is not obvious.
- No premature abstraction.
- Extract only after a third caller or clear readability pressure.
- Delete dead code.
- No compatibility shims.
- No unused placeholder renames.

## Visual Language

- Retro mainframe CRT terminal.
- Monospace only.
- One accent channel on near-black.
- All colors in `:root` custom properties.
- No hard-coded rule colors.
- Glow via `text-shadow` and `box-shadow`.
- No depth shadows.
- No glass.
- No decorative gradients except scanlines, meters, sweep.
- Sharp chrome: 1px borders, hairline radius.
- Section headers as labelled rules.
- Glyphs via text or pseudo-elements.
- No emoji.
- Segmented meters.
- Sparse motion behind `prefers-reduced-motion`.
- Restyle only `assets/index.html` and `assets/style.css`.
- Preserve server morph hooks.

## Scope Control

- New features land in `PLAN.md` first.
- Anything outside `PLAN.md` is out of scope.
- Push back before writing scope creep.
