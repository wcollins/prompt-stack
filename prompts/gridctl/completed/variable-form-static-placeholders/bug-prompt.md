# Bug Fix: Variable Form Static Placeholders

## Context

**gridctl** is a Go CLI + React/Vite (TypeScript) web UI for managing stacks,
resources, MCP servers, and variables. The web frontend lives in `web/`, uses
Vitest + React Testing Library, and follows the design system documented in
`web/AGENTS.md`.

The "unified variable store" feature (PR #670, commit `70a516a`) introduced a
typed variable system: variables have a `type` (`string`, `json`, `list`,
`number`, or `bool`) and a visibility flag (`Secret` vs `Plaintext`). The
backend lives in `pkg/vault/types.go` and `cmd/gridctl/var.go`; the frontend
mirror lives under `web/src/components/vault/`.

## Investigation Context

- **Root cause confirmed**: three duplicate hardcoded `placeholder="..."`
  attributes in the variable creation forms. State for `newType` and
  `newIsSecret` is correctly tracked but never used to compute placeholder
  text. Most visibly: the value placeholder reads `Secret value` even when the
  user has selected `Plaintext`.
- **Risk profile**: pure UI string change, no state/API/validation changes.
  Confidence: high.
- **Reproduces deterministically**: every browser, every OS, since the feature
  merged. No environmental dependency.
- **Full investigation**:
  `<prompt-stack>/prompts/gridctl/variable-form-static-placeholders/bug-evaluation.md`

## Bug Description

In the variable creation form, the two input placeholders are hardcoded
strings (`KEY_NAME` / `Secret value` in the vault forms; `VARIABLE_KEY` /
`Variable value` in the wizard popover). They never adapt when the user
toggles the variable type tab (`string`/`json`/`list`/`number`/`bool`) or the
visibility tab (`Secret`/`Plaintext`).

The most user-visible symptom: when a user clicks the `Plaintext` button, the
value input still shows `Secret value` as a placeholder — directly
contradicting the user's selection.

Secondary symptoms: users picking `list`, `number`, `bool`, or `json` types
get no hint about expected input format. For `list` in particular this
matters because the validator splits by comma rather than parsing JSON, so a
user typing `["a","b"]` (a reasonable guess) gets unexpected results.

## Root Cause

The form state (`newType`, `newIsSecret`) is correctly initialized and
correctly passed to `VariableTypeSelector` and `VariableSecretToggle`
components. The state updates correctly on tab clicks. **But** the
`<input placeholder="...">` attribute on the value input is a string
literal, not a derived value — so re-renders never change it.

The companion file `web/src/components/vault/variableTypeHelpers.ts` already
defines per-type validation logic (`validateVariableInput`) that establishes
the canonical "what does a valid value for type X look like" — but no
companion helper exists for placeholder generation.

The correct fix is to add a `getValuePlaceholder(type, isSecret)` helper to
that same file (single source of truth for per-type input semantics) and use
it in all three call sites.

## Fix Requirements

### Required Changes

1. **Add helper** `getValuePlaceholder(type: VariableType, isSecret: boolean): string`
   to `web/src/components/vault/variableTypeHelpers.ts`. Behavior:
   - For `string` type: return `'plaintext value'` if `!isSecret`, else `'secret value'`
   - For `json` type: return `'{"key": "value"}'`
   - For `list` type: return `'item1, item2, item3'` (matches the validator's
     comma-splitting behavior — critically, NOT `["a","b"]`)
   - For `number` type: return `'42'`
   - For `bool` type: return `'true or false'`
   - The visibility (`isSecret`) parameter only changes the `string`-type
     placeholder. For the other types, the value format is the same regardless
     of visibility (a JSON object is a JSON object whether secret or plaintext).
2. **Replace placeholder in `web/src/components/vault/VaultPanel.tsx`** at line 581:
   change `placeholder="Secret value"` to
   `placeholder={getValuePlaceholder(newType, newIsSecret)}`. Add the import.
3. **Replace placeholder in `web/src/pages/DetachedVaultPage.tsx`** at line 577:
   same change as above. Add the import.
4. **Replace placeholder in `web/src/components/wizard/VariablesPopover.tsx`** at
   line 246: same change. Add the import.
5. **Add new test file** `web/src/__tests__/VaultPanel.test.tsx` covering
   placeholder adaptation (see "Regression Test" below). This component currently
   has no tests at all — this fix creates the foothold.
6. **Extend** `web/src/__tests__/VariablesPopover.test.tsx`: add placeholder
   adaptation cases AND update any existing assertion that checks for the
   literal string `Variable value` (it will change to the new computed default).

### Constraints

- Do NOT change the key-input placeholders (`KEY_NAME`, `VARIABLE_KEY`). They
  stay as-is per product decision — the key naming convention is the same
  across types.
- Do NOT change the backend (`cmd/gridctl/var.go`, `pkg/vault/`). This is a
  frontend-only fix.
- Do NOT touch the `VariableTypeSelector` or `VariableSecretToggle`
  components — they are working correctly.
- Do NOT change the validator (`validateVariableInput`). The placeholders
  should match the validator's behavior, not vice versa.
- Do NOT introduce new dependencies.
- Preserve all existing functionality: type and visibility tabs must still
  control state correctly; submit behavior must be unchanged.

### Out of Scope

- Documentation update of `docs/config-schema.md` to describe per-type input
  formats (separate PR — flagged but explicitly excluded here)
- Inline error-message improvements on validation failure
- Per-type key placeholder (e.g., `DATABASE_URL` for string,
  `CONFIG_JSON` for json) — explicitly rejected during scoping
- Tests for `DetachedVaultPage` — structurally identical to `VaultPanel`,
  covered transitively via the helper test and code review
- Refactoring `DetachedVaultPage` to not duplicate `VaultPanel`'s form (real
  duplication exists but is out of scope for this bug fix)

## Implementation Guidance

### Key Files to Read

1. `web/src/components/vault/variableTypeHelpers.ts` — the helper module to extend.
   The new function should mirror the structure and style of `validateVariableInput`.
2. `web/src/components/vault/VaultPanel.tsx` (around lines 562-616 for the quick-add
   form) — first call site
3. `web/src/pages/DetachedVaultPage.tsx` (around lines 558-612) — duplicate call site
4. `web/src/components/wizard/VariablesPopover.tsx` (around lines 218-280) — third
   call site
5. `web/src/__tests__/VariablesPopover.test.tsx` — existing test patterns to follow
6. `web/vitest.config.ts` and `web/vitest.setup.ts` — test config
7. `web/src/components/vault/VariableTypeSelector.tsx` and
   `web/src/components/vault/VariableSecretToggle.tsx` — to understand how the
   tabs render (test will need to query/click these)

### Files to Modify

| File | Change |
|---|---|
| `web/src/components/vault/variableTypeHelpers.ts` | Add `getValuePlaceholder` export |
| `web/src/components/vault/VaultPanel.tsx` | Update placeholder at line 581 + import |
| `web/src/pages/DetachedVaultPage.tsx` | Update placeholder at line 577 + import |
| `web/src/components/wizard/VariablesPopover.tsx` | Update placeholder at line 246 + import |
| `web/src/__tests__/VaultPanel.test.tsx` | **NEW** — add test file |
| `web/src/__tests__/VariablesPopover.test.tsx` | Add placeholder-adaptation cases; update any existing `Variable value` literal assertions |

### Reusable Components

- The placeholder helper should live next to `validateVariableInput` in
  `variableTypeHelpers.ts` because both are derived from the same per-type
  semantics. Single source of truth.
- Use the existing `VariableType` type import from `../../lib/api`
- For testing, follow `VariablesPopover.test.tsx`'s existing patterns
  (`render`, `screen`, `fireEvent` from `@testing-library/react`)

### Conventions to Follow

- TypeScript: use union types and exhaustive `switch`/`Record` for the
  type → placeholder mapping (matches the existing `validateVariableInput`
  style — a switch with one branch per type)
- React: use the helper directly in the JSX expression
  (`placeholder={getValuePlaceholder(newType, newIsSecret)}`); no need for
  a memoized computation — this is a tiny pure string function called once
  per render
- Tests: existing tests use `@testing-library/react` with `render`, `screen`,
  `fireEvent`. No snapshot testing in this project.
- Imports: relative paths consistent with neighboring files (`'./variableTypeHelpers'`)
- Comments: per global CLAUDE.md, concise and meaningful. The existing comment
  block at the top of `variableTypeHelpers.ts` is a good style reference.

## Regression Test

### Test Outline

**`web/src/__tests__/VaultPanel.test.tsx`** (new file):

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { VaultPanel } from '../components/vault/VaultPanel';
// ... necessary mocks for API calls / context providers per VariablesPopover.test.tsx patterns

describe('VaultPanel - value placeholder adaptation', () => {
  // Mock setup follows the existing VariablesPopover.test.tsx pattern

  it('shows secret-value placeholder by default (string + Secret)', () => {
    render(<VaultPanel />);
    const valueInput = screen.getByPlaceholderText(/secret value/i);
    expect(valueInput).toBeInTheDocument();
  });

  it('drops the word "secret" from placeholder when Plaintext is selected', () => {
    render(<VaultPanel />);
    fireEvent.click(screen.getByRole('button', { name: /plaintext/i }));
    expect(screen.queryByPlaceholderText(/secret value/i)).not.toBeInTheDocument();
    expect(screen.getByPlaceholderText(/plaintext value/i)).toBeInTheDocument();
  });

  it('shows list format hint when list type is selected', () => {
    render(<VaultPanel />);
    fireEvent.click(screen.getByRole('button', { name: 'list' }));
    expect(screen.getByPlaceholderText(/item1, item2, item3/i)).toBeInTheDocument();
  });

  it('shows JSON hint when json type is selected', () => {
    render(<VaultPanel />);
    fireEvent.click(screen.getByRole('button', { name: 'json' }));
    expect(screen.getByPlaceholderText(/\{"key": "value"\}/)).toBeInTheDocument();
  });

  it('shows number example when number type is selected', () => {
    render(<VaultPanel />);
    fireEvent.click(screen.getByRole('button', { name: 'number' }));
    expect(screen.getByPlaceholderText(/42/)).toBeInTheDocument();
  });

  it('shows bool hint when bool type is selected', () => {
    render(<VaultPanel />);
    fireEvent.click(screen.getByRole('button', { name: 'bool' }));
    expect(screen.getByPlaceholderText(/true or false/i)).toBeInTheDocument();
  });
});
```

**`web/src/__tests__/VariablesPopover.test.tsx`** (extend):
- Add a parallel `describe` block: "placeholder adaptation"
- Mirror the same six assertions above against `VariablesPopover`
- Update any existing assertion that checks for the literal `Variable value`
  placeholder string — it will be replaced by `getValuePlaceholder` output

### Existing Test Patterns

- Files live in `web/src/__tests__/`
- Use `vitest` (not jest), import from `'vitest'`
- Use `@testing-library/react` for rendering and queries
- `web/src/__tests__/VariablesPopover.test.tsx` (158 lines) is the closest
  existing reference — copy its mock setup pattern (API mocks, context
  providers, etc.) for the new `VaultPanel.test.tsx`
- No snapshot testing
- Run tests with `cd web && npm test` (or however `package.json` exposes vitest)

## Potential Pitfalls

1. **`VaultPanel` mock complexity**: `VaultPanel` is a 1000-line component that
   probably reads from React Query, context providers, and the vault API. The
   new test file will likely need a fair amount of mock setup. **Read
   `VariablesPopover.test.tsx` carefully first** to see what mocking pattern
   the project uses — copy that approach rather than inventing one.

2. **Don't break the existing `VariablesPopover` test**: it almost certainly
   has an assertion that checks for `placeholder="Variable value"` literally.
   That assertion needs updating to the new computed default. Run the
   existing test suite before making changes to know what currently passes,
   then again after to confirm no unrelated breakage.

3. **Don't over-engineer the helper**: this is a tiny pure function. Don't
   add memoization, don't extract a `PLACEHOLDERS` constants module, don't
   add i18n hooks. Single function in `variableTypeHelpers.ts`, full stop.

4. **Match validator semantics on `list`**: the placeholder MUST be
   `item1, item2, item3` (comma-separated) and NOT `["a","b"]` (JSON array).
   The validator splits by comma — using a JSON-array example would mislead
   users into doing the wrong thing.

5. **Visibility only affects `string` placeholder**: `{"key": "value"}` is
   the same hint whether the JSON is secret or plaintext; don't add
   visibility-aware variants for json/list/number/bool. Keep the helper
   simple.

6. **Run `npm run build` and `npm test` before opening the PR** — both must
   pass. The project's standard checks per `release-gridctl` workflow include
   lint, tests, and web build.

## Acceptance Criteria

1. `web/src/components/vault/variableTypeHelpers.ts` exports a
   `getValuePlaceholder(type: VariableType, isSecret: boolean): string`
   function whose output matches the per-type table in "Required Changes"
2. `web/src/components/vault/VaultPanel.tsx:581`, `web/src/pages/DetachedVaultPage.tsx:577`,
   and `web/src/components/wizard/VariablesPopover.tsx:246` all use
   `getValuePlaceholder(newType, newIsSecret)` instead of a hardcoded string
3. Key-input placeholders (`KEY_NAME` / `VARIABLE_KEY`) are unchanged
4. Selecting `Plaintext` causes the value-input placeholder to no longer
   contain the word "Secret"
5. Selecting `list` causes the placeholder to display `item1, item2, item3`
   (or equivalent that hints comma separation, not JSON)
6. Selecting `json` causes the placeholder to display `{"key": "value"}`
7. Selecting `number` and `bool` show appropriate format hints
8. New file `web/src/__tests__/VaultPanel.test.tsx` exists and exercises
   all six placeholder cases above
9. `web/src/__tests__/VariablesPopover.test.tsx` covers the same
   placeholder cases and updates any literal-string assertions affected
10. `cd web && npm test` passes
11. `cd web && npm run build` succeeds (no TS errors)
12. Manual verification: run `make build && ./gridctl serve`, open the web UI,
    toggle through all type/visibility combinations on all three surfaces (vault
    panel, `/var` detached page, wizard variable popover) and confirm the
    placeholder updates correctly in each

## References

- Full investigation:
  `<prompt-stack>/prompts/gridctl/variable-form-static-placeholders/bug-evaluation.md`
- PR #670: `feat: unified variable store — gridctl var (PR 1)` (commit `70a516a`)
- Backend validator (canonical per-type semantics): `cmd/gridctl/var.go:220-265`
- Frontend validator (mirrors backend): `web/src/components/vault/variableTypeHelpers.ts`
- Convention reference for computed placeholders in this codebase:
  `web/src/components/wizard/steps/ResourceForm.tsx` and `StackForm.tsx`
