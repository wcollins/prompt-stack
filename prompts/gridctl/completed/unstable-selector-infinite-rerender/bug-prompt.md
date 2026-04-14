# Bug Fix: Unstable Selector Infinite Re-render (React Error #185)

## Context

gridctl is a Go + React 19 application that provides a UI for managing MCP (Model Context Protocol) server stacks. The frontend is in `web/src/`, uses Zustand v5 for state management, Vite 8 as the build tool, and Vitest 4 for tests. The app is wrapped in React `<StrictMode>` (`main.tsx:16`).

State is managed via Zustand stores in `web/src/stores/`. Components subscribe to stores via selector hooks. Zustand v5 uses React's `useSyncExternalStore` internally, which has a hard requirement: the `getSnapshot` function (i.e., the selector) must return a **stable reference** when the underlying store state has not changed.

## Investigation Context

- Root cause confirmed at `web/src/stores/usePinsStore.ts:17-24`
- Crash is deterministic — triggers on every app load
- React StrictMode is the amplifier: it double-invokes `getSnapshot`, which immediately exposes the reference instability
- Risk is low: fix is isolated to one file, one export
- Full investigation: `prompt-stack/prompts/gridctl/unstable-selector-infinite-rerender/bug-evaluation.md`

## Bug Description

**What is wrong**: The `useDriftedServers` selector in `usePinsStore.ts` creates a new array reference on every call — both `return []` in the null branch and `.map()` in the non-null branch.

**How it manifests**: Zustand's `useSyncExternalStore` calls `getSnapshot()` multiple times per render. Each call returns a new `[]` reference. React detects snapshot inconsistency, schedules a re-render, and the cycle repeats until React throws error #185 ("Maximum update depth exceeded"). The ErrorBoundary catches it and the app shows "Something went wrong" immediately on load.

**Who is affected**: All users — the app is completely non-functional.

## Root Cause

`web/src/stores/usePinsStore.ts:17-24`:

```typescript
export const useDriftedServers = () =>
  usePinsStore((s) => {
    if (!s.pins) return [];        // ← new [] on every getSnapshot() call
    return Object.entries(s.pins)
      .filter(([, sp]) => sp.status === 'drift')
      .map(([name, sp]) => ({ name, ...sp }));  // ← new array + objects every call
  });
```

React's `useSyncExternalStore` contract requires that calling the selector twice in a row with the same store state returns the same reference. Both branches of this selector violate that contract.

The correct pattern: subscribe to the raw `pins` value (a stable reference from Zustand), then derive the filtered array using `useMemo` so it only recomputes when `pins` actually changes.

## Fix Requirements

### Required Changes

1. Add a module-level stable empty array constant in `usePinsStore.ts`:
   ```typescript
   const EMPTY_DRIFTED: Array<{ name: string } & ServerPins> = [];
   ```

2. Refactor `useDriftedServers` to split the Zustand subscription from the derived computation:
   ```typescript
   export const useDriftedServers = () => {
     const pins = usePinsStore((s) => s.pins);
     return useMemo(() => {
       if (!pins) return EMPTY_DRIFTED;
       return Object.entries(pins)
         .filter(([, sp]) => sp.status === 'drift')
         .map(([name, sp]) => ({ name, ...sp }));
     }, [pins]);
   };
   ```

3. Add `useMemo` to the import from `'react'` in `usePinsStore.ts`.

### Constraints

- Do NOT change the shape of the returned objects — `PinDriftBadge` consumes `driftedServers.length` and the hook is exported
- Do NOT change `usePinsStore` store definition or `setPins` action
- Do NOT touch `PinDriftBadge.tsx` — the fix must be entirely in `usePinsStore.ts`
- Do NOT add a new dependency; `useMemo` is already available from React

### Out of Scope

- Secondary bugs (`useKeyboardShortcuts([options])` unstable dep in `App.tsx`, inline `onMessage` in `useDetachedWindowSync`) — real issues but not blocking, separate PR
- Test coverage improvements beyond the regression test for this specific fix

## Implementation Guidance

### Key Files to Read

- `web/src/stores/usePinsStore.ts` — the file to fix; understand the full store before editing
- `web/src/components/pins/PinDriftBadge.tsx` — the only consumer of `useDriftedServers`; verify the fix doesn't break its usage
- `web/src/hooks/usePolling.ts:46-63` — where `setPins` is called; understand what data flows into the store

### Files to Modify

**`web/src/stores/usePinsStore.ts`** — three changes:
1. Add `import { useMemo } from 'react';` at the top
2. Add `const EMPTY_DRIFTED` constant after the store definition
3. Replace the `useDriftedServers` export with the `useMemo`-based version

### Reusable Components

- `useMemo` from React — standard memoization hook, already used elsewhere in the codebase
- Zustand's `(s) => s.pins` selector pattern — already used in `PinDriftBadge` and `PinsPanel`; follow this exact pattern

### Conventions to Follow

- Zustand stores in this project use `create<State>()(subscribeWithSelector(...))` — don't change the store structure
- TypeScript strict mode is enabled — the `EMPTY_DRIFTED` constant must be properly typed
- Import order: React imports first, then third-party, then local

## Regression Test

### Test Outline

Add to `web/src/__tests__/hooks.test.ts` (or create `web/src/__tests__/usePinsStore.test.ts`):

```typescript
import { renderHook, act } from '@testing-library/react';
import { usePinsStore, useDriftedServers } from '../stores/usePinsStore';

describe('useDriftedServers', () => {
  beforeEach(() => {
    usePinsStore.setState({ pins: null });
  });

  it('returns a stable reference when pins is null', () => {
    const { result, rerender } = renderHook(() => useDriftedServers());
    const first = result.current;
    rerender();
    expect(result.current).toBe(first); // same reference
  });

  it('returns a stable reference when pins has no drifted servers', () => {
    act(() => {
      usePinsStore.setState({
        pins: { 'my-server': { status: 'pinned', tool_count: 3, last_verified_at: null } },
      });
    });
    const { result, rerender } = renderHook(() => useDriftedServers());
    const first = result.current;
    rerender();
    expect(result.current).toBe(first);
  });

  it('returns drifted servers with correct shape', () => {
    act(() => {
      usePinsStore.setState({
        pins: {
          'server-a': { status: 'drift', tool_count: 5, last_verified_at: null },
          'server-b': { status: 'pinned', tool_count: 2, last_verified_at: null },
        },
      });
    });
    const { result } = renderHook(() => useDriftedServers());
    expect(result.current).toHaveLength(1);
    expect(result.current[0].name).toBe('server-a');
    expect(result.current[0].status).toBe('drift');
  });
});
```

The critical assertion is `expect(result.current).toBe(first)` — same object reference across re-renders when state hasn't changed.

### Existing Test Patterns

- Tests live in `web/src/__tests__/`
- `@testing-library/react` with `renderHook` and `act` for hook testing
- `vitest` with `describe`/`it`/`expect` (no `jest` global needed — `vitest.config.ts` has `globals: true`)
- Zustand stores can be reset via `usePinsStore.setState({...})` directly in tests

## Potential Pitfalls

1. **`useMemo` inside a custom hook is valid** — `useDriftedServers` is a hook (it calls `usePinsStore`), so calling `useMemo` inside it is correct. Don't extract it to module scope.

2. **The `EMPTY_DRIFTED` constant must be module-scoped** — declaring it inside the hook would defeat the purpose (new reference every render).

3. **`pins` from `usePinsStore((s) => s.pins)` is already stable** — Zustand stores the same object reference between `setPins` calls. The `useMemo([pins])` dep will only recompute when `setPins` is called with new data.

4. **Don't use `shallow` from `zustand/shallow` as the fix** — while `shallow` solves the empty array case, it fails for the `.map()` case because `shallow` uses `Object.is` to compare array elements, and the spread objects `{ name, ...sp }` are new references every time. `useMemo` is the correct solution.

5. **TypeScript type for `EMPTY_DRIFTED`** — the type should match what `.map()` returns. Looking at the selector: `{ name: string } & ServerPins` (where `ServerPins` comes from `'../lib/api'`). Check the `ServerPins` type definition in `web/src/lib/api.ts` to ensure the constant is typed correctly.

## Acceptance Criteria

1. The app loads without throwing React error #185
2. `PinDriftBadge` renders in `StatusBar` without errors when `pins === null`
3. `PinDriftBadge` renders correctly when `pins` contains drifted servers
4. `useDriftedServers()` returns the same reference on consecutive calls with unchanged store state
5. The regression test in `hooks.test.ts` (or `usePinsStore.test.ts`) passes
6. `npm run build` in `web/` completes without TypeScript errors

## References

- Full investigation: `prompt-stack/prompts/gridctl/unstable-selector-infinite-rerender/bug-evaluation.md`
- React error #185: https://react.dev/errors/185
- React `useSyncExternalStore` docs — "getSnapshot must return a cached value" section
- Defect introduced by commit: `bf03850` ("add usePinsStore with drift server selector")
