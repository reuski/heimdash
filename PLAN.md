# Plan: server-rendered SVG sparklines

## Goal

Add an inline trend sparkline to each metric row, rendered server-side as SVG,
driven by the in-memory history the background sampler already accumulates. No
client-side charting, no canvas, no new dependencies.

## Data source (already wired)

- `metric.Row.history: []const ?u64` is populated by `Sampler.snapshot` for every
  row and is currently unused by the renderer. This is the only input needed.
- Ring buffer: `sampler.history_capacity = 120` samples at
  `sampler.sample_interval_seconds = 15` → a rolling ~30 min window.
- `null` entries mark gaps (reader/probe failure at that tick).
- `sampler.History.max()` exists for relative scaling.

### Per-row domain

The plot domain follows a signal already present on the row:

| Rows                  | `row.percent` | History values | Domain ceiling        |
| --------------------- | ------------- | -------------- | --------------------- |
| CPU, Memory, Disks    | set (0–100)   | percent 0–100  | fixed `100`           |
| Temperature           | set (0–100)   | deci-celsius   | observed max in slice |
| Network (down series) | `null`        | bytes/sec      | observed max in slice |

Rule: `row.percent != null and label != "Temp"` → fixed `100`; otherwise scale to
`@max(1, observed_max)` via `metric.relativePercent`. Renderer computes the max
from the passed slice; no new fields on `Row`.

Network carries two series (down history + up history). The split-meter already
encodes both; the initial sparkline plots the **down** series only to stay
uncluttered. Revisit a dual-trace once the single trace looks right.

## Rendering

New `render.sparkline(w, history, opts)` emitting one element, called from
`metricRow` after the meter:

```
<span class="spark">
  <svg class="spark-svg" viewBox="0 0 119 100" preserveAspectRatio="none" aria-hidden="true">
    <polyline class="spark-line" points="0,72 1,68 …" />
  </svg>
</span>
```

- Coordinate space: `x = sample_index` (0..len-1), `y = 100 - scaled_value`
  (SVG y is top-down; invert so higher = up). `viewBox` width = `len-1`.
- `preserveAspectRatio="none"` stretches the fixed grid to the cell; the line
  stays a crisp hairline via `vector-effect: non-scaling-stroke` (CSS).
- Empty / single-point history: emit the `<svg>` wrapper with no `<polyline>`
  (stable structure for morphing; nothing to draw yet).
- Gaps: split into multiple `<polyline>` segments at each `null` rather than
  interpolating across unknown time. One polyline when there are no gaps.

### Morph stability (Datastar)

- The metrics section is re-sent whole every `stream_metrics_every_ticks` (≈30 s)
  and morphed by `section#metrics`. Keep the wrapper/classes identical every
  tick so the morph reduces to a `points` attribute update.
- Keep element order stable: `label`, `bar`, `spark`, `free`. No id churn.
- Payload: ~120 coord pairs/row as one attribute string — a few KB per patch,
  lighter than the existing LED grid.

## Visual style — CRT mainframe oscilloscope trace

Restyle surface stays in `assets/style.css` + the markup in `render.zig`. All
colors/dims come from `:root` custom properties; no hard-coded values in rules.

- **Trace = phosphor sweep.** 1px non-scaling stroke in the row's state color,
  reusing `--metric-state-color` (and `--status-ok` for the network series), so
  each sparkline matches its row's health channel. One accent channel on
  near-black — cohesive with the meters and status dots.
- **Glow.** Subtle `filter: drop-shadow(0 0 4px …)` keyed to the existing
  `--metric-state-glow` / `--glow-*`, echoing the lit-LED bloom. Static, not
  animated.
- **Frame.** Match the meter cell: `--panel-raised` background, 1px
  `--border-strong`, `box-shadow: inset 0 0 0 1px var(--meter-inset)`. Sharp
  chrome, hairline radius.
- **Baseline.** Optional 1px `--border` zero-line for the scope look. No grid
  graticule (keep it minimal).
- **Live cursor.** Optional small lit dot at the newest sample — reads as the
  CRT sweep head and rhymes with the `.live` indicator. Any motion gated behind
  `@media (prefers-reduced-motion: reduce)`.
- **No** depth shadows, glass, gradients (the trace is line-only — the allowed
  scanline/meter/sweep exceptions cover only the existing overlay), emoji, or
  decorative fills. No area fill in v1; consider a faint state-color fill later
  only if it stays within the motif.
- New tokens in `:root`: `--spark-h` (cell height), `--spark-stroke`,
  `--spark-glow`, `--spark-cursor`. Reuse spacing/border tokens otherwise.

## Layout

- Each metric row gains a `spark` cell in `#metrics li`'s grid. Size with
  `--spark-h`; let the SVG fill width (`width: 100%`). Verify the existing
  `label / bar / free` template still aligns at the `--meter-gap: 1px` mobile
  breakpoint.
- `index.html` needs no change: `render.page` overwrites `section#metrics` on
  first paint, so sparklines are present on initial load and on every patch.

## Steps

1. `render.zig`: add `sparkline` + scaling helper; call from `metricRow`. Pure
   function over `[]const ?u64`.
2. `render.zig` tests: points count, y-inversion, percent vs relative domain,
   gap-splitting into segments, empty-history wrapper. Update the existing
   `metricRow` assertions for the new `spark` element.
3. `style.css`: `.spark` / `.spark-svg` / `.spark-line` rules, `:root` tokens,
   row grid slot, reduced-motion guard.
4. `zig build test`, `zig build`, `zig fmt --check src/*.zig`, `git diff --check`.
5. Visual pass against the dashboard for cohesion with meters and service cards.

## Decisions to confirm before coding

- Network: single down-trace (chosen) vs dual down/up traces.
- Gaps: segment-split (chosen) vs interpolate.
- Live cursor dot: include vs omit.
- Baseline zero-line: include vs omit.

## Non-goals

- No client JS, canvas, tooltips, or interactivity.
- No persistence beyond the existing in-memory ring.
- No axis labels or legends — the numeric `free`/detail already carries the value.
