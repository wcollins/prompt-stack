# Bug Fix: Plaintext Variable Input Stays Masked

## Context

gridctl is a Go CLI plus a React/TypeScript web UI (under `web/`). The web UI has a
**Variables** workspace for managing variables/secrets. Each variable has a type
(`string | json | list | number | bool`) and an `is_secret` flag. Secrets are masked and
require an explicit reveal; **Plaintext** variables are meant to be legible in the UI.

Web stack: React + TypeScript, Vite, Tailwind, Zustand store (`useVaultStore`), Vitest +
`@testing-library/react` for tests. Variable data flows through `useVaultManager` (IO hook)
and the `api.ts` client, which maps the frontend camelCase `isSecret` to the backend
snake_case `is_secret`.

## Investigation Context

- **Root cause confirmed:** The variable value `<input>`'s `type` (password vs text) is keyed
  only off the eye-reveal toggle and never consults the `isSecret` flag.
  - Add form: `web/src/components/vault/VariableQuickAddForm.tsx:108`
  - Inline edit: `web/src/components/vault/SecretItem.tsx:87`
- **Reference (correct) implementation already exists:** `web/src/components/wizard/VariablesPopover.tsx:243`
  uses `type={showValue || !newIsSecret ? 'text' : 'password'}`. The fix mirrors this.
- **Not a data bug:** `isSecret` round-trips correctly to the backend; plaintext read-only
  rows already display unmasked. Only the editable input is wrong.
- **Reproduces deterministically** on all platforms (client-side rendering logic).
- **No existing test** asserts the input `type` for secret vs plaintext.
- Full investigation: `prompts/gridctl/plaintext-input-stays-masked/bug-evaluation.md`

## Bug Description

In the Variables workspace add form (and the inline edit form), selecting **Plaintext** mode
does not unmask the value input — it stays rendered as password dots (`••••••••`), identical
to **Secret** mode. The Secret/Plaintext toggle has no effect on input masking. Expected:
Plaintext mode shows the value as visible text (`type="text"`); Secret mode stays masked
with the eye toggle available to reveal. This affects anyone adding or editing a plaintext
variable and contradicts documented behavior (`CHANGELOG.md:140`, `docs/config-schema.md:717`).

## Root Cause

The masking expression checks only the reveal toggle and omits the plaintext case:

- `VariableQuickAddForm.tsx:108` — `type={showValue ? 'text' : 'password'}`. The component
  already tracks `isSecret` (line 46) and renders `VariableSecretToggle` (line 127), but the
  input ignores it.
- `SecretItem.tsx:87` — `type={showEditValue ? 'text' : 'password'}`. The component receives
  the full `secret: Variable` prop, so `secret.is_secret` is available here — no new prop
  needed.

The correct logic is `showValue || !isSecret` (reveal toggle OR plaintext), as already used
in `VariablesPopover.tsx:243`.

## Fix Requirements

### Required Changes
1. In `web/src/components/vault/VariableQuickAddForm.tsx`, change line 108 from
   `type={showValue ? 'text' : 'password'}` to
   `type={showValue || !isSecret ? 'text' : 'password'}`.
2. In `web/src/components/vault/SecretItem.tsx`, change line 87 from
   `type={showEditValue ? 'text' : 'password'}` to
   `type={showEditValue || !secret.is_secret ? 'text' : 'password'}`.
3. Add a regression test asserting the value input `type` is `text` in Plaintext mode and
   `password` in Secret mode (see Regression Test below).

### Constraints
- When editing or adding a **Secret** (the default, `isSecret === true`), the input must
  remain masked (`type="password"`) until the eye toggle reveals it. Do not change this.
- Do not alter the submit payload, the `isSecret`/`is_secret` data mapping, the placeholder
  logic, or the read-only row display — they are already correct.
- Do not refactor `SecretItem`'s prop signature; `secret.is_secret` is already in scope.

### Out of Scope
- Refactoring the two parallel add-form implementations (`VariableQuickAddForm` vs
  `VariablesPopover`) into one shared component.
- Any backend changes.
- The expanded read-only "Value" display in `SecretItem.tsx:161-165` (already correct via the
  eager plaintext fetch).

## Implementation Guidance

### Key Files to Read
- `web/src/components/vault/VariableQuickAddForm.tsx` — add-form value input (primary fix).
- `web/src/components/vault/SecretItem.tsx` — inline-edit value input (second fix); note
  `secret.is_secret` availability.
- `web/src/components/wizard/VariablesPopover.tsx` — the correct reference pattern (line 243).
- `web/src/components/vault/VariableSecretToggle.tsx` — the Secret/Plaintext toggle.
- `web/src/__tests__/VaultPanel.test.tsx` — host for the regression test; renders the add form.
- `web/src/__tests__/AuthPrompt.test.tsx` — example of asserting input `type` (password/text).

### Files to Modify
- `web/src/components/vault/VariableQuickAddForm.tsx` (line 108)
- `web/src/components/vault/SecretItem.tsx` (line 87)
- A test file (extend `web/src/__tests__/VaultPanel.test.tsx` or add a focused test)

### Reusable Components
- Mirror the exact expression from `VariablesPopover.tsx:243`.
- Reuse the existing test setup patterns: `render()`, `useVaultStore.setState(...)` to seed,
  `vi.mock('../lib/api', ...)`, and `screen.getByPlaceholderText(...)` to locate the input.

### Conventions to Follow
- Tests live in `web/src/__tests__/*.test.tsx`, Vitest + Testing Library, jsdom.
- Match the existing assertion style (e.g. `expect(input).toHaveAttribute('type', 'text')`).
- Keep the boolean expression terse and consistent with the reference (`showValue || !isSecret`).

## Regression Test

### Test Outline
- Render the Variables add form (via `VaultPanel` or by importing `VariableQuickAddForm`).
- Locate the value input (by placeholder).
- Assert default (Secret): input has `type="password"`.
- Click the **Plaintext** toggle; assert input now has `type="text"`.
- Click back to **Secret**; assert input returns to `type="password"`.
- (Optional) Render `SecretItem` with `isEditing` true and a `secret` where `is_secret: false`;
  assert the edit input has `type="text"`.

### Existing Test Patterns
- See `VaultPanel.test.tsx` (renders the form, seeds the store, asserts placeholder changes
  on Plaintext) and `AuthPrompt.test.tsx` (asserts `type` toggling between password/text).
- Use `fireEvent.click` on the toggle option located via `screen.getByText('Plaintext')` /
  `getByRole`, consistent with how `VariablesPopover.test.tsx` exercises the toggle.

## Potential Pitfalls

- Don't break the secret default: `!isSecret` must be `false` for secrets so they stay masked.
- The two affected components have slightly different state names (`isSecret`/`showValue` in
  the add form; `secret.is_secret`/`showEditValue` in `SecretItem`). Use the right one in each.
- `VariableQuickAddForm` resets `isSecret` to `true` on successful submit (line 75) — verify the
  input correctly re-masks after a plaintext add clears the form. (Expected and fine.)
- Locating the input by `getByRole('textbox')` won't match a `type="password"` input (it's not
  in the textbox role) — query by placeholder instead, as existing tests do.

## Acceptance Criteria

1. Selecting **Plaintext** in the add form renders the value input as visible text (`type="text"`).
2. Selecting **Secret** in the add form keeps the value input masked (`type="password"`) until
   the eye toggle is clicked.
3. Editing a **Plaintext** variable opens the edit input as visible text; editing a **Secret**
   variable opens it masked.
4. A regression test covers Plaintext-vs-Secret input `type` and passes (`npm test` in `web/`).
5. `npm run build` (web) and existing tests still pass; no changes to data flow or backend.

## References

- Correct reference: `web/src/components/wizard/VariablesPopover.tsx:243`
- Documented behavior: `CHANGELOG.md:140-142`, `docs/config-schema.md:714-722`
- Full investigation: `prompts/gridctl/plaintext-input-stays-masked/bug-evaluation.md`
