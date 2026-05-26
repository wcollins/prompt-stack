# Bug Investigation: Cost KPI Card Misaligned

**Date**: 2026-05-07
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Low (Cosmetic)
**Fix Complexity**: Trivial

## Summary

The Cost KPI card on the Metrics tab renders its `$ COST` label inline with the `$0.00` value, breaking the label-above-value layout used by the three sibling cards (Input Tokens, Output Tokens, Total Tokens). Root cause is a Tailwind class collision in `CostKPICard`: the label `<span>` carries both `block` and `inline-flex`, and `inline-flex` wins. Two-line fix in two files.

## The Bug

In the gridctl web UI, on a server detail page → Metrics tab, four KPI cards sit side-by-side:

- **INPUT TOKENS** — value stacks below the label
- **OUTPUT TOKENS** — value stacks below the label
- **TOTAL TOKENS** — value stacks below the label
- **$ COST** — label and value render on the **same line** ❌

Expected: all four cards have identical layout — label on top, value below.
Actual: only the Cost card collapses label and value onto one line.

Discovered by user inspection of the Metrics tab.

## Root Cause

### Defect Location

- `web/src/components/metrics/MetricsTab.tsx:600`
- `web/src/pages/DetachedMetricsPage.tsx:606`

### Code Path

`MetricsTab` (or `DetachedMetricsPage`) renders four KPI cards in a row. The first three use the shared `KPICard` component (correct). The fourth, `CostKPICard`, hand-rolls its own markup to add a `DollarSign` icon — and this is where the bug lives.

### Why It Happens

The label `<span>` in `CostKPICard` has this class list:

```
text-[10px] text-text-muted uppercase tracking-wider block mb-1 inline-flex items-center gap-1
```

Both `block` and `inline-flex` set the `display` property. Tailwind emits the rule for `inline-flex` later in the cascade, so it wins:

- The label `<span>` becomes `display: inline-flex` (an inline-level box).
- The sibling value `<span>` is also inline (default for `<span>`).
- Two inline boxes sit on the same horizontal line, producing the observed layout.

By contrast, the working `KPICard` label has only `block`, so it forces a line break and the value drops to the next line.

### Similar Instances

None elsewhere. The defect is isolated to the two `CostKPICard` definitions (the second is a copy in the detached metrics window).

## Impact

### Severity Classification

Cosmetic. No data is lost or misreported; the value `$0.00` displays correctly — just on the wrong line.

### User Reach

Every user who opens the Metrics tab on a server detail page or pops it out into the detached metrics window.

### Workflow Impact

None. The cost number is still readable. The defect breaks visual consistency with the three sibling cards but does not block any task.

### Workarounds

None needed.

### Urgency Signals

Low. The cost feature shipped recently (commit `e772fcd`, two commits back on `main`); folding this in as a small follow-up is appropriate.

## Reproduction

### Minimum Reproduction Steps

1. Run `make build && ./gridctl <args-to-start-server>` (or whatever the local dev path is).
2. Open the web UI.
3. Navigate to a server's detail page.
4. Click the **Metrics** tab.
5. Observe the four KPI cards. The Cost card on the right has its label and value on one line; the others stack.

Repro is also available via the detached metrics window (same markup, same bug).

### Affected Environments

All browsers, all viewports. Pure CSS specificity issue.

### Non-Affected Environments

None.

### Failure Mode

`<span>` for label and `<span>` for value both compute to inline-level boxes; they sit horizontally adjacent inside the card, producing `$ COST $0.00` on a single line.

## Fix Assessment

### Fix Surface

- `web/src/components/metrics/MetricsTab.tsx:600` — change `inline-flex` to `flex`, drop redundant `block`.
- `web/src/pages/DetachedMetricsPage.tsx:606` — same change.

### Risk Factors

Very low. `flex` is block-level by default, which preserves the label-above-value stacking, and the inner `flex items-center gap-1` continues to keep the dollar icon aligned with the "Cost" text. No other component imports or depends on `CostKPICard`.

### Regression Test Outline

Optional. A snapshot test on `CostKPICard` would catch a recurrence, asserting the rendered DOM places the label span as a block-level sibling of the value span. Given the change is a one-class swap, manual visual confirmation in dev is sufficient.

## Recommendation

**Fix immediately.** Trivial one-class change in two files; no architectural risk; high confidence; visible to every user of the Metrics tab. Bundle into the next commit on `main`.

## References

- Commit `e772fcd`: feat: cost KPI, cost-over-time chart, top clients panel — introduced `CostKPICard` with the bug.
- `web/src/components/metrics/MetricsTab.tsx` — primary location.
- `web/src/pages/DetachedMetricsPage.tsx` — duplicate copy.
