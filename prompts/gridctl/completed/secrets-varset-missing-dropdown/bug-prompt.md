# Bug Fix: Secrets Variable Set Missing Dropdown

## Context

gridctl is a Go + React (Vite/TypeScript) CLI tool for managing AI agent stacks. The web UI (served via `./gridctl serve`) includes a stack creation wizard with a multi-section form (`StackForm.tsx`). One section manages "Secrets", which allows a stack to reference vault secret sets by name.

The vault system manages secrets in named sets. The sets are stored in a Zustand store (`useVaultStore`) and fetched via `/api/vault/sets`. A `SecretsPopover` component already implements the fetch-on-open + filtered-list + create-new pattern for individual secret references elsewhere in the form.

## Investigation Context

- **Root cause confirmed**: `StackForm.tsx:1081` uses the generic `StringArrayEditor` component for Variable Sets, which only renders plain text inputs. No API call is made, no dropdown is shown.
- **Risk**: Low — the data structure (`data.secrets?.sets: string[]`) is unchanged. Fix is isolated to the Secrets section of `StackForm`.
- **Reproduction**: Deterministic. Any user who opens the wizard Secrets section and clicks "+ Add set" hits this immediately.
- **All building blocks exist**: `fetchVaultSets()`, `useVaultStore.sets`, `setSets()`, and `SecretsPopover` as a reference pattern.
- Full investigation: `prompts/gridctl/secrets-varset-missing-dropdown/bug-evaluation.md`

## Bug Description

In the stack wizard's Secrets section, clicking "+ Add set" renders a plain `<input type="text">`. There is no dropdown or combobox showing existing vault secret sets. Users cannot browse or select from sets they've already created — they must manually type exact set names.

**Expected**: A popover/dropdown listing existing vault sets (fetched from `/api/vault/sets`), with a search/filter input and the ability to select an existing set or type a new name.

**Actual**: A plain text input with placeholder `secret-set-name`.

**Who is affected**: All users creating stacks via wizard who reference secret sets.

## Root Cause

`web/src/components/wizard/steps/StackForm.tsx:1081-1090`:

```tsx
<StringArrayEditor
  label="Variable Sets"
  value={data.secrets?.sets ?? []}
  onChange={(sets) =>
    onChange({ secrets: sets.length > 0 ? { sets } : undefined })
  }
  placeholder="secret-set-name"
  addLabel="Add set"
  emptyText="No secret sets referenced"
/>
```

`StringArrayEditor` (defined at `StackForm.tsx:189-250`) is a generic text array editor. It calls no APIs, shows no dropdown, and has no awareness of vault sets. It should be replaced with a purpose-built component.

## Fix Requirements

### Required Changes

1. Create a `VaultSetSelector` component (new file or inline in StackForm) that:
   - Accepts `value: string[]` and `onChange: (val: string[]) => void` props
   - Fetches vault sets via `fetchVaultSets()` when the section is used (on mount or on "+ Add set" click)
   - Stores results in `useVaultStore` via `setSets()`
   - For each set slot, renders either:
     - A dropdown/combobox showing available set names (from `useVaultStore.sets`), OR
     - A popover (matching `SecretsPopover` style) that opens on "+ Add set" click, shows a searchable list of existing sets, and allows selecting one or typing a new name
   - Maintains the existing string array data structure — no changes to `data.secrets.sets`
   - Includes a remove (×) button per entry, matching `StringArrayEditor`'s current behavior

2. Replace the `StringArrayEditor` usage at `StackForm.tsx:1081` with the new `VaultSetSelector` component.

### Constraints

- Do NOT change the data structure: `data.secrets?.sets` must remain `string[]`
- Do NOT change the YAML output format — `secrets: sets: [name]` must be preserved
- Do NOT modify `StringArrayEditor` — it is used elsewhere and should remain a generic component
- The component must handle `useVaultStore.sets === null` (loading state) gracefully
- Follow the same portal + fixed positioning approach as `SecretsPopover` if implementing as a popover, to avoid overflow clipping from ancestor containers

### Out of Scope

- Creating new vault sets inline from the wizard (nice to have, but not required for this fix)
- Changing the walkthrough documentation (`proto/walkthrough.md`) — update it only if the new UX makes "type `dev`" instructions incorrect

## Implementation Guidance

### Key Files to Read

| File | Why |
|------|-----|
| `web/src/components/wizard/SecretsPopover.tsx` | **Primary reference** — fetch-on-open, filtered list, portal popover, useVaultStore pattern |
| `web/src/components/wizard/steps/StackForm.tsx:189-250` | `StringArrayEditor` — understand current data flow and styling conventions |
| `web/src/components/wizard/steps/StackForm.tsx:1073-1091` | Defect location — Secrets section |
| `web/src/stores/useVaultStore.ts` | `sets: VaultSet[] | null`, `setSets()` action |
| `web/src/lib/api.ts:446-489` | `VaultSet` interface, `fetchVaultSets()` function |
| `web/src/__tests__/StackForm.test.tsx` | Existing test patterns for the form |

### Files to Modify

- `web/src/components/wizard/steps/StackForm.tsx` — replace `StringArrayEditor` at line 1081 with `VaultSetSelector`; add the new component (inline or via import)
- `web/src/__tests__/StackForm.test.tsx` — add regression test

### Reusable Components

- `useVaultStore` (`../../stores/useVaultStore`) — use `sets` state and `setSets()` action exactly as `SecretsPopover` uses `secrets`/`setSecrets`
- `fetchVaultSets()` (`../../lib/api`) — call this to populate the dropdown, parallel to how `fetchVaultSecrets()` is used in `SecretsPopover`
- `cn` utility, `inputClass` constant, `Plus`/`X`/`Search`/`Loader2` icons — already imported in StackForm
- Portal pattern from `SecretsPopover` — use `createPortal(dropdown, document.body)` to escape overflow containers

### Conventions to Follow

- Component file: use the same glass-panel styling (`glass-panel-elevated`, `animate-fade-in-scale`) as `SecretsPopover`
- Text sizes: labels at `text-xs`, secondary text at `text-[10px]`, buttons match existing form button styles
- Empty/loading states: match `SecretsPopover`'s `secrets === null ? 'Loading...' : 'No secrets found'` pattern
- No TypeScript `any` — use `VaultSet` from `api.ts`
- Tailwind only — no inline styles except for portal positioning (which requires `style={{ position: 'fixed', ... }}`)

## Regression Test

### Test Outline

File: `web/src/__tests__/StackForm.test.tsx`

```
Test: "Secrets section shows vault set dropdown with existing sets"
- Mock `fetchVaultSets` to resolve with [{ name: 'dev', count: 2 }, { name: 'prod', count: 5 }]
- Render StackForm with empty initial data
- Expand the Secrets section
- Click "+ Add set"
- Assert: a list/dropdown is visible containing "dev" and "prod"
- Click "dev"
- Assert: onChange was called with { secrets: { sets: ['dev'] } }
```

### Existing Test Patterns

- Tests use `@testing-library/react` with `vi.mock` for API modules
- API functions are mocked at the module level: `vi.mock('../../lib/api', () => ({ fetchVaultSets: vi.fn() }))`
- See existing tests in `web/src/__tests__/StackForm.test.tsx` for form rendering and interaction patterns

## Potential Pitfalls

- **Portal overflow**: The Secrets section is inside a scrollable container. If you don't use a portal for the dropdown, it will be clipped by `overflow-hidden` ancestors. Follow `SecretsPopover`'s `createPortal(dropdown, document.body)` pattern.
- **Position calculation**: If using a popover, compute position from `getBoundingClientRect()` on the trigger button. Check for space below (like `SecretsPopover:43-47`) to flip the dropdown upward when near the bottom of the viewport.
- **Loading state**: `useVaultStore.sets` starts as `null`. Show a loading indicator and avoid rendering an empty list before the fetch completes.
- **Empty string entries**: `StringArrayEditor` uses `addItem = () => onChange([...value, ''])`. If the new component also appends empty strings, ensure they're filtered out before saving (or handle them in the change handler).
- **Deduplication**: Prevent the user from selecting the same set name twice. Filter already-selected names from the dropdown options.

## Acceptance Criteria

1. Expanding the Secrets section and clicking "+ Add set" opens a dropdown/popover listing all existing vault sets fetched from `/api/vault/sets`
2. Selecting a set from the list adds it to `data.secrets.sets` and closes the dropdown
3. The YAML preview updates correctly to show the selected set under `secrets: sets:`
4. If no vault sets exist, the dropdown shows an appropriate empty state (e.g., "No sets found")
5. Each added set has a remove (×) button that removes it from the list
6. The `StringArrayEditor` component is unchanged and continues working for all other fields that use it
7. A regression test passes that mocks `fetchVaultSets` and verifies the dropdown renders existing sets

## References

- `web/src/components/wizard/SecretsPopover.tsx` — reference implementation
- `web/src/stores/useVaultStore.ts` — vault Zustand store
- `web/src/lib/api.ts` — `fetchVaultSets`, `VaultSet` interface
- `web/src/components/wizard/steps/StackForm.tsx` — defect location
- `proto/walkthrough.md:211-216` — walkthrough context (section 3.6)
