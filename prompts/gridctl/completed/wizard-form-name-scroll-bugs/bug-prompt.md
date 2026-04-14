# Bug Fix: Wizard Form Name Hyphen + Form Panel Scroll

## Context

gridctl is a Go + React (Vite/TypeScript/Tailwind) application for managing MCP servers and stacks. The frontend wizard (`web/src/components/wizard/`) provides a multi-step "Create New Resource" flow. The form step shows a split-panel layout: a form on the left and a live YAML preview on the right, using `react-resizable-panels` v4.

## Investigation Context

- Root cause for Bug 1 confirmed: trailing-hyphen strip runs on every keystroke in `toKebabCase()` at `MCPServerForm.tsx:164`, `StackForm.tsx:38`, `ResourceForm.tsx:85`
- Root cause for Bug 2 confirmed (high confidence): Panel height not explicitly propagated to child div in `CreationWizard.tsx:363-364`, causing `overflow-y: auto` to never activate
- Both bugs reproduce deterministically on all platforms
- Full investigation: `prompts/gridctl/wizard-form-name-scroll-bugs/bug-evaluation.md`

## Bug Description

### Bug 1: Hyphens stripped from name field

All three form components (MCPServerForm, StackForm, ResourceForm) run `toKebabCase()` on every keystroke via `onChange`. The function ends with `.replace(/^-|-$/g, '')` which strips trailing hyphens. Because the hyphen is always the last typed character when first entered, it is always treated as trailing and immediately stripped. The user can never type a hyphenated name despite the field hint reading "Kebab-case identifier."

- Typing `test-stack` → shows `teststack` (hyphen never appears)
- Field hint: "Kebab-case identifier for this server"

### Bug 2: Form panel cannot scroll

When the YAML preview split-panel is active (the default for all non-skill/non-secret form steps), the form is rendered inside a `Panel` from `react-resizable-panels`. The Panel's child div has `h-full overflow-y-auto`, but because the Panel element may not propagate an explicit CSS `height` to its children, `h-full` does not resolve to a constrained height and scroll never activates. Fields below the fold (Environment & Secrets, Advanced) cannot be reached.

## Root Cause

### Bug 1

**File**: `web/src/components/wizard/steps/MCPServerForm.tsx` (and identical copies in StackForm.tsx, ResourceForm.tsx)

```typescript
// Lines 159-165 in MCPServerForm.tsx (same in other files)
function toKebabCase(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');   // ← This strips the trailing hyphen on every keystroke
}
```

The trailing-hyphen strip is appropriate for final validation but wrong to apply during mid-typing.

### Bug 2

**File**: `web/src/components/wizard/CreationWizard.tsx` lines 361-391

```tsx
<PanelGroup orientation="horizontal" className="h-full">
  <Panel defaultSize={55} minSize={40}>
    {/* h-full doesn't resolve to Panel's flex-computed height */}
    <div className="h-full overflow-y-auto scrollbar-dark px-6 py-4">
      {/* form content */}
    </div>
  </Panel>
  ...
</PanelGroup>
```

The `Panel` element from react-resizable-panels gets its width from flex, but height propagation to child elements may not work without explicitly setting `overflow: hidden` on the Panel, which forces the browser to establish a block formatting context with a defined height.

## Fix Requirements

### Required Changes

**Bug 1** — apply to all three files:

1. In `MCPServerForm.tsx`, `StackForm.tsx`, and `ResourceForm.tsx`: modify `toKebabCase()` to NOT strip trailing hyphens. Rename to `toKebabCaseMid` or keep the name and just remove the trailing-hyphen replacement.
2. Add an `onBlur` handler to each name input that strips the trailing hyphen when the user leaves the field. This preserves mid-type state while cleaning up on completion.
3. Alternatively: keep `toKebabCase` as-is and add a separate `finalizeKebabCase` (strips trailing hyphens) that is called only on blur.

**Bug 2** — one file:

4. In `CreationWizard.tsx`, add `style={{ overflow: 'hidden' }}` to the `Panel` component (line ~363) so the Panel establishes an explicit block formatting context with height propagation.

### Constraints

- The final saved/submitted value must still not have trailing hyphens. The cleanup must happen on blur, not be removed entirely.
- Do not change the validation schema or YAML serialization — those already accept kebab-case strings with hyphens.
- Do not modify the YAMLPreview panel or the non-preview fallback path (`else` branch at line 393) — those work correctly.
- Keep the `toKebabCase` function name consistent across all three files for symmetry.

### Out of Scope

- Adding a leading-hyphen guard (already handled by the regex)
- Refactoring the three `toKebabCase` functions into a shared utility (worthwhile but not required for this fix)
- Scroll behavior in non-preview mode (already works correctly)

## Implementation Guidance

### Key Files to Read

1. `web/src/components/wizard/steps/MCPServerForm.tsx` — lines 159-165 (toKebabCase), lines 495-504 (name input with onChange)
2. `web/src/components/wizard/steps/StackForm.tsx` — lines 33-39 (toKebabCase), lines 589-598 (name input)
3. `web/src/components/wizard/steps/ResourceForm.tsx` — lines 80-86 (toKebabCase), line 425 (name input onChange)
4. `web/src/components/wizard/CreationWizard.tsx` — lines 354-391 (content layout, PanelGroup)
5. `web/src/__tests__/MCPServerForm.test.tsx` — existing kebab-case test to extend

### Files to Modify

**`web/src/components/wizard/steps/MCPServerForm.tsx`**:
- Lines 159-165: Change `toKebabCase` to not strip trailing hyphens on every call. Example:
  ```typescript
  function toKebabCase(value: string): string {
    return value
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-/, ''); // only strip leading hyphen, not trailing
  }
  ```
- Line 498: Add `onBlur` to the name input:
  ```tsx
  onBlur={(e) => onChange({ name: e.target.value.replace(/-+$/, '') })}
  ```

**`web/src/components/wizard/steps/StackForm.tsx`**: Same changes at equivalent lines.

**`web/src/components/wizard/steps/ResourceForm.tsx`**: Same changes at equivalent lines.

**`web/src/components/wizard/CreationWizard.tsx`**:
- Line ~363: Add `style={{ overflow: 'hidden' }}` to the Panel:
  ```tsx
  <Panel defaultSize={55} minSize={40} style={{ overflow: 'hidden' }}>
  ```

### Reusable Components

- The onBlur cleanup pattern is 1 line: `.replace(/-+$/, '')` strips trailing hyphens only
- The Panel `style` prop is the documented react-resizable-panels approach for enabling child scroll

### Conventions to Follow

- Existing test style: vitest + @testing-library/react with `fireEvent.change`
- Tailwind for all styling — no inline styles except for the Panel library workaround
- Inline comments are minimal; only add one if the onBlur/onChange split needs explanation

## Regression Test

### Test Outline

In `web/src/__tests__/MCPServerForm.test.tsx`, add two tests:

1. **Hyphen preserved mid-type**:
   ```typescript
   it('preserves trailing hyphen mid-type', () => {
     render(<MCPServerForm data={defaultData()} onChange={onChange} />);
     const nameInput = screen.getByPlaceholderText('my-server');
     fireEvent.change(nameInput, { target: { value: 'test-' } });
     expect(onChange).toHaveBeenCalledWith({ name: 'test-' });
   });
   ```

2. **Hyphen stripped on blur**:
   ```typescript
   it('strips trailing hyphen on blur', () => {
     render(<MCPServerForm data={defaultData({ name: 'test-' })} onChange={onChange} />);
     const nameInput = screen.getByPlaceholderText('my-server');
     fireEvent.blur(nameInput);
     expect(onChange).toHaveBeenCalledWith({ name: 'test' });
   });
   ```

Add equivalent tests to `web/src/__tests__/StackForm.test.tsx`.

### Existing Test Patterns

Tests use `vitest` + `@testing-library/react`. `fireEvent.change` with `{ target: { value: '...' } }` is the pattern. `fireEvent.blur` works the same way.

## Potential Pitfalls

- **onBlur on controlled input**: The `onBlur` handler updates the parent store via `onChange`. Since the input is controlled (`value={data.name}`), after `onBlur` fires and `onChange` updates the parent, the input will re-render with the cleaned value. This is correct behavior and causes no flicker.
- **Panel style prop**: The `style={{ overflow: 'hidden' }}` is applied to the library's `Panel` component, not a DOM div. react-resizable-panels v4 forwards style to the underlying DOM element. Verify that the import (`Panel` from `react-resizable-panels`) forwards the style prop — it does in v4.
- **Three identical functions**: If you change `toKebabCase` in one file, remember to change it in all three. They are not shared — each file defines its own copy.
- **Existing test breaks**: The existing "enforces kebab-case on name input" test fires onChange with `'My Server Name'` and expects `'my-server-name'`. This test should still pass since interior hyphens are not affected.

## Acceptance Criteria

1. Typing `test-stack` in the name field produces `test-stack` in the input and calls `onChange({ name: 'test-stack' })`.
2. Typing `test-` and then blurring the field produces `test` (trailing hyphen stripped).
3. Typing spaces and uppercase (e.g., `My Server`) still produces `my-server` (existing behavior preserved).
4. The form panel in the split-panel layout scrolls vertically to reveal Environment & Secrets and Advanced sections.
5. All existing tests in `MCPServerForm.test.tsx` and `StackForm.test.tsx` continue to pass.
6. Two new regression tests pass: one for mid-type hyphen preservation, one for blur cleanup.

## References

- `react-resizable-panels` v4 — Panel component accepts `style` prop forwarded to DOM
- Bug evaluation: `prompts/gridctl/wizard-form-name-scroll-bugs/bug-evaluation.md`
- Existing tests: `web/src/__tests__/MCPServerForm.test.tsx`, `web/src/__tests__/StackForm.test.tsx`
