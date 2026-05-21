## Source of truth

[`PLAN.md`](./PLAN.md) is the spec. Read it before proposing changes. If a suggestion conflicts with `PLAN.md`, prefer the plan or flag the conflict.

## Hard rules

- **Zig stdlib only.** No third‑party Zig deps. `build.zig.zon` `.dependencies` stays empty.
- **Embedded assets.** Use `@embedFile` for everything under `assets/`. No runtime asset paths.
- **JSON config is the Nix↔Zig contract.** Additive changes only; never reorder or rename existing fields.
- **Stable IDs in markup.** Never rename a Datastar morph target without updating every handler that emits it.
- **SSE on every dynamic response.** `text/event-stream` with `datastar-patch-elements` events — the same wire format must serve both pull‑mode polls and long‑lived streams.
- **One arena per request**, `defer arena.deinit()`. Allocate freely inside.
- **Single binary, single process.** No sidecars, no separate frontend service.

## Layout

| Path                 | Purpose                                                   |
| -------------------- | --------------------------------------------------------- |
| `PLAN.md`            | Current spec and scope                                    |
| `flake.nix`          | Zig (zig‑overlay master), ZLS, treefmt, package, devShell |
| `module.nix`         | NixOS module: JSON config + hardened systemd unit         |
| `build.zig`          | Single executable target                                  |
| `build.zig.zon`      | Manifest; empty deps                                      |
| `src/`               | All Zig code. Split files only when one hurts to read     |
| `assets/`            | HTML, CSS, vendored Datastar JS — all `@embedFile`'d      |
| `.github/workflows/` | CI: `nix flake check`                                     |

## Commands

```sh
nix develop                                     # dev shell
zig build                                       # build
zig build run -- --config /path/to/config.json  # run
nix flake check                                 # eval + formatter
nix build .#default                             # build via Nix
nix fmt                                         # treefmt
```

The maintainer machine has no local Nix. CI is the canonical verification — push and watch `gh run watch`.

## Code style

- Functional where applicable; isolate side effects to the edges (`/proc`, `statvfs`, sockets).
- Self‑documenting names. Comments only for non‑obvious algorithmic rationale.
- No premature abstraction. Three similar lines beat a wrong helper. Extract when a third caller appears, not before.
- No backwards‑compat shims, no `// removed` notes, no unused `_var` renames. Delete dead code completely.

## Scope

Anything not in `PLAN.md` is out of scope. New features land in `PLAN.md` first, then in code. Push back on scope creep before writing any of it.
