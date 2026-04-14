# Bug Investigation: Skill Import Wizard Broken

**Date**: 2026-04-13
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial (Bug 1) + Small (Bug 2)

## Summary

The 4-step skill import wizard is completely non-functional for git repository imports. Two bugs combine to produce "Import Failed — 0 imported, 0 skipped" on every attempt: the backend serializes import results with uppercase JSON field names while the frontend expects lowercase, and the user's skill selections from the Browse step are never sent to the backend. Both bugs have been present since the feature was introduced on 2026-03-13.

## The Bug

**Reported behavior**: When importing a skill from a git repository, the Browse & Select step (step 2) correctly discovers and displays 18 skills and allows selection. On clicking "Install 1 Skill" and proceeding to Review & Install (step 4), the operation fails with "Import Failed — 0 imported, 0 skipped".

**Expected behavior**: The selected skill should be imported/installed to the user's local skills registry with a success confirmation.

**Discovery**: User testing.

There are two distinct defects:

- **Bug 1**: Silent result marshaling failure — the UI always shows "0 imported, 0 skipped" regardless of backend outcome.
- **Bug 2**: User selections ignored — the backend imports all discovered skills, not just the user-selected ones.

## Root Cause

### Bug 1: Missing JSON Struct Tags

**Defect location**: `pkg/skills/importer.go:23-42`

```go
type ImportResult struct {
    Imported []ImportedSkill  // no json tag → marshals as "Imported"
    Skipped  []SkippedSkill   // no json tag → marshals as "Skipped"
    Warnings []string         // no json tag → marshals as "Warnings"
}

type ImportedSkill struct {
    Name      string          // no json tag → marshals as "Name"
    Path      string          // no json tag → marshals as "Path"
    Origin    *Origin
    Findings  []SecurityFinding
}

type SkippedSkill struct {
    Name   string             // no json tag → marshals as "Name"
    Reason string             // no json tag → marshals as "Reason"
}
```

**Code path**: `handleSkillSourceAdd` (internal/api/skills.go:174) → `writeJSON(w, result)` → `json.Encode` → HTTP 201 with `{"Imported": [...], "Skipped": [...], "Warnings": [...]}`

**Frontend expectation** (`web/src/types/index.ts:449-453`):
```typescript
export interface ImportResult {
  imported?: ImportedSkillResult[];   // lowercase
  skipped?: SkippedSkillResult[];     // lowercase
  warnings?: string[];
}
```

**Why it fails** (`web/src/components/wizard/steps/SkillImportWizard.tsx:83-84`):
```typescript
const imported = (result.imported ?? []).map((i) => i.name);
// result.imported is undefined (backend sent "Imported") → [] via ??
```

The API call returns HTTP 201 (no exception thrown), but `result.imported` and `result.skipped` are `undefined` because field names don't match. Both default to `[]` via nullish coalescing. `setInstallResult` is called with `{imported: [], skipped: [], warnings: []}`. UI renders "Import Failed — 0 imported, 0 skipped".

### Bug 2: User Selections Never Passed to Backend

**Defect location**: `web/src/components/wizard/steps/SkillImportWizard.tsx:66-113`

The `handleInstall()` function manages a `selected: Set<string>` of user-chosen skills throughout the wizard but never passes it to the API call:

```typescript
const result = await addSkillSource({
  repo: repoUrl,
  ref: ref || undefined,
  path: path || undefined,
  trust: hasFlagged,
  noActivate: false,
  // ← selected Set never included
});
```

The backend API (`internal/api/skills.go:136-142`) accepts no `selected` field. `ImportOptions` (`pkg/skills/importer.go:13-21`) has no filter field. `Import()` iterates all discovered skills unconditionally (`importer.go:91`).

**Compound effect**: Since the user's repo has skills that already exist locally, the backend skips all of them (Force is false). Even with Bug 1 fixed, the result would be "0 imported, N skipped" — still a failure from the user's perspective.

### Code Path (Trigger to Failure)

```
User clicks "Install 1 Skill" (browse step)
→ goNext() (SkillImportWizard.tsx:128)
→ needsConfig = true (mcp-builder exists) → setStep('configure')
→ User clicks "Install" from configure step
→ handleInstall() (SkillImportWizard.tsx:66)
→ addSkillSource({repo, ref, path, trust}) [selected omitted]
→ POST /api/skills/sources
→ handleSkillSourceAdd() (skills.go:130)
→ imp.Import({Repo, Ref, Path, Trust}) [no selected filter]
→ CloneAndDiscover() → all 18 skills
→ for each skill: GetSkill() succeeds (exists) → Skipped (Force=false)
→ ImportResult{Imported: nil, Skipped: [18 items], Warnings: nil}
→ writeJSON → {"Imported": null, "Skipped": [...], "Warnings": null}
→ HTTP 201
→ result.imported ?? [] → []
→ result.skipped ?? [] → []
→ setInstallResult({imported: [], skipped: [], warnings: []})
→ "Import Failed — 0 imported, 0 skipped"
```

### Similar Instances

No other Go structs returned via the wizard API appear to have this problem — `SkillPreview` and `SkillSourceStatus` in `internal/api/skills.go` have correct json tags. The issue is isolated to the three types in `pkg/skills/importer.go`.

## Impact

### Severity Classification

High — complete feature failure. The skill import wizard is the primary UX for adding remote skills. It has been non-functional for every user since introduction.

### User Reach

100% of users attempting to import skills from a git repository via the wizard. The feature has been present for ~31 days (since 2026-03-13) with no successful imports possible through the UI.

### Workflow Impact

Core path blocker for the wizard flow. Steps 2 (Browse & Select) and 4 (Review & Install) are both broken. Steps 1 (Add Source) and 3 (Configure) work correctly.

### Workarounds

The CLI command `gridctl skill add <repo-url>` works because it uses Go types directly without JSON marshaling. However:
- CLI imports all skills from the repo (no selection support either)
- CLI requires terminal access and manual command construction
- CLI does not support the Configure step UX (security review, activate toggle)

### Urgency Signals

Feature introduced 2026-03-13, broken from day one. No user-facing fix or known issue documentation. Core differentiating UX for skill management.

## Reproduction

### Minimum Reproduction Steps

1. Open gridctl web UI → Skills → New Skill (or equivalent import entry point)
2. Step 1 (Add Source): Enter any valid git repository URL containing SKILL.md files
3. Step 2 (Browse & Select): Observe skills are listed correctly. Select one or more.
4. Click "Install N Skill(s)" or proceed through Configure step
5. Step 4 (Review & Install): Observe "Import Failed — 0 imported, 0 skipped"

### Affected Environments

All environments — the bug is structural (JSON field name mismatch), not environment-specific.

### Non-Affected Environments

CLI (`gridctl skill add`) — not affected because it bypasses JSON serialization.

### Failure Mode

The backend executes successfully (HTTP 201) but the response JSON uses Go's default capitalized field names. The frontend reads `undefined` for all result fields and displays a false failure. The system is left in a clean state — no partial writes, no corruption. However:
- If the backend DID import skills (e.g., first-time import of new skills), those skills ARE installed despite the UI showing failure.
- This means the user may retry imports unnecessarily, leading to "already exists" errors on subsequent attempts.

## Fix Assessment

### Fix Surface

**Bug 1** (1 file):
- `pkg/skills/importer.go:23-42` — Add json struct tags to `ImportResult`, `ImportedSkill`, `SkippedSkill`

**Bug 2** (5 files):
- `pkg/skills/importer.go:13-21` — Add `Selected []string` field to `ImportOptions`
- `pkg/skills/importer.go:91` — Add filter to skip skills not in `Selected` (when Selected is non-empty)
- `internal/api/skills.go:136-165` — Accept `selected` in request body, pass to `ImportOptions`; set `Force: true` when skill is selected AND exists
- `web/src/lib/api.ts:669-677` — Add `selected?: string[]` to `addSkillSource` parameter type
- `web/src/components/wizard/steps/SkillImportWizard.tsx:75-81` — Pass `[...selected]` to `addSkillSource`

### Risk Factors

Bug 1: No risk. Adding json tags to unexported struct fields only affects JSON marshaling, which was broken before.

Bug 2: Low-medium risk. The Force-on-selected logic (importing existing skills when explicitly selected) is new behavior. The importer has other callers (CLI, Update flow) that must remain unaffected — the `Selected` filter should only activate when `len(Selected) > 0`.

### Regression Test Outline

**Bug 1**: HTTP-level test for `POST /api/skills/sources` that asserts the response JSON contains lowercase `imported`, `skipped`, `warnings` keys.

**Bug 2**: Unit test for `Import()` with a populated `Selected` list to verify only selected skills are processed.

## Recommendation

Fix immediately. Both bugs are straightforward with low blast radius. Bug 1 alone (trivial, 1 file) restores the results display and unblocks users from understanding what happened. Bug 2 (small, 5 files) makes the Browse & Select step meaningful. They should be fixed together in a single PR since they address the same broken feature.

## References

- Feature introduced: commit `ff8067f` — "feat: add 4-step skill import wizard" (2026-03-13)
- CLI workaround: `gridctl skill add <repo-url> [--trust] [--no-activate] [--force]`
- Go JSON encoding defaults: https://pkg.go.dev/encoding/json — field names default to struct field name when no json tag is present
