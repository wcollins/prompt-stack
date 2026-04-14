# Bug Investigation: Unstable Selector Infinite Re-render

**Date**: 2026-04-06
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Critical
**Fix Complexity**: Trivial (3-5 lines, one file)

## Summary

The `useDriftedServers` selector in `usePinsStore.ts` creates a new array reference on every call, violating React's `useSyncExternalStore` contract. React's StrictMode double-invokes snapshot checks, detects the reference instability, and schedules re-renders infinitely. The app crashes immediately on load for all users with React error #185 ("Maximum update depth exceeded").

## The Bug

**Wrong behavior**: The UI crashes immediately on load, showing the ErrorBoundary with "Something went wrong" and the minified React error #185.

**Expected behavior**: The UI renders normally.

**Discovery**: Direct user observation — app is completely unusable.

The `useDriftedServers` hook uses a Zustand selector that returns a new array reference (`return []` or `.map()`) on every invocation. Zustand v5 uses React's `useSyncExternalStore` internally, which calls `getSnapshot()` multiple times per render to detect concurrent store tearing. Because every call returns a new reference, React perpetually detects a "snapshot changed" condition and schedules re-renders without bound. With `<StrictMode>` enabled, this manifests immediately on the very first render.

## Root Cause

### Defect Location

`web/src/stores/usePinsStore.ts:17-24` — the `useDriftedServers` selector.

```typescript
export const useDriftedServers = () =>
  usePinsStore((s) => {
    if (!s.pins) return [];        // ← new [] reference every call
    return Object.entries(s.pins)
      .filter(([, sp]) => sp.status === 'drift')
      .map(([name, sp]) => ({ name, ...sp }));  // ← new array + new objects every call
  });
```

### Code Path

```
main.tsx (StrictMode)
  → App → AppContent → StatusBar (StatusBar.tsx:134)
    → PinDriftBadge (PinDriftBadge.tsx:8)
      → useDriftedServers()
        → usePinsStore(selector)
          → useSyncExternalStore(subscribe, getSnapshot)
            → getSnapshot() called multiple times per render
              → selector returns new [] reference each call
                → React detects snapshot inconsistency
                  → schedules re-render → infinite loop → error #185
```

### Why It Happens

React's `useSyncExternalStore` (which Zustand v5 uses under the hood) requires that `getSnapshot()` be a **pure function returning a stable reference** when the underlying store has not changed. The contract: if called twice in a row without a store mutation in between, it must return the same reference.

`useDriftedServers` violates this contract in both branches:
- **Null branch**: `return []` — allocates a new array on every call
- **Non-null branch**: `.map(([name, sp]) => ({ name, ...sp }))` — allocates a new array and new objects on every call

In React's Strict Mode (enabled in `main.tsx:16`), `getSnapshot` is invoked twice during each render pass. The two calls return different references. React treats this as "the external store was mutated during render" and schedules another render. This cycle repeats until React's maximum update depth (25 iterations) is exceeded, throwing error #185.

### Similar Instances

`useDetachedWindowSync` in `useBroadcastChannel.ts:52-59` passes an inline `onMessage` callback to `useBroadcastChannel`, making its `[onMessage]` dep array unstable on every render. This is a different pattern but the same class of issue (unstable reference in effect/hook deps). It only affects detached window pages, not the main app.

`useKeyboardShortcuts` in `App.tsx:129-144` receives an inline options object every render, making `[options]` dep always change. This causes unnecessary event listener re-registration on every render but does not call setState, so it does not contribute to error #185. Still a secondary bug worth fixing.

## Impact

### Severity Classification

**Critical** — Full app crash. This is not a degraded experience; the app is completely non-functional for all users.

### User Reach

100% of users who run `gridctl` and open the UI. The crash occurs on the main `/` route during initial render.

### Workflow Impact

Complete critical-path blocker. No feature of the app is accessible.

### Workarounds

None. The app cannot be used at all in its current state. Rolling back to before commit `bf03850` would restore functionality.

### Urgency Signals

- App is non-functional for all users
- The bug was introduced in a recent feature commit (`bf03850` — "add usePinsStore with drift server selector")
- No partial mitigation is available short of reverting or applying the fix

## Reproduction

### Minimum Reproduction Steps

1. Run `gridctl` (or ensure the backend is accessible)
2. Open the UI at `http://localhost:<port>/`
3. Observe the "Something went wrong" error screen immediately on load

### Affected Environments

- All environments where the current codebase is built and served
- Both development (with Vite dev server) and production builds
- Crash is triggered by React StrictMode on initial render, before any async polling

### Non-Affected Environments

- Any environment running a commit before `bf03850` (before `usePinsStore` was introduced)

### Failure Mode

The crash occurs synchronously during the initial render cycle. React's ErrorBoundary (`App.tsx:11-42`) catches the thrown error and renders the fallback "Something went wrong" UI. The progress bar visible in the screenshot indicates the boundary rendered mid-load.

## Fix Assessment

### Fix Surface

Single file: `web/src/stores/usePinsStore.ts`

The `useDriftedServers` export must be refactored to:
1. Return a stable empty array constant for the null-pins case (instead of `return []`)
2. Use `useMemo` to memoize the derived array, recomputing only when `pins` changes

No other files need modification for the primary fix.

### Risk Factors

- Low risk — change is isolated to one store file
- `PinDriftBadge` is the only consumer of `useDriftedServers`; behavior for that component is unchanged
- The `pins` reference from Zustand is stable between `setPins()` calls, so `useMemo([pins])` correctly recomputes only on actual data changes

### Regression Test Outline

In `web/src/__tests__/hooks.test.ts` (or a new `usePinsStore.test.ts`):
1. Call `useDriftedServers()` twice with pins state set to `null` — assert both calls return the same reference (`Object.is` equality)
2. Set pins to a non-drifted server map — call `useDriftedServers()` twice — assert same reference
3. Set pins with drifted servers — call `useDriftedServers()` twice — assert same reference and correct content

## Recommendation

Fix immediately. This is a trivial fix (3-5 lines changed in a single file) with low risk and maximum user impact. The root cause is fully understood, the exact defect location is confirmed, and the correct pattern is well-established in React/Zustand best practices.

The secondary bugs (`useKeyboardShortcuts([options])` and inline `onMessage` in `useDetachedWindowSync`) should be addressed in a follow-up PR — they are not blocking but represent the same class of reference-stability mistake.

## References

- React error #185: https://react.dev/errors/185
- React `useSyncExternalStore` docs: the "getSnapshot must return a stable value" requirement
- Zustand v5 migration: stores now use `useSyncExternalStore` under the hood, making selector stability a hard requirement
- Commit introducing defect: `bf03850` ("add usePinsStore with drift server selector")
