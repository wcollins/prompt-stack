# Feature Implementation: SDD Governance Layer

## Context

gridctl is an MCP (Model Context Protocol) orchestration platform — "Containerlab for AI Agents." It aggregates tools from multiple MCP servers (Docker containers, local processes, SSH tunnels, external HTTP) into a single unified gateway endpoint. The project is built in Go (cobra CLI + net/http API server) with a React 19 + Zustand + TailwindCSS frontend.

**Key files for orientation:**
- `/Users/william/code/gridctl/AGENTS.md` — comprehensive architectural reference
- `/Users/william/code/gridctl/pkg/registry/types.go` — AgentSkill struct (agentskills.io spec + gridctl extensions)
- `/Users/william/code/gridctl/pkg/registry/validate.go` — ValidateSkill() function
- `/Users/william/code/gridctl/cmd/gridctl/skill.go` — skill CLI commands
- `/Users/william/code/gridctl/.github/workflows/gatekeeper.yaml` — CI pipeline

## Evaluation Context

This prompt implements the four "meaningful gaps" identified in EVAL.md (created 2026-03-23) after a deep analysis of gridctl against Gartner G00846981 ("Assessing Spec-Driven Development for Agentic Coding", March 2026) and the GitHub spec-kit constitutional framework.

Key findings that shaped this prompt:
- Gartner explicitly names `AGENT.md`, `SKILL.md`, and `constitution.md` as spec gardening artifacts. AGENTS.md exists; CONSTITUTION.md does not.
- 71% of engineers use AI agents always/usually (Gartner 2026 survey). Governance artifacts are now load-bearing infrastructure.
- gridctl already has `gridctl validate` with exit-code support — the CI integration gap is wiring, not building.
- The agentskills.io spec has no acceptance criteria field. This is a gridctl extension opportunity — scope it as documentation-only (YAML strings), not an executable test harness.

Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/sdd-governance-layer/feature-evaluation.md`

**Related evaluation (DO NOT overlap with):** `/Users/william/code/prompt-stack/prompts/gridctl/spec-driven-development/feature-evaluation.md` covers user-facing SDD features (plan command improvements, visual wizard, skill dependency management). This prompt is about gridctl's *own* development practices.

## Feature Description

Close three governance gaps that prevent gridctl from practicing the SDD standards it enables for users:

1. **CONSTITUTION.md** — An immutable governance document at the repo root containing ≤15 articles that cannot be overridden by any prompt or contributor. Distinct from AGENTS.md (mutable architectural reference).

2. **Skill acceptance criteria** — A new `acceptance_criteria` frontmatter field on AgentSkill (gridctl extension to agentskills.io spec). Stored as `[]string` of human-readable Given/When/Then scenarios. Surfaced in `gridctl skill info` and checked during `gridctl skill validate` (warning for executable skills with no criteria, not an error).

3. **CI validate gate** — A new step in `.github/workflows/gatekeeper.yaml` that runs `gridctl validate` against example stack YAML files in the repo, failing the pipeline on invalid configs.

> **Note on feature spec artifacts (removed from scope):** In infrastructure and developer tooling, "spec" has an established technical meaning — protocol specs (MCP spec), provider schemas (Terraform, Kubernetes CRDs), format specs (agentskills.io). A `specs/` directory would clash with that convention. Pre-implementation design documents for gridctl development belong in GitHub Issues and PRs, which is already the practice. No new directory is needed.

## Requirements

### Functional Requirements

1. `CONSTITUTION.md` MUST exist at the repo root and contain immutable project articles covering: library-first architecture, test-first development, no mocks in integration tests, semantic versioning stability guarantees, CLI output machine-parseability, and stack YAML backward compatibility.

2. `CONSTITUTION.md` MUST be clearly distinguished from `AGENTS.md` — its header and introduction MUST state that its articles are non-negotiable and not subject to per-feature override.

3. `CONSTITUTION.md` MUST contain no more than 15 articles. Each article MUST have: an identifier (Article I, Article II, etc.), a short title, and a brief rationale.

4. The `AgentSkill` struct in `pkg/registry/types.go` MUST have a new `AcceptanceCriteria []string` field tagged `yaml:"acceptance_criteria,omitempty" json:"acceptanceCriteria,omitempty"`.

5. `gridctl skill info <name>` MUST display acceptance criteria if present, formatted as a numbered list under an "Acceptance Criteria" heading in the CLI output.

6. `gridctl skill validate` MUST emit a warning (not an error, exit code 0) for executable skills (`IsExecutable() == true`) that have no acceptance criteria defined.

7. The gatekeeper CI pipeline MUST include a new step that runs `gridctl validate` against all `*.yaml` files in any `examples/` directory (or equivalent) in the repo. The step MUST fail the pipeline (not `continue-on-error`) if validation returns a non-zero exit code.

8. If no example stack YAML files exist in the repo, the CI step MUST still be added with a clear comment indicating where to add examples, and MUST succeed vacuously (no files to validate = pass).

### Non-Functional Requirements

- All markdown files MUST follow the existing formatting conventions in AGENTS.md (headers, code blocks, table style).
- The `acceptance_criteria` field is a gridctl extension. It MUST be documented as an extension in the field's source comment, referencing the agentskills.io spec URL.
- The `AcceptanceCriteria` field MUST be backwards compatible — skills without the field parse and function identically to current behavior.
- The CI validate step MUST complete in under 60 seconds. If gridctl is not installed in CI, use `go run ./cmd/gridctl validate` instead.

### Out of Scope

- Do NOT build an executable test runner for acceptance criteria. The `[]string` field is documentation-only in this pass.
- Do NOT make acceptance criteria a hard requirement (error) for publishing skills — only a warning.
- Do NOT create a `specs/` directory — in infrastructure tooling this term refers to protocol/provider specifications (MCP spec, agentskills.io spec, Terraform schemas). Pre-implementation design docs belong in GitHub Issues/PRs.
- Do NOT modify AGENTS.md — the constitution supplements it; it does not replace it.
- Do NOT add CONSTITUTION.md validation to the CI pipeline in this pass.

## Architecture Guidance

### Recommended Approach

All three changes are additive. Work in this order — each item is independently mergeable:

1. CONSTITUTION.md (pure markdown, zero code risk)
2. Acceptance criteria field (small Go struct change, additive)
3. CI gate (CI YAML change, test locally first)

### Key Files to Understand

1. **`AGENTS.md`** — Read the full document to understand the existing governance model and what belongs in CONSTITUTION.md vs what stays in AGENTS.md.
2. **`pkg/registry/types.go`** — The `AgentSkill` struct and existing gridctl extension fields. Follow the `ItemState` pattern for adding new extension fields.
3. **`pkg/registry/validate.go`** — `ValidateSkill()` function. Acceptance criteria warning hooks here.
4. **`cmd/gridctl/skill.go`** — The `skill info` output format. Acceptance criteria display goes here.
5. **`.github/workflows/gatekeeper.yaml`** — CI pipeline. Study the Go vulnerability check step as a model for adding the validate step (similar pattern: install tool if needed, run against target, check exit code).
6. **`pkg/registry/types.go` lines 22-58** — `AgentSkill` struct definition. The new field goes after `AllowedTools` in the frontmatter section, before the gridctl extensions section.

### Integration Points

**For acceptance criteria field (`pkg/registry/types.go`):**
```go
// AcceptanceCriteria documents expected skill behavior as human-readable
// Given/When/Then scenarios. Gridctl extension; not part of agentskills.io spec.
// See https://agentskills.io/specification
AcceptanceCriteria []string `yaml:"acceptance_criteria,omitempty" json:"acceptanceCriteria,omitempty"`
```

Add in the frontmatter fields section, after `AllowedTools`.

**For validate warning (`pkg/registry/validate.go`):**
Find `ValidateSkill()`. After structural validation passes, add:
```go
if len(skill.Workflow) > 0 && len(skill.AcceptanceCriteria) == 0 {
    // Return as a warning, not an error. Use a dedicated warning type if one exists,
    // or append to a warnings []string and print separately from errors.
}
```
Check how the existing validate output is structured before choosing the warning pattern.

**For `skill info` display (`cmd/gridctl/skill.go`):**
Find the `info` subcommand output section. After existing fields, add:
```go
if len(skill.AcceptanceCriteria) > 0 {
    fmt.Fprintln(cmd.OutOrStdout(), "\nAcceptance Criteria:")
    for i, c := range skill.AcceptanceCriteria {
        fmt.Fprintf(cmd.OutOrStdout(), "  %d. %s\n", i+1, c)
    }
}
```

**For CI gate (`.github/workflows/gatekeeper.yaml`):**
Add after the `Build Go binary` step in the `test` job:
```yaml
- name: Validate example stacks
  run: |
    if ls examples/*.yaml 1>/dev/null 2>&1; then
      for f in examples/*.yaml; do
        echo "Validating $f..."
        go run ./cmd/gridctl validate "$f"
      done
    else
      echo "No example stacks found, skipping validation"
    fi
```
Adjust the glob pattern to match where example stacks actually live in the repo.

### Reusable Components

- Follow the `ItemState` field pattern in `AgentSkill` for the new `AcceptanceCriteria` extension field
- Follow the `govulncheck` step in gatekeeper.yaml as the CI template — similar "install if not present, run against target" pattern
- AGENTS.md section formatting as the canonical document style for CONSTITUTION.md

## UX Specification

**CONSTITUTION.md discovery:** Placed at repo root alongside AGENTS.md. AI coding sessions automatically read root-level markdown files. No special tooling needed.

**Acceptance criteria in `skill info`:**
```
$ gridctl skill info git-workflow/branch-fork

Name:        branch-fork
Description: Sync with upstream, create feature branch, make changes
State:       active
License:     MIT

Acceptance Criteria:
  1. Given a clean main branch, When I run the skill, Then a new feature branch is created
  2. Given upstream has new commits, When I run the skill, Then the branch is synced before creation
```

**Acceptance criteria warning in `skill validate`:**
```
$ gridctl skill validate my-skill

⚠  my-skill: executable skill has no acceptance criteria defined
   Add acceptance_criteria: [...] to the skill frontmatter to document expected behavior
```

**CI gate output (success):**
```
Validate example stacks
  Validating examples/basic-stack.yaml... ✓
  Validating examples/multi-agent.yaml... ✓
```

## Implementation Notes

### Conventions to Follow

- Commit format: `<type>: <subject>` — use `docs:` for markdown files, `feat:` for Go struct changes, `ci:` for gatekeeper changes
- Go: follow existing `slog` logging patterns; no `fmt.Println` in library code, only in CLI output
- Markdown: match the AGENTS.md header hierarchy and table format exactly
- YAML tags: follow the `yaml:"name,omitempty" json:"name,omitempty"` pattern in `AgentSkill`

### Potential Pitfalls

- **CONSTITUTION.md tone**: Must be authoritative ("MUST", "MUST NOT") not advisory ("should", "consider"). If it sounds like AGENTS.md guidance, it's not constitutional enough.
- **Backwards compatibility**: The `acceptance_criteria` YAML field is `omitempty`. Existing skills without the field must parse and function identically — test this explicitly.
- **CI validate requires the binary**: If `gridctl` is not installed in the CI runner, use `go run ./cmd/gridctl`. Confirm which approach works in the Ubuntu runner environment used in gatekeeper.yaml.
- **Example YAML files**: Check whether example stacks exist in the repo before writing the CI glob. If they're in `docs/`, `examples/`, or inline in README, adjust accordingly. Running `find . -name "stack.yaml" -not -path "*/testdata/*"` is a good discovery step.
- **Article count**: Keep CONSTITUTION.md to ≤15 articles. The temptation is to be comprehensive. Each article should be a hard boundary, not a preference.

### Suggested Build Order

1. Read AGENTS.md in full, then draft CONSTITUTION.md. Review for tone — each article should be non-negotiable.
2. Update AGENTS.md to reference CONSTITUTION.md (one sentence, no significant edits).
3. Add `AcceptanceCriteria []string` to `AgentSkill` in `pkg/registry/types.go`.
4. Add the warning to `ValidateSkill()` in `pkg/registry/validate.go`.
5. Update `skill info` in `cmd/gridctl/skill.go` to display acceptance criteria.
6. Find all example stack YAML files in the repo (`find . -name "stack.yaml" -not -path "*/testdata/*"`).
7. Add the CI validate step to `.github/workflows/gatekeeper.yaml`.
8. Run `go build ./...` and `go test ./pkg/registry/...` to confirm no regressions.

## Acceptance Criteria

1. `CONSTITUTION.md` exists at the repo root, contains 5-15 articles, each with an identifier and rationale, and uses MUST/MUST NOT language throughout.
2. `CONSTITUTION.md` is clearly distinguished from AGENTS.md — its introduction explicitly states articles are immutable and not overridable.
3. `AgentSkill.AcceptanceCriteria` field exists in `pkg/registry/types.go` with correct YAML/JSON tags and a source comment referencing agentskills.io.
4. `gridctl skill info <name>` displays acceptance criteria for skills that have them; displays nothing extra for skills that don't.
5. `gridctl skill validate <name>` emits a warning (not an error) for executable skills with no acceptance criteria; returns exit code 0 in all cases.
6. Existing skills without `acceptance_criteria` in their frontmatter parse and validate without errors.
7. `.github/workflows/gatekeeper.yaml` contains a "Validate example stacks" step that runs `gridctl validate` (or `go run ./cmd/gridctl validate`) against example YAML files.
8. The CI validate step fails the pipeline (non-zero exit) when an example stack YAML is invalid.
9. All changes pass `go test -race ./...` and `golangci-lint run`.

## References

- Gartner G00846981: *Assessing Spec-Driven Development for Agentic Coding* — Erin Khoo, March 2026 (`/Users/william/code/gridctl/doc.pdf`)
- gridctl EVAL.md — `/Users/william/code/gridctl/EVAL.md`
- Feature evaluation — `/Users/william/code/prompt-stack/prompts/gridctl/sdd-governance-layer/feature-evaluation.md`
- GitHub spec-kit constitutional framework: https://github.com/github/spec-kit
- agentskills.io specification: https://agentskills.io/specification
- Gartner spec gardening guidance: AGENT.md, SKILL.md, constitution.md as spec artifact standards
