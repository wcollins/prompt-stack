# Bug Fix: Compare to Running — Wire Up the Diff Modal

## Context

gridctl is an MCP gateway control plane (Go backend, React/TypeScript frontend in `web/`, Zustand state, Tailwind). The web UI has a Spec tab that shows the on-disk `stack.yaml` with validation, plus a "Compare to running" toggle in the toolbar. The intent of that toggle is to surface a diff between what's on disk and what the gateway is currently running.

The full diff-rendering component (`SpecDiffModal`) already exists and is used by the reload flow when the user reloads with edited config — it renders an LCS-based unified diff with line numbers and added/removed/context coloring. This bug fix reuses that component for the "Compare to running" path.

## Investigation Context

- Root cause confirmed: the "Compare to running" button in `web/src/components/spec/SpecTab.tsx` only toggles `compareActive` and applies a fragile per-line substring tint via `getDriftForLine()` (lines 88-100). It never opens a real diff surface, and produces no output at all when there's no drift.
- The well-built `SpecDiffModal` at `web/src/components/spec/SpecDiffModal.tsx` already does line diffing against `appliedSpec` from the Zustand store. The store seeds `appliedSpec` from the first loaded spec (`useSpecStore.ts:66`) and updates it after successful reloads.
- Risk mitigations baked into requirements: do **not** add a new backend endpoint. Reuse `appliedSpec` as the baseline. Modal must support both the existing reload flow (with Apply) and the new compare flow (read-only, no Apply).
- Reproduction confirmed: deterministic on the current main build (`v0.1.0-beta.6-19-gfbac6cf`). Click the button, see only the orange highlight on the button itself.
- Full investigation: `/Users/william/code/prompt-stack/prompts/gridctl/compare-to-running-no-diff-view/bug-evaluation.md`

## Bug Description

In the gridctl web UI Spec tab, the "Compare to running" button (top-right of the toolbar, with a `GitCompareArrows` icon) only toggles its own active styling when clicked. It does not open a diff view, and when the on-disk spec matches the running gateway's spec it produces no visible feedback at all. The user reasonably expects a comparison view between the on-disk YAML and the spec the gateway is actually running.

## Root Cause

The button's onClick handler (`SpecTab.tsx:218`) calls `toggleCompare()`, which only flips a boolean. The render path (`SpecTab.tsx:235-294`) uses `getDriftForLine()` (`SpecTab.tsx:88-100`) to apply faint per-line tints when `compareActive` is true and the line text contains a changed item's name. This is a partial implementation — there is no modal, panel, or side-by-side surface, and the substring-based line matching is unreliable.

The correct surface (`SpecDiffModal`) already exists but is currently only invoked by the Header's reload flow (`Header.tsx:64-94`).

## Fix Requirements

### Required Changes

1. **Add a `mode` field to the diff modal state in `web/src/stores/useSpecStore.ts`.** Track whether the modal is open in `apply` mode (existing behavior, called from Header reload) or `compare` mode (new behavior, called from Spec tab). Add an action to open it in compare mode without setting a `pendingSpec` — compare always diffs current `spec.content` against `appliedSpec.content`.

2. **Update `web/src/components/spec/SpecDiffModal.tsx`** to read the new `mode`:
   - In `compare` mode, render header title `"Compare to Running"` instead of `"Configuration Changed"`.
   - In `compare` mode, do not render the Apply button or the validation-errors block. The Cancel button becomes a Close button.
   - In `compare` mode, when `diffLines` has no non-context entries, render an empty state: `"No drift — on-disk spec matches the running gateway."` (replace the existing `"No changes detected"` copy only in compare mode).
   - In `compare` mode, source the diff inputs as `appliedSpec.content` (old) and the live `spec.content` from the store (new), not `pendingSpec`.

3. **Update `web/src/components/spec/SpecTab.tsx`**:
   - Replace the `toggleCompare` onClick on the button (line 218) with a handler that calls the new "open compare modal" action. The button no longer needs to track a persistent active state — it just opens the modal.
   - Remove the `compareActive`-driven plan loading effect (`SpecTab.tsx:148-153`), the `getDriftForLine` import/usage, the `drift` calculation in the render loop (line 238), and the `drift === 'added' | 'removed' | 'changed'` class names (lines 250-252). Also remove the now-unused `getDriftForLine` function (lines 88-100).
   - The button's icon and label stay the same. Its visual styling can drop the active/inactive split since the modal now provides the feedback; use the inactive style permanently.

4. **Add a regression test** in `web/src/__tests__/SpecComponents.test.tsx` covering the new compare flow (see Regression Test section below).

### Constraints

- Do not change the `apply` mode behavior. The Header reload flow must continue to work exactly as it does today (validate, open modal with `pendingSpec`, allow Apply with `onApply` callback).
- Do not introduce a new backend endpoint. Use `appliedSpec` already present in the store.
- Do not remove the `compareActive`, `setCompareActive`, `plan`, or `setPlan` store fields yet — other code may read them and a follow-up cleanup can remove them once verified unused. (Grep first; if no remaining readers, you may delete in this PR. Be explicit in the PR description either way.)
- Keep the `GitCompareArrows` icon and the label `"Compare to running"`.
- No changes to `internal/api/stack.go`, `pkg/config/plan.go`, or any other Go file.

### Out of Scope

- Adding a `GET /api/stack/spec/running` endpoint that returns the gateway's actual loaded spec. (`appliedSpec` is the baseline for now; a follow-up can introduce a true running-spec endpoint.)
- Fixing the case where `appliedSpec` is stale on first session load before any reload (it gets seeded from the first-loaded on-disk spec at `useSpecStore.ts:66`). Document as a known limitation in the PR description; do not address here.
- Refactoring `SpecDiffModal` beyond the mode plumbing.
- Removing or renaming `compareActive` / `plan` store fields if any code still reads them. Leave them; clean up in a follow-up.

## Implementation Guidance

### Key Files to Read

- `web/src/components/spec/SpecTab.tsx` — the button and render loop you'll modify
- `web/src/components/spec/SpecDiffModal.tsx` — the modal you'll extend with a mode prop
- `web/src/stores/useSpecStore.ts` — Zustand state where you'll add the mode field
- `web/src/components/layout/Header.tsx:50-94` — existing `apply`-mode entry point; do not regress this
- `web/src/__tests__/SpecComponents.test.tsx` — patterns for store tests and component tests in this project

### Files to Modify

- `web/src/stores/useSpecStore.ts` — add `diffModalMode: 'apply' | 'compare'` to state, default `'apply'`. Update `openDiffModal(pendingSpec)` to also set `diffModalMode: 'apply'`. Add `openCompareModal()` action that sets `diffModalOpen: true, diffModalMode: 'compare', pendingSpec: null`. Update `closeDiffModal` to reset mode to `'apply'`.
- `web/src/components/spec/SpecDiffModal.tsx` — read `diffModalMode` from the store. Compute diff inputs and rendered surface conditionally on mode. The existing LCS function and table rendering stay intact.
- `web/src/components/spec/SpecTab.tsx` — replace `toggleCompare` button handler with `openCompareModal`. Strip drift-related render logic (see Required Changes #3).
- `web/src/__tests__/SpecComponents.test.tsx` — add tests for compare mode.

### Reusable Components

- `computeLineDiff` in `SpecDiffModal.tsx` (lines 15-59) — reuse, do not duplicate.
- The `createPortal` modal frame in `SpecDiffModal.tsx` — reuse, just gate the footer/title on mode.
- Existing Zustand patterns (`subscribeWithSelector`, single `set` calls) — match style.

### Conventions to Follow

- Imports use relative paths (e.g., `'../ui/Button'`). Follow existing.
- Tailwind classes use the design tokens already in use (`text-text-primary`, `bg-surface-elevated`, `text-status-running`, etc.). Do not introduce new color tokens.
- TypeScript: prefer literal union types (`'apply' | 'compare'`) over enums.
- React state: keep selectors thin (`useSpecStore((s) => s.x)`), do not introduce derived stores.
- No console logs. Errors caught silently (the existing pattern in this file is `.catch(() => {})` at `SpecTab.tsx:151`).

## Regression Test

### Test Outline

Add to `web/src/__tests__/SpecComponents.test.tsx`. Use the existing test patterns (Vitest + React Testing Library, store reset between tests).

Tests to add:

1. **Store: `openCompareModal` sets correct state.** Calling the action sets `diffModalOpen: true`, `diffModalMode: 'compare'`, `pendingSpec: null`.

2. **Store: `closeDiffModal` resets mode.** After `openCompareModal`, calling `closeDiffModal` resets `diffModalMode` to `'apply'` (and other fields to their defaults).

3. **Modal renders compare-mode title.** Render `SpecDiffModal` with store state `{diffModalOpen: true, diffModalMode: 'compare', spec: {content: 'a\nb'}, appliedSpec: {content: 'a\nc'}}`. Assert title contains `"Compare to Running"` and that no `"Apply"` button is present.

4. **Modal renders no-drift empty state.** Same as above but `spec.content === appliedSpec.content`. Assert the empty state copy `"No drift — on-disk spec matches the running gateway."` is rendered. Assert no Apply button.

5. **Modal renders diff content in compare mode.** Same as test 3. Assert at least one row with `text-status-running` (added) or `line-through` (removed) class is present.

6. **SpecTab button opens compare modal.** Render `SpecTab` with a loaded spec. Click the "Compare to running" button. Assert the store's `diffModalOpen` is `true` and `diffModalMode` is `'compare'`.

7. **Apply mode regression.** Verify existing reload flow still works: call `openDiffModal('newcontent')`, render modal, assert title is `"Configuration Changed"` and Apply button is present.

### Existing Test Patterns

- File location: `web/src/__tests__/SpecComponents.test.tsx`
- Test runner: Vitest (`describe`, `it`, `expect`, `beforeEach`)
- Component testing: `@testing-library/react` (`render`, `screen`, `fireEvent`)
- Store reset between tests: pattern at the top of the existing file — copy it
- Mocking API: existing `vi.mock('../lib/api', ...)` block — extend, do not duplicate

## Potential Pitfalls

1. **Modal mounted but invisible** — `SpecDiffModal` returns `null` when `diffModalOpen` is false. Make sure your tests await the open state or assert post-click.
2. **`appliedSpec` may be null** — handle the null case gracefully in compare mode (already handled in `SpecDiffModal:86-89`, but verify your no-Apply-button branch doesn't crash if `diffLines` is empty).
3. **Header reload flow regression** — the reload flow opens the modal via `openDiffModal(pendingSpec)`. After your store changes, this must still set mode to `'apply'`. Verify by exercising the reload flow manually.
4. **Stale `compareActive` / `plan` references** — grep `compareActive` and `setPlan` across `web/src/` after your changes. If anything still reads these, leave the fields in place. The button itself no longer needs `compareActive`.
5. **Escape key behavior** — `SpecDiffModal` already handles Escape via `closeDiffModal`. This is correct for both modes; do not change it.
6. **Polling** — `SpecTab` polls `loadSpec` every 10s. The poll's optional plan fetch (`SpecTab.tsx:128-130`) can be removed along with the rest of compare-active drift logic.

## Acceptance Criteria

1. Clicking "Compare to running" in the Spec tab opens `SpecDiffModal` immediately.
2. When `spec.content === appliedSpec.content`, the modal shows the "No drift — on-disk spec matches the running gateway." empty state and no Apply button.
3. When `spec.content !== appliedSpec.content`, the modal renders a unified line diff with added/removed/context rows and no Apply button.
4. Modal title in compare mode reads "Compare to Running".
5. Closing the modal (Close button or Escape) returns the user to the Spec tab unchanged; `diffModalMode` resets to `'apply'`.
6. Existing reload flow (Header → reload with edited spec) still opens the modal in `apply` mode with the "Configuration Changed" title and a working Apply button.
7. `getDriftForLine` is removed from `SpecTab.tsx` and no per-line drift classes are applied during normal rendering.
8. New tests pass: store actions, compare-mode title, no-drift empty state, diff content rendering, button behavior, apply-mode regression.
9. `npm run lint && npm run build && npm test` all green in `web/`.
10. Manual verification on a `make build && ./gridctl up` session: click button → modal opens → close → reopen behaves consistently.

## References

- Investigation: `/Users/william/code/prompt-stack/prompts/gridctl/compare-to-running-no-diff-view/bug-evaluation.md`
- Project conventions: `AGENTS.md` in repo root
- Existing diff modal usage: `web/src/components/layout/Header.tsx:64-94`
