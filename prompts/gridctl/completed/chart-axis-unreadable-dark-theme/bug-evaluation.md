# Bug Investigation: Chart Axis Unreadable in Dark Theme

**Date**: 2026-04-23
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial

## Summary

The MCP server detail page's **Metrics** tab renders the Token Usage Over Time chart's Y-axis labels (`120k`, `60k`, `0`) and X-axis time label (e.g. `09:38 PM`) in near-black text on the `#08080a` dark background, producing a contrast ratio of ~1.1:1 — the chart is effectively unreadable. The root cause is that `AreaChart.tsx` explicitly sets `fill=""` and `stroke=""` on the Recharts `<XAxis>` / `<YAxis>` components, which overrides the intended Tailwind `fill-text-secondary` class via inline SVG attribute precedence. A sweep of the web app surfaces several more low-contrast instances that will be fixed in the same PR.

## The Bug

When a user navigates to `MCP server detail → Metrics tab` (or opens the detached metrics window), the Token Usage Over Time chart renders but its axis labels are nearly invisible. The labels are rendered as SVG `<text>` elements with an empty `fill` attribute, which falls back to the browser default `fill: black` — black text on a near-black background. The chart line data renders correctly; only the axis text is unreadable. The user can see that tokens trend downward but cannot read any quantitative values or the time scale.

Reported by the product owner after inspecting the metrics UI on 2026-04-23. Screenshot attached shows the Y-axis values and X-axis timestamp rendered in near-black on the dark theme.

## Root Cause

### Defect Location

Primary: `web/src/components/chart/AreaChart.tsx:390-391` and `411-412`

```tsx
<XAxis
  ...
  fill=""           // line 390 — empty string override
  stroke=""         // line 391 — empty string override
  className="text-xs fill-text-secondary"   // line 392 — intended color
  ...
/>
<YAxis
  ...
  fill=""           // line 411 — same issue
  stroke=""         // line 412
  className="text-xs fill-text-secondary"   // line 413
  ...
/>
```

### Code Path

Recharts' `<XAxis>` and `<YAxis>` components propagate their `fill` and `stroke` props directly to the tick `<text>` elements as SVG attributes. When `fill=""` is supplied, Recharts sets the attribute to the empty string. An inline SVG attribute takes precedence over the CSS cascade from the Tailwind `fill-text-secondary` class, so the tick text inherits the browser's default SVG fill (`black`). The `<Label>` children (axis titles, lines 398 and 423) do not have this problem because no `fill` prop is passed at that level — they render correctly in `text-secondary`.

### Why It Happens

The code was likely written against an older Recharts API pattern where `fill=""` and `stroke=""` were used as a defensive "unset" signal, with the expectation that the Tailwind className would supply the real fill via CSS. But SVG attribute precedence means an explicit `fill=""` attribute wins over a CSS `fill` declaration. The correct Recharts idiom is to configure tick appearance via the `tick` prop, which spreads its value as attributes onto each `<text>` element.

### Similar Instances

The same class of defect — using a token designed for low-emphasis contexts (`#27272a` border, `text-muted`) on elements that the user must actually read or interact with — appears in:

1. **`web/src/components/chart/AreaChart.tsx:433`** — tooltip cursor stroke hardcoded to `#27272a` (the border token). On hover, the vertical indicator line is indistinguishable from background.
2. **`web/src/components/workflow/WorkflowGraph.tsx:73`** and **`DesignerGraph.tsx:72,163`** — workflow edge strokes hardcoded to `#27272a`. Idle/pending edges between nodes effectively disappear.
3. **`web/src/components/workflow/WorkflowGraph.tsx:140`** and **`DesignerGraph.tsx:272`** — React Flow background grid hardcoded to `#27272a`. Grid dots barely perceptible.
4. **`web/src/components/playground/ReasoningWaterfall.tsx:99`** — code-block text uses `text-text-muted/70` (`#78716c` at 70% opacity), producing ~2:1 contrast — fails WCAG AA.

## Impact

### Severity Classification

**High — visual defect that renders a core observability surface unusable.** Not a crash, data-corruption, or security issue, but the Metrics tab is the canonical telemetry view for MCP servers and the user cannot read the numeric axis of its primary chart.

### User Reach

All users. Every MCP server detail page uses `AreaChart` via `MetricsTab`, and the detached-metrics fullscreen window uses the same component. There is no code path on Metrics that avoids the buggy chart.

### Workflow Impact

Core-path blocker for the observability workflow. Users can still see the *shape* of the token-usage trend from the line, but cannot read:
- actual token count at any point (Y-axis values)
- the time window being displayed (X-axis time label)

This undermines the purpose of the tab, which was explicitly added for autoscale observability (commits `b1aac01`, `2ed214c`, `abf4f8a`).

### Workarounds

None. The user cannot copy/select SVG text in a way that would reveal it; there is no alternate numeric display of the same data on the Metrics tab.

### Urgency Signals

- Product-owner filed the bug directly after inspecting their own UI.
- The Metrics tab is the primary observability UX and was just released.
- Accessibility: current contrast ratio (~1.1:1) fails WCAG AA for any text.

## Reproduction

### Minimum Reproduction Steps

1. `cd web && npm run dev`
2. Open the gridctl web UI in a browser.
3. Navigate to any MCP server detail page.
4. Click the **Metrics** tab.
5. Observe: Y-axis labels (`120k`, `60k`, `0`) and X-axis time label render in near-black on the dark background.

Reproduces identically in the detached metrics window (`DetachedMetricsPage`).

### Affected Environments

All browsers, all operating systems. The bug is inline SVG attributes plus theme CSS — rendering-engine-independent.

### Non-Affected Environments

None known.

### Failure Mode

Purely visual. The SVG text is rendered and technically accessible to DOM queries / screen readers, but visually indistinguishable from background. No runtime errors, no state corruption.

## Fix Assessment

### Fix Surface

- `web/src/components/chart/AreaChart.tsx` — remove `fill=""`/`stroke=""` overrides, pass `tick={{ fill: "var(--color-text-primary)" }}` on both axes; fix tooltip cursor stroke.
- `web/src/components/workflow/WorkflowGraph.tsx` — raise idle edge + background grid colors to a token with more contrast.
- `web/src/components/workflow/DesignerGraph.tsx` — same.
- `web/src/components/playground/ReasoningWaterfall.tsx` — drop the `/70` alpha on `text-text-muted` or switch to `text-text-secondary`.

### Risk Factors

- Low. Each change is a visual tweak, no data-path or state impact.
- Workflow edge/grid changes are slightly more subjective — bumping them from `#27272a` (border) to, e.g., `#3f3f46` or a `rgba(255,255,255,0.08)` stroke changes the aesthetic. Verify with a browser check after the change.
- Reasoning waterfall code-block change should preserve the "muted" feel while clearing WCAG AA.

### Regression Test Outline

No unit test for SVG attribute values is warranted — brittle and low-signal. The correct regression check is a manual visual review:

1. Navigate to `MCP server → Metrics`. Confirm axis labels readable.
2. Hover over the chart. Confirm vertical cursor line visible.
3. Navigate to a workflow page with multi-node graphs. Confirm idle edges visible and grid visible.
4. Open playground reasoning waterfall, expand a code block, confirm text readable.

If desired, add a lightweight Vitest test that renders `AreaChart` and asserts the ticks' computed `fill` is not empty — but this is low-value vs. the visual check.

## Recommendation

**Fix immediately.** This is a trivial code change on the critical observability surface. Scope for the same PR (per user direction 2026-04-23):
- Primary fix: AreaChart tick labels (both axes, both `MetricsTab` and `DetachedMetricsPage`).
- Hardening: AreaChart tooltip cursor stroke, workflow edge/grid colors, reasoning-waterfall muted code-block opacity.

Use `text-primary` (`#fafaf9`) for axis ticks rather than `text-secondary` — the latter (`#a8a29e`) is ~3:1 on this background and fails WCAG AA for small text even when correctly applied.

## References

- Screenshot: attached to bug-scout invocation 2026-04-23
- Recent autoscale-observability commits that introduced the Metrics tab: `abf4f8a`, `2ed214c`, `b1aac01`, `f6b5139`, `aa4bdfd`
- WCAG 2.1 SC 1.4.3 (Contrast Minimum) — 4.5:1 for small text
- Recharts `<XAxis>` tick configuration: https://recharts.org/en-US/api/XAxis (the `tick` prop pattern)
