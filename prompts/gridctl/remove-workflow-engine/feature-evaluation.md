# Feature Evaluation: Remove YAML Workflow Engine

**Date**: 2026-05-08
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

Delete the YAML-driven skill workflow engine in `pkg/registry/` (DAG, executor, template, tester) along with its UI designer, examples, integration tests, and API handlers — making a clean cut before Brief 3 introduces a code-first agent runtime. The audit confirms the user's deletion list is mostly accurate but surfaced three corrections and several pieces of "kept" code that need surgical edits to stay compilable. With those corrections folded in, the work is a deterministic, well-scoped removal worth doing now rather than carrying dead code through the transition.

## The Idea

Remove the "skills are YAML DAGs you author by hand or in a form-builder" idea while preserving the "skills are versioned, importable units of behavior with metadata" idea. SKILL.md as a manifest survives; the `workflow:` block inside it does not. The MCP gateway, Code Mode sandbox, and remote-skill-import infrastructure (the project's strongest assets) stay intact.

## Project Context

### Current State

gridctl is a Go CLI plus React web UI that orchestrates MCP servers, with a registry layer for skill management. The workflow engine is a tightly bounded subsystem (`pkg/registry/dag.go`, `executor.go`, `template.go`, `tester.go`) plus a frontend designer (`web/src/components/workflow/`) and a small set of API handlers and CLI subcommands. It is not a load-bearing dependency of the gateway, the Code Mode sandbox, or the import/lockfile infrastructure.

### Integration Surface

**Pure-deletion files (verified to exist, no surgery needed beyond removal):**

- `pkg/registry/dag.go`, `dag_test.go`
- `pkg/registry/executor.go`, `executor_test.go`
- `pkg/registry/template.go`, `template_test.go`
- `pkg/registry/tester.go`, `tester_test.go`
- `cmd/gridctl/test.go`, `test_test.go`
- `cmd/gridctl/activate.go`, `activate_test.go`
- `tests/integration/skills_executor_test.go`
- `web/src/components/workflow/` (all 10 components)
- `web/src/pages/DetachedWorkflowPage.tsx`
- `web/src/stores/useWorkflowStore.ts`
- `web/src/lib/workflowSync.ts`
- `web/src/hooks/useWorkflowKeyboardShortcuts.ts`
- `web/src/hooks/useWorkflowFontSize.ts`
- `examples/registry/items/{workflow-basic,workflow-conditional,workflow-parallel,chained-calculation,add-and-echo,echo-and-time}/`

**Files requiring surgical edits (kept, but contain workflow coupling):**

- `pkg/registry/types.go` — remove `WorkflowStep`, `WorkflowOutput`, `RetryPolicy`, `SkillInput`, `StringOrSlice`, `IsExecutable()`, `ToMCPTool()`, the `Inputs/Workflow/Output` fields on `AgentSkill`, and the orphaned `StringOrSlice.UnmarshalYAML()` helper.
- `pkg/registry/validator.go` — remove `validateWorkflow`, `validateInputTypes`, `validateTemplateRefs`, `parseAllowedTools`, `matchesAllowedTools`; remove the line in `ValidateSkillFull` that calls them.
- `pkg/registry/server.go` — remove the `executor` field, `WithToolCaller()` option, and the `Tools()` and `CallTool()` methods (entirely workflow-execution, despite living in a "kept" file).
- `pkg/registry/frontmatter.go` — keep parsing as-is. After type fields are removed, YAML unmarshaling silently ignores them. No code change needed in this file.
- `internal/api/registry.go` — delete three handlers: `handleRegistrySkillWorkflow`, `handleRegistrySkillExecute`, `handleRegistrySkillValidateWorkflow` (lines 353–541), plus their route registrations. **Note:** the original brief said `internal/api/skills.go`, but the workflow handlers actually live here; `internal/api/skills.go` stays untouched.
- `pkg/skills/scanner.go` — remove `scanWorkflowStep()` and the `for _, step := range skill.Workflow` loop. (The brief said "do not touch `pkg/skills/*`" but these references make that impossible once the type is gone. User confirmed surgical edits here are aligned with intent.)
- `pkg/skills/fingerprint.go` — remove `countWorkflowSteps()` and any `WorkflowLen` field on the fingerprint struct.
- `web/src/components/registry/SkillEditor.tsx` — remove imports of `VisualDesigner` and `WorkflowPanel`, the `hasWorkflowBlock()` state, and the two mount sites (lines ~741, ~753).
- `web/src/types/index.ts` — remove `SkillInput`, `WorkflowStep`, `WorkflowOutput`, `WorkflowDefinition`, `StepExecutionResult`, `ExecutionResult`.
- `docs/api-reference.md` — remove the workflow API sections (10 mentions; `GET .../workflow`, `POST .../execute`, `POST .../validate-workflow`).
- `*_test.go` fixtures referencing `WorkflowStep`: `internal/api/registry_test.go` (4 sites), `pkg/registry/validator_test.go` (~20 sites), `pkg/registry/frontmatter_test.go` (1 site), `pkg/registry/types_test.go` (2 sites), `pkg/skills/scanner_test.go` (4 sites). Delete the test cases (or whole test functions) that depend on workflow types — do not rewrite. Aligned with the brief's existing guidance: "delete those tests rather than rewrite them."

### Brief Corrections

Three items in the original brief were inaccurate; the implementation prompt corrects them:

1. **`internal/api/skills.go` does not contain workflow handlers.** Workflow handlers are in `internal/api/registry.go`. `skills.go` is purely about skill *sources* (git remotes, lockfile updates) and stays untouched.
2. **`proto/skills/` is not a workflow harness.** It tests skill metadata CRUD, source management, and the editor UI (sidebar, save/revert, import wizard, CLI `skill list`/`add`/`update`). It contains zero workflow content. Keep it.
3. **`pkg/skills/*` "do not touch" cannot be absolute.** `scanner.go` and `fingerprint.go` reference `WorkflowStep` and would fail to compile without surgical edits. The rest of `pkg/skills` (importer, lockfile, origin tracking, scanner core, fingerprint core) stays untouched.

### Reusable Components

Nothing reusable from the deleted code. The kept surfaces (`store.go`, `server.go` minus executor, frontmatter parsing, metadata validation) become the foundation for whatever Brief 3 introduces.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Carrying the workflow engine through the Brief 3 transition would mean every PR has to consider two execution models. Cutting now buys clarity. |
| User impact | Narrow + Shallow | Workflow YAML authors (an internal/early-adopter audience) lose the feature. The MCP gateway, Code Mode, and skill import — the actual user-facing surface — are untouched. |
| Strategic alignment | Core mission | Aligned with stated direction (code-first agent runtime). The brief explicitly calls this a clean cut for Brief 3. |
| Market positioning | Maintain | Not a competitive feature. Removing it has no positioning impact; the gateway and Code Mode are the differentiators. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | More surgical edits than the brief implied (3 corrections + the audit found ~10 more "kept" files needing edits), but each one is small and isolated. No architectural restructuring. |
| Effort estimate | Medium | Roughly 25–35 file touches across Go, TypeScript, examples, and docs. Deterministic; no design decisions. |
| Risk level | Low | Compilation will surface anything missed. Acceptance criteria (`make build`, `make test`, `gridctl apply`, `gridctl skill list`, `gridctl link claude`) cover the surviving surface end-to-end. The grep targets in the brief are a strong correctness gate. |
| Maintenance burden | Negative (reduces it) | Removing the workflow engine reduces ongoing test surface, doc maintenance, and review cognitive load. |

## Recommendation

**Build.** This is a low-risk, high-clarity removal that aligns with the project's stated direction. The deletion list in the brief is mostly accurate; the audit surfaced three corrections and a roster of "kept-but-coupled" files that the implementation prompt addresses head-on. The acceptance criteria are sound once those corrections are folded in.

Two specific guard-rails the implementation prompt enforces:

1. **Order of operations matters.** Edit the call sites in kept files *before* deleting the types they reference, so the build stays close to compilable through the change. The prompt prescribes the order.
2. **Examples will be thin after deletion.** Only `explain-error` and `code-review` survive in `examples/registry/items/`. The prompt instructs the agent to verify `gridctl skill list` still produces a non-empty result against those two and to flag if it doesn't.

## References

- Brief 3 (referenced but not provided): drives the timing of this removal
- gridctl CHANGELOG.md `[Unreleased]` section: the new entry will record this as a breaking change
- `examples/getting-started/skills-basic.yaml`: validated to reference no specific skills (defines an MCP server stack only), so apply-time behavior is unaffected
