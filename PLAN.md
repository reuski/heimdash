# heimdash Plan

## Current Contract

- Single Zig executable, stdlib only.
- No runtime asset paths; every file under `assets/` is embedded.
- JSON config is the Nix-to-Zig contract.
- Config fields are additive only.
- Consuming NixOS flakes own hostnames, domains, ports, mounts, and service inventory.
- Heimdash owns rendering, polling, probing, read-only adapters, and dashboard state.
- Dynamic responses use `text/event-stream` and `datastar-patch-elements`.
- One arena per request, with `defer arena.deinit()`.

## Remaining Gaps

- No credentials contract for read-only service APIs.
- No service-specific summary adapters.
- Render path still couples `/proc` and `statfs` IO with HTML emission.
- No long-lived SSE stream.

## Priority 1: Service Summary Foundation

### Objective

- Add safe read-only API metadata and credential plumbing.
- Keep generic reachability active for every service.
- Keep generated JSON free of secret values.
- Do not add service-specific API calls in this step.

### Design Decisions

- `kind` is optional and only enables summary capability selection.
- `credential` is optional and names a systemd credential file, not a secret value.
- A service with no `kind` remains a generic link and reachability card.
- A service with `kind` but no `credential` renders no API summary.
- A service with missing credential material renders no API summary and does not affect reachability.
- Credential names are opaque identifiers shared by service config and `LoadCredential`.

### File Actions

- `module.nix`
  - Extend each service entry with optional `kind`.
  - Extend each service entry with optional `credential`.
  - Add `services.heimdash.credentials.<name>.path`.
  - Emit `LoadCredential = [ "<name>:<path>" ]` from configured credential paths.
  - Assert every configured service `credential` exists under `services.heimdash.credentials`.
  - Assert credential names do not contain `/` or `:`.
  - Keep `DynamicUser = true`.
  - Keep generated JSON limited to service metadata, never credential path contents or values.
- `src/main.zig`
  - Extend `Service` with optional `kind` and `credential`.
  - Add a pure helper that resolves `$CREDENTIALS_DIRECTORY/<name>`.
  - Load credential bytes only when both `kind` and `credential` are present.
  - Treat missing credential files as summary unavailable.
  - Keep probe state separate from summary state.
- `src/format.zig` or a new pure module
  - Add small testable helpers for credential name validation and path joining if the code would otherwise sit in `main.zig`.
  - Add the new pure module to the `build.zig` test target list if created.
- `assets/index.html` and `assets/style.css`
  - Preserve Datastar morph targets.
  - Add only the minimal summary line structure needed for future adapters.
  - Render unavailable summaries as blank.
- `README.md`
  - Document `kind`, `credential`, and `services.heimdash.credentials`.
  - Show that secret values stay outside generated JSON.

### Validation

- `zig build test`.
- `zig build`.
- `git diff --check`.
- `nix flake check` in CI.
- Verify JSON output contains credential names but no secret values.
- Verify process args include only the generated config path.
- Verify missing credential files do not mark reachability as down.
- Verify services without `kind` or `credential` still render and probe normally.

## Priority 2: Service Summary Adapters

### Objective

- Add one compact read-only operational summary per supported service.
- Keep adapter failures isolated from reachability state.
- Parse only fields rendered by the UI.

### Design Decisions

- Adapter output is `available` or `unavailable`; it is not a reachability verdict.
- API auth failures render summary unavailable.
- Unknown JSON fields are ignored.
- HTTP client code stays thin; response parsing lives in pure testable helpers.
- Start with services that share `X-Api-Key` semantics before unique auth flows.

### Adapter Order

| Order | Kind             | Auth          | First Summary                                    |
| ----- | ---------------- | ------------- | ------------------------------------------------ |
| 1     | `sonarr`         | `X-Api-Key`   | version plus queue count                         |
| 1     | `radarr`         | `X-Api-Key`   | version plus queue count                         |
| 1     | `prowlarr`       | `X-Api-Key`   | version plus indexer or health count             |
| 2     | `jellyfin`       | API key token | server version plus active sessions              |
| 3     | `adguard`        | HTTP Basic    | protection state plus query stats                |
| 4     | `qbittorrent`    | cookie login  | app version plus transfer speed                  |
| 5     | `home_assistant` | Bearer token  | API status plus one configured entity state line |

### File Actions

- Add service summary value types separate from reachability types.
- Add one adapter dispatcher keyed by `kind`.
- Add parser helpers and fixtures per adapter before wiring live requests.
- Keep rendered service cards to status, name, link, and one summary line.
- Do not add control buttons or write endpoints.
- Do not persist API responses.

### Validation

- `zig build test`.
- Fixture tests for every parser.
- Smoke-test each adapter against a configured NixOS host.
- Verify auth failure and malformed JSON render summary unavailable.
- Verify no credential value appears in generated JSON, logs, rendered HTML, or process args.

## Priority 3: Render Purity Refactor

### Objective

- Separate metric gathering from metric rendering.
- Give rendered output targeted unit coverage.
- Prepare shared render paths for long-lived SSE.

### Design Decisions

- IO readers stay at the edge: `/proc`, hostname, uptime, `statfs`, sockets, and HTTP.
- Pure render functions accept already gathered values.
- Existing morph targets and CSS classes remain stable.
- Pull-mode routes keep their current behavior.

### File Actions

- Move metric value structs and pure render helpers out of the IO-heavy path in `src/main.zig`.
- Keep side-effecting readers thin and unmocked.
- Add unit tests for metric row rendering, service card rendering, escaping, and unknown-state output.
- Add any new pure module to the `build.zig` test target list.

### Validation

- `zig build test`.
- `zig build`.
- Request `/`, `/poll`, and `/poll/services` with a local config.
- Verify Datastar morph target IDs are unchanged.

## Priority 4: Long-Lived SSE

### Objective

- Add one streaming endpoint after summary rendering and pure render paths are stable.
- Preserve pull-mode endpoints as compatibility and debugging surfaces.

### Design Decisions

- Add `GET /stream`.
- Emit metrics every 30 seconds.
- Emit service reachability and summaries every 60 seconds.
- Emit comment heartbeat every 15 seconds.
- Close cleanly on client disconnect.
- Keep one arena per stream.
- Keep one binary and one process.

### File Actions

- Add a stream route that emits `datastar-patch-elements`.
- Reuse pure render helpers from Priority 3.
- Keep `/poll` and `/poll/services` intact.
- Ensure stream loops do not retain per-tick allocations.

### Validation

- `zig build test`.
- `zig build`.
- `curl -N http://127.0.0.1:<port>/stream`.
- Browser idle test for 30 minutes.
- Repeated connect and disconnect cycles do not grow memory.
- Pull-mode endpoints still work.

## Out of Scope

- Service start, stop, or restart.
- Torrent actions.
- Home Assistant service calls.
- Auth in the Zig server.
- TLS in the Zig server.
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
