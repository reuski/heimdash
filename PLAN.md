# heimdash

A single‑binary NixOS home‑server dashboard. Zig stdlib on the server,
Datastar on the wire, configured by a JSON file the NixOS module writes.

## Status

Skeleton bootstrapped. The next iteration writes the actual server.

**In place:**

- Repo layout per the original plan: `flake.nix`, `module.nix`, `build.zig`,
  `build.zig.zon`, `src/main.zig` (stub), `assets/{index.html, style.css,
  datastar.js}`.
- Nix flake with `zig‑overlay` (master channel), ZLS, `treefmt`, dev shell,
  and a hardened systemd service in `module.nix`.
- NixOS module options matching the config schema below
  (`listen`, `mounts`, `services`); module renders the JSON config.
- `assets/index.html` carries the stable IDs (`#hostline`, `#uptime`,
  `#disks`, `#services`, `#metrics`) and the
  `data-on-interval__duration.30s.leading="@get('/poll')"` poll trigger.
- `assets/datastar.js` is vendored (v1.0.1). Served at `/datastar.js`,
  never from a CDN.
- GitHub Actions runs `nix flake check` and `nix build .#default` on push.

**Not yet in place — this is the next session's work:**

- A real HTTP server in `src/main.zig`. Today it prints a stub line.

## Next: implement the v1 server

The whole job fits in `src/main.zig`. Split out `metrics.zig` only if it
exceeds ~50 lines.

### Use case

The first useful render shows:

- **Hostname + uptime** — read `/etc/hostname` and `/proc/uptime`.
- **Disk free per mount** — for each entry in `config.mounts`, call
  `statvfs` and render a bar.
- **Service grid** — render `<a>` tags from `config.services`.

CPU and RAM gauges are still deferred; the goal is the smallest thing that
earns its pixels.

### Wire format

Every dynamic response is `text/event-stream` with a single
`datastar-patch-elements` event, then close. No long‑lived connections in
v1. One SSE helper (~15 lines) handles the framing:

```
event: datastar-patch-elements
data: elements <section id="metrics">…</section>

```

Stable IDs already exist in `index.html`; the `/poll` handler returns the
full `<section id="metrics">…</section>` and Datastar morphs it in.

### Endpoints

| Method | Path           | Returns                                                         |
| ------ | -------------- | --------------------------------------------------------------- |
| GET    | `/`            | Full HTML page, `text/html`. Substitutes services into the grid |
| GET    | `/poll`        | One `datastar-patch-elements` event, `text/event-stream`         |
| GET    | `/style.css`   | `@embedFile` asset, long cache                                  |
| GET    | `/datastar.js` | `@embedFile` asset, long cache                                  |

### Implementation order

Aim for one feature working end‑to‑end before adding the next.

1. **Config parse.** Accept `--config <path>`, read the file, parse with
   `std.json.parseFromSlice` into a `Config` struct
   (`listen: []const u8`, `mounts: [][]const u8`,
   `services: []struct { name, url }`).
2. **HTTP server.** Use `std.http.Server` if present in the resolved Zig
   version; otherwise hand‑roll a minimal HTTP/1.1 handler on `std.net`
   (~100 lines: parse request line + headers, route by path, write
   response). One arena per request, `defer arena.deinit()`.
3. **Static endpoints.** Wire `/style.css` and `/datastar.js` to
   `@embedFile("../assets/...")`. `Cache-Control: public, max-age=31536000,
   immutable`. Verify in a browser.
4. **Page render `/`.** Read the embedded `index.html`, substitute the
   `<ul id="services">` body with rendered link cards from
   `config.services`. Initial `<section id="metrics">` can render with
   the same code path the SSE helper uses, so the first paint matches
   subsequent polls.
5. **Metrics readers.**
   - `readUptime()` → parses `/proc/uptime`, returns seconds.
   - `readHostname()` → trims `/etc/hostname`.
   - `readDiskFree(mount)` → wraps `std.posix.statvfs` and returns
     `{ total, free }`.
6. **`/poll` handler.** Build the `<section id="metrics">` HTML
   (uptime + a `<li>` per mount with its bar and free bytes), emit one
   SSE event via the helper, close.
7. **Smoke test on the target host.** `nix run` on a Linux box; confirm
   the page loads, the services grid is populated, and metrics update on
   the 30 s interval.

## Hard rules (do not negotiate in v1)

- **Zig stdlib only.** `build.zig.zon` `.dependencies` stays empty.
- **All assets embedded** via `@embedFile`. No runtime asset paths.
- **JSON config is the contract** between Nix and Zig — additive changes
  only.
- **Stable IDs already in `index.html`** — never rename without updating
  the morph targets in `/poll`.
- **One arena per request**, `defer arena.deinit()`. No allocator strategy
  decisions.
- **SSE wire format, pull‑mode lifecycle.** Same wire format will extend
  to long‑lived push in v2 without a client rewrite.

## Config schema (in module.nix and parsed by the binary)

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

No `controlPath`, no `healthcheck`, no `icon` yet. Add fields only when
something consumes them.

## What stays deferred

Auth, TLS in the Zig server (reverse proxy handles it), Prometheus,
service start/stop, WebSockets, persistence, logs UI, i18n, CPU/RAM
gauges, per‑metric SSE channels, a `services.zig` abstraction, any
third‑party Zig library. Every one of these is a fine v2+ topic; none
belongs in the v1 server.

## After v1 — illustrative, not committed

Each future addition is intended to be small, local, and reversible:

- New disk‑adjacent metric (e.g. SMART) → add a reader + lines in the
  `#metrics` render. One file.
- New service link → one entry in the Nix module config. Zero Zig
  touched.
- Faster updates for part of the page → split `/poll` into `/poll/fast`
  and `/poll/slow` with different `data-on-interval` durations. Same SSE
  helper.
- Live log tail → keep the SSE connection open and yield more events.
  Wire format and client unchanged.
- Service control → new POST endpoint returning a
  `datastar-patch-elements` event for the updated status indicator. Auth
  becomes necessary at this step — and only at this step.
