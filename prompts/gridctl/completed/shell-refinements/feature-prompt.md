# Feature Implementation: Unified Shell Refinements

## Context

`gridctl` is a Go + React workspace for inspecting MCP servers, agent skills, and run traces. The web UI lives in `web/` (Vite + React 18 + TypeScript + Tailwind + Zustand + React Router + React Flow).

The recently shipped unified shell (PRs #635/#637/#638/#639) merged the legacy `/topology` and `/agent` IDE shells into a single `AppShell` at `web/src/components/shell/AppShell.tsx`. The shell uses CSS grid for the outer layout (header / outlet / bottom panel / status bar) and React Router `<Outlet />` to swap workspaces. Three workspaces exist today:

- `/topology` — `TopologyWorkspace` (React Flow canvas + right-rail Sidebar inspector)
- `/skills` — `SkillsWorkspace` (the former Agent IDE — sidebar / canvas / inspector triptych)
- `/runs` — `RunsWorkspace` (filtered runs grid with global SSE bus)

Cross-workspace state lives on `useUIStore` (Zustand slices pattern). Workspace-specific stores: `useStackStore` (topology), `useRunsStore` (runs).

A global SSE stream mounts via `useGlobalRunsStream()` at the shell level so the in-flight badge stays live regardless of the active workspace.

## Evaluation Context

Three follow-up gaps were identified from the four-PR shell unification:

1. **Layout drift between workspaces.** `TopologyWorkspace` uses an absolute overlay for its right-rail inspector; `SkillsWorkspace` uses a permanent grid column. The center content (canvas) shifts horizontally when switching workspaces.
2. **Hardcoded workspace indexing.** `AppShell.tsx:117-119` literally indexes `WORKSPACES[0/1/2]`; `useKeyboardShortcuts.ts` enumerates per-workspace callbacks. A partial registry already exists in `web/src/types/workspace.ts` (`WORKSPACES`, `WORKSPACE_LABELS`) — it needs to be *extended*, not created from scratch.
3. **No SSE control.** `useGlobalRunsStream` is always-on for the session. No UI affordance to pause/resume.

The evaluation found all three claims accurate as of 2026-05-15. See `feature-evaluation.md` in this folder for full verification notes.

**Architectural decisions baked into this prompt:**
- Phase 1 uses a *collapsible* grid column (column collapses to 0 when inspector is closed) so the canvas can still reclaim full width — matching today's behaviour for a wide topology view.
- Phase 2 *extends* the existing `web/src/types/workspace.ts` rather than creating `web/src/config/workspaces.ts` — keeps the type guard, labels, and runtime metadata colocated. Icons via direct `lucide-react` component imports (consistent with project conventions; typesafe; tree-shakeable).
- Phase 3 uses a single global toggle in `useUIStore` (per-stream toggle is speculation — only one stream exists). State persists via the existing `partialize` config.

## Feature Description

Three independent refinements, each shipped as its own PR:

1. **Standardize Right-Rail Inspector Layout** — Refactor `TopologyWorkspace` from absolute-overlay inspector to a collapsible grid-column inspector matching `SkillsWorkspace`.
2. **Dynamic Workspace Registration** — Extend `web/src/types/workspace.ts` into a flat config registry (route + label + icon + shortcut) and refactor `AppShell` and `useKeyboardShortcuts` to iterate the registry.
3. **Global SSE Stream Control** — Add a "Live"/"Paused" toggle in `BottomPanel` (Runs tab header) and `StatusBar` that gates `useGlobalRunsStream`'s EventSource.

## Requirements

### Functional Requirements

**Phase 1 (Inspector Layout):**
1. `TopologyWorkspace` uses a CSS grid layout with `gridTemplateColumns` for the inspector column (not absolute positioning).
2. When `sidebarOpen` is `false`, the inspector grid column has zero width (or is omitted) so the canvas reclaims the full main area.
3. When `sidebarOpen` is `true`, the inspector grid column animates in. Animation parity with today's slide-in is nice-to-have but not required — a clean show/hide is acceptable if it cleanly preserves the rest of the UX.
4. The `ResizeHandle` for the inspector remains functional (user can drag to resize width).
5. The Canvas component (React Flow) renders correctly inside a grid cell. The current Canvas uses `CanvasBase` and React Flow's `<ReactFlow>` which size to their container — confirm by manual test, not by reading.
6. Switching between `/topology` (inspector open) and `/skills` produces no horizontal shift of the center content area.
7. The "loading" and "error" overlays still render correctly (they were absolute-positioned inside `<main>`; they may need adjustment if `<main>` no longer contains an absolute child as the layout root).

**Phase 2 (Workspace Registry):**
1. `web/src/types/workspace.ts` exports a `WORKSPACE_CONFIG` array (or equivalent name) where each entry has: `id: Workspace`, `label: string`, `icon: LucideIcon`, `shortcutKey: string` (e.g., `'1'`, `'2'`, `'3'`).
2. The existing `WORKSPACES` constant continues to be derived from `WORKSPACE_CONFIG` (e.g., `WORKSPACES = WORKSPACE_CONFIG.map(w => w.id)`) so existing call-sites that use it keep working.
3. `WORKSPACE_LABELS` may either be retained as a derived `Record<Workspace, string>` for backwards compat, or removed if every call-site is migrated to read `.label` from the config — pick one and apply it consistently. No half-migrations.
4. `AppShell.tsx` no longer indexes `WORKSPACES[0..2]`. Workspace-switch shortcuts wire up by iterating the config.
5. `useKeyboardShortcuts.ts` no longer enumerates `onSwitchToTopology/Skills/Runs`. Replace with a single `onSwitchToWorkspace: (id: Workspace) => void` callback (or equivalent) called with the right id based on the matched shortcut key.
6. `WorkspaceSwitcher.tsx` reads icon + label from the registry (currently only uses label).
7. Existing tests in `web/src/__tests__/WorkspaceSwitcher.test.tsx` and `web/src/__tests__/useKeyboardShortcuts.test.tsx` pass (update fixtures as needed).
8. Adding a new workspace to the registry is sufficient to make it appear in the switcher and bind a shortcut — no AppShell edits required (verify this property in code review, not by adding a fake workspace).

**Phase 3 (SSE Control):**
1. `useUIStore` exposes `runsStreamEnabled: boolean` (defaults to `true`) and `setRunsStreamEnabled` / `toggleRunsStreamEnabled` actions.
2. `runsStreamEnabled` is added to the `partialize` allowlist so it persists to localStorage.
3. `useGlobalRunsStream` reads `runsStreamEnabled`. When `false`, the EventSource is closed (or never opened). When toggled back to `true`, the EventSource reopens.
4. `useRunsStore.streamStatus` union gains a `'paused'` variant. The hook sets status to `'paused'` when the toggle is off, `'connecting'` / `'open'` / `'error'` otherwise.
5. `BottomPanel` shows a Live/Paused toggle in the tabs header — visually associated with (but not blocking) the Runs tab. The toggle is always visible (not gated on the Runs tab being active) so users can pause without navigating.
6. `StatusBar` shows a stream-status chip that doubles as a click-to-toggle control. Visual treatment matches the existing `connectionStatus` chip so it doesn't feel bolted on.
7. When paused, the in-flight badge value freezes at its last-known value — do not clear `inFlightRuns`.
8. Toggle state survives page reload.

### Non-Functional Requirements

- **No backend changes.** All three phases are frontend-only.
- **Type safety.** `tsc --noEmit` passes after each phase.
- **No new dependencies.** Use existing `lucide-react`, Zustand, React Router.
- **Tests.** Don't add elaborate new tests, but keep existing tests green. Update fixtures for Phase 2.
- **No emoji** in code, comments, or commits.
- **Sign commits with `-S`.**

### Out of Scope

- Renaming workspaces, routes, or store names.
- Adding a fourth workspace.
- Per-stream pause (only one stream exists).
- Reworking how `useRunsStore` dedupes events.
- A "snooze for N minutes" feature for the SSE toggle.
- Animating the grid column transition with anything fancier than a tailwind transition class.
- Replacing the Topology Sidebar component itself — only its container layout changes.

## Architecture Guidance

### Recommended Approach

**Phase 1:** Mirror `SkillsWorkspace.tsx:184-188`'s `gridTemplateColumns` pattern. Topology has only two columns to consider (canvas + inspector — no left sidebar, unlike Skills). The grid template should be `'minmax(0, 1fr) ${sidebarOpen ? sidebarWidth : 0}px'` (or equivalent). When closed, the inspector column has 0 width; keep `overflow-hidden` on the column so any partially-rendered content is clipped during transition. Move the loading/error overlays to render inside the canvas-column wrapper if needed — they should overlay the canvas, not the inspector column.

**Phase 2:** Define `WORKSPACE_CONFIG` as a `readonly` array of objects in `web/src/types/workspace.ts`. Use `lucide-react` icon component types (`LucideIcon` from `lucide-react` is the right type for `icon`). The shortcut wiring becomes: in `useKeyboardShortcuts`, build a lookup `Map<string, Workspace>` from the registry inside `useEffect`, then in the keydown handler do `const ws = lookup.get(e.key); if (ws) options.onSwitchToWorkspace?.(ws)`.

**Phase 3:** Add a `createRunsStreamSlice` following the existing slices pattern in `useUIStore`. The slice exports `runsStreamEnabled`, `setRunsStreamEnabled`, `toggleRunsStreamEnabled`. In `useGlobalRunsStream`, wrap the existing EventSource setup in an `if (runsStreamEnabled)` guard so the effect's setup function only opens the connection when enabled. The cleanup function still runs on disable (which will close the prior EventSource). Toggle the `'paused'` streamStatus from the same hook.

### Key Files to Understand

Read these before starting:

- `web/src/components/shell/AppShell.tsx` — the shell root; understand how the grid template, workspaces, and shortcut wiring fit together
- `web/src/components/workspaces/SkillsWorkspace.tsx` — the grid pattern to mirror in Phase 1
- `web/src/components/workspaces/TopologyWorkspace.tsx` — what's changing in Phase 1
- `web/src/types/workspace.ts` — the partial registry to extend in Phase 2
- `web/src/hooks/useKeyboardShortcuts.ts` — the wiring to generalise in Phase 2
- `web/src/stores/useUIStore.ts` — slices pattern + partialize convention for Phase 3
- `web/src/stores/useRunsStore.ts` — streamStatus union to extend in Phase 3
- `web/src/components/runs/useGlobalRunsStream.ts` — the hook to gate in Phase 3
- `web/src/components/layout/BottomPanel.tsx` — where Phase 3's primary toggle renders
- `web/src/components/layout/StatusBar.tsx` — where Phase 3's secondary chip renders

### Integration Points

**Phase 1:**
- `TopologyWorkspace` renders inside `AppShell`'s `<main>` outlet. `<main>` has `position: relative` and `overflow: hidden` — the new grid container should respect that (just become the immediate child).
- The Canvas's React Flow setup uses `<ReactFlowProvider>` at the shell level (`AppShell.tsx:188`) so the workspace just renders `<Canvas />`. No provider changes.

**Phase 2:**
- `Workspace` type stays as a string literal union (`'topology' | 'skills' | 'runs'`) — derive the union from `WORKSPACE_CONFIG[number]['id']` only if it stays readable.
- `isWorkspace` type guard remains. Implementation can switch to `WORKSPACES.includes(value)` if cleaner.
- `LAST_WORKSPACE_GLOBAL_KEY` / `LAST_WORKSPACE_PER_STACK_PREFIX` (used in AppShell) stay as-is.

**Phase 3:**
- The runs subscription helper `subscribeToGlobalRunEvents` returns `{ close: () => void }`. The hook already calls `sub.close()` in cleanup — that's the path used when the toggle disables.
- `useRunsStore.setStreamStatus` accepts the union directly. Add `'paused'` to the type union and call `setStreamStatus('paused')` from the hook when disabled.

### Reusable Components

- `CanvasBase` and `ResizeHandle` — already used in both workspaces; Phase 1 keeps using them
- The compact mode pattern in `useUIStore` (`createCompactModeSlice`) — Phase 3's slice should follow the same shape
- `WorkspaceSwitcher.tsx`'s `WORKSPACES.map(...)` — the same map pattern generalises to AppShell and shortcuts in Phase 2

## UX Specification

**Phase 1 — Discovery & feedback:** No new UI. The fix is invisible until users notice the absence of horizontal shift between workspaces.

**Phase 2 — Discovery & feedback:** No new UI. Pure refactor.

**Phase 3 — Discovery, activation, feedback:**
- **Discovery:** Users see a "Live" chip with a small status dot (green when active, muted when paused) in two places: BottomPanel tabs row (right-aligned), StatusBar (next to the gateway "Connected" chip).
- **Activation:** Click the chip to toggle. No confirmation needed — toggle is cheap and reversible.
- **Feedback:** Chip immediately reflects new state. When paused, the existing in-flight badge value freezes (no clearing). When resumed, the SSE reconnects and the badge resumes ticking.
- **Error states:** If the SSE errors while enabled, `streamStatus` becomes `'error'` and the chip shows a muted red state. Toggle still works to disable / re-enable.

## Implementation Notes

### Conventions to Follow

- **Tailwind classes** — match the existing density and palette of `BottomPanel`/`StatusBar`. Reuse `text-text-muted`, `text-status-running`, `text-primary` tokens.
- **Persistence** — extend the `partialize` allowlist in `useUIStore` for Phase 3. Pattern: `runsStreamEnabled: state.runsStreamEnabled`.
- **Sign commits.** Use `-S`. No `Co-Authored-By` trailers. No mention of Claude anywhere — branch name, commit message, PR title, PR body.
- **One PR per phase.** Each PR is reviewable independently. Do not bundle.

### Potential Pitfalls

- **Phase 1:** React Flow inside a grid cell. If the Canvas misbehaves (zero height, blank canvas), the grid cell likely needs an explicit `min-h-0` and `h-full` chain. Test with both inspector open and closed, and with both small and large viewports.
- **Phase 1:** The loading/error overlays (`TopologyWorkspace.tsx:43-95`) use `absolute inset-0`. After the refactor, "inset-0" should still cover the canvas area, not also the inspector column. Wrap them in the canvas-column container.
- **Phase 2:** Avoid creating a circular import between the workspace registry and any workspace components that themselves import workspace types. Keep the registry leaf-level (it imports from `lucide-react` and nothing from `web/src/components/*`).
- **Phase 2:** `useKeyboardShortcuts` is generic — its consumer (AppShell) supplies the callback. Don't import the registry inside the hook; let AppShell pass the registry-aware callback in.
- **Phase 3:** When toggling rapidly off→on→off, React's effect cleanup must not race. The existing hook closes the prior EventSource in cleanup which is correct — verify by toggling fast and watching the Network panel for orphaned streams.
- **Phase 3:** localStorage may be unavailable (privacy mode, etc.) — the existing `try { ... } catch {}` pattern in `persistLastWorkspace` (AppShell) is the convention to follow if you write raw localStorage. Going through `useUIStore`'s `persist` middleware handles this for you.

### Suggested Build Order

This feature is built in three sequential PRs. Each PR follows the standard `/branch-fork` → implement → `/pr-fork` flow. After each PR is merged, run `/reset-fork` and start the next phase.

1. **Phase 1: Standardize Right-Rail Inspector Layout** (`frontend-design`)
   Refactor `TopologyWorkspace` to use a grid-based layout for its inspector matching `SkillsWorkspace`. The inspector column collapses to 0 width when closed so the canvas reclaims full width. Touchpoints: `web/src/components/workspaces/TopologyWorkspace.tsx`. Acceptance:
   - No horizontal shift of canvas when switching `/topology` ↔ `/skills` (inspector open in both)
   - Canvas fills the full main area when inspector is closed on `/topology`
   - Inspector resize handle still works
   - Loading and error overlays cover the canvas area only, not the inspector
   - `tsc --noEmit` and existing tests pass

2. **Phase 2: Dynamic Workspace Registration** (`feature-dev`)
   Extend `web/src/types/workspace.ts` into a flat `WORKSPACE_CONFIG` registry (id + label + icon + shortcut key). Replace hardcoded indices in `AppShell` and per-workspace callbacks in `useKeyboardShortcuts`. Touchpoints: `web/src/types/workspace.ts`, `web/src/components/shell/AppShell.tsx`, `web/src/hooks/useKeyboardShortcuts.ts`, `web/src/components/shell/WorkspaceSwitcher.tsx`, related tests. Acceptance:
   - `AppShell` contains no `WORKSPACES[0]` / `[1]` / `[2]` indexing
   - `useKeyboardShortcuts` no longer enumerates three workspace-specific callbacks
   - `WorkspaceSwitcher` renders icons sourced from the registry
   - `tsc --noEmit` passes; existing tests in `__tests__/WorkspaceSwitcher.test.tsx` and `__tests__/useKeyboardShortcuts.test.tsx` pass (fixtures updated as needed)
   - No behavioural change visible to the user

3. **Phase 3: Global SSE Stream Control** (`frontend-design`)
   Add a `runsStreamEnabled` slice to `useUIStore` (persisted), gate `useGlobalRunsStream` on the flag, and render a Live/Paused toggle in `BottomPanel` and `StatusBar`. Extend `useRunsStore.streamStatus` with `'paused'`. Touchpoints: `web/src/stores/useUIStore.ts`, `web/src/stores/useRunsStore.ts`, `web/src/components/runs/useGlobalRunsStream.ts`, `web/src/components/layout/BottomPanel.tsx`, `web/src/components/layout/StatusBar.tsx`. Acceptance:
   - Clicking the Live toggle closes the EventSource (verified in Network tab); clicking again reopens it
   - Toggle state persists across page reload
   - When paused, in-flight badge value is preserved (not cleared)
   - Chips in BottomPanel and StatusBar stay in sync (single source of truth)
   - `streamStatus` returns to `'open'` after a paused→active toggle settles
   - `tsc --noEmit` passes

## Acceptance Criteria

The feature is complete when all three PRs are merged and:

1. Switching between any two workspaces produces no horizontal shift in the center content area (Phase 1).
2. `AppShell.tsx` and `useKeyboardShortcuts.ts` contain no references to `WORKSPACES[0]`/`WORKSPACES[1]`/`WORKSPACES[2]` or per-workspace callback enumerations (Phase 2).
3. `WORKSPACE_CONFIG` (or chosen equivalent) is the single source of truth for workspace metadata, including icon and shortcut (Phase 2).
4. Users can pause the global SSE stream via a visible affordance in BottomPanel or StatusBar; the toggle persists across reload (Phase 3).
5. `tsc --noEmit` passes; `npm run build` (or `make web`) completes; no console errors in the browser on `/topology`, `/skills`, `/runs`.

## References

- Existing implementation snapshot (verified 2026-05-15): `feature-evaluation.md` in this folder.
- React Flow grid-cell sizing notes: <https://reactflow.dev/learn/troubleshooting/remove-attribution> (general parent-sizing guidance applies)
- Lucide icon component types: `lucide-react`'s `LucideIcon` type
