# Bug Fix: Wizard Card Gating Bypass

## Context

gridctl is a Go + React application that manages MCP (Model Context Protocol) servers and resources. The frontend (`web/`) is a React/TypeScript SPA using Zustand for state management. The wizard is a multi-step creation flow for stacks, MCP servers, resources, secrets, and skills. In "stackless mode" (`gridctl serve`), no stack is loaded at startup — users must create a Stack first before adding MCP Servers or Resources.

## Investigation Context

- Root cause confirmed: wrong condition at `web/src/components/wizard/CreationWizard.tsx:523`
- Risk: very low — isolated single-line fix with zero side effects
- Correct pattern already exists in `web/src/components/graph/Canvas.tsx:169`
- Reproduces deterministically in `gridctl serve` mode when opening the wizard
- Full investigation: `prompts/gridctl/wizard-card-gating-bypass/bug-evaluation.md`

## Bug Description

In stackless mode (`gridctl serve`), the wizard's resource type selection screen fails to gate the MCP Server and Resource cards:

1. **No opacity dimming** — all 5 cards appear at full opacity; MCP Server and Resource should be `opacity-40`
2. **No hover tooltip** — hovering disabled cards shows nothing; should show `"Requires an active stack — create a Stack first"`
3. **Click navigates** — clicking MCP Server advances to template selection; should do nothing

Expected behavior is documented in `proto/walkthrough.md` Phase 4.3.

## Root Cause

**File**: `web/src/components/wizard/CreationWizard.tsx`
**Line**: 523

```tsx
// CURRENT (wrong)
const hasActiveStack = connectionStatus === 'connected';

// SHOULD BE
const hasActiveStack = connectionStatus === 'connected' && gatewayInfo !== null;
```

`connectionStatus` becomes `'connected'` whenever the browser successfully polls `/api/status` — which succeeds in stackless mode because the API server is running. However, `gatewayInfo` is `null` when no stack is loaded. The missing `&& gatewayInfo !== null` makes `hasActiveStack` evaluate to `true` in stackless mode, disabling all three gating behaviors simultaneously.

## Fix Requirements

### Required Changes

1. Add `gatewayInfo` to the Zustand store selector in `TypePicker` (line 522-523):
   ```tsx
   const connectionStatus = useStackStore((s) => s.connectionStatus);
   const gatewayInfo = useStackStore((s) => s.gatewayInfo);
   const hasActiveStack = connectionStatus === 'connected' && gatewayInfo !== null;
   ```

That's the complete fix. No other changes needed.

### Constraints

- Do NOT change the `STACK_GATED_TYPES` array — it correctly lists `['mcp-server', 'resource']`
- Do NOT change the `isGated` calculation on line 540 — it is correct
- Do NOT change the onClick handler, title attribute, or className logic — they are all correct; the only issue is the `hasActiveStack` derivation
- Do NOT touch `Canvas.tsx` — it already uses the correct pattern

### Out of Scope

- Adding automated tests (no UI test framework in this project)
- Refactoring the gating logic into a shared hook
- Any changes to the `gridctl apply` flow

## Implementation Guidance

### Key Files to Read

1. `web/src/components/wizard/CreationWizard.tsx:510-598` — the `TypePicker` component and all gating logic
2. `web/src/stores/useStackStore.ts:59-94` — how `connectionStatus` and `gatewayInfo` are set
3. `web/src/components/graph/Canvas.tsx:169` — the reference implementation to mirror

### Files to Modify

**`web/src/components/wizard/CreationWizard.tsx`** — lines 522-523 only:

```tsx
// Before
const connectionStatus = useStackStore((s) => s.connectionStatus);
const hasActiveStack = connectionStatus === 'connected';

// After
const connectionStatus = useStackStore((s) => s.connectionStatus);
const gatewayInfo = useStackStore((s) => s.gatewayInfo);
const hasActiveStack = connectionStatus === 'connected' && gatewayInfo !== null;
```

### Reusable Components

The `useStackStore` selector pattern is used throughout the codebase. Follow the existing pattern: call `useStackStore` once per state slice needed.

### Conventions to Follow

- TypeScript strict mode — no `any` types
- Zustand selectors use arrow functions: `(s) => s.fieldName`
- One selector call per state slice (don't combine into one object selector)

## Regression Test

### Test Outline

Manual verification (no automated UI test framework):

1. `make build && ./gridctl serve`
2. Open `http://localhost:8180`, click `+` to open wizard
3. **Verify dimming**: MCP Server and Resource cards should be visibly darker (`opacity-40`) vs Stack, Skill, Secret cards
4. **Verify tooltip**: Hover over MCP Server card → tooltip reads `"Requires an active stack — create a Stack first"`
5. **Verify block**: Click MCP Server card → wizard stays on type selection, does not advance
6. **Verify Resource**: Same checks for Resource card
7. **Verify Stack loaded**: `gridctl apply <any-stack.yaml>` → reopen wizard → all 5 cards at full opacity, all clickable

### Existing Test Patterns

See `proto/walkthrough.md` Phase 4.3 for the manual test checklist.

## Potential Pitfalls

- `gatewayInfo` is the `ServerInfo` object from `/api/status` — it's `null` until a stack is successfully loaded, which is exactly the discriminator needed
- Do not confuse `connectionStatus === 'connected'` (HTTP polling succeeds) with "a stack is active" — these are different conditions
- The fix adds one more Zustand selector in the `TypePicker` component. This is fine — `TypePicker` is only rendered when the wizard is open, so there is no performance concern

## Acceptance Criteria

1. In `gridctl serve` mode: MCP Server and Resource cards render at `opacity-40` with `cursor-not-allowed`
2. In `gridctl serve` mode: Hovering either disabled card shows tooltip `"Requires an active stack — create a Stack first"`
3. In `gridctl serve` mode: Clicking either disabled card does not advance the wizard
4. In `gridctl apply` mode (stack loaded): All 5 cards are at full opacity and clickable
5. No TypeScript errors
6. `make build` succeeds

## References

- `proto/walkthrough.md` Phase 4.3 — expected gating behavior
- `web/src/components/graph/Canvas.tsx:169` — correct reference implementation
- PR #461: feat: wizard gating and UX polish — introduced the feature
