# Bug Fix: Popout Button Closes Its Own Window

## Context

gridctl is a Go-based control plane for MCP gateways, with a React 19 + Vite web UI under `web/`. The web app uses Zustand for client state (`web/src/stores/useUIStore.ts`), React Router v7 for routing, and a `useWindowManager` hook (`web/src/hooks/useWindowManager.ts`) for opening "detached" panels into separate browser tabs. The right-hand sidebar (gateway/node detail) and bottom-panel tabs each render a `PopoutButton` (square-with-arrow icon) that calls `useWindowManager.openDetachedWindow(type)` to spawn a detached window at `/<type>` (e.g. `/registry`, `/sidebar`, `/logs`).

## Investigation Context

- Root cause confirmed: per-component `windowRefs` (`useWindowManager.ts:18`) + unmount cleanup at `useWindowManager.ts:172-182` that calls `win.close()` for every tracked window. The same `openDetachedWindow` call that opens the window also flips `setSidebarOpen(false)` (or `setBottomPanelOpen(false)`), which causes the caller's parent (`{sidebarOpen && <aside>…<Sidebar/>…</aside>}` at `web/src/components/workspaces/TopologyWorkspace.tsx:106`) to unmount, firing the cleanup, which closes the just-opened window.
- Reproduces deterministically in Chrome, Safari, and Firefox; popups allowed; user confirmed bottom-panel popouts (logs, metrics, traces) work in practice while right-sidebar popouts do not — the architectural fix below covers both paths.
- Approach selected by user: **hoist `windowRefs` to module scope** so unmounting a hook consumer never closes child windows. Plus a defensive null-check on `window.open` for robustness.
- Full investigation: `prompt-stack/prompts/gridctl/popout-button-closes-itself/bug-evaluation.md`.

## Bug Description

Clicking the PopoutButton (ExternalLink icon) in the gridctl gateway detail sidebar (or any non-bottom-panel popout) causes:

- The source sidebar collapses (expected, intentional).
- A new browser tab momentarily appears and immediately closes (not expected).
- No detached window remains for the user.

Expected behavior: the detached window opens and stays open, showing the panel content. The user can drag it to a second monitor or arrange it alongside the main app.

## Root Cause

`useWindowManager` stores opened-window references in a per-component `useRef<Map>` (`web/src/hooks/useWindowManager.ts:18`). Its unmount cleanup (`web/src/hooks/useWindowManager.ts:172-182`) iterates that map and calls `win.close()` on every tracked window.

The synchronous `openDetachedWindow(type)` flow mutates a UI flag *before* calling `window.open`:

```ts
// useWindowManager.ts:96-99 (the registry case — others are analogous)
} else if (type === 'registry') {
  setRegistryDetached(true);
  setSidebarOpen(false);              // ← triggers unmount of the caller's parent
}
// ...
const newWindow = window.open(url, `gridctl-${type}`);
// ...
windowRefs.current.set(type, newWindow);   // ref stored
```

After the handler returns, React 19 flushes the state update; `TopologyWorkspace`'s `{sidebarOpen && <aside>…<Sidebar/>…</aside>}` evaluates false; `Sidebar` (and its subtree, including `GatewaySidebar`) unmounts; the cleanup fires and calls `close()` on the window opened ~milliseconds earlier.

The correct logical model: detached windows live for the lifetime of the *opener page*, not the lifetime of any one React component that happens to have called the hook. The fix is to make `windowRefs` module-scoped (a singleton) and remove the unmount cleanup that closes them.

## Fix Requirements

### Required Changes

All changes are in `web/src/hooks/useWindowManager.ts`.

1. Move `windowRefs` to module scope:
   ```ts
   // Module-scope: detached windows live for the lifetime of the opener page,
   // not the lifetime of any particular component instance.
   const windowRefs: Map<string, Window | null> = new Map();
   ```
   Remove the `const windowRefs = useRef<Map<string, Window | null>>(new Map());` from inside `useWindowManager()`.

2. Update every reference to `windowRefs.current` to use `windowRefs` directly (there are several: focus-existing-window check at lines 81-85, `windowRefs.current.set` at 112, `windowRefs.current.delete` at 70 and 123, and the unmount-cleanup `forEach` at 175).

3. Delete the unmount-cleanup `useEffect` at `useWindowManager.ts:172-182` in its entirety. The browser already reaps child windows when the opener unloads — no explicit close is needed. Detached windows have their own close button and their own `beforeunload` notification path (`useBroadcastChannel.ts:69-77`).

4. Add a `null`-return guard on `window.open` (lines 109-141). If the browser blocks the popup, roll back the eager state-flip so the source panel doesn't end up collapsed with no window to show for it:
   ```ts
   const newWindow = window.open(url, `gridctl-${type}`);
   if (!newWindow) {
     // Popup blocked or otherwise refused. Roll back the eager state flip so
     // the user still sees the source panel.
     if (type === 'logs') {
       setLogsDetached(false);
       setBottomPanelOpen(true);
     } else if (type === 'sidebar') {
       setSidebarDetached(false);
       setSidebarOpen(true);
     } else if (type === 'editor') {
       setEditorDetached(false);
     } else if (type === 'registry') {
       setRegistryDetached(false);
       setSidebarOpen(true);
     } else if (type === 'metrics') {
       setMetricsDetached(false);
     } else if (type === 'var') {
       setVaultDetached(false);
     } else if (type === 'traces') {
       setTracesDetached(false);
     }
     return;
   }
   ```
   The branches mirror the eager-flip block at lines 89-106. (If you want to avoid the duplicate branching, factor them into two small `setDetached(type, value)` / `restorePanel(type)` helpers — optional.)

### Constraints

- Do not change `openDetachedWindow`'s public surface (it's used by `Sidebar`, `GatewaySidebar`, `RegistrySidebar`, `LogsTab`, `MetricsTab`, `TracesTab`).
- Preserve the existing focus-existing-window behavior at lines 81-85 (`existingWindow.focus()`).
- Preserve the existing `setInterval` `closed`-polling block (lines 120-141) that syncs state back when the user closes the detached window manually — but it now reads from module-scope `windowRefs`.
- Keep the `handleMessage` BroadcastChannel logic unchanged — it only reads `windowRefs.delete` (was `windowRefs.current.delete`).

### Out of Scope

- `web/src/components/vault/VaultPanel.tsx:190-193` directly calls `window.open('/var', 'gridctl-var')` outside `useWindowManager`. Out of scope here — fix in a separate follow-up.
- Runs and Pins tabs have no PopoutButton yet — separate feature gap, do not add here.
- Do not refactor the per-type `if/else if` chains into a config map in this PR — keep the diff focused on the bug fix.

## Implementation Guidance

### Key Files to Read

- `web/src/hooks/useWindowManager.ts` — the file you are modifying. Read in full first.
- `web/src/hooks/useBroadcastChannel.ts` — confirm BroadcastChannel sync does not depend on the per-component ref storage (it doesn't; it uses the channel directly).
- `web/src/stores/useUIStore.ts:148-260` — confirm the setters you'll be calling for rollback exist with the names used above.
- `web/src/components/workspaces/TopologyWorkspace.tsx:106` and `web/src/components/layout/BottomPanel.tsx:147` — to understand why the cleanup-causes-close path exists.
- `web/src/__tests__/RegistryPanel.test.tsx:22` and `web/src/__tests__/GatewayPanel.test.tsx:20` — to see how `openDetachedWindow` is currently mocked away in tests.

### Files to Modify

- `web/src/hooks/useWindowManager.ts` — the only production file changed.
- `web/src/__tests__/useWindowManager.test.tsx` — new file with the regression test (see below).

### Reusable Components

- `useUIStore` setters are already imported; reuse them in the rollback branch.
- `vi.spyOn(window, 'open')` for the test — see `web/src/__tests__/` for existing patterns using `vi`.

### Conventions to Follow

- This codebase prefers concise inline comments only when they explain *why*. Don't add docstrings.
- Keep the diff minimal — don't reformat, don't rename, don't introduce abstractions beyond the rollback helper (and only if it improves the diff).
- Use `pnpm`-style scripts if applicable; otherwise `npm run` from `web/`.

## Regression Test

### Test Outline

Create `web/src/__tests__/useWindowManager.test.tsx`. Use `@testing-library/react`, `vitest`, and Zustand's store reset pattern used elsewhere in this directory.

Test case 1 — **the failing case (must pass after fix):**
- Mock `window.open` to return a `{ closed: false, focus: vi.fn(), close: vi.fn(), addEventListener: vi.fn() } as unknown as Window` stub.
- Render a tiny test harness component that uses `useWindowManager` *inside* a conditional render gated by `useUIStore.sidebarOpen`.
- Set `sidebarOpen = true`. Render. Call `openDetachedWindow('registry')`.
- `act()` to flush effects.
- Assert: `window.open` was called once with `'/registry'` and `'gridctl-registry'`.
- Assert: the stub `close` spy was **not** called.
- Assert: `useUIStore.getState().registryDetached === true` and `sidebarOpen === false`.

Test case 2 — **popup blocked rollback:**
- Mock `window.open` to return `null`.
- Same harness; call `openDetachedWindow('registry')`; flush.
- Assert: `useUIStore.getState().registryDetached === false` and `sidebarOpen === true` (state rolled back).

### Existing Test Patterns

- See `web/src/__tests__/GatewayPanel.test.tsx` and `web/src/__tests__/RegistryPanel.test.tsx` for how this codebase wires `@testing-library/react`, mocks Zustand, and structures `describe`/`it` blocks. Match that style.
- Use `beforeEach(() => { useUIStore.setState(initialState) })` (or the codebase equivalent) to isolate store state across tests.

## Potential Pitfalls

- After moving `windowRefs` to module scope, the file no longer needs `useRef` for that ref. Make sure you remove the import if it becomes unused, but don't strip other React imports relied on by `useCallback` / `useEffect`.
- The `setInterval(...500)` poll loop at lines 120-141 closes over `newWindow` already, so moving `windowRefs` doesn't change its capture. Just update the `windowRefs.current.delete(type)` call inside it to `windowRefs.delete(type)`.
- React 19 Strict Mode still applies in dev. With the unmount cleanup gone, Strict Mode's double-mount no longer can spuriously close windows. Verify this manually: in dev, open and close a popout, then immediately open another — both should work.
- The `handleMessage` callback at lines 31-73 references `windowRefs.current.delete` on line 70 — update that too.
- Don't accidentally introduce a leak: the `setInterval` poll already cleans up `windowRefs` when the user closes the detached window. That path still works after this change — verify the polling block runs whether `windowRefs` is module-scope or component-scope; it does (the loop captures `newWindow` and `type` directly).
- The hook's `openDetachedWindow` is wrapped in `useCallback` with Zustand setter deps. Those setters are stable, so the callback identity stays stable. Don't change the deps array — that's correctness-preserving.

## Acceptance Criteria

1. Clicking the PopoutButton in the gridctl-gateway sidebar (matching the reported screenshot) opens a new browser tab at `/registry` AND the tab remains open.
2. Same for the node-detail sidebar PopoutButton (opens `/sidebar?node=…`).
3. Same for the bottom-panel popouts (logs, metrics, traces) — no regression.
4. If popups are blocked (test by enabling a popup blocker for the origin), the source panel does NOT collapse — state rolls back cleanly.
5. Closing the detached window by clicking its system close button still flips the corresponding `*Detached` UI flag back to `false` in the main window (BroadcastChannel path still works).
6. New regression test `web/src/__tests__/useWindowManager.test.tsx` passes.
7. Existing `web/src/__tests__/RegistryPanel.test.tsx` and `web/src/__tests__/GatewayPanel.test.tsx` still pass.
8. `cd web && npm run build` succeeds (typecheck + vite build).
9. `cd web && npm run lint` is clean.

## References

- Investigation document: `prompt-stack/prompts/gridctl/popout-button-closes-itself/bug-evaluation.md`
- Touched-recently commits: `70a516a` (var rename, did not introduce this bug but is the most recent edit), `3f741ce` (popup→tab refactor, intentional).
- Detached page routes: `web/src/routes.tsx:68-78`.
- Detached pages that the popouts navigate to: `web/src/pages/Detached*Page.tsx`.
