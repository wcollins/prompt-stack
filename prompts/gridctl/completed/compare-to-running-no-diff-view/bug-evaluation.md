# Bug Investigation: Compare to Running — No Diff View

**Date**: 2026-04-26
**Project**: gridctl
**Recommendation**: Fix with caveats
**Severity**: Medium
**Fix Complexity**: Small

## Summary

The Spec tab's "Compare to running" button toggles its own active styling but produces no visible diff. When the on-disk spec matches the running gateway, nothing happens at all; when it differs, only a fragile substring-based line tint appears. The fix is to wire the existing `SpecDiffModal` (already used by the reload flow) to this button, with a read-only "compare" mode and an explicit empty state for the no-drift case.

## The Bug

In the gridctl web UI Spec tab there is a button labeled "Compare to running" with a git-compare icon. The expected behavior is that clicking it surfaces a comparison between the on-disk stack spec and the spec the gateway is actively running, so the user can see drift before reloading.

**Actual behavior**: Clicking the button only toggles its own background to the active orange highlight. No diff modal, panel, or side-by-side view opens. When the on-disk spec already matches the gateway's applied spec, there is zero visible feedback.

**Discovered**: User reported during routine inspection of the gridctl UI on the current main build (`v0.1.0-beta.6-19-gfbac6cf`).

## Root Cause

### Defect Location
- `web/src/components/spec/SpecTab.tsx:88-100` — `getDriftForLine()` provides the only visual output of compare mode
- `web/src/components/spec/SpecTab.tsx:217-228` — the button itself
- `web/src/components/spec/SpecTab.tsx:148-153` — effect that loads plan data on toggle
- The full `SpecDiffModal` UI exists at `web/src/components/spec/SpecDiffModal.tsx` but is only triggered by the reload flow in `web/src/components/layout/Header.tsx:64-94`

### Code Path
1. User clicks button at `SpecTab.tsx:217`
2. `toggleCompare()` flips `compareActive` boolean (`useSpecStore.ts:74`)
3. Effect at `SpecTab.tsx:149` fires `fetchStackPlan()` → `GET /api/stack/plan`
4. Backend `internal/api/stack.go:217-237` runs `config.ComputePlan(proposed, current)` and returns `{hasChanges, items[], summary}`
5. `setPlan(plan)` stores result in Zustand
6. Render loop at `SpecTab.tsx:235` calls `getDriftForLine(lineNum, content, plan?.items)` for every line
7. `getDriftForLine` returns `null` unless a YAML line's trimmed text *contains* the substring `item.name`
8. Class names from line 250-252 apply subtle background tints — no full diff display

### Why It Happens
The feature was implemented as a partial inline-highlight only. The author wired the state, the API call, and the data flow correctly, but the user-facing surface stops at line-level color tints driven by naive substring matching against `item.name`. There is no modal, no side-by-side view, and no empty/no-drift state. When the on-disk spec matches the running spec (the common case after a reload), the entire feature is invisible.

The mature `SpecDiffModal` component — which performs LCS line diffing and renders a polished added/removed/context view — already exists in the codebase, but its only entry point is `Header.tsx`'s reload handler.

### Similar Instances
None. This is a one-off partial implementation. The reload-flow diff modal is fully implemented and correct.

## Impact

### Severity Classification
Medium — incorrect/missing UI behavior on a discoverable, labeled control. Not a crash, no data loss, no security risk. Erodes trust in the UI because a clearly-labeled action produces no perceivable result.

### User Reach
Anyone who clicks the button in the Spec tab. The button is prominently placed in the toolbar of the Spec tab, so any user investigating spec/gateway state will encounter it.

### Workflow Impact
Edge of core path. Drift detection is a marketed feature of gridctl ("detect the moment your environment drifts from what's in version control"), so this gap directly undercuts a positioned-as-key workflow. Users can still reload, edit, and inspect specs; they just cannot use this button for its stated purpose.

### Workarounds
- Edit the on-disk YAML and click Reload — the existing reload flow surfaces a real diff modal via `Header.tsx:64`.
- Manually inspect both the YAML file and the gateway state. Adequate but defeats the point of the button.

### Urgency Signals
None. No active user complaints in the issue tracker. Recent main build, user discovered organically. The drift feature is marked Experimental in README, which lowers urgency but does not eliminate it.

## Reproduction

### Minimum Reproduction Steps
1. Run `make build && ./gridctl up` with any valid `stack.yaml`
2. Open the web UI
3. Open the Spec tab (bottom panel)
4. Click "Compare to running"
5. Observe: button text/background turns orange; nothing else changes on screen
6. (Optional) Edit the on-disk YAML to introduce a small change without reloading. Toggle compare off and on. The most you'll see is faint line tinting on the few lines whose text happens to contain a changed item's name.

### Affected Environments
All — this is pure frontend logic in `web/src/components/spec/SpecTab.tsx`. No platform, browser, or backend dependency.

### Non-Affected Environments
None. The Header reload flow shows a full diff modal correctly, but that is a separate code path.

### Failure Mode
Silent UX failure. No console errors. No network errors. The plan endpoint succeeds; its data is just routed to a near-invisible inline highlighter that returns null for most lines and never opens a comparison surface.

## Fix Assessment

### Fix Surface
- `web/src/components/spec/SpecTab.tsx` — change the toggle handler to open the diff modal in a new "compare" mode instead of relying on inline tinting; remove or sunset `getDriftForLine` and the per-line drift classes
- `web/src/components/spec/SpecDiffModal.tsx` — add a "compare" mode (different title, no Apply button, explicit no-drift empty state)
- `web/src/stores/useSpecStore.ts` — minimal additions to drive compare-mode modal state (or reuse `diffModalOpen` with a mode flag)
- One regression test in `web/src/__tests__/SpecComponents.test.tsx`

No backend changes required. The `appliedSpec` baseline already exists in the store (`useSpecStore.ts:17, 66`) and is set whenever the user reloads.

### Risk Factors
- `appliedSpec` is seeded from the first-loaded spec when the user opens the UI (`useSpecStore.ts:66`). If the gateway is already running a different spec from before the session and the user has not reloaded, "compare to running" will say "no drift" even when drift exists. This is a follow-up worth flagging — out of scope for this fix.
- Two callers (reload flow + compare button) sharing the diff modal means the modal must distinguish modes cleanly. Mishandling the mode could break either flow.
- Removing the per-line tint behavior is a small visible behavior change but unlikely to be missed since it was barely perceptible.

### Regression Test Outline
Add a test in `web/src/__tests__/SpecComponents.test.tsx`:
- Setup: store with `spec.content = "a"` and `appliedSpec.content = "b"`
- Action: render `SpecTab`, click the "Compare to running" button
- Assert: `diffModalOpen` becomes true; modal renders with mode=compare; modal shows the diff; clicking close resets state. Assert the Apply button is not present in compare mode.
- Second case: same content for both → modal opens, "No drift" empty state visible, no Apply button.

## Recommendation

**Fix with caveats — minimal scope, reuse `SpecDiffModal`.**

Wire "Compare to running" to open `SpecDiffModal` in a new read-only "compare" mode that diffs `spec.content` against `appliedSpec.content`. Add an explicit "No drift — spec matches running gateway" empty state. Hide the Apply button in compare mode.

Caveats:
- `appliedSpec` is initialized to the first spec the user loads, not the gateway's actual running spec at session start. Document this in the UI copy or a follow-up ticket; do not block this fix on a new `/api/stack/spec/running` endpoint.
- Remove the dead-code path in `getDriftForLine` and the per-line drift class names in `SpecTab.tsx:88-100, 250-252`. They are misleading and replaced by the modal.

This keeps blast radius small, reuses a proven component, and delivers the user-visible behavior the button promises. A future ticket can introduce a true running-spec backend endpoint if `appliedSpec` proves insufficient.

## References

- Frontend component: `web/src/components/spec/SpecTab.tsx`
- Diff modal (reusable): `web/src/components/spec/SpecDiffModal.tsx`
- State store: `web/src/stores/useSpecStore.ts`
- Reload flow (existing modal consumer): `web/src/components/layout/Header.tsx`
- Backend plan endpoint (kept as-is, not used by this fix): `internal/api/stack.go:217-237`
- Plan computation (kept as-is): `pkg/config/plan.go`
