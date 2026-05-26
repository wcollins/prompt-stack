# Bug Fix: Cost KPI Card Misaligned

## Context

gridctl is an MCP gateway tool with a web UI built in React + TypeScript + Tailwind CSS. The frontend lives under `web/src/`. On a server detail page, a **Metrics** tab displays four KPI cards in a horizontal row: Input Tokens, Output Tokens, Total Tokens, and Cost. The same metrics view is also rendered in a detached/popped-out window.

## Investigation Context

- **Root cause confirmed**: The label `<span>` in `CostKPICard` mixes Tailwind classes `block` and `inline-flex`. `inline-flex` wins the cascade, so the label becomes inline and renders on the same line as the value span.
- **Scope**: Two files — `web/src/components/metrics/MetricsTab.tsx:600` and `web/src/pages/DetachedMetricsPage.tsx:606`. The second is a duplicate of the first in the detached metrics page.
- **Risk**: Very low. `CostKPICard` is local to each file; no external imports.
- **Reproduction**: Deterministic in all browsers — pure CSS specificity issue.
- Full investigation: `prompt-stack/prompts/gridctl/cost-kpi-card-misaligned/bug-evaluation.md`.

## Bug Description

On the Metrics tab, the four KPI cards are expected to all use a label-above-value layout (label on line 1, large numeric value on line 2). The first three cards (Input/Output/Total Tokens) render correctly. The fourth card (Cost) renders the `$ COST` label and the `$0.00` value on a single line, breaking visual consistency with the row.

This affects every user who opens the Metrics tab. It is cosmetic only — the cost value itself is correct and readable.

## Root Cause

In both `CostKPICard` definitions, the label `<span>` carries this class list:

```
text-[10px] text-text-muted uppercase tracking-wider block mb-1 inline-flex items-center gap-1
```

Both `block` and `inline-flex` set the CSS `display` property. Tailwind emits `inline-flex` later in the cascade, so the span computes to `display: inline-flex` — an inline-level box. The sibling value `<span>` is also inline by default, so the two boxes sit horizontally adjacent.

The correct behavior requires the label to be **block-level** (so the value drops to the next line) while still using flex to align the dollar icon next to the "Cost" text. `flex` (block-level flex) achieves both.

## Fix Requirements

### Required Changes

1. In `web/src/components/metrics/MetricsTab.tsx`, line 600, change the label span's class list from:
   ```
   text-[10px] text-text-muted uppercase tracking-wider block mb-1 inline-flex items-center gap-1
   ```
   to:
   ```
   text-[10px] text-text-muted uppercase tracking-wider flex items-center gap-1 mb-1
   ```
2. Apply the identical change to `web/src/pages/DetachedMetricsPage.tsx`, line 606.

### Constraints

- Must preserve the dollar icon's alignment with the "Cost" label text (i.e., icon and text remain side-by-side inside the label).
- Must not change the value's color logic (`text-emerald-400` when `hasCost`, `text-text-muted` otherwise) or the em-dash fallback (`'—'`).
- Must not alter any other KPI card or the surrounding grid.

### Out of Scope

- Refactoring `CostKPICard` to share a base component with `KPICard` — explicitly **not** part of this fix. The two files diverge intentionally because Cost has an icon. Save the refactor for later.
- Deduplicating `MetricsTab.tsx` and `DetachedMetricsPage.tsx` — out of scope.
- Any change to formatting (`formatUSD`), pricing logic, or API.
- New tests beyond what is already in the repo.

## Implementation Guidance

### Key Files to Read

- `web/src/components/metrics/MetricsTab.tsx` — locate `CostKPICard` (currently around line 597) and confirm the class list before editing.
- `web/src/pages/DetachedMetricsPage.tsx` — same component duplicated; locate `CostKPICard` (around line 603) and apply the matching change.
- Compare against the working `KPICard` component immediately above each `CostKPICard` definition to confirm the intent: label on its own line, value below.

### Files to Modify

- `web/src/components/metrics/MetricsTab.tsx` — line 600 (label span class list).
- `web/src/pages/DetachedMetricsPage.tsx` — line 606 (label span class list).

### Reusable Components

None new. Reuse the existing markup; only the class list on the label `<span>` changes.

### Conventions to Follow

- Tailwind utility classes inline on JSX elements — match the existing style.
- No `any` types, no new dependencies.
- Don't introduce new comments; the fix is self-evident.

## Regression Test

### Test Outline

Optional and not required for merge. If desired, add a React Testing Library snapshot or DOM assertion that:

- Renders `<CostKPICard usd={1.23} hasCost />`.
- Asserts the rendered label span's computed `display` is **not** `inline-flex` (or asserts the label and value spans render as separate visual lines via a snapshot diff).

If a snapshot test is added, place it next to the consuming file under a `__tests__` folder if the project uses one — otherwise skip the test.

### Existing Test Patterns

Check `web/src/` for existing `.test.tsx` files to confirm the project's testing conventions before adding any test. Do not introduce a new testing framework solely for this fix.

## Potential Pitfalls

- **Don't drop the icon styling.** The inner alignment between the `DollarSign` icon and the "Cost" text comes from `flex items-center gap-1`. Keep those classes; only the `display` family is changing (from `inline-flex` to `flex`, dropping the conflicting `block`).
- **Both files must be updated.** The detached metrics page mirrors the same component verbatim; if you fix only one, the bug persists in the popped-out window.
- **Verify visually after the fix.** Run `npm run build` (or the project's dev script) and load the Metrics tab in a browser to confirm all four cards now stack label-above-value.

## Acceptance Criteria

1. `web/src/components/metrics/MetricsTab.tsx` line 600 no longer contains `inline-flex` and no longer contains a redundant `block` alongside `flex`.
2. `web/src/pages/DetachedMetricsPage.tsx` line 606 receives the matching change.
3. In the running web UI, the Metrics tab's Cost KPI card displays the `$ COST` label on one line and the value (e.g., `$0.00`) on the line below, matching the visual layout of the Input/Output/Total Tokens cards.
4. The dollar icon remains aligned next to the "Cost" text inside the label.
5. The detached metrics window shows the same corrected layout.
6. No other UI changes regress (run the existing test suite if one is configured for this area).
7. `golangci-lint` is irrelevant here; if a frontend lint/format step exists (`npm run lint` or similar), it passes.

## References

- Investigation: `prompt-stack/prompts/gridctl/cost-kpi-card-misaligned/bug-evaluation.md`
- Origin commit: `e772fcd` — feat: cost KPI, cost-over-time chart, top clients panel
- Tailwind docs on `display` utilities: https://tailwindcss.com/docs/display
