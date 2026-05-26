# Bug Investigation: Secrets Variable Set Missing Dropdown

**Date**: 2026-04-16
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Medium
**Fix Complexity**: Small

## Summary

In the stack creation wizard's Secrets section, the "Variable Sets" field uses a generic `StringArrayEditor` component that renders plain text inputs. No dropdown or combobox is shown, so users cannot select from existing vault secret sets — they must type names manually. All infrastructure for a proper selector (API endpoint, Zustand store, `fetchVaultSets()`, and a reference popover pattern) already exists; only the frontend component needs to be replaced.

## The Bug

**Description**: When a user clicks "+ Add set" in the Secrets section of the stack wizard, a plain text input field appears. There is no dropdown, combobox, or list of existing vault sets to select from.

**Expected behavior**: Clicking "+ Add set" should present the user with a selector showing all existing vault secret sets (fetched from `/api/vault/sets`) so they can pick from them — similar to how `SecretsPopover` shows a searchable list of individual secrets.

**Actual behavior**: A plain text `<input type="text">` appears with placeholder text `secret-set-name`. The user must know and manually type the exact name of an existing set.

**Discovery**: Reported during manual walkthrough (`proto/walkthrough.md` section 3.6) in `./gridctl serve` mode while creating a stack. User created a set named `dev` and expected to be able to select it from a list.

## Root Cause

### Defect Location

`web/src/components/wizard/steps/StackForm.tsx:1081-1090` — The Secrets section uses `StringArrayEditor` for the Variable Sets field.

`web/src/components/wizard/steps/StackForm.tsx:189-250` — `StringArrayEditor` is a generic text array editor with no API integration, no dropdown logic, and no awareness of vault sets.

### Code Path

1. User expands Secrets section in `StackForm`
2. `StringArrayEditor` renders with `value={data.secrets?.sets ?? []}` and `addLabel="Add set"`
3. User clicks "+ Add set" → `addItem()` appends `''` to the array
4. For each item, `StringArrayEditor` renders `<input type="text">` — no other code path exists

### Why It Happens

`StringArrayEditor` is a reusable utility component for editing string arrays. It was used for simplicity but it has no capability to fetch or display a list of available options. The Secrets Variable Sets field needed a purpose-built component (like `SecretsPopover`) that fetches vault sets from the API and presents them as selectable options.

### Similar Instances

No other fields in `StackForm` appear to have this issue. Other resource selectors (networks, MCP servers) have custom form components. `SecretsPopover` (for individual secret references in resource env fields) works correctly.

## Impact

### Severity Classification

**Incorrect behavior** — The UI renders a functionally degraded interaction that omits the intended selection experience. Not a crash or data loss.

### User Reach

All users who use the stack creation wizard to add a secret set reference. This is a core workflow step in the walkthrough.

### Workflow Impact

Common path blocker for discoverability. The workaround (typing manually) works and produces correct YAML, but users cannot discover or browse their existing secret sets from the wizard.

### Workarounds

Type the exact set name in the plain text input. The YAML output is correct — `secrets: sets: [name]` is properly generated. The workaround is adequate but degrades UX significantly and requires users to already know their set names.

### Urgency Signals

- `proto/walkthrough.md` section 3.6 documents this step as "Click Add set → type `dev`" — the walkthrough describes the broken flow rather than the intended selector UX
- New users following the walkthrough will not know to use the vault panel first to discover set names

## Reproduction

### Minimum Reproduction Steps

1. Run `./gridctl serve`
2. Create a vault secret set: `./gridctl vault sets create dev` (or via Vault panel)
3. Open the web UI → New Stack → enter any stack name
4. Scroll to the Secrets section → expand it
5. Click "+ Add set"
6. **Observe**: A plain text input appears with no dropdown

### Affected Environments

All environments running `./gridctl serve` mode. Deterministic reproduction — not intermittent.

### Non-Affected Environments

The Vault panel itself (`VaultPanel.tsx`) correctly fetches and displays sets. `SecretsPopover` for individual secret references works correctly.

### Failure Mode

Deterministic. The `StringArrayEditor` component has no conditional code path for showing a dropdown — it always renders `<input type="text">`. No API call is made. No error is thrown.

## Fix Assessment

### Fix Surface

- `web/src/components/wizard/steps/StackForm.tsx` — replace the `StringArrayEditor` usage for Variable Sets with a new `VaultSetSelector` component
- New file: `web/src/components/wizard/VaultSetSelector.tsx` (or inline in StackForm) — a popover-style component that fetches sets and renders a searchable list

### Risk Factors

Low risk. The data structure (`data.secrets?.sets: string[]`) does not change. The fix is isolated to one section of `StackForm`. The `SecretsPopover` provides a validated reference pattern.

### Regression Test Outline

In `web/src/__tests__/StackForm.test.tsx`:
- Mock `fetchVaultSets` to return `[{ name: 'dev', count: 2 }]`
- Mount `StackForm` and expand Secrets section
- Click "+ Add set"
- Assert the dropdown/popover is visible and contains a "dev" option
- Click "dev" and assert `data.secrets.sets` contains `"dev"`

## Recommendation

**Fix immediately.** This is a small, low-risk change. All required infrastructure already exists:
- `fetchVaultSets()` in `api.ts:479` calls the functional `/api/vault/sets` endpoint
- `useVaultStore` has `sets: VaultSet[] | null` and `setSets()` already implemented
- `SecretsPopover.tsx` is a nearly identical reference implementation (fetch on open, filtered list, create-and-select)

The fix scope is: create a `VaultSetSelector` component mirroring `SecretsPopover`'s pattern (adapted for sets instead of individual secrets), and replace the `StringArrayEditor` usage at `StackForm.tsx:1081` with it.

## References

- `web/src/components/wizard/steps/StackForm.tsx` — defect location (line 1081)
- `web/src/components/wizard/SecretsPopover.tsx` — reference implementation pattern
- `web/src/stores/useVaultStore.ts` — existing store with `sets` state
- `web/src/lib/api.ts:479` — `fetchVaultSets()` API function
- `proto/walkthrough.md:215` — walkthrough step that surfaces the bug
