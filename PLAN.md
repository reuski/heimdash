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

## Shipped: system vitals + CRT restyle

CPU load and memory landed in the `#metrics` section, proven on the Linux
host. `readLoadAvg` (`/proc/loadavg`, bar = `load / nproc` via
`std.Thread.getCpuCount`) and `readMemInfo` (`/proc/meminfo`, bar =
used / total) feed `renderBarRow`, which now backs CPU, memory, and every
disk row. Reused the existing `/poll` morph — zero client/wire change; the
new readers stub to zero off‑Linux like `readDiskFree`.

The frontend was restyled into a retro CRT/mainframe terminal: monospace,
phosphor palette with a light paper‑terminal variant, framed window with a
title bar, segmented LED meters, labelled‑rule section headers, inverse‑video
service cells. Pure `index.html` + `style.css`; all morph targets unchanged.

## Next: service status

The service cards are dumb links. Probe each service and show
reachable / unreachable, reusing the SSE morph — the page renders the links
instantly, a slow poll fills status in. No new visible data is invented; this
is the first feature that reaches _off the box_.

- **Config (additive).** Service gains an optional `check` URL:
  `{ name, url, check? }`; probe `check`, falling back to `url`. Existing
  configs unaffected — honours the additive‑only contract.
- **`GET /poll/services`.** Probes every service with a short timeout
  (~2 s), emits one `datastar-patch-elements` morphing `<ul id="services">`
  with a per‑card status. A second `data-on-interval` at a slower cadence
  (~60 s) than metrics' 30 s — the foreshadowed fast/slow split, same SSE
  helper.
- **Probe.** `std.Io.net` connect + minimal HTTP GET; classify by connect
  success and status `< 500`. A side‑effect‑isolated reader like the metric
  readers. First paint renders cards as `checking…`.
- **Indicator.** A `.status` glyph per card (up / down / checking), styled
  in the existing CRT palette. New stable hooks inside the services markup;
  update `renderServices` and the morph emitter together.

**Concurrency — the real decision this forces.** The accept loop serves one
connection at a time, so a blocking probe round (N services × timeout) would
freeze `/` and `/poll` for its whole duration. This increment must make the
loop concurrent: spawn a detached `std.Thread` per accepted stream, keeping
one arena per connection exactly as today (`gpa` is already thread‑safe).
That is the minimum. Keep probes serial within the request first; parallelise
per‑probe only if N × timeout latency actually hurts — YAGNI until measured.
No auth needed: this is read‑only egress. Auth arrives only at _control_.

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
    {
      "name": "Nextcloud",
      "url": "https://cloud.lan",
      "check": "https://cloud.lan/status.php"
    }
  ]
}
```

`check` is optional and consumed by `/poll/services` (next step); probes
fall back to `url` when it is absent. No `controlPath`, no `icon` yet — add
fields only when something consumes them.

## What stays deferred

Auth, TLS in the Zig server (reverse proxy handles it), Prometheus,
service start/stop, WebSockets, persistence, logs UI, i18n, per‑metric
SSE channels, a `services.zig` abstraction, any third‑party Zig library. Every one of these is a fine v2+ topic; none
belongs in the v1 server.

## After v1 — illustrative, not committed

Each future addition is intended to be small, local, and reversible:

- New disk‑adjacent metric (e.g. SMART) → add a reader + lines in
  `renderMetrics`. One function.
- New service link → one entry in the Nix module config. Zero Zig
  touched.
- Live log tail → keep the SSE connection open and yield more events.
  Wire format and client unchanged.
- Service control → new POST endpoint returning a
  `datastar-patch-elements` event for the updated status indicator.
  Auth becomes necessary at this step — and only at this step.
