# Bug Fix: Secrets Dropdown Scroll Bug

## Context

gridctl is a Go + React/TypeScript project that provides a UI for configuring MCP servers, resources, and stacks. The frontend is in `web/src/` and uses Tailwind CSS for styling. The wizard flow (`web/src/components/wizard/`) is the primary UI for creating and configuring MCP servers. Vault secrets are stored and referenced via `${vault:KEY}` syntax in env var values.

## Investigation Context

- Root cause confirmed: Two interacting CSS/rendering issues cause the secrets dropdown to be unscrollable
- Primary cause: The form panel (`CreationWizard.tsx:365`) has `overflow-y: auto`, which clips `position: absolute` children that extend beyond the panel's visible area — including `SecretsPopover`
- Secondary cause: `overflow-hidden` on `SecretsPopover`'s outer container (line 102) clips the inner `max-h-36 overflow-y-auto` scroll list
- Regression introduced by PR #435 which added `overflow-y: auto` to the form panel
- Fix is scoped entirely to `SecretsPopover.tsx` — no changes needed in `CreationWizard.tsx`
- Full investigation: `prompts/gridctl/secrets-dropdown-scroll-bug/bug-evaluation.md`

## Bug Description

When a user clicks the key icon (🔑) next to an env var value field in the StackForm, a secrets selection popover opens. This popover cannot be scrolled — secrets below the visible area are inaccessible. The popover is also clipped at the form panel's scroll boundary when the trigger is near the bottom of the panel.

**Expected**: The popover renders fully visible and its secrets list is scrollable regardless of where the trigger is positioned in the form.

**Actual**: The popover is clipped by the ancestor `overflow-y: auto` container, and the inner scroll list is clipped by `overflow-hidden` on the popover's outer div.

**Who is affected**: All users configuring MCP server env vars with vault secrets.

## Root Cause

### Primary — Form panel clips the absolute popover

`web/src/components/wizard/CreationWizard.tsx:365`:
```tsx
<div className="flex-1 overflow-y-auto scrollbar-dark px-6 py-4">
```

CSS spec: `position: absolute` elements inside `overflow: auto` containers are clipped to that container's viewport. The `SecretsPopover` renders with `position: absolute` and is a descendant of this div. When the trigger button is near the bottom of the form panel, the popover extends below the clipping boundary.

### Secondary — overflow-hidden clips inner scroll list

`web/src/components/wizard/SecretsPopover.tsx:102`:
```tsx
className={cn(
  'absolute right-0 top-full mt-1.5 z-50 w-72',
  'glass-panel-elevated rounded-xl overflow-hidden',  // <-- culprit
  'animate-fade-in-scale',
)}
```

The `overflow-hidden` clips the scrollbar area of the inner list (`max-h-36 overflow-y-auto` at line 122), preventing scroll interaction even when the popover is fully visible.

## Fix Requirements

### Required Changes

1. **Remove `overflow-hidden` from the outer popover container** in `SecretsPopover.tsx`. The `rounded-xl` class should be preserved for visual styling. Apply `overflow-hidden` only to individual sections (header, footer) if needed to clip their content to rounded corners, rather than on the entire popover container.

2. **Render the popover dropdown via a React Portal** (`ReactDOM.createPortal`) mounted to `document.body`. This removes the popover from the ancestor `overflow-y: auto` scroll container and allows it to render freely over the page. Position the portal element using `getBoundingClientRect()` on the trigger button ref, with fixed positioning (`position: fixed`) and calculated `top`/`right`/`left` coordinates.

3. **Update outside-click detection** to work correctly with the Portal. The current handler checks `popoverRef.current.contains(e.target)`. After portaling, the dropdown is outside the component's DOM subtree — update the handler to check both the trigger button ref and the portal container ref.

4. **Handle viewport edge detection**: When the popover would extend below the viewport, flip it to open upward (`bottom-full` instead of `top-full`). Calculate this based on the trigger's `getBoundingClientRect()` and `window.innerHeight`.

### Constraints

- Do NOT change the popover's visual design — keep `glass-panel-elevated rounded-xl`, the search input, list styling, and create-new form exactly as-is
- Do NOT change `CreationWizard.tsx` — the fix must be self-contained in `SecretsPopover.tsx`
- Do NOT use third-party positioning libraries — implement with native browser APIs
- Preserve the `animate-fade-in-scale` animation class on the portal container

### Out of Scope

- Refactoring `KeyValueEditor` or other env var components
- Changing how secrets are fetched or stored
- Fixing scroll issues in any other form section
- Adding pagination or virtual scrolling to the secrets list

## Implementation Guidance

### Key Files to Read

1. `web/src/components/wizard/SecretsPopover.tsx` — the component to fix; read the full file before changing anything
2. `web/src/components/wizard/CreationWizard.tsx:354-390` — shows the scroll container structure to understand why Portal is needed
3. `web/src/index.css` — check `glass-panel-elevated` and `scrollbar-dark` class definitions to understand what styling is inherited
4. `web/src/__tests__/SecretsPopover.test.tsx` — existing tests to preserve and extend

### Files to Modify

- `web/src/components/wizard/SecretsPopover.tsx` — sole file requiring changes

### Reusable Components

- `ReactDOM.createPortal` from `react-dom` — already in the project's dependencies
- `useRef` + `getBoundingClientRect()` — for positioning the portal
- Existing `useEffect` cleanup pattern in `SecretsPopover` for event listeners — follow the same pattern for the position update listener

### Conventions to Follow

- Use `cn()` from `../../lib/cn` for conditional class merging (already used in this component)
- TypeScript strict mode — no `any` types
- Keep state management inside the component (no store changes)
- Follow the existing `useEffect` with cleanup pattern for event listeners

## Regression Test

### Test Outline

Add to `web/src/__tests__/SecretsPopover.test.tsx`:

1. **Scroll accessibility test**: Render `SecretsPopover` with 20 mock secrets. Open the popover. Assert all 20 secrets are reachable (rendered in the DOM, not clipped). Assert the secrets list container has `overflow-y: auto` and a `max-height`.

2. **Portal mount test**: Open the popover and assert the dropdown is mounted on `document.body` (not inside the component's container div).

3. **Outside click with Portal**: Open the popover, simulate a `mousedown` on `document.body` outside both the trigger and portal. Assert the popover closes.

### Existing Test Patterns

Tests use Vitest + React Testing Library. See `web/src/__tests__/SecretsPopover.test.tsx` for existing patterns. Mock `fetchVaultSecrets` with `vi.mock('../../lib/api')`.

## Potential Pitfalls

1. **Portal positioning on window resize/scroll**: The portal is positioned with fixed coordinates from `getBoundingClientRect()`. If the user scrolls the form panel while the popover is open, the popover won't reposition. Add a `scroll` and `resize` event listener in the `useEffect` that repositions the popover, and clean it up on close.

2. **z-index stacking**: The portal renders at `document.body` level. Ensure the portal container uses a high enough `z-index` (currently `z-50` — confirm this is sufficient above modals if the wizard is in a modal).

3. **React Testing Library + portals**: `render()` by default mounts to `document.body`, so portals should work in tests. Use `within(document.body)` if needed to query the portal content.

4. **SSR/hydration**: Not applicable — this is a client-side app.

## Acceptance Criteria

1. Clicking the 🔑 key icon opens the secrets dropdown at all positions in the form panel without clipping
2. The secrets list is scrollable when there are more secrets than fit in `max-h-36`
3. Clicking outside the popover (including on the form panel) closes it
4. The "Create New Secret" flow still works correctly after portaling
5. The visual appearance (glass panel, rounded corners, animation) is unchanged
6. Existing `SecretsPopover` tests pass
7. New regression tests pass

## References

- PR #435 (root cause): `dc628c9` — "fix: wizard form name hyphen stripping and panel scroll"
- CSS overflow clipping spec: https://www.w3.org/TR/CSS22/visufx.html#overflow
- React Portal docs: https://react.dev/reference/react-dom/createPortal
