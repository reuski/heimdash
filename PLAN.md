# heimdash Plan

## Current Status

| Area           | State                                                                                |
| -------------- | ------------------------------------------------------------------------------------ |
| Build          | `zig build` passes on Zig 0.16.0                                                     |
| Binary         | Single executable target                                                             |
| Dependencies   | Zig stdlib only                                                                      |
| Assets         | `index.html`, `style.css`, `datastar.js` embedded                                    |
| Config         | JSON: `listen`, `mounts`, `services`, optional `services[].check`                    |
| Default listen | `127.0.0.1:8080`                                                                     |
| NixOS          | Module emits config file and hardened systemd unit                                   |
| Runtime        | Detached thread per accepted connection                                              |
| Metrics        | Hostname, uptime, CPU load, memory, disk free                                        |
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

## Gap List

- No metric health states or thresholds.
- No module assertions for invalid dashboard config.
- No credentials contract for read-only service APIs.
- No service-specific summary adapters.
- No long-lived SSE stream.

## Next Step Evaluation

| Candidate                  | Value  | Cost/Risk | Decision                                           |
| -------------------------- | ------ | --------- | -------------------------------------------------- |
| Metric Health States       | High   | Low       | Next. Makes existing metrics actionable.           |
| NixOS Module Guardrails    | High   | Low       | Do after thresholds so assertions cover new config. |
| Service Summary Foundation | High   | Medium    | Split credential plumbing from service adapters.   |
| Service Summary Adapters   | High   | High      | Build after credential contract is proven.         |
| Long-Lived SSE             | Medium | Medium    | Defer until metrics and service patches are stable. |

## Priority 1: Metric Health States

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

## Priority 2: NixOS Module Guardrails

### Objective

- Improve deployment ergonomics without making host assumptions.
- Catch invalid dashboard config at evaluation time.
- Keep config additive.

### Actions

- Add examples for optional `check` and thresholds.
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

## Priority 3: Service Summary Foundation

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

## Priority 4: Service Summary Adapters

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

## Priority 5: Long-Lived SSE

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
