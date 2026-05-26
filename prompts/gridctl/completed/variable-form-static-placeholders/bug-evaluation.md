# Bug Investigation: Variable Form Static Placeholders

**Date**: 2026-05-19
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Medium (incorrect-information UI defect)
**Fix Complexity**: Trivial

## Summary

The variable creation form's value-input placeholder is hardcoded as `Secret value`
(or `Variable value` in the wizard popover) and never adapts to the user's selected
type (`string`/`json`/`list`/`number`/`bool`) or visibility (`Secret`/`Plaintext`).
Most visibly, the placeholder reads `Secret value` even when the user has explicitly
selected `Plaintext` — actively contradicting their selection. The defect exists in
three near-identical places in the web frontend. Fix is a single small helper plus
three call-site replacements; recommend landing as a fast follow-up to PR #670
before further iteration on the unified variable store.

## The Bug

**Expected behavior**: When the user picks a type tab and/or a visibility tab in the
variable quick-add form, the value-input placeholder should update to reflect the
selection — e.g., `item1, item2, item3` for `list`, `42` for `number`, `true or false`
for `bool`, `{"key": "value"}` for `json`, and never the word "Secret" when
`Plaintext` is selected.

**Actual behavior**: The placeholders are static string literals (`KEY_NAME` and
`Secret value` in the vault forms; `VARIABLE_KEY` and `Variable value` in the wizard
popover) and never change regardless of tab selection.

**Discovery**: Self-reported by project owner while dogfooding the unified variable
store UI that landed in PR #670 (`70a516a feat: unified variable store — gridctl var
(PR 1)`).

## Root Cause

### Defect Location

Three duplicate locations in `web/`:

- `web/src/components/vault/VaultPanel.tsx:569` — `placeholder="KEY_NAME"`
- `web/src/components/vault/VaultPanel.tsx:581` — `placeholder="Secret value"`
- `web/src/pages/DetachedVaultPage.tsx:565` — `placeholder="KEY_NAME"`
- `web/src/pages/DetachedVaultPage.tsx:577` — `placeholder="Secret value"`
- `web/src/components/wizard/VariablesPopover.tsx:238` — `placeholder="VARIABLE_KEY"`
- `web/src/components/wizard/VariablesPopover.tsx:246` — `placeholder="Variable value"`

### Code Path

1. User opens vault panel / detached vault page / wizard variable popover
2. The form renders with `useState` for `newType` (default `'string'`) and `newIsSecret`
   (default `true`)
3. The form passes these into `VariableTypeSelector` and `VariableSecretToggle`,
   which call `setNewType` / `setNewIsSecret` on click
4. State updates correctly — the segmented controls re-render with the new active tab
5. **Defect**: the `<input placeholder="...">` attribute is a string literal,
   never derived from `newType` or `newIsSecret`. Re-renders don't change it.

### Why It Happens

Plain oversight during the form's construction in PR #670. The form correctly tracks
type and visibility state for the eventual submit payload, but the placeholder text
was authored as a static label rather than a computed hint. There is no
`getValuePlaceholder` helper or equivalent in the codebase; type-specific UX hints
simply weren't wired in.

The neighboring file `web/src/components/vault/variableTypeHelpers.ts` defines exactly
the per-type validation logic (`validateVariableInput`) that the placeholder should
mirror — so the canonical "what is a valid value for type X" already lives in the
right place; it just doesn't have a companion placeholder helper yet.

### Similar Instances

The wizard forms `web/src/components/wizard/steps/ResourceForm.tsx` and
`StackForm.tsx` already use the *correct* pattern (computed placeholders passed via
props from a data-driven config). The variable forms simply didn't follow that
pattern.

No other variable-related forms found.

## Impact

### Severity Classification

**Medium**. This is an incorrect-information UI defect, one step above pure cosmetic
polish because the `Secret value` placeholder *actively contradicts* a user's
`Plaintext` selection. Not a crash, not data loss, not security. The submitted variable
is still stored correctly — only the hint is wrong.

### User Reach

Every user who creates a variable through the web UI hits one of the three affected
surfaces. The unified variable store feature is the most recent addition (PR #670)
so adoption is presumably ramping; fixing this before broad adoption is preferable
to fixing it after.

### Workflow Impact

**Common path, not blocker**. Users can still create variables of any type — they
just receive a misleading or absent hint. The most concrete downstream risk: a user
selecting `list` and entering `["a","b"]` (a reasonable guess) will silently get a
single-element list because the `list` validator splits by comma rather than
parsing JSON. Surfaces clearly enough on retrieval that users will recover, but it's
friction that a hint would prevent.

### Workarounds

None at the user level. The CLI bypasses the web UI but isn't a "workaround" so much
as a different surface. `docs/config-schema.md` does not document per-type value
format expectations, so docs don't compensate either.

### Urgency Signals

Low. No reported incident, no security implication, no time pressure. Self-discovered
during dogfooding — the ideal time to fix UX defects.

## Reproduction

### Minimum Reproduction Steps

**Surface A — Vault Panel (primary)**:
1. `make build && ./gridctl serve`
2. Open the web UI; open the right-side Vault panel
3. Observe the quick-add form below the search
4. Click any type tab (`string`/`json`/`list`/`number`/`bool`) and/or toggle
   `Secret`/`Plaintext`
5. The two input placeholders never change

**Surface B — Detached Vault Page**: same as A but navigate directly to `/var`.

**Surface C — Variable Popover (wizard)**: open a wizard step that contains a
"Create New Variable" button (e.g., a resource/stack/MCP-server form), click it,
observe the same hardcoded placeholders.

### Affected Environments

Every browser, every OS. The placeholders are hardcoded JSX attributes — no
environmental variance.

### Non-Affected Environments

The CLI (`gridctl var add`) is unaffected (no placeholders involved).

### Failure Mode

Pure informational defect. The submitted variable is stored with the correct type and
visibility (validation via `validateVariableInput` in
`web/src/components/vault/variableTypeHelpers.ts` and the Go-side `validateAndNormalize`
in `cmd/gridctl/var.go:220`). Only the placeholder hint is wrong. System state is
always clean.

## Fix Assessment

### Fix Surface

- **New**: a `getValuePlaceholder(type, isSecret)` helper in
  `web/src/components/vault/variableTypeHelpers.ts` (co-located with the validator
  that defines per-type formats — single source of truth)
- **Modify**: 3 placeholder lines:
  - `web/src/components/vault/VaultPanel.tsx:581`
  - `web/src/pages/DetachedVaultPage.tsx:577`
  - `web/src/components/wizard/VariablesPopover.tsx:246`
- **Key placeholder stays as-is**: per scope decision, `KEY_NAME` / `VARIABLE_KEY`
  are generic enough and don't need per-type variants

### Risk Factors

Effectively none. Pure UI string change — no state changes, no API changes, no
validation logic changes. Worst case: a placeholder string is awkward, which is
easy to iterate on.

One thing to be careful about: don't break the existing
`VariablesPopover.test.tsx` assertions that check for the literal placeholder
`Variable value` (or similar). The test must be updated to match the new computed
default rather than left to fail.

### Regression Test Outline

**New file** `web/src/__tests__/VaultPanel.test.tsx` (no tests exist for this
1000-line component today — creates a test foothold):
- Render `<VaultPanel />` with default state
- Assert value-input placeholder when `string` + `Secret`
- Click `Plaintext` button → assert placeholder no longer contains the word "Secret"
- Click `list` type tab → assert placeholder contains list format hint
- Click `number` type tab → assert placeholder contains a number example
- Click `json` type tab → assert placeholder contains JSON syntax hint
- Click `bool` type tab → assert placeholder contains bool format hint

**Extend** `web/src/__tests__/VariablesPopover.test.tsx`:
- Add a test that toggles type tabs and visibility tabs and asserts placeholder changes
- Update any existing assertion that checks for the literal string `Variable value`

The `DetachedVaultPage` form is structurally identical to `VaultPanel`'s form. Per
the project's existing test patterns (no snapshot tests, focused unit tests over
broad render tests), covering `VaultPanel` plus the helper itself is sufficient.
Optionally add a one-line snapshot or assertion in a `DetachedVaultPage` test if
one ever gets created — but creating a parallel test file just for this fix is
overkill.

## Recommendation

**Fix immediately, standard scope**:
1. Add `getValuePlaceholder(type, isSecret): string` to
   `web/src/components/vault/variableTypeHelpers.ts`
2. Replace the three hardcoded value placeholders with `getValuePlaceholder(newType,
   newIsSecret)` calls
3. Leave key placeholders (`KEY_NAME`, `VARIABLE_KEY`) untouched
4. Add `VaultPanel.test.tsx` covering placeholder adaptation
5. Extend `VariablesPopover.test.tsx` with placeholder-adaptation cases and update
   any literal-string assertions

Land as a `fix:` PR following the variable-store PR sequence. Estimated work: ~30
minutes including tests.

Out of scope for this fix (worth tracking separately):
- Documentation of per-type input formats in `docs/config-schema.md` (Phase 2 agent
  flagged this gap; doesn't need to be in this PR)
- Inline format-error help text on submit failure (related polish, but distinct)
- Per-type key placeholder (`DATABASE_URL` for string, `CONFIG_JSON` for json, etc.)
  — explicitly out of scope per Phase 1 decision

## References

- PR #670: `feat: unified variable store — gridctl var (PR 1)` (commit `70a516a`)
- `web/src/components/vault/variableTypeHelpers.ts` — companion validator that
  defines canonical per-type input formats
- `cmd/gridctl/var.go:220-265` — Go-side validator (`validateAndNormalize`)
  mirrors the same formats
- `web/src/components/wizard/steps/ResourceForm.tsx` and `StackForm.tsx` — existing
  examples of computed-placeholder patterns in this codebase
