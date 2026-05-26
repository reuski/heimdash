# heimdash Plan

## Current Status

| Area           | State                                                                                |
| -------------- | ------------------------------------------------------------------------------------ |
| Build          | `zig build` passes on Zig 0.16.0                                                     |
| Tests          | `zig build test`; pure units in `src/health.zig`, `src/format.zig`; run in CI via `unit-tests` flake check |
| Binary         | Single executable target                                                             |
| Dependencies   | Zig stdlib only                                                                      |
| Assets         | `index.html`, `style.css`, `datastar.js` embedded                                    |
| Config         | JSON: `listen`, `mounts`, `services`, optional `services[].check`, optional `thresholds` |
| Default listen | `127.0.0.1:8080`                                                                     |
| NixOS          | Module emits config file and hardened systemd unit                                   |
| Runtime        | Detached thread per accepted connection                                              |
| Metrics        | Hostname, uptime, CPU load, memory, disk free, per-row health state                  |
| Services       | Link cards with reachability states                                                  |
| Dynamic wire   | SSE `datastar-patch-elements`                                                        |
| Host contract  | Host agnostic; consuming flakes own hostnames, domains, ports, mounts, and inventory |

## Implemented Routes

| Method | Path           | Status            |
| ------ | -------------- | ----------------- |
| `GET`  | `/`              | Full HTML page     |
| `GET`  | `/poll`          | Metrics SSE patch  |
| `GET`  | `/poll/services` | Services SSE patch |
| `GET`  | `/style.css`     | Embedded asset     |
| `GET`  | `/datastar.js`   | Embedded asset     |
| any    | other            | `404 text/plain`   |

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

| Kind             | Purpose                 |
| ---------------- | ----------------------- |
| `adguard`        | DNS/filtering dashboard |
| `jellyfin`       | Media server            |
| `sonarr`         | Series automation       |
| `radarr`         | Movie automation        |
| `prowlarr`       | Indexer management      |
| `qbittorrent`    | Torrent client          |
| `home_assistant` | Home automation         |

## Completed

### Metric Health States

- `thresholds` config: `cpu` / `memory` / `disk` (each `warn` + `critical`) plus per-mount `disks` overrides; omitted fields fully defaulted (cpu 75/90, memory 80/90, disk 80/90).
- Runtime classifies every metric row `ok` / `warn` / `critical` / `unknown`; missing `/proc` or `statfs` data renders `unknown`, never `critical`.
- UI: `is-*` row state classes, CSS state glyphs, segmented meters preserved, expanded status palette in `:root` shared by metrics and services.
- Classification lives in pure `src/health.zig`; `/poll` remains the only metrics morph endpoint.
- NixOS module emits a `thresholds` passthrough; typing and assertions deferred to Priority 1 below.

### Testing & Structure

- Pure logic split into `src/health.zig` (thresholds, classification) and `src/format.zig` (byte/uptime formatting, meminfo parse, HTML escape), each with colocated `test` blocks.
- `main.zig` is the IO/wiring edge and holds no unit tests.
- `zig build test` builds each pure module as its own target; CI runs it via the `unit-tests` flake check.

## Gap List

- Render path couples `/proc` IO with HTML emit, so rendered output has no unit coverage.
- No module assertions for invalid dashboard config.
- No credentials contract for read-only service APIs.
- No service-specific summary adapters.
- No long-lived SSE stream.

## Next Step Evaluation

| Candidate                  | Value  | Cost/Risk | Decision                                                       |
| -------------------------- | ------ | --------- | -------------------------------------------------------------- |
| NixOS Module Guardrails    | High   | Low       | Next. Assertions now also cover `thresholds` config.           |
| Service Summary Foundation | High   | Medium    | After guardrails. Split credential plumbing from adapters.     |
| Render Purity Refactor     | Medium | Low       | Optional. Separate gather (IO) from render (pure); unlocks render tests and eases SSE. |
| Service Summary Adapters   | High   | High      | Build after the credential contract is proven.                 |
| Long-Lived SSE             | Medium | Medium    | Defer until metric and service patches are stable.             |

## Priority 1: NixOS Module Guardrails

### Objective

- Improve deployment ergonomics without making host assumptions.
- Catch invalid dashboard config at evaluation time.
- Keep config additive.

### Actions

- Type the `thresholds` option (currently freeform passthrough): percent ints with `warn` / `critical` and a `disks` list of `{ mount, warn, critical }`.
- Add module assertions for duplicate service names.
- Add module assertions for empty service names.
- Add module assertions for empty service URLs.
- Add module assertions for empty `check` URLs when present.
- Add module assertions that warning thresholds are lower than critical thresholds.
- Keep `services.heimdash.services = [ ]` valid.

### Validation

- `nix flake check` in CI.
- Invalid module examples fail evaluation.
- Minimal module example still evaluates.
- Existing `check` and `thresholds` examples on the options stay valid.

## Priority 2: Service Summary Foundation

### Objective

- Add safe read-only API config and credential plumbing.
- No writes.
- No control actions.
- No secrets in JSON generated into the Nix store.
- No service-specific API calls in this step.

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

### Runtime

- Load credentials only when `kind` and `credential` are both present.
- Treat missing credential files as `summary unavailable`.
- Keep probe state separate from API summary state.
- Keep one arena per request.

### Validation

- Unit-test credential path resolution.
- Verify missing credential behavior.
- Verify invalid credential name behavior.
- Verify no credential value appears in generated JSON or process args.

## Priority 3: Service Summary Adapters

### Objective

- Add one compact operational line per service.
- Build adapters after the credential contract is proven.
- Start with the shared `X-Api-Key` family before unique auth flows.

### Adapters

| Order | Kind             | Auth          | Read-only endpoints                                               |
| ----- | ---------------- | ------------- | ----------------------------------------------------------------- |
| 1     | `sonarr`         | `X-Api-Key`   | `/api/v3/system/status`, `/api/v3/queue/status`                   |
| 1     | `radarr`         | `X-Api-Key`   | `/api/v3/system/status`, `/api/v3/queue/status`                   |
| 1     | `prowlarr`       | `X-Api-Key`   | `/api/v1/system/status`, indexer health/count from instance API   |
| 2     | `jellyfin`       | API key token | instance OpenAPI; first summary: server version + active sessions |
| 3     | `adguard`        | HTTP Basic    | `/control/status`, `/control/stats`                               |
| 4     | `qbittorrent`    | cookie login  | `/api/v2/app/version`, `/api/v2/transfer/info`                    |
| 5     | `home_assistant` | Bearer token  | `/api/`, selected `/api/states/<entity_id>`                       |

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

### Prerequisite

- Render Purity Refactor: separate metric gathering (IO) from rendering (pure value → HTML) so the stream and pull paths share a tested renderer.

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
