# Feature Evaluation: Skills Registry UX Polish

**Date**: 2026-04-21
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium (~10–14 eng-days across two PRs)

## Summary

An unsolicited external UX review scored gridctl's Skills Registry at B+/86 and proposed 15 concrete polish items. Thirteen of the fifteen claims are substantiated against the current code; two are partially wrong (`IconButton` already meets WCAG 2.2 target-size minimum; a dedicated `text-hint` token isn't necessary). Recommend shipping the high-leverage subset as two focused PRs, deferring five comfort features until demand appears, and treating this as tuning — not redesign — of an already-good surface.

## The Idea

Apply a curated set of UX polish changes to the Skills Registry surfaces (`web/src/components/registry/*` and `web/src/pages/DetachedRegistryPage.tsx`) to:

- Close accessibility gaps (WCAG 2.2 AA + WAI-ARIA APG)
- Eliminate dual-dialect drift between the sidebar `SkillItem` and the detached `SkillCard`
- Add keyboard navigation expected by the developer-tool audience
- Reduce readability friction from sub-10px text

This is a polish initiative, not a redesign. The Obsidian Observatory visual language stays untouched.

**Who benefits:** every user of the registry (the product's most-demo-first surface). Keyboard users and users with uncorrected vision benefit most.

## Project Context

### Current State

gridctl is an MCP orchestration tool with a React 19 + Vite + Tailwind 4 + Zustand frontend. The Skills Registry is one of the most-developed surfaces, spanning:

- `RegistrySidebar.tsx` (605 lines) — embedded list view, search, inline `SkillItem`
- `SkillCard.tsx` — memoized card for the detached-window grid
- `SkillEditor.tsx` (960 lines) — frontmatter form + markdown split + workflow designer + tests
- `DetachedRegistryPage.tsx` — grid with tab filters + empty/error states
- `SkillFileTree.tsx`, `SkillCardSkeleton.tsx` — supporting pieces

Recent activity shows active investment (commit `c80201e "skills registry UI polish"` landed Apr 15, 2026, six days before this review). No refactors in flight.

### Integration Surface

Primary:
- `web/src/components/registry/RegistrySidebar.tsx` — SkillItem row, delete dialog, header
- `web/src/components/registry/SkillCard.tsx` — StateBadge, actions, top-accent gradient
- `web/src/components/registry/SkillEditor.tsx` — save-disabled state, name input, split-pane grip, hasWorkflow memo
- `web/src/pages/DetachedRegistryPage.tsx` — delete dialog duplicate, footer dot, animation cascade
- `web/src/components/ui/Modal.tsx` — missing focus trap, needs `role="dialog"` + `aria-modal`
- `web/tailwind.config.js`, `web/src/index.css` — tokens, animation keyframes

Secondary (benefit from shared `ConfirmDialog` primitive):
- `web/src/components/vault/VaultPanel.tsx` — same ad-hoc inline confirm pattern
- `web/src/components/metrics/MetricsTab.tsx` — same pattern for clear-metrics confirm

### Reusable Components

**Already in the tree, worth leaning on:**
- `ui/Modal.tsx` handles Escape + backdrop-click but has no focus trap — upgrade this once, `ConfirmDialog` inherits the fix
- `ui/IconButton.tsx` supports `variant="ghost"` + sm/md sizes; `p-2` padding yields ~30–32px hit area (already passes WCAG 2.2 SC 2.5.8)
- `hooks/useKeyboardShortcuts.ts` is page-level; a new `useListNav` hook for row-level arrow-key nav is the missing piece
- `cmdk` command palette (`components/palette/`) already ships arrow-key nav patterns worth mirroring
- Vitest + jsdom is set up (28 existing test files); no registry tests exist today — add alongside refactor

## Market Analysis

### Competitive Landscape

The external reviewer benchmarked against Linear, Raycast, GitHub, Cursor, and Vercel. Gaps gridctl has that peers ship:

- **Keyboard nav on list:** Linear, Raycast, Notion, Height, GitHub Issues all ship ↑/↓ + `/` for search + letter shortcuts. gridctl has none.
- **Row-hover actions:** Linear, Raycast, GitHub all reveal actions on hover without requiring expansion. gridctl buries activate/disable behind expand-to-reveal.
- **Confirm-dialog rigor:** all peers use proper modal role + focus trap + name-echo on destructive actions. gridctl uses raw divs.

Differentiators gridctl already has (confirmed by reviewer):
- Detached window and popout editor — neither peer ships these
- Fuzzy search integrated into sidebar via `fuse.js`
- Visual + markdown + tests in a single editor modal

### Market Positioning

**Catch-up on table stakes, not a differentiator.** The 15 items are all "polish existing surface to industry standard." None are new-category features. This is the right kind of work to fund when the bones are already good — it moves perceived quality from B+ to A– without design risk.

### Ecosystem Support

Standards cited and verified as real:
- **WCAG 2.2 SC 2.5.8 (Target Size Minimum, AA):** 24×24 CSS pixels. gridctl's `IconButton` already exceeds this.
- **WAI-ARIA APG — Alertdialog pattern:** prefer `role="alertdialog"` (not `role="dialog"`) for destructive confirms; autofocus safest option; trap focus; close on Escape.
- **Material, Shopify Polaris, Atlassian:** all advise against gradients/glow on destructive actions.

No new libraries needed. `cmdk` (already a dependency) provides reference patterns for keyboard nav.

### Demand Signals

- **Unsolicited external review.** Someone chose to audit this surface in detail — strongest positive signal of external attention.
- **Active internal investment.** "skills registry UI polish" shipped six days before the review; team is already improving this surface.
- **No competing demand signals against.** No bug reports, no user complaints, no pending refactors that would conflict.

## User Experience

### Interaction Model

Users currently interact with the registry in two places: a sidebar list (`SkillItem`) for triage and a detached grid window (`SkillCard`) for bulk work. The mismatch between them is the top UX cost — switching between surfaces forces users to retrain their eye on the same object.

Post-polish interaction model:
- **Consistent visual language** across sidebar and detached card (shared `StateBadge`, `TestStatusBadge`, `SkillActions` primitives)
- **One-click power toggle** on the collapsed sidebar row (was two clicks via expansion)
- **Keyboard-first navigation:** ↑/↓ to move, Enter to expand, `/` to focus search, `n` for new, `e` for edit, `d` to toggle
- **Safer destructive flow:** `role="alertdialog"` with autofocus-Cancel, focus trap, Escape-to-close, and destructive button reading `Delete "skill-name"` instead of `Delete`
- **Readable at rest:** no text below 10px; hint text at full-opacity `text-muted` (4.92:1 on surface, passes AA)

### Workflow Impact

- **Toggle-state flow:** 2 clicks → 1 click (most common action)
- **Delete flow:** one more safety check (name-echo) prevents mis-clicks; focus trap makes keyboard users actually able to navigate
- **Scan flow:** legible type and consistent badges reduce scan-time across every session
- **Author/edit flow:** live `hasWorkflowBlock` detection means the Visual/Test tabs appear as soon as the user types `workflow:`, not after save/reopen
- **No regressions introduced** if the unification is done with care — shared primitives preserve existing behavior with consistent styling

### UX Recommendations

1. **Layer `ConfirmDialog` on top of `Modal`, not alongside it.** Upgrade `Modal` with focus trap + proper role once; every modal in the app benefits.
2. **Use `role="alertdialog"` for destructive confirms.** Stricter than `role="dialog"`, per WAI-ARIA APG.
3. **Go icon-only on sidebar actions, matching `SkillCard`.** The reviewer suggests keeping text labels on `SkillItem`; I'd push harder — the row already has 8 competing visual elements, and icon+tooltip matches the grid surface.
4. **Drop the `text-hint` token idea.** Replace opacity-stacked hints with full-opacity `text-muted` — fewer new tokens, same contrast win.
5. **Stagger card animations via CSS `animation-delay` tied to index, and gate the whole cascade behind `motion-safe:`.** The global `prefers-reduced-motion` rule exists but individual cards still trigger; this fix is component-level.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Real a11y gaps; unrecoverable-action dialog is particularly weak |
| User impact | Broad+Deep | Registry is the primary surface; every session hits it |
| Strategic alignment | Core mission | Reviewer calls this "the surface you demo first" |
| Market positioning | Catch up | Keyboard nav + row-hover + dialog rigor are table-stakes |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | 3 surfaces share the confirm-dialog pattern; `Modal` upgrade ripples through `SkillEditor` and the wizard |
| Effort estimate | Medium | PR 1: 3–4 eng-days; PR 2: 6–8 eng-days |
| Risk level | Low-Medium | Main risk is regressions during `SkillCard`/`SkillItem` unification; zero existing test coverage for registry components |
| Maintenance burden | Reduced net | Shared primitives remove duplication across Registry/Vault/Metrics |

## Recommendation

**Build with caveats.**

Ship the high-leverage subset (items 1, 2, 3, 4, 5, 6, 7, 8, subset of 9, subset of 10) as two focused PRs. Defer items 11–15 until demand shows up.

**Caveats:**

1. **Scope as two PRs, not seven.** The reviewer's seven-day sequencing is optimistic. Two PRs is the right cut — a review bottleneck at one end, churn at the other.

2. **Layer `ConfirmDialog` on top of an upgraded `Modal`.** Don't build `ConfirmDialog` standalone. Fix `Modal` focus-trap + `aria-modal` first; `ConfirmDialog` is then a thin wrapper with `role="alertdialog"`, autofocus on Cancel, and a destructive-action slot.

3. **Skip the new `text-hint` token.** Replace `text-text-muted/50` and `/60` with full-opacity `text-muted`. Less API surface, same accessibility win.

4. **Don't raise every hit area to 28×28.** `IconButton` is already 30–32px (passes WCAG 2.2 SC 2.5.8 and the reviewer's proposed floor). Only the inline test-status toggle and a few ad-hoc buttons need a padding audit.

5. **Add Vitest coverage alongside the unified primitives.** Registry has zero tests today. `StateBadge.test.tsx`, `ConfirmDialog.test.tsx`, `useListNav.test.ts` should land with PR 2.

6. **Ship the visual language untouched.** This is tuning, not redesign.

**Proposed PR breakdown:**

- **PR 1 — "Registry polish: dialogs, destructive, typography"** (~3–4 eng-days)
  - Items 1, 3, 4, 5, 6, parts of 9, parts of 10
  - Upgrade `Modal` with focus trap + `aria-modal`
  - Introduce `ConfirmDialog` primitive; use across Registry, Vault, Metrics
  - Kill all `text-[8px]` and `text-[9px]`
  - Replace opacity-stacked hints with `text-muted`
  - Destructive solid color + name-echo

- **PR 2 — "Registry unified primitives + keyboard nav"** (~6–8 eng-days)
  - Items 2, 7, 8, subset of 9, subset of 10
  - Extract `StateBadge`, `TestStatusBadge`, `SkillActions` primitives
  - Unify `SkillCard` and `SkillItem` to consume them
  - Promote power-toggle to collapsed row
  - `useListNav` hook for ↑/↓ + `/` + `n` + `e` + `d`
  - Live `hasWorkflowBlock` detection in editor
  - Split-pane grip visible at rest
  - Animation stagger + motion-safe gating
  - Vitest coverage for new primitives

- **Future (defer items 11–15):** persist split-pane ratio, sort control, tag chips, shortcut overlay, pref persistence. Ship as small PRs when demand shows up or catalog-size friction surfaces.

## References

- External UX review (source document — see Phase 1 intake)
- WCAG 2.2 Success Criterion 2.5.8 Target Size (Minimum): https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html
- WAI-ARIA APG Alertdialog Pattern: https://www.w3.org/WAI/ARIA/apg/patterns/alertdialog/
- Material Design — Destructive actions guidance
- Shopify Polaris — Button usage and destructive patterns
- Atlassian Design System — Warning and danger buttons
- Linear, Raycast, GitHub keyboard patterns (referenced in the review's benchmarking table)
