# Feature Evaluation: Unified Shell Refinements

**Date**: 2026-05-15
**Project**: gridctl
**Recommendation**: Build
**Value**: Medium
**Effort**: Small–Medium (three loosely-coupled phases)

## Summary

Three follow-up refinements to the recently shipped unified shell (PRs #635/#637/#638/#639). Each closes a concrete gap the implementation left open: layout drift between workspaces, brittle hardcoded workspace indexing, and an SSE stream the user can't control. All three are small, isolated, and align with the architectural direction already taken. Build.

## The Idea

After the four-PR shell unification, three sharp edges remain:

1. **Layout jump on workspace switch** — `TopologyWorkspace` uses an absolute overlay for its right-rail inspector; `SkillsWorkspace` uses a permanent grid column. The center content shifts horizontally between routes.
2. **Hardcoded workspace indices** — `AppShell` and `useKeyboardShortcuts` reference `WORKSPACES[0..2]` and enumerate per-workspace callbacks. Adding a fourth workspace requires touching three files.
3. **No SSE pause affordance** — `useGlobalRunsStream` is always-on for the session. Low-bandwidth / battery-sensitive users have no control short of refreshing.

Each addresses developer-facing polish, not new user-facing functionality. Combined, they raise the shell from "works" to "feels like one application."

## Project Context

### Current State

The shell lives at `web/src/components/shell/AppShell.tsx` (CSS grid: header / outlet / bottom panel / status bar). Three workspaces are mounted via React Router `<Outlet />`. State splits across:
- `useUIStore` — cross-workspace shell state via slices (`activeWorkspace`, `compactMode`, panel toggles)
- `useStackStore` — topology data
- `useRunsStore` — runs grid, in-flight set, SSE stream status
- Workspace-local state inside each workspace component

The global SSE bus mounts via `useGlobalRunsStream()` at `AppShell.tsx:128` and stays connected for the entire session.

### Integration Surface

**Phase 1 (Inspector Layout):**
- `web/src/components/workspaces/TopologyWorkspace.tsx` — primary refactor (aside → grid column)
- Reference: `web/src/components/workspaces/SkillsWorkspace.tsx:182-252` — existing grid pattern to mirror
- `web/src/components/graph/Canvas.tsx` — Canvas currently fills via absolute positioning; confirm it still renders correctly in a grid cell

**Phase 2 (Workspace Registry):**
- `web/src/types/workspace.ts` — extend existing `WORKSPACES`/`WORKSPACE_LABELS` with icon + shortcut
- `web/src/components/shell/AppShell.tsx:103-121` — replace `WORKSPACES[0..2]` with iteration
- `web/src/hooks/useKeyboardShortcuts.ts:13-19, 73-85` — replace three callbacks with map
- `web/src/components/shell/WorkspaceSwitcher.tsx` — already iterates; minor — pull icon from config
- `web/src/__tests__/WorkspaceSwitcher.test.tsx`, `web/src/__tests__/useKeyboardShortcuts.test.tsx` — update fixtures

**Phase 3 (SSE Control):**
- `web/src/stores/useUIStore.ts` — add `runsStreamEnabled: boolean` + setter (persisted)
- `web/src/components/runs/useGlobalRunsStream.ts` — gate EventSource on the flag
- `web/src/components/layout/BottomPanel.tsx:54-114` — add Live toggle in tabs header
- `web/src/components/layout/StatusBar.tsx` — add stream indicator/toggle
- `web/src/stores/useRunsStore.ts` — extend `streamStatus` union with `'paused'`

### Reusable Components

- Existing slices pattern in `useUIStore` (`createWorkspaceSlice`, `createCompactModeSlice`) — the runs-stream toggle should follow the same convention
- Existing `partialize` config in `useUIStore` already persists `compactMode`, `edgeStyle`, `compactCards` — add `runsStreamEnabled` to the same allowlist
- `WORKSPACES.map(...)` pattern already in use at `WorkspaceSwitcher.tsx:41` — Phase 2 generalises the same idea to AppShell and shortcuts

## Market Analysis

N/A — this is internal architectural cleanup, not a user-facing feature. No competitive landscape applies. Skipping deep market research.

For reference, the registry pattern (route + icon + label + shortcut as a flat config array) is a standard React/SPA convention seen in VS Code's view containers, Linear's sidebar config, and most React Router-based shells. The conditional-grid-column pattern for collapsible inspectors is the dominant approach in IDE-style web UIs.

## User Experience

### Interaction Model

**Phase 1:** No behaviour change visible to the user beyond the absence of horizontal shift when switching workspaces. The right-rail inspector still toggles via the same triggers (node selection, escape to close). When the inspector is closed, the grid column collapses to 0 so the canvas reclaims the full width — preserving today's behaviour where an unselected Topology canvas is wide.

**Phase 2:** Zero user-visible change. Pure refactor.

**Phase 3:** A new "Live" pill/toggle appears in:
- BottomPanel tabs header (next to the Runs tab badge), labelled "Live" / "Paused" with a dot indicator
- StatusBar, as a compact stream-status chip clickable to toggle

Toggle state persists across reloads via localStorage. When paused, the in-flight badge freezes at its last value (no clearing — users can still see "there were N runs running when I paused"); resuming reconnects and the badge resumes updating.

### Workflow Impact

All three are net-positive or neutral for existing workflows. Phase 1 removes a small "huh, the canvas jumped" annoyance. Phase 3 adds a control most users will never touch but battery-sensitive users will appreciate.

### UX Recommendations

- Phase 3 toggle label: short, two-word affordance ("Live" active state, "Paused" inactive). Avoid "Stream" — too jargon-y.
- Use the same chip styling already used for `connectionStatus` in StatusBar so the new chip doesn't feel bolted on.
- Tooltip: "Pause real-time run updates" / "Resume real-time run updates" with the keyboard shortcut if added.

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Minor–Significant | Layout jump is the most visible irritant; SSE control is a power-user nicety; registry is invisible to users but real maintenance debt |
| User impact | Broad+Shallow | Affects everyone using the web UI, but each refinement is small |
| Strategic alignment | Core mission | The four shell PRs explicitly aimed at "feels like one app" — this finishes that arc |
| Market positioning | Maintain | Internal polish; no competitive angle |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal–Moderate | Three loosely-coupled phases. Phase 1 risks Canvas regression; Phase 2 touches tests; Phase 3 is additive |
| Effort estimate | Small (each phase) | ~1 file primary + 1-2 incidental files per phase |
| Risk level | Low | All three changes are reversible and isolated. Phase 1 has the highest risk (Canvas + sidebar interactions) but is contained |
| Maintenance burden | Minimal | Registry actively reduces future maintenance |

## Recommendation

**Build, in three sequential PRs.** Each phase is independently shippable and reviewable.

Suggested ordering follows risk and dependency:
1. **Phase 1 (Layout)** first — touches the most layout-sensitive code; ship and observe before stacking other changes on top.
2. **Phase 2 (Registry)** second — pure refactor, naturally consumes the cleaner Phase 1 layout pattern if any iteration emerges there.
3. **Phase 3 (SSE Control)** last — additive feature with no dependency on the prior two.

Caveats baked into the prompt:
- Phase 1 must preserve "wide canvas when no node is selected" (collapsible grid column, not permanent reservation)
- Phase 2 must keep existing `WORKSPACES`/`WORKSPACE_LABELS` exports unless every call-site is migrated in the same PR (no half-migrations)
- Phase 3 must not silently lose the "the badge once said 3" state when toggling off — leave last-known value visible

## References

- `web/src/components/shell/AppShell.tsx` — verified 2026-05-15
- `web/src/components/workspaces/TopologyWorkspace.tsx` — verified 2026-05-15
- `web/src/components/workspaces/SkillsWorkspace.tsx` — verified 2026-05-15
- `web/src/hooks/useKeyboardShortcuts.ts` — verified 2026-05-15
- `web/src/components/runs/useGlobalRunsStream.ts` — verified 2026-05-15
- `web/src/stores/useUIStore.ts` — slices pattern reference
- `web/src/stores/useRunsStore.ts` — streamStatus union to extend
- `web/src/types/workspace.ts` — existing registry primitives to extend
