# Bug Investigation: Popout Button Closes Its Own Window

**Date**: 2026-05-19
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

The "Open in new tab" PopoutButton on the gateway / node sidebar appears to flash a tab and then close it — no detached window remains. Root cause is a self-inflicted unmount-then-close race in `useWindowManager`: the same click that calls `window.open` also flips a UI flag that conditionally unmounts the calling component, and the hook's unmount cleanup then closes the window it just opened. Reproduces in Chrome, Safari, and Firefox because the cause is React lifecycle, not browser policy.

## The Bug

Clicking the PopoutButton (ExternalLink icon, square-with-arrow) in the right-hand sidebar — visible in the gateway detail panel ("gridctl-gateway"), node detail panel, and embedded registry — produces:

- **Observed**: Source sidebar collapses; main screen flashes; no new tab/window is visible.
- **Expected**: Source sidebar collapses (intentional) AND a new browser window opens with the detached panel content.
- **Discovery**: User report. Reproduces deterministically across three browsers with popups allowed.
- **Reported scope**: User confirmed the bottom-panel popouts (logs, metrics, spec, traces) work correctly; this bug is scoped to the right-hand sidebar popouts (gateway / registry / node sidebar). Runs and Pins tabs lack a popout button entirely (separate feature gap, not part of this bug).

## Root Cause

### Defect Location

- Primary: `web/src/hooks/useWindowManager.ts:172-182` — unmount cleanup forcibly closes every window in the per-component `windowRefs` Map.
- Trigger: `web/src/hooks/useWindowManager.ts:89-106` — `openDetachedWindow` calls `setSidebarOpen(false)` (and friends) in the same synchronous handler that calls `window.open`.
- Conditional render that unmounts the caller: `web/src/components/workspaces/TopologyWorkspace.tsx:106` — `{sidebarOpen && <aside>…<Sidebar />…</aside>}`.

### Code Path

1. User clicks `PopoutButton` in `GatewaySidebar` (`web/src/components/gateway/GatewaySidebar.tsx:46-49`).
2. `handlePopout` → `openDetachedWindow('registry')`.
3. Inside `openDetachedWindow` (synchronous):
   - `setRegistryDetached(true)`
   - `setSidebarOpen(false)`  ← **this is the fuse**
   - `window.open('/registry', 'gridctl-registry')` returns a `Window`.
   - `windowRefs.current.set('registry', newWindow)` — ref stored.
4. Event handler returns.
5. React flushes batched state updates. `sidebarOpen` is now `false`.
6. `TopologyWorkspace` re-renders → `{sidebarOpen && …}` evaluates false → the `<aside>` (and its `<Sidebar>` → `<GatewaySidebar>` subtree) unmounts.
7. React fires every `useEffect` cleanup in the unmounted subtree, including the one at `useWindowManager.ts:172-182`:
   ```ts
   useEffect(() => {
     const refs = windowRefs.current;
     return () => {
       refs.forEach((win) => { if (win && !win.closed) win.close(); });
       refs.clear();
     };
   }, []);
   ```
8. `win.close()` runs on the registry window opened ~milliseconds earlier. The browser closes it before its first paint — the user perceives only a flash.

### Why It Happens

`useWindowManager` keeps `windowRefs` in a component-local `useRef`. Each component using the hook (Sidebar, GatewaySidebar, RegistrySidebar, LogsTab, MetricsTab, TracesTab) owns an independent Map. The unmount cleanup is conceptually meant to clean up "when the main app unloads," but it actually runs every time the component instance unmounts — including transient unmounts caused by the same panel-collapse animation that `openDetachedWindow` triggers as part of its happy path.

In other words: `openDetachedWindow` and its own caller's parent's conditional render are at war. The hook fires the eager state mutation to give a flicker-free panel collapse, then the unmount that flicker-free collapse causes turns around and kills the window the hook just opened.

### Similar Instances

- `web/src/components/vault/VaultPanel.tsx:190-193` calls `window.open('/var', 'gridctl-var')` *directly*, bypassing `useWindowManager` entirely — no detached-state tracking, no ref management, no broadcast sync. This is a separate consistency bug worth fixing alongside (out of scope for this fix).
- All call sites of `useWindowManager()` share the same per-component-ref architecture (`Sidebar`, `GatewaySidebar`, `RegistrySidebar`, `LogsTab`, `MetricsTab`, `TracesTab`) — any of them can in principle trip the same unmount-closes-window race. User report indicates only the right-sidebar popouts visibly break in practice (most likely because `setSidebarOpen(false)` is the most aggressive unmount trigger); the architectural fix eliminates the class regardless.

## Impact

### Severity Classification

Regression-class **incorrect behavior** affecting a flagship UI affordance. Not a crash, not data loss, not security — just a feature that visibly does the opposite of what it advertises.

### User Reach

100% of users who try to detach the right-hand sidebar (gateway, node, embedded registry). High visibility because the gateway detail panel is opened by clicking the gateway node on the topology — a common interaction.

### Workflow Impact

Blocks the "scan details in a second window while keeping the main view free" workflow. The user-facing PopoutButton is the only entry point — there is no keyboard shortcut, no "Open in new tab" via right-click (these are programmatic `window.open` targets, not anchor links).

### Workarounds

None in-product. Users could manually navigate to `/registry` or `/sidebar?node=…` in a new tab if they know the URLs, but that's not a discoverable workflow.

### Urgency Signals

Pre-stable beta, but visibly broken on the most prominent right-side affordance. Bad first-run impression. Should land before the next beta cut.

## Reproduction

### Minimum Reproduction Steps

1. Build: `make build` then `./gridctl serve --foreground` (or `cd web && npm run dev`).
2. Open the web UI; click the gateway node on the topology to open the gateway detail sidebar on the right.
3. In the sidebar header, click the **ExternalLink** icon (square + arrow) to the left of the close X.
4. Observe: sidebar collapses, a tab momentarily appears and disappears, no detached window remains.

Repeat for a non-gateway node — same result via `openDetachedWindow('sidebar', …)`.

### Affected Environments

- All browsers (confirmed Chrome, Safari, Firefox).
- All OS (logic is React/JS only).
- Vite dev server and embedded `gridctl serve` static build.

### Non-Affected Environments

Bottom-panel popouts (Logs, Metrics, Traces, Spec) work — confirmed by user. This is consistent with the bottom tabs not following the same `setSidebarOpen(false)`-triggered conditional render pattern in observed behavior, even though the code path is similar; the architectural fix covers them either way.

### Failure Mode

`window.open` succeeds. The new window briefly mounts in the browser's tab strip. React's commit phase then unmounts the caller component, runs the cleanup, and `Window.prototype.close()` fires on the still-loading detached page.

## Fix Assessment

### Fix Surface

Single file: `web/src/hooks/useWindowManager.ts`.

### Risk Factors

- BroadcastChannel sync is already independent of windowRefs, so changing the ref storage doesn't break cross-window state.
- The cleanup currently in place provides no real safety net — when the main page actually unloads, the browser closes child windows anyway (or at minimum doesn't leak references on a reaped origin). Removing it has effectively zero downside.
- Need to keep the per-type focus-existing-window behavior at lines 81-85; that depends on `windowRefs` and should work identically after hoisting.

### Regression Test Outline

Add to `web/src/__tests__/useWindowManager.test.tsx` (new file). With a `vi.spyOn(window, 'open')` returning a stub Window-like object with a `close` spy:

1. Render a component that uses `useWindowManager` and a parent that conditionally renders that component based on a Zustand flag.
2. Invoke `openDetachedWindow('registry')` (the failing case).
3. Flush effects.
4. Assert: `window.open` called once; the stub's `close` spy **not** called; `registryDetached` is `true` in the store.

The current code (pre-fix) fails the "`close` not called" assertion.

## Recommendation

**Fix immediately**, with approach #1: hoist `windowRefs` to module scope.

- Move `const windowRefs = new Map<string, Window | null>()` to module level.
- Remove the unmount cleanup that calls `win.close()` (lines 172-182) entirely — windows live across hook instances.
- Optionally add a `window`-level `beforeunload` listener for a *truly* one-time "close children on page unload" hook, but the browser already handles this and the listener is not necessary for correctness.
- Defensive add: handle the `window.open(...) === null` case by rolling back the eager state flip and showing a toast (unrelated to this bug but a small, cheap robustness gain).

Approach #2 (just delete `win.close()` from the cleanup) is acceptable as a minimal-diff fallback if the reviewer prefers it, but #1 is structurally correct: detached-window tracking is application-global, not component-local.

## References

- Touched in: `70a516af` (var rename, recent), `3f741ce` (popup → tab refactor, intentional, not the cause).
- Related files visible during investigation: `web/src/components/workspaces/TopologyWorkspace.tsx`, `web/src/components/layout/BottomPanel.tsx`, `web/src/hooks/useBroadcastChannel.ts`, `web/src/pages/Detached*Page.tsx`.
- Out-of-scope follow-ups discovered:
  - `web/src/components/vault/VaultPanel.tsx:190-193` bypasses `useWindowManager` with a direct `window.open` — should be migrated for consistency.
  - Runs and Pins tabs have no popout button — separate feature gap noted by user.
