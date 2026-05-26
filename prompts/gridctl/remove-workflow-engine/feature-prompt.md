# Feature Implementation: Remove YAML Workflow Engine

## Context

gridctl is a Go CLI plus React web UI (located at `/Users/william/code/gridctl`) that orchestrates MCP servers, with a registry layer for skill management and a Code Mode sandbox for code-first execution. It has had two parallel skill execution models: a YAML-driven workflow DAG engine (`pkg/registry/dag.go`, `executor.go`, `template.go`, `tester.go`) authored in `SKILL.md` `workflow:` blocks, and a code-first model that is becoming primary in Brief 3.

This task removes the YAML workflow engine entirely. The MCP gateway (`pkg/mcp/*`), the Code Mode sandbox (`pkg/mcp/codemode*.go`), and the remote skill import infrastructure (`pkg/skills/*` — importer, lockfile, origin tracking) all stay intact. SKILL.md as a manifest file survives; the `workflow:` block inside it does not.

Tech stack: Go (CLI + server), React + TypeScript (web UI under `web/`), YAML for skill manifests, MCP for tool surfaces. Build via `make build` (chains web build + Go build). Tests via `make test` (`go test -v ./...`).

## Evaluation Context

The full evaluation lives at `prompts/gridctl/remove-workflow-engine/feature-evaluation.md`. Key findings the implementer must understand:

- **The brief's deletion list was mostly accurate but had three concrete errors:**
  1. Workflow API handlers are in `internal/api/registry.go`, not `internal/api/skills.go`. `internal/api/skills.go` (skill *sources*) stays untouched.
  2. `proto/skills/` is a generic CRUD/metadata test harness, not a workflow harness. Keep it.
  3. `pkg/skills/*` "do not touch" cannot be absolute — `scanner.go` and `fingerprint.go` reference `WorkflowStep`. Surgical edits to those two files are required and authorized. The rest of `pkg/skills` (importer, lockfile, scanner core, fingerprint core) stays untouched.

- **The audit surfaced kept-but-coupled files the brief did not list:** `pkg/registry/server.go` (executor field, `Tools()`, `CallTool()`, `WithToolCaller()`), `web/src/components/registry/SkillEditor.tsx`, `web/src/pages/DetachedWorkflowPage.tsx`, `web/src/stores/useWorkflowStore.ts`, `web/src/lib/workflowSync.ts`, `web/src/hooks/useWorkflowKeyboardShortcuts.ts`, `web/src/hooks/useWorkflowFontSize.ts`, `web/src/types/index.ts`, `docs/api-reference.md`, and several `*_test.go` files with `Workflow: []registry.WorkflowStep{...}` fixtures.

- **Deletion order matters.** Editing call sites in kept files *before* deleting the types/functions they reference keeps the build close to compilable across the change. The build order below prescribes this.

- **Examples will be thin after deletion.** Only `explain-error` and `code-review` survive in `examples/registry/items/`. The implementer must verify `gridctl skill list` still produces a non-empty result and flag if it doesn't.

## Feature Description

Delete the YAML workflow engine and its surrounding scaffolding (UI designer, executor, DAG builder, template engine, acceptance-criteria runner, integration tests, examples, docs sections), apply surgical edits to a roster of kept files that reference workflow types, and add a `[Unreleased]` CHANGELOG entry describing the removal as a breaking change.

The goal is a clean cut. Do not preserve the workflow YAML grammar via shims, deprecation warnings, or empty stubs. If a function in a kept file becomes dead after the deletions (no callers), remove it too. If a test fails because of removed types, delete that test rather than rewrite it.

## Requirements

### Functional Requirements

1. All files in the **Pure Deletion** list below are removed from the repo.
2. All edits in the **Surgical Edits** list below are applied; no orphaned references to deleted types/functions remain.
3. The grep `rg "WorkflowStep|BuildWorkflowDAG|registry.Executor|TemplateContext" pkg/ cmd/ internal/ web/` returns zero results across the codebase.
4. `make build` produces a working `gridctl` binary.
5. `make test` passes.
6. `./gridctl apply examples/getting-started/skills-basic.yaml` applies a stack with the surviving skills present in the registry as prompts.
7. `./gridctl skill list` works against the kept skill examples (`explain-error`, `code-review`) and shows them.
8. `./gridctl link claude` still wires Claude Desktop to the gateway.
9. A `CHANGELOG.md` entry under `[Unreleased]` describes the removal as a breaking change.

### Non-Functional Requirements

- This is a deliberate breaking change. No shims, no deprecation warnings, no backwards-compat for the `workflow:` block.
- No new features. This is a pure removal; do not refactor surviving code beyond what the deletions force.
- Sign all commits with `-S`. No "Co-Authored-By" trailer. No mention of Claude in commits, PRs, or branch names.

### Out of Scope

- The Brief 3 code-first agent runtime (lands separately).
- Refactoring `pkg/registry/store.go` or `pkg/registry/server.go` beyond removing executor coupling.
- Changes to `pkg/mcp/*`, `pkg/mcp/codemode*.go`, `pkg/vault`, `pkg/pins`, `pkg/git`, `pkg/builder`, `pkg/runtime`, `pkg/controller`, `pkg/format`, `pkg/metrics`, `pkg/pricing`, `pkg/tracing`, `pkg/optimize`, `pkg/output`, `pkg/provisioner`.
- The bulk of `pkg/skills/*` (importer, lockfile, origin tracking, updater). Only `scanner.go` and `fingerprint.go` get surgical edits.
- `internal/api/skills.go` (skill source CRUD — untouched).
- `proto/skills/` (generic CRUD harness — untouched).
- `cmd/gridctl/skill.go` `try` subcommand (verified not to depend on the executor — leave it alone).
- New examples or skills to replace the deleted ones (the thin state is acceptable; just verify the surviving two list correctly).

## Architecture Guidance

### Recommended Approach

Work in the order below. Each phase should leave the build closer to compilable than the last; do not delete a type before its call sites are edited.

1. **Phase A — Edit call sites in kept Go files.** Remove every reference to soon-to-be-deleted symbols (`WorkflowStep`, `WorkflowOutput`, `RetryPolicy`, `SkillInput`, `StringOrSlice`, `IsExecutable()`, `ToMCPTool()`, `BuildWorkflowDAG`, `TemplateContext`) from `pkg/registry/validator.go`, `pkg/registry/server.go`, `internal/api/registry.go`, `pkg/skills/scanner.go`, `pkg/skills/fingerprint.go`. Remove the workflow handlers' route registrations from wherever routes are wired. Build will still succeed at this phase because the types still exist — they just become unused.
2. **Phase B — Delete the *_test.go fixtures that use workflow types.** Remove offending test cases / functions in `internal/api/registry_test.go`, `pkg/registry/validator_test.go`, `pkg/registry/frontmatter_test.go`, `pkg/registry/types_test.go`, `pkg/skills/scanner_test.go`. Do not rewrite them.
3. **Phase C — Delete standalone Go files.** `pkg/registry/dag.go`, `executor.go`, `template.go`, `tester.go` and their tests. `cmd/gridctl/test.go`, `activate.go` and their tests. `tests/integration/skills_executor_test.go`.
4. **Phase D — Remove types from `pkg/registry/types.go`.** Delete `SkillInput`, `WorkflowStep`, `RetryPolicy`, `WorkflowOutput`, `StringOrSlice` (and `StringOrSlice.UnmarshalYAML`). Remove the `Inputs`, `Workflow`, `Output` fields from `AgentSkill`. Remove the `IsExecutable()` and `ToMCPTool()` methods. Confirm `validateState()` and the kept types (`ItemState`, `AgentSkill`, `SkillFile`, `RegistryStatus`) remain intact.
5. **Phase E — Run `make build`.** Fix any remaining Go compilation errors. They will be in places the audit didn't find. If a kept function in a kept file becomes dead (no callers) after the edits, remove it.
6. **Phase F — Web UI.** Delete the workflow components directory and the workflow-coupled non-component files. Edit `SkillEditor.tsx` to remove the workflow UI mounts. Remove workflow types from `web/src/types/index.ts`. Run `npm run build` (or `make build-web`) and fix any TypeScript errors.
7. **Phase G — Examples and docs.** Delete the workflow example directories. Remove workflow API sections from `docs/api-reference.md`.
8. **Phase H — Verify acceptance criteria.** Run the full verification checklist (below).
9. **Phase I — CHANGELOG.** Add the `[Unreleased]` breaking-change entry.

### Key Files to Understand

Read these before starting:

- `pkg/registry/types.go` — the types being removed and the `AgentSkill` struct that survives.
- `pkg/registry/validator.go` — `ValidateSkillFull()` is the entry point; it conditionally calls `validateWorkflow()` which must go.
- `pkg/registry/server.go` — see how the `executor` field is wired and which methods depend on it.
- `internal/api/registry.go` — handlers at lines 353–541 are the workflow ones; CRUD handlers above them stay.
- `pkg/skills/scanner.go` and `fingerprint.go` — small, isolated workflow references.
- `web/src/components/registry/SkillEditor.tsx` — the only kept React file with workflow imports.
- `Makefile` — `build` chains `build-web` and `build-go`; `test` runs `go test -v ./...`.
- `examples/getting-started/skills-basic.yaml` — verified to reference no specific skills (defines an MCP server stack only).

### Integration Points (Surgical Edits Required)

#### `pkg/registry/types.go`

Delete:
- Type `SkillInput` (struct around lines 105–112)
- Type `WorkflowStep` (struct around lines 114–124)
- Type `RetryPolicy` (struct around lines 126–130)
- Type `WorkflowOutput` (struct around lines 132–137)
- Type `StringOrSlice` (lines 139–141) and its `UnmarshalYAML` method (lines 143–155)
- Method `(s *AgentSkill) IsExecutable()` (lines 54–57)
- Method `(s *AgentSkill) ToMCPTool()` (lines 64–103)
- Fields `Inputs`, `Workflow`, `Output` from `AgentSkill`

Keep:
- All other `AgentSkill` fields (`Name`, `Description`, `License`, `Compatibility`, `Metadata`, `AllowedTools`, `AcceptanceCriteria`, `State`, `Body`, `FileCount`, `Dir`)
- `(s *AgentSkill) Validate()` method (delegates to `ValidateSkill`)
- `ItemState`, `SkillFile`, `RegistryStatus`, `validateState()`

#### `pkg/registry/validator.go`

Delete:
- `validateWorkflow()` (lines 112–218)
- `validateInputTypes()` (lines 220–229)
- `validateTemplateRefs()` (lines 231–260)
- `parseAllowedTools()` (line 263) and `matchesAllowedTools()` (line 276) — orphaned after `validateWorkflow` goes
- The line in `ValidateSkillFull()` (around line 75) that calls `validateWorkflow()`

Keep:
- `ValidateSkill()`, `ValidateSkillFull()` (with the workflow call removed), `ValidateSkillName()`, `suggestFromSet()`, `sortedKeys()`

#### `pkg/registry/server.go`

Delete:
- The `executor` field on `Server`
- The `WithToolCaller()` option function
- The `Tools()` method (returns workflow-skill tools)
- The `CallTool()` method (executes workflow skills)
- Any helper that becomes dead after these go

Keep:
- The MCP server interface (the parts that expose skills as prompts, not as tools)
- `store` field and any prompt-serving methods

#### `pkg/registry/frontmatter.go`

No changes needed. YAML unmarshal silently ignores fields no longer in the struct. Verify the file still parses kept skills (`explain-error`, `code-review`) correctly during Phase E.

#### `internal/api/registry.go`

Delete:
- `handleRegistrySkillWorkflow` — `GET /api/registry/skills/{name}/workflow` (lines 353–385)
- `handleRegistrySkillExecute` — `POST /api/registry/skills/{name}/execute` (lines 389–419)
- `handleRegistrySkillValidateWorkflow` — `POST /api/registry/skills/{name}/validate-workflow` (lines 423–541)
- The route registrations for the three handlers above (find them by grepping for the handler names; routes are wired in this file or a nearby `routes.go`)

Keep:
- All CRUD handlers: `handleRegistryStatus`, `handleRegistrySkillsList`, `handleRegistrySkillCreate`, `handleRegistrySkillGet`, `handleRegistrySkillPut`, `handleRegistrySkillDelete`, `handleRegistrySkillActivate`, `handleRegistrySkillDisable`, `handleRegistrySkillFileList`, `handleRegistrySkillFileGet`, `handleRegistrySkillFilePut`, `handleRegistrySkillFileDelete`, `handleRegistryValidate`, `handleRegistrySkillTest`
- `handleRegistryValidate` — verify it does not call `validateWorkflow` or check `IsExecutable()`. If it does, remove just that call site.

#### `pkg/skills/scanner.go`

Delete:
- `scanWorkflowStep()` function
- The `for _, step := range skill.Workflow { scanWorkflowStep(...) }` loop in the scanner entry point

Keep everything else in this file (the scanner core that scans skill metadata, files, sources).

#### `pkg/skills/fingerprint.go`

Delete:
- `countWorkflowSteps()` function
- `WorkflowLen` (or similarly named) field on the fingerprint struct, and any code that assigns it
- Any comment block describing workflow-step counting

Keep the rest of fingerprinting (file hashing, manifest hashing, behavioral-change detection unrelated to workflow).

#### `*_test.go` fixture cleanup

Locate and delete (do not rewrite) test cases that depend on `WorkflowStep`, `WorkflowOutput`, or `SkillInput` literals:

- `internal/api/registry_test.go` — ~4 sites (search for `Workflow: []registry.WorkflowStep`)
- `pkg/registry/validator_test.go` — ~20 sites (most of the workflow-validation tests; expect to delete several whole test functions)
- `pkg/registry/frontmatter_test.go` — 1 site
- `pkg/registry/types_test.go` — 2 sites
- `pkg/skills/scanner_test.go` — 4 sites

If a test function's *only* purpose is testing a deleted code path, delete the whole function. Do not preserve coverage for code that no longer exists.

#### `web/src/components/registry/SkillEditor.tsx`

Delete:
- Imports of `VisualDesigner` and `WorkflowPanel` from `../workflow/...`
- Imports of `WorkflowStep`, `SkillInput`, `WorkflowOutput` from `../../types`
- The `hasWorkflow` state and the `hasWorkflowBlock(...)` calls (around lines 464, 467)
- The two component mount sites (around lines 741 and 753)
- Any tab UI or conditional rendering that only existed for the workflow editor

Keep the metadata editor, file editor, and acceptance-criteria editor portions of `SkillEditor`.

#### `web/src/types/index.ts`

Delete:
- Interface `SkillInput` (around line 384)
- Interface `WorkflowStep` (around line 392)
- Interface `WorkflowOutput` (around line 403)
- Interface `WorkflowDefinition` (around line 409)
- Interface `StepExecutionResult` (around line 419)
- Interface `ExecutionResult` (around line 431)

Keep all other types (the file is shared across the UI).

#### `docs/api-reference.md`

Delete:
- The section documenting `GET /api/registry/skills/{name}/workflow`
- The section documenting `POST /api/registry/skills/{name}/execute`
- The section documenting `POST /api/registry/skills/{name}/validate-workflow`
- Any introductory text or examples referencing DAG, WorkflowStep, the executor, or template context

Keep documentation of all other API endpoints.

### Reusable Components

None. This is removal-only.

## UX Specification

There is no end-user UX for this change beyond the disappearance of the workflow designer page in the web UI. After this change:

- The "Visual Designer" and "Workflow Panel" tabs in the skill editor are gone.
- The detached workflow page (`DetachedWorkflowPage`) is gone; any direct route to it 404s. If the route is registered separately (e.g., in a router config file), remove that registration too.
- The skill registry page lists skills as before; only the workflow-specific UI is missing.
- CLI users lose `gridctl test` and `gridctl activate` subcommands. (Deliberate; replacement lands in Brief 3.)

## Implementation Notes

### Conventions to Follow

- Commit style: `<type>: <subject>` (imperative, ≤50 chars, no period). Types: `feat`, `fix`, `docs`, `refactor`, `chore`, `perf`. For this change, use `refactor:` for code edits and `chore:` for the CHANGELOG entry. Or one combined commit with `refactor: remove yaml workflow engine` if doing it as a single commit.
- Sign every commit with `-S`. No `Co-Authored-By` trailer. No mention of Claude in commits/PRs/branches.
- The user's preferred workflow is **fork-based** for gridctl. Use `/branch-fork`, `/pr-fork`, `/reset-fork` skills if available, or follow the equivalent manual flow (sync upstream, branch off, push to origin, PR upstream).
- Build and test using `make build` (which produces `./gridctl` in repo root), not the brew-installed `gridctl`. The Makefile's `build-go` target builds the binary; use `./gridctl <command>` for verification.

### Potential Pitfalls

- **The audit's line numbers may drift.** `ValidateSkillFull` workflow call at line ~75, handlers at lines 353–541, etc. — verify by re-reading the file before editing. Treat audit line numbers as starting points, not absolutes.
- **Route registrations live separately from handlers.** Search for the handler function names to find where they're wired into the router. Common locations: `internal/api/routes.go`, `internal/api/router.go`, or inline in `internal/api/server.go`.
- **The web routing for `DetachedWorkflowPage`.** Find and remove its route registration (likely in `web/src/App.tsx` or a router config). Don't leave a dead route entry pointing at a deleted page.
- **CSS or styling files imported only by workflow components.** After deleting components, do a quick `rg "workflow"` in `web/src/` to catch orphaned imports of CSS modules or test files.
- **`internal/api/skills.go` is NOT the file with workflow handlers** despite the original brief's mention. The handlers are in `internal/api/registry.go`. Do not edit `skills.go` (it handles git remote/source CRUD).
- **Don't delete `proto/skills/`.** It's a generic CRUD/metadata test harness, not workflow-specific.
- **Don't delete `cmd/gridctl/skill.go`'s `try` subcommand.** It uses `pkg/skills.Importer`, not the executor. The brief's "drop only if it depends on the executor" check is satisfied — keep it.
- **Build cache.** If a deletion seems to leave behind compile errors that don't make sense, run `go clean -cache` and rebuild.

### Suggested Build Order

Same as Architecture Guidance phases A–I. To recap as a checklist:

- [ ] Phase A: Edit call sites in `validator.go`, `server.go`, `internal/api/registry.go`, `pkg/skills/scanner.go`, `pkg/skills/fingerprint.go`. Remove route registrations for the three deleted handlers.
- [ ] Phase B: Delete `*_test.go` fixtures that use workflow types.
- [ ] Phase C: Delete standalone Go files (executor, dag, template, tester, test, activate, integration test).
- [ ] Phase D: Remove types and methods from `pkg/registry/types.go`.
- [ ] Phase E: `make build` — fix any remaining Go errors. Remove dead helpers in kept files.
- [ ] Phase F: Delete web workflow components, store, hooks, lib helpers, and the detached page. Edit `SkillEditor.tsx`. Remove workflow types from `web/src/types/index.ts`. Remove route registration for the detached page. Run `make build-web` (or `npm run build` from `web/`) and fix TS errors.
- [ ] Phase G: Delete workflow example directories and remove workflow API sections from `docs/api-reference.md`.
- [ ] Phase H: Verify acceptance criteria (see below).
- [ ] Phase I: Add CHANGELOG `[Unreleased]` entry.

## Acceptance Criteria

Run all of the following from the repo root after the work is done. Every one must pass.

1. **Build succeeds:**
   ```bash
   make build
   ```
   Produces `./gridctl` with no compilation errors.

2. **Tests pass:**
   ```bash
   make test
   ```
   All Go tests pass (`go test -v ./...`).

3. **Web build succeeds:**
   ```bash
   make build-web
   ```
   No TypeScript errors.

4. **Apply works against a stack:**
   ```bash
   ./gridctl apply examples/getting-started/skills-basic.yaml
   ```
   Applies successfully. Skills present in the registry are exposed as prompts.

5. **Skill list works:**
   ```bash
   ./gridctl skill list
   ```
   Shows `explain-error` and `code-review` (the two surviving prompt-only examples). If the list is empty, something went wrong with the registry store — investigate before claiming done.

6. **Link works:**
   ```bash
   ./gridctl link claude
   ```
   Wires Claude Desktop to the gateway without errors. (Skip executing this if it would mutate the user's actual `~/Library/Application Support/Claude/` config — verify the command flow loads without erroring instead.)

7. **Grep returns zero results:**
   ```bash
   rg "WorkflowStep|BuildWorkflowDAG|registry.Executor|TemplateContext" pkg/ cmd/ internal/ web/
   ```
   Must produce no output.

8. **Spot-check no orphaned imports:**
   ```bash
   rg "from .*workflow" web/src/
   rg "import.*workflow" web/src/
   ```
   Should return zero results except for any kept workflow-unrelated matches (unlikely; expect empty).

9. **CHANGELOG entry exists** under `[Unreleased]` describing the removal as a breaking change. Suggested entry:
   ```markdown
   ### Breaking Changes

   - Removed the YAML-driven skill workflow engine. The `workflow:` block in
     `SKILL.md`, the workflow visual designer, the `gridctl test` and
     `gridctl activate` subcommands, and the `/workflow`, `/execute`, and
     `/validate-workflow` registry API endpoints are no longer supported.
     Skill manifests, the registry store, the MCP gateway, the Code Mode
     sandbox, and remote skill import are unaffected. A code-first agent
     runtime replaces the YAML engine in a follow-up release.
   ```

10. **Diff sanity check:** `git diff --stat` should show roughly: ~15–20 Go files deleted, ~5–8 Go files modified, ~12–15 TypeScript files deleted, ~2–3 TypeScript files modified, ~6 example directories deleted, 1 doc file modified, 1 CHANGELOG modified. If the shape of the diff is dramatically different (e.g., hundreds of unrelated files touched), stop and re-check scope.

## References

- Evaluation: `prompts/gridctl/remove-workflow-engine/feature-evaluation.md`
- gridctl repo: `/Users/william/code/gridctl`
- Brief 3 (referenced but not in scope here): introduces the code-first agent runtime that replaces this engine
- gridctl Makefile: `build`, `build-go`, `build-web`, `test` targets
- Workflow handlers (to delete): `internal/api/registry.go` lines 353–541
- Workflow types (to delete): `pkg/registry/types.go` lines 54–155
- Workflow validator (to delete): `pkg/registry/validator.go` lines 112–290
- Server executor coupling (to delete): `pkg/registry/server.go` `executor` field, `Tools()`, `CallTool()`, `WithToolCaller()`
