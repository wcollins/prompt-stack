# Bug Investigation: Plaintext Variable Input Stays Masked

**Date**: 2026-05-23
**Project**: gridctl
**Recommendation**: Fix immediately (quick win)
**Severity**: Low
**Fix Complexity**: Trivial

## Summary

In the Variables workspace add/edit forms, selecting **Plaintext** mode does not unmask
the value input — it stays rendered as password dots (`••••••••`), identical to **Secret**
mode. The value input's `type` is keyed only off the eye-reveal toggle and never consults
the `isSecret` flag. A correct implementation already exists in the wizard popover, making
this a trivial, low-risk, high-confidence fix that restores documented behavior.

## The Bug

- **What is wrong:** When adding (or editing) a variable in the Variables workspace and
  selecting `Plaintext`, the value input field continues to mask the value as `••••••••`
  exactly as it does in `Secret` mode. The Secret/Plaintext toggle has no effect on input
  masking.
- **Expected behavior:** Plaintext mode should display the value natively as visible text
  (`type="text"`). This is documented in `CHANGELOG.md:140` ("plaintext variables display
  their value unmasked by default") and `docs/config-schema.md:717` (plaintext is "kept
  legible in logs and the web UI").
- **Actual behavior:** The input remains `type="password"` regardless of the toggle. The
  only way to see the value while typing is to click the eye icon, which defeats the
  purpose of choosing Plaintext.
- **How discovered:** Manual testing on `v0.1.0-beta.10-16-g16841f3` (screenshots provided).

## Root Cause

### Defect Location
- **Add form (reported):** `web/src/components/vault/VariableQuickAddForm.tsx:108`
  ```tsx
  type={showValue ? 'text' : 'password'}
  ```
- **Inline edit (same defect):** `web/src/components/vault/SecretItem.tsx:87`
  ```tsx
  type={showEditValue ? 'text' : 'password'}
  ```

### Code Path
1. `VariableSecretToggle` (`VariableQuickAddForm.tsx:127`) updates `isSecret` state via
   `onChange={setIsSecret}`.
2. `isSecret` flows into `getValuePlaceholder(type, isSecret)` (line 111) and the submit
   payload (line 67) — but **never** into the value input's `type` (line 108).
3. The input's `type` reads only `showValue`, which defaults to `false` (line 44) and is
   toggled solely by the eye button (line 119). → toggle has no effect on masking.
4. Edit path: `SecretItem` receives the full `secret: Variable` object (so `secret.is_secret`
   is available at line 87), but the edit input also reads only `showEditValue`.

### Why It Happens
A missing condition. The masking expression should include the plaintext case
(`showValue || !isSecret`) but only checks the reveal toggle (`showValue`). The plaintext
branch was simply never wired into the input's `type`.

### Similar Instances
- The same defect appears in both the add form (`VariableQuickAddForm.tsx`) and the inline
  edit (`SecretItem.tsx`).
- The **correct** reference implementation is `web/src/components/wizard/VariablesPopover.tsx:243`:
  `type={showValue || !newIsSecret ? 'text' : 'password'}`. This confirms the intended
  pattern and the exact fix.
- Read-only row display is already plaintext-aware (`SecretItem.tsx:128-134`, eager fetch
  in `useVaultManager`), so this is not a data-path bug — only the editable input is wrong.

## Impact

### Severity Classification
Low — Incorrect behavior / cosmetic-UX. Not a crash, not data loss. It is the inverse of a
security risk: it over-hides a value the user explicitly flagged as non-sensitive.

### User Reach
Anyone adding or editing a Plaintext variable in the web UI. The data is stored correctly
(the `isSecret` flag round-trips to the backend) and plaintext rows display unmasked in the
read-only list — only the input-while-editing is affected.

### Workflow Impact
Minor friction on a non-critical path. Users can still complete the action; they just can't
see what they type without an extra click.

### Workarounds
Click the eye icon to reveal. Adequate but annoying, and it contradicts the entire point of
selecting Plaintext mode.

### Urgency Signals
No active outage or data risk. The mild urgency is that it contradicts shipped documentation
in a workspace under active development (recent commits #689–#692 promoting Variables to a
first-class workspace), so correctness polish here has compounding value.

## Reproduction

### Minimum Reproduction Steps
1. Open the web UI → **Variables** workspace.
2. Focus the add form at the top.
3. Click **Plaintext**.
4. Type a value → observe it renders as `••••••••` instead of visible text.
5. (Edit variant) Expand a plaintext variable → **Edit** → the input opens masked.

### Affected Environments
All — purely client-side React rendering logic. Independent of OS/browser/backend.

### Non-Affected Environments
The wizard's variable popover (`VariablesPopover.tsx`) is unaffected; it already includes the
correct `|| !newIsSecret` condition.

### Failure Mode
Deterministic. The input's `type` is computed solely from `showValue`/`showEditValue`, so it
fails every time Plaintext is selected without the reveal toggle on. No corrupted state — the
underlying value and `is_secret` flag are correct.

## Fix Assessment

### Fix Surface
- `web/src/components/vault/VariableQuickAddForm.tsx:108` — add `|| !isSecret`.
- `web/src/components/vault/SecretItem.tsx:87` — add `|| !secret.is_secret`.

### Risk Factors
Minimal. Both are isolated one-line boolean changes mirroring an existing correct pattern.
The only behavioral consideration: when a user is *editing a secret*, the value should remain
masked by default (preserved — the `!secret.is_secret` term is false for secrets).

### Regression Test Outline
Add a test (host: `web/src/__tests__/VaultPanel.test.tsx`, mirroring the placeholder-text
assertions and `AuthPrompt.test.tsx`'s `type` assertions):
- Render the add form, select Plaintext, assert the value input has `type="text"`.
- Select Secret, assert the value input has `type="password"`.
- Optionally: render `SecretItem` in editing mode for a plaintext variable, assert `type="text"`.

## Recommendation

**Fix immediately (quick win).** Severity is genuinely Low, but this is not the "low value,
real effort" case that warrants deferral. It is a two-line, high-confidence change that mirrors
existing in-repo code and restores documented behavior in a workspace being actively polished.
Cover both the add form and the inline edit in one fix for consistency, and add a small
regression test asserting the input `type` per mode (no such coverage exists today).

## References

- Correct reference implementation: `web/src/components/wizard/VariablesPopover.tsx:243`
- Documented intended behavior: `CHANGELOG.md:140-142`, `docs/config-schema.md:714-722`
- Constitution (secret-default rationale): `CONSTITUTION.md` Article XII
- Toggle component: `web/src/components/vault/VariableSecretToggle.tsx`
