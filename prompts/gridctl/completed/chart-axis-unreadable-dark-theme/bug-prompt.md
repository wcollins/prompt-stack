# Bug Fix: Chart Axis Unreadable in Dark Theme

## Context

gridctl is an MCP server control plane with a web UI under `web/`. Tech stack: Vite + React 19 + TypeScript, Tailwind CSS v4, Recharts 3.8, React Flow for workflow canvases. The design system is "Obsidian Observatory" — a dark-only theme defined via the `@theme` block in `web/src/index.css` and mirrored in `web/tailwind.config.js`. Color tokens are exposed both as CSS variables (`var(--color-text-primary)`) and as Tailwind utilities (`text-text-primary`, `fill-text-primary`, etc.).

Relevant theme tokens:
- `--color-text-primary: #fafaf9` (warm off-white — body text, titles)
- `--color-text-secondary: #a8a29e` (warm mid-gray — ~3:1 on bg; decorative only)
- `--color-text-muted: #78716c` (dark gray — hints only)
- `--color-background: #08080a`
- `--color-border: #27272a` (panel borders; **not** interactive indicators)

## Investigation Context

Root cause confirmed in the code: `web/src/components/chart/AreaChart.tsx` sets `fill=""` and `stroke=""` on the Recharts `<XAxis>` and `<YAxis>` (lines 390-391, 411-412). Recharts passes these as inline SVG attributes to the tick `<text>` elements, which overrides the `fill-text-secondary` Tailwind class. With an empty-string `fill`, the browser falls back to default `fill: black`, producing ~1.1:1 contrast against the `#08080a` background.

User confirmed scope on 2026-04-23: full low-contrast audit (chart axes + tooltip cursor + workflow edges/grid + reasoning-waterfall code block). Use `text-primary` for the axis ticks — `text-secondary` is ~3:1 and fails WCAG AA even when correctly applied.

Full investigation: `prompts/gridctl/chart-axis-unreadable-dark-theme/bug-evaluation.md`.

## Bug Description

The Token Usage Over Time chart on the MCP server detail page's **Metrics** tab renders its Y-axis labels (`120k`, `60k`, `0`) and X-axis time label (e.g. `09:38 PM`) in near-black text on a near-black background, making them unreadable. The same bug affects the detached metrics window.

Additionally, a sweep of the web app surfaces four related low-contrast issues that should be fixed in the same PR.

Expected behavior: axis labels are clearly legible in the theme's foreground color (`--color-text-primary` = `#fafaf9`). Related visual indicators (tooltip cursor, workflow edges, grid dots, muted code text) reach at least WCAG AA contrast (4.5:1 for small text, 3:1 for non-text elements).

## Root Cause

`AreaChart.tsx` lines 383–428 configure the X and Y axes:

```tsx
<XAxis
  ...
  fill=""           // empty string — overrides className fill via SVG attribute precedence
  stroke=""
  className="text-xs fill-text-secondary"
  ...
/>
```

Recharts forwards `fill` to the tick `<text>` SVG elements. An inline SVG attribute of `fill=""` beats the CSS `fill` declaration produced by the Tailwind class, so ticks fall back to the default `fill: black`. The correct Recharts idiom is to configure tick appearance via the `tick` prop, whose object is spread as attributes onto each `<text>`.

## Fix Requirements

### Required Changes

1. **`web/src/components/chart/AreaChart.tsx` — X axis (lines 383–402)**
   - Remove the `fill=""` and `stroke=""` props entirely.
   - Extend the existing `tick` prop to include `fill: "var(--color-text-primary)"` (currently it only sets `transform`).
   - Remove `className="text-xs fill-text-secondary"` from the `<XAxis>` (it no longer does anything useful once the tick prop handles fill); optionally replace with `className="text-xs"` to preserve the font-size rule, or move the font-size into `tick={{ fontSize: ... }}`.
   - Leave the `<Label>` children's `fill-text-secondary` className alone — it works correctly there.

2. **`web/src/components/chart/AreaChart.tsx` — Y axis (lines 403–428)**
   - Apply the same change: remove `fill=""` / `stroke=""`, set `tick={{ ...existing, fill: "var(--color-text-primary)" }}`.

3. **`web/src/components/chart/AreaChart.tsx` — tooltip cursor (line 433)**
   - Change `cursor={{ stroke: "#27272a", strokeWidth: 1 }}` to use a stroke visible on the dark background. Recommended: `cursor={{ stroke: "var(--color-text-muted)", strokeWidth: 1, strokeDasharray: "3 3" }}` for a subtle dashed indicator. A simpler alternative is `stroke: "rgba(255,255,255,0.25)"`. Pick the one that looks best in the browser.

4. **`web/src/components/workflow/WorkflowGraph.tsx` (line 73) and `DesignerGraph.tsx` (lines 72, 163)**
   - Replace the hardcoded `'#27272a'` edge stroke with a more visible value. Recommended: `'#3f3f46'` (zinc-700) or `'rgba(255,255,255,0.12)'`. The goal is an edge that is visibly present but still subordinate to active/running edges (keep whatever existing stroke is used for active states — do not change it).

5. **`web/src/components/workflow/WorkflowGraph.tsx` (line 140) and `DesignerGraph.tsx` (line 272)**
   - The React Flow `<Background color="#27272a" />` grid is barely visible. Bump to `#3f3f46` or `rgba(255,255,255,0.08)` so the grid reads as a subtle positioning aid without becoming noisy.

6. **`web/src/components/playground/ReasoningWaterfall.tsx` (line 99)**
   - `text-text-muted/70` produces ~2:1 contrast. Replace with `text-text-muted` (drops the `/70` opacity) or, if the design intent is "muted code text", switch to `text-text-secondary`. Verify contrast in browser.

### Constraints

- **Do not** alter chart data-path logic, Recharts version, or the axis domain / tick formatter code.
- **Do not** change the axis *title* `<Label>` styling — those already render correctly via the className.
- **Do not** introduce new color tokens. Use existing CSS variables or the Tailwind utilities that resolve to them. The only hardcoded hex values permitted are near-equivalents of existing tokens (`#3f3f46` for the grid/edge bump) — prefer CSS variables where one already fits.
- **Do not** touch `SparkChart.tsx`. Its hardcoded stroke/fill hex values are the chart *series* colors (teal, amber, etc.) by design and are unrelated to the contrast bug.
- **Do not** add unit tests that assert SVG fill attribute values — they are brittle and test Recharts internals.

### Out of Scope

- Generalizing chart axis styling into a shared helper. There's currently only one chart with axes (`AreaChart`); extract later if a second one appears.
- Theme-token refactors (e.g. renaming tokens, introducing a new `chart-axis` token).
- Any light-mode support. The app is dark-only.
- Accessibility audit beyond the listed instances (those were the full sweep result from bug-scout).
- Updating `AGENTS.md` unless the change to chart conventions warrants documenting.

## Implementation Guidance

### Key Files to Read

- **`web/src/components/chart/AreaChart.tsx`** — the primary file. Focus on lines 383–440 (XAxis, YAxis, Tooltip).
- **`web/tailwind.config.js`** — confirms the color token names and their resolved hex values (lines 15–60).
- **`web/src/index.css`** — CSS variables for the theme (lines 4–67, particularly `--color-text-primary`, `--color-border`).
- **`web/src/components/workflow/WorkflowGraph.tsx`** and **`DesignerGraph.tsx`** — for the edge/grid fixes.
- **`web/src/components/playground/ReasoningWaterfall.tsx`** — for the muted code-block fix.
- **`web/AGENTS.md`** — the Obsidian Observatory design guide. Skim Section 2 (Color Palette).

### Files to Modify

| File | Change |
|---|---|
| `web/src/components/chart/AreaChart.tsx` | X/Y axis tick fill (lines ~383–428); tooltip cursor (~433) |
| `web/src/components/workflow/WorkflowGraph.tsx` | Edge stroke (~73), background grid (~140) |
| `web/src/components/workflow/DesignerGraph.tsx` | Edge stroke (~72, ~163), background grid (~272) |
| `web/src/components/playground/ReasoningWaterfall.tsx` | Muted code text opacity (~99) |

### Reusable Components

No helper currently exists for chart axis styling; do not introduce one in this PR. Use CSS variables directly via the `tick={{ fill: "var(--color-text-primary)" }}` pattern.

### Conventions to Follow

- Keep diffs minimal — this is a visual fix, not a refactor.
- Tailwind v4 supports arbitrary values (`fill-[var(--color-text-primary)]`) and named tokens (`fill-text-primary`). Either is acceptable; match whatever is local to the component. For the AreaChart tick fix, use the `tick` prop with a CSS var string — don't rely on the Tailwind class, because that's what caused the original bug.
- Commit message format: `fix: ` prefix, imperative, ≤50 chars (e.g. `fix: restore chart axis contrast on dark theme`).
- Sign commits with `-S`. No Claude co-author trailer, no mention of Claude in version control (per user's global CLAUDE.md).

## Regression Test

### Test Outline

Manual visual check is the right test for this. No automated test required. Verification steps:

1. `cd web && npm run dev`
2. Open any MCP server detail page → **Metrics** tab. Confirm `120k / 60k / 0` Y-axis labels and the X-axis time labels are clearly readable.
3. Hover over the chart. Confirm the vertical cursor line is visible (subtle is fine; invisible is not).
4. Open the detached metrics window. Confirm same labels are readable there.
5. Navigate to a workflow / designer page with multi-node graphs. Confirm idle edges between nodes are visible. Confirm the canvas grid dots are subtle but perceptible.
6. Open the playground reasoning waterfall and expand a code block. Confirm the muted text is readable (not invisible, not overly bright).

### Existing Test Patterns

- Frontend tests under `web/src/__tests__/` use Vitest + `@testing-library/react` with jsdom. Commands: `npm run test` (one-shot), `npm run test:watch`.
- There is no visual-regression / screenshot-test harness in this repo.
- `AreaChart` and `MetricsTab` currently have **no** test coverage. If you want to add a smoke test that renders `AreaChart` with fixture data and asserts the component mounts without error, follow the pattern in `web/src/__tests__/` — but it's optional and not required for this fix.

## Potential Pitfalls

- **Tailwind class order / purging**: Tailwind v4 uses a different engine than v3. If you choose to use a Tailwind utility instead of `var(--color-text-primary)` in an inline style, confirm the class appears in generated CSS via `npm run dev` — missing classes are silent.
- **Recharts API**: The `tick` prop on `<XAxis>` / `<YAxis>` accepts either a boolean, a ReactElement, or a props-object that is spread onto the tick `<text>`. When using the props-object form, the entire object becomes the tick config — so preserve any existing keys (e.g., `transform: "translate(0, 6)"` on the XAxis) when adding `fill`.
- **Empty-string SVG attributes**: Do not re-introduce `fill=""` or `stroke=""`. They were the bug.
- **Workflow edge contrast vs. visual noise**: The edge color bump is subjective — idle edges should be "present but subordinate." If the bumped color makes active edges look washed out by comparison, consider bumping active-edge saturation instead; but default to the minimal change.
- **React Flow grid**: The `<Background />` component accepts color on a per-instance basis. Make sure both the Workflow and Designer canvases get the same treatment so they stay visually consistent.
- **Detached metrics window**: `DetachedMetricsPage.tsx` uses the same `AreaChart`, so fixing the shared component fixes both views. Verify both.

## Acceptance Criteria

1. Y-axis labels (`120k`, `60k`, `0`) on the Metrics tab Token Usage chart render in `#fafaf9` (or resolved equivalent), visually legible against the dark background.
2. X-axis time label on the same chart is legible.
3. Same legibility holds in the detached metrics window.
4. Tooltip cursor line is visible when hovering over the chart.
5. Workflow edges in idle/pending state are visibly present against the canvas background.
6. React Flow canvas grid dots are perceptible as a positioning aid on both the Workflow and Designer canvases.
7. Reasoning waterfall expanded code blocks render at ≥4.5:1 contrast.
8. No `fill=""` or `stroke=""` empty-string props remain on Recharts axis components.
9. `npm run lint`, `npm run build`, `npm run test` all pass.
10. No unrelated code changes; diff is confined to the five files listed under **Files to Modify**.

## References

- Investigation: `prompts/gridctl/chart-axis-unreadable-dark-theme/bug-evaluation.md`
- Recharts `XAxis` API: https://recharts.org/en-US/api/XAxis
- WCAG 2.1 SC 1.4.3 (Contrast Minimum): 4.5:1 for small text, 3:1 for non-text graphics
- Design system: `web/AGENTS.md` §2 (Color Palette)
- Autoscale observability feature that introduced the Metrics tab: commits `abf4f8a`, `2ed214c`, `b1aac01`
