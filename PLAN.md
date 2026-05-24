# heimdash

A single‑binary NixOS home‑server dashboard. Zig stdlib on the server,
Datastar on the wire, configured by a JSON file the NixOS module writes.

## Status

v1 server implemented end‑to‑end in `src/main.zig` (~270 lines). Builds
clean on Zig 0.16 (`Debug` and `ReleaseSafe`). Smoke‑tested locally on
darwin — every endpoint responds correctly; Linux‑only readers
(`readUptime`, `readDiskFree`) fall back to zeros off‑target.

**Working:**

- `--config <path>` parses with `std.json.parseFromSliceLeaky` into the
  `Config` struct.
- `std.Io.net.IpAddress.parseLiteral` + `listen` + `accept` loop, one
  arena per connection, `connection: close` lifecycle.
- `GET /` renders the embedded `index.html`, substituting `<h1>`,
  `<span id="uptime">`, the full `<section id="metrics">`, and the
  services `<ul>` via a single landmark walk. First paint uses the same
  `renderMetrics` the SSE handler emits.
- `GET /poll` emits one `event: datastar-patch-elements` /
  `data: elements <section id="metrics">…</section>` and closes.
- `GET /style.css` and `GET /datastar.js` serve `@embedFile`'d bytes
  with `cache-control: public, max-age=31536000, immutable`.
- Metric readers: `readHostname` (`/etc/hostname`), `readUptime`
  (`/proc/uptime`), `readDiskFree` (Linux `statfs` syscall via
  `std.os.linux.syscall2`, stub‑zero on non‑Linux).

**Build note:** `@embedFile` in 0.16 rejects paths outside the module's
package dir, so `build.zig` registers each asset via
`exe_mod.addAnonymousImport("name", …)`. `src/main.zig` imports them as
`@embedFile("index.html")` etc.

## Next: prove it on a Linux host

The whole point of v1 is to actually run on the target. None of that
has happened yet.

1. **CI green.** Push and `gh run watch`. `nix flake check` and
   `nix build .#default` must pass on a Linux runner — the maintainer
   machine has no local Nix, so CI is the canonical Linux build.
2. **Smoke test on Linux.** `nix run` (or the built binary) on a real
   NixOS box. Confirm hostname + uptime populate, disk bars reflect
   real `statfs` output, the 30 s `data-on-interval` polls land, and
   Datastar morphs the metrics section without flicker.
3. **NixOS module dry‑run.** Build the module against a test config in
   a VM or nixos‑rebuild dry‑activate. Verify the hardened systemd unit
   starts, binds to `127.0.0.1:8080`, and survives a restart.

If any of those surface bugs, fix in `src/main.zig` and re‑verify. Do
not start v2 work before all three pass.

## Endpoints (implemented)

| Method | Path           | Returns                                                     |
| ------ | -------------- | ----------------------------------------------------------- |
| GET    | `/`            | Full HTML page, `text/html`. Substitutes services + metrics |
| GET    | `/poll`        | One `datastar-patch-elements` event, `text/event-stream`    |
| GET    | `/style.css`   | `@embedFile` asset, long cache                              |
| GET    | `/datastar.js` | `@embedFile` asset, long cache                              |

Any other path returns `404 text/plain`.

## Hard rules (do not negotiate in v1)

- **Zig stdlib only.** `build.zig.zon` `.dependencies` stays empty.
- **All assets embedded** via `@embedFile`. No runtime asset paths.
- **JSON config is the contract** between Nix and Zig — additive
  changes only.
- **Stable IDs in `index.html`** — never rename without updating the
  morph targets `/poll` emits.
- **One arena per request**, `defer arena.deinit()`. No allocator
  strategy decisions.
- **SSE wire format, pull‑mode lifecycle.** Same wire format will
  extend to long‑lived push in v2 without a client rewrite.
- **`metrics.zig` only if `main.zig` hurts to read.** Today it doesn't;
  the metric readers total ~30 lines.

## Config schema (in `module.nix`, parsed by the binary)

```json
{
  "listen": "127.0.0.1:8080",
  "mounts": ["/", "/home", "/mnt/data"],
  "services": [
    { "name": "Jellyfin", "url": "http://media.lan:8096" },
    { "name": "Nextcloud", "url": "https://cloud.lan" }
  ]
}
```

No `controlPath`, no `healthcheck`, no `icon` yet. Add fields only
when something consumes them.

## What stays deferred

Auth, TLS in the Zig server (reverse proxy handles it), Prometheus,
service start/stop, WebSockets, persistence, logs UI, i18n, CPU/RAM
gauges, per‑metric SSE channels, a `services.zig` abstraction, any
third‑party Zig library. Every one of these is a fine v2+ topic; none
belongs in the v1 server.

## After v1 — illustrative, not committed

Each future addition is intended to be small, local, and reversible:

- New disk‑adjacent metric (e.g. SMART) → add a reader + lines in
  `renderMetrics`. One function.
- New service link → one entry in the Nix module config. Zero Zig
  touched.
- Faster updates for part of the page → split `/poll` into `/poll/fast`
  and `/poll/slow` with different `data-on-interval` durations. Same
  SSE helper.
- Live log tail → keep the SSE connection open and yield more events.
  Wire format and client unchanged.
- Service control → new POST endpoint returning a
  `datastar-patch-elements` event for the updated status indicator.
  Auth becomes necessary at this step — and only at this step.
