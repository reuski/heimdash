# heimdash Plan

## Current Status

| Area | State |
| --- | --- |
| Build | `zig build` passes on Zig 0.16.0 |
| Binary | Single executable target |
| Dependencies | Zig stdlib only |
| Assets | `index.html`, `style.css`, `datastar.js` embedded |
| Config | JSON: `listen`, `mounts`, `services` |
| Default listen | `127.0.0.1:8080` |
| NixOS | Module emits config file and hardened systemd unit |
| Runtime | Serial accept loop |
| Metrics | Hostname, uptime, CPU load, memory, disk free |
| Services | Static link cards |
| Dynamic wire | SSE `datastar-patch-elements` |
| Host contract | Host agnostic; consuming flakes own hostnames, domains, ports, mounts, and inventory |

## Implemented Routes

| Method | Path | Status |
| --- | --- | --- |
| `GET` | `/` | Full HTML page |
| `GET` | `/poll` | Metrics SSE patch |
| `GET` | `/style.css` | Embedded asset |
| `GET` | `/datastar.js` | Embedded asset |
| any | other | `404 text/plain` |

## Scope

- Host agnostic.
- No hard-coded hostnames.
- No hard-coded domains.
- No hard-coded LAN addresses.
- No hard-coded consuming-flake ports.
- No built-in service inventory.
- Consuming NixOS flakes own `listen`, `mounts`, and `services`.
- Heimdash owns rendering, polling, probing, read-only adapters, and dashboard state.

## Target Service Kinds

| Kind | Purpose |
| --- | --- |
| `adguard` | DNS/filtering dashboard |
| `jellyfin` | Media server |
| `sonarr` | Series automation |
| `radarr` | Movie automation |
| `prowlarr` | Indexer management |
| `qbittorrent` | Torrent client |
| `home_assistant` | Home automation |

## Gap List

- Serial accept loop blocks all requests during slow work.
- No service reachability probes.
- No service status morph target updates.
- No metric health states or thresholds.
- No credentials contract for read-only service APIs.
- No service-specific summary adapters.
- No long-lived SSE stream.

## Priority 1: Service Reachability

### Objective

- Show `checking`, `up`, or `down` for every configured service.
- Require no credentials.
- Reuse SSE patch format.
- Keep service links visible on first paint.

### Config

- Extend `Service` with optional `check`.
- Extend Nix service submodule with optional `check`.
- Keep existing fields unchanged: `name`, `url`.
- Probe `check` when present.
- Probe `url` when `check` is absent.

### Runtime

- Add `GET /poll/services`.
- Return `text/event-stream`.
- Emit one `datastar-patch-elements` event.
- Patch `<ul id="services">...</ul>`.
- Add `data-on-interval__duration.60s.leading="@get('/poll/services')"`.
- Keep `/poll` at 30s for system metrics.
- Spawn one detached thread per accepted connection before adding probes.
- Keep one arena per request.
- Keep probes serial inside `/poll/services`.

### Probe Rules

- Use `std.http.Client`.
- Timeout: 2s per service.
- Method: `GET`.
- Body: discard.
- `2xx`, `3xx`, `401`, `403`, `404`: `up`.
- `5xx`, connect failure, timeout, malformed URL: `down`.
- No retries.
- No API-specific parsing.

### UI

- Preserve `ul#services`.
- Add service item states: `is-checking`, `is-up`, `is-down`.
- Add one status glyph via CSS.
- Keep colors in `:root`.
- No new cards.
- No emoji.

### Validation

- `zig build`.
- `zig build run -- --config /tmp/heimdash.json`.
- `curl -i http://127.0.0.1:<port>/`.
- `curl -i http://127.0.0.1:<port>/poll`.
- `curl -i http://127.0.0.1:<port>/poll/services`.
- Linux host: compare each status against direct `curl` to configured `check` or `url`.

## Priority 2: Metric Health States

### Objective

- Make existing CPU, memory, and disk metrics actionable.
- Add warning and critical states without adding persistence or alert delivery.

### Config

- Extend config with optional `thresholds`.
- Defaults:
  - CPU warn `75`, critical `90`.
  - Memory warn `80`, critical `90`.
  - Disk warn `80`, critical `90`.
- Allow per-mount disk threshold overrides.
- Keep omitted thresholds fully defaulted.

### Runtime

- Compute `ok`, `warn`, `critical`, or `unknown` for every metric row.
- Keep calculations inside existing readers/render path.
- Keep `/poll` as the only metrics morph endpoint.
- Do not add historical sampling.

### UI

- Add row state classes.
- Add state glyphs with CSS.
- Keep segmented meters.
- Keep all colors in `:root`.
- Preserve `section#metrics`, `ul#system`, and `ul#disks`.

### Validation

- Unit-test threshold classification helper.
- `zig build`.
- `/poll` returns state classes for CPU, memory, and disks.
- Missing `/proc` data renders `unknown`, not `critical`.

## Priority 3: Read-Only Service Summaries

### Objective

- Add one compact operational line per service.
- No writes.
- No control actions.
- No secrets in JSON generated into the Nix store.

### Config

- Extend `Service` with optional `kind`.
- Extend `Service` with optional `credential`.
- Accepted `kind` values:
  - `adguard`
  - `jellyfin`
  - `sonarr`
  - `radarr`
  - `prowlarr`
  - `qbittorrent`
  - `home_assistant`
- `credential` names a systemd credential file.
- Missing `kind` keeps generic reachability only.
- Missing `credential` disables API summary for that service.
- Reachability remains active without credentials.

### NixOS

- Add `services.heimdash.credentials.<name>.path`.
- Emit `LoadCredential = [ "<name>:<path>" ]`.
- Keep generated JSON free of secret values.
- Keep `DynamicUser = true`.
- Zig reads credentials from `$CREDENTIALS_DIRECTORY/<name>`.

### Adapters

| Kind | Auth | Read-only endpoints |
| --- | --- | --- |
| `adguard` | HTTP Basic | `/control/status`, `/control/stats` |
| `jellyfin` | API key token | instance OpenAPI; first summary: server version + active sessions |
| `sonarr` | `X-Api-Key` | `/api/v3/system/status`, `/api/v3/queue/status` |
| `radarr` | `X-Api-Key` | `/api/v3/system/status`, `/api/v3/queue/status` |
| `prowlarr` | `X-Api-Key` | `/api/v1/system/status`, indexer health/count from instance API |
| `qbittorrent` | cookie login | `/api/v2/app/version`, `/api/v2/transfer/info` |
| `home_assistant` | Bearer token | `/api/`, selected `/api/states/<entity_id>` |

### Parser Scope

- Parse only fields rendered by the UI.
- Ignore unknown JSON fields.
- Treat API auth failure as `summary unavailable`, not `down`.
- Keep probe state separate from API summary state.

### UI

- Keep service cards scannable.
- Render status, name, link, and one summary line.
- Render unavailable summaries as blank.
- No control buttons.

### Validation

- Unit-test JSON parsers with fixture responses.
- Smoke-test each adapter against a configured NixOS host.
- Verify missing credential behavior.
- Verify invalid credential behavior.
- Verify no credential value appears in generated JSON or process args.

## Priority 4: Long-Lived SSE

### Objective

- Replace pull-mode intervals with one stream after reachability and metric states are stable.
- Preserve `datastar-patch-elements`.
- Preserve `/poll` and `/poll/services` as compatibility/debug endpoints.

### Runtime

- Add `GET /stream`.
- Emit metrics every 30s.
- Emit service reachability every 60s.
- Emit comment heartbeat every 15s.
- Close cleanly on client disconnect.
- Keep one arena per stream.
- Keep one binary and one process.

### Validation

- `curl -N http://127.0.0.1:<port>/stream`.
- Browser idle for 30 minutes.
- Repeated connect/disconnect cycle does not grow memory.
- Pull-mode endpoints still work.

## Priority 5: NixOS Module Polish

### Objective

- Improve deployment ergonomics without making host assumptions.
- Keep config additive.

### Actions

- Add examples for optional `check`, `kind`, `credential`, and thresholds.
- Add module assertions for duplicate service names.
- Add module assertions for empty service URLs.
- Add module assertions for duplicate credential names.
- Keep `services.heimdash.services = [ ]` valid.

### Validation

- `nix flake check` in CI.
- Invalid module examples fail evaluation.
- Minimal module example still evaluates.

## Out of Scope

- Service start/stop/restart.
- Torrent actions.
- Home Assistant service calls.
- Auth in Zig server.
- TLS in Zig server.
- Prometheus export.
- Persistence.
- Log browser.
- Third-party Zig libraries.
- Separate frontend process.
- Host-specific service defaults.
- Host-specific documentation examples.

## References

- AdGuard Home OpenAPI: `https://github.com/AdguardTeam/AdGuardHome/blob/master/openapi/openapi.yaml`
- Jellyfin OpenAPI: `https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json`
- Sonarr API: `https://sonarr.tv/docs/api/`
- Radarr API: `https://radarr.video/docs/api/`
- Prowlarr API: `https://prowlarr.com/docs/api/`
- qBittorrent Web API: `https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-4.1%29`
- Home Assistant REST API: `https://developers.home-assistant.io/docs/api/rest/`
- systemd credentials: `https://systemd.io/CREDENTIALS/`
