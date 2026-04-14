# Bug Fix: Skill Import Wizard Broken

## Context

gridctl is a Go + React application for managing Claude Code skills and MCP servers. The backend is a Go HTTP API server (`internal/api/`), the skill management logic lives in `pkg/skills/`, and the frontend is a React + TypeScript SPA in `web/src/`.

Skills are markdown files (SKILL.md) that define Claude Code behaviors. The 4-step import wizard allows users to clone a git repository, browse and select skills, configure them, and install them.

Tech stack: Go 1.22+, React, TypeScript, Vite, Tailwind. No ORM — filesystem-backed skill registry.

## Investigation Context

- Root cause fully confirmed. See full investigation: `prompts/gridctl/skill-import-wizard-broken/bug-evaluation.md`
- Bug 1 confirmed: `pkg/skills/importer.go:23-42` — three Go structs lack json tags, causing case mismatch
- Bug 2 confirmed: `web/src/components/wizard/steps/SkillImportWizard.tsx:75-81` — selected skills Set never passed to backend
- Both bugs reproduce 100% on any git repo import via wizard
- CLI (`gridctl skill add`) is unaffected and serves as validation baseline
- No risk of data corruption — backend is clean, only display and selection filtering are broken

## Bug Description

### Bug 1: JSON Field Name Mismatch

The backend returns import results with **capitalized** JSON field names (`Imported`, `Skipped`, `Warnings`, `Name`, `Reason`, `Path`) because the Go structs have no `json:` struct tags. The frontend TypeScript interfaces expect **lowercase** names (`imported`, `skipped`, `warnings`, `name`, `reason`, `path`).

Result: `result.imported` is `undefined` on the frontend → `??` coalesces to `[]` → "Import Failed — 0 imported, 0 skipped" on every import, even when the backend succeeds.

### Bug 2: User Skill Selections Ignored

The wizard's Browse & Select step (step 2) tracks user selections in a `Set<string>`. When the user clicks Install, `handleInstall()` calls `addSkillSource()` without passing the selection. The backend imports all discovered skills from the repo, not just the selected ones.

Because all existing skills have `Force=false` protection, any skill that already exists is skipped. If the user's repo contains skills they already have installed, all imports are skipped.

## Root Cause

### Bug 1 — Specific files and lines

`pkg/skills/importer.go:23-42`:
```go
type ImportResult struct {
    Imported []ImportedSkill   // ← missing json:"imported"
    Skipped  []SkippedSkill    // ← missing json:"skipped"
    Warnings []string          // ← missing json:"warnings"
}

type ImportedSkill struct {
    Name      string           // ← missing json:"name"
    Path      string           // ← missing json:"path"
    Origin    *Origin
    Findings  []SecurityFinding
}

type SkippedSkill struct {
    Name   string              // ← missing json:"name"
    Reason string              // ← missing json:"reason"
}
```

### Bug 2 — Specific files and lines

`web/src/components/wizard/steps/SkillImportWizard.tsx:75-81`:
```typescript
const result = await addSkillSource({
  repo: repoUrl,
  ref: ref || undefined,
  path: path || undefined,
  trust: hasFlagged,
  noActivate: false,
  // selected is never passed
});
```

## Fix Requirements

### Required Changes

**Bug 1 — Add json struct tags** (`pkg/skills/importer.go`):

1. Add `json:"imported"` tag to `ImportResult.Imported`
2. Add `json:"skipped"` tag to `ImportResult.Skipped`
3. Add `json:"warnings"` tag to `ImportResult.Warnings`
4. Add `json:"name"` tag to `ImportedSkill.Name`
5. Add `json:"path"` tag to `ImportedSkill.Path`
6. Add `json:"name"` tag to `SkippedSkill.Name`
7. Add `json:"reason"` tag to `SkippedSkill.Reason`

Also check `ImportedSkill.Origin` and `ImportedSkill.Findings` — add lowercase json tags if frontend reads these fields. (Frontend `ImportedSkillResult` only uses `name` and `path`, so `Origin` and `Findings` can use `json:"origin"` and `json:"findings"` for consistency, or be omitted from the frontend type.)

**Bug 2 — Wire selections through the stack** (5 files):

1. **`pkg/skills/importer.go`** — Add `Selected []string` to `ImportOptions`. In the `Import()` loop, when `len(opts.Selected) > 0`, skip any `discovered.Name` not in the selected set. Also: when a skill is in `Selected` and already exists, treat it as `Force=true` (user explicitly chose to re-import it).

2. **`internal/api/skills.go`** — Add `Selected []string` field to the anonymous request struct in `handleSkillSourceAdd()`. Pass it to `ImportOptions.Selected`.

3. **`web/src/lib/api.ts`** — Add `selected?: string[]` to the parameter object type in `addSkillSource()`. Pass it through to the POST body.

4. **`web/src/components/wizard/steps/SkillImportWizard.tsx`** — In `handleInstall()`, add `selected: [...selected]` to the `addSkillSource()` call.

5. **`web/src/types/index.ts`** — No changes needed (ImportResult already uses lowercase field names in the TypeScript interface, which Bug 1 fixes will align with).

### Constraints

- The `Selected` filter in `Import()` must only activate when `len(opts.Selected) > 0`. When empty (CLI, update flow), all skills continue to be imported — no behavior change for existing callers.
- The Force-on-selected logic (re-importing existing skills) must only apply within the `Selected` filter branch, not globally.
- Do not change the `Update()` or `Remove()` methods — they are unrelated and working correctly.
- Do not change CLI commands — they do not use the wizard path and work correctly.

### Out of Scope

- Rename support (`--rename` flag) — not part of the wizard, unrelated
- Auto-update configuration (skills.yaml) — separate feature
- The Configure step's `activate` toggle per skill — the `noActivate` field handling already exists; do not change it (though wiring per-skill activate config is a future improvement)
- Adding tests for unrelated code paths

## Implementation Guidance

### Key Files to Read

1. `pkg/skills/importer.go` — Core import logic; read before making any changes to understand the full loop at lines 91-183 and `ImportOptions` at lines 13-21
2. `internal/api/skills.go` — API handler; read `handleSkillSourceAdd()` at lines 128-175
3. `web/src/components/wizard/steps/SkillImportWizard.tsx` — Full wizard; read `handleInstall()` at lines 66-113 and `goNext()` at lines 128-144
4. `web/src/lib/api.ts` — API client; read `addSkillSource()` at lines 669-677 and `mutateJSON()` to understand response handling
5. `web/src/types/index.ts` — TypeScript types; read `ImportResult`, `ImportedSkillResult`, `SkippedSkillResult` at lines 439-453

### Files to Modify

| File | Change |
|------|--------|
| `pkg/skills/importer.go` | Add json tags to 3 structs; add `Selected []string` to `ImportOptions`; add filter logic in the `Import()` loop |
| `internal/api/skills.go` | Accept `selected` in request body; pass to `ImportOptions` |
| `web/src/lib/api.ts` | Add `selected?: string[]` to `addSkillSource` parameter type |
| `web/src/components/wizard/steps/SkillImportWizard.tsx` | Pass `[...selected]` in `handleInstall()` API call |

### Reusable Components

- The existing `opts.Force` boolean in `Import()` shows the pattern for per-skill overrides — use the same guard pattern for the selected filter
- `imp.store.GetSkill(skillName)` returning nil error means skill exists — already used at line 98 for the Force check; reuse this for the selected+exists case

### Conventions to Follow

- Go: All exported JSON types in this project use `json:"camelCase"` tags (see `SkillPreview`, `SkillSourceStatus` in `internal/api/skills.go` as reference)
- Go: Error messages use `fmt.Sprintf("skill %q ...", skillName)` pattern
- TypeScript: Optional fields use `?: T` (not `| undefined`)
- TypeScript: API client functions pass the full source object to `mutateJSON` — add new fields directly to the existing object literal

### Selected Filter Implementation Sketch (Go)

```go
// Build a lookup set for efficient filtering
selectedSet := make(map[string]bool, len(opts.Selected))
for _, name := range opts.Selected {
    selectedSet[name] = true
}

for _, discovered := range result.Skills {
    skillName := discovered.Name
    // ... rename logic ...

    // Filter to selected skills only (when selection is provided)
    if len(opts.Selected) > 0 && !selectedSet[skillName] {
        continue
    }

    // If skill exists and is explicitly selected, treat as force
    force := opts.Force
    if _, err := imp.store.GetSkill(skillName); err == nil {
        if len(opts.Selected) > 0 && selectedSet[skillName] {
            force = true // user explicitly chose to re-import
        } else if !force {
            importResult.Skipped = append(...)
            continue
        }
    }
    // ... rest of loop unchanged
```

## Regression Test

### Test Outline

**Bug 1 test** — API contract (Go, `internal/api/skills_test.go` or new test file):
- Mock or stub `Importer.Import()` to return a known `ImportResult` with 1 imported skill and 1 skipped skill
- Call `POST /api/skills/sources` via `httptest`
- Assert response JSON contains lowercase keys: `imported`, `skipped`, `warnings`
- Assert `imported[0].name` is accessible (not `imported[0].Name`)

**Bug 2 test** — Selection filter (Go, `pkg/skills/importer_test.go`):
- Construct `ImportOptions` with `Selected: []string{"skill-a"}` and a mock repo containing `skill-a` and `skill-b`
- Call `Import()`
- Assert only `skill-a` appears in `result.Imported`, `skill-b` is not present in either Imported or Skipped

### Existing Test Patterns

- Go backend tests live in `internal/api/skills_test.go` — use `httptest.NewRecorder()` and `httptest.NewRequest()`
- `pkg/skills/importer_test.go` exists but only tests `Remove`, `Pin`, `Info` — the `Import()` function has no tests, so a new test function is needed
- Frontend tests: `web/src/__tests__/SkillImportWizard.test.tsx` (mocked) — not required for this fix

## Potential Pitfalls

1. **`Origin` and `Findings` fields on `ImportedSkill`**: The frontend `ImportedSkillResult` type only uses `name` and `path`, so these fields aren't consumed by the wizard. Add json tags for consistency but don't let this block the fix.

2. **Nil vs empty slice in JSON**: Go marshals nil slices as `null` and empty slices as `[]`. The frontend uses `result.imported ?? []` which handles null correctly. After adding json tags, `null` is fine for empty results — no need to initialize slices to `[]` in `ImportResult`.

3. **Other callers of `Import()`**: `Update()` in `importer.go` calls `Import()` with `Force: true` and no `Selected`. Confirm `len(opts.Selected) == 0` check means the selected filter is a no-op for `Update()`.

4. **`addSkillSource` backend not rejecting unknown fields**: Go's `json.Decoder` ignores unknown fields by default, so adding `selected` to the frontend request is safe and backward-compatible.

5. **`noActivate` per-skill**: The Configure step has a per-skill `activate` toggle stored in `configs: Map<string, SkillConfig>`, but `handleInstall()` hardcodes `noActivate: false`. This is a pre-existing limitation — do not change it in this fix.

## Acceptance Criteria

1. Importing a skill from a git repository via the wizard shows the correct result on the Review & Install step (imported count > 0 when skills were successfully imported).
2. Skills not selected in the Browse & Select step are not imported.
3. Selecting a skill that already exists and clicking Install successfully re-imports (overwrites) it without requiring `--force`.
4. The CLI `gridctl skill add` continues to work as before (imports all skills, no selection filter applied).
5. The `Update()` flow continues to work as before (Force=true, no Selected filter).
6. Response JSON from `POST /api/skills/sources` uses lowercase field names: `imported`, `skipped`, `warnings`, `name`, `path`, `reason`.

## References

- Full investigation: `prompts/gridctl/skill-import-wizard-broken/bug-evaluation.md`
- Go JSON encoding docs: https://pkg.go.dev/encoding/json
- Reference structs with correct json tags: `internal/api/skills.go:36-45` (`SkillPreview`), `internal/api/skills.go:12-24` (`SkillSourceStatus`)
