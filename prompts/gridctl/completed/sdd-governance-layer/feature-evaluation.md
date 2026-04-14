# Feature Evaluation: SDD Governance Layer

**Date**: 2026-03-23
**Project**: gridctl
**Recommendation**: Build
**Value**: Medium
**Effort**: Small

## Summary

Four targeted additions that close the gap between gridctl's own development practices and the SDD standards it enables for users. These are internal governance improvements — not user-facing features — and all four can be implemented in a single focused session. The changes are additive, low-risk, and high-signal: a CONSTITUTION.md, a feature spec template, acceptance criteria on skills, and a CI validation gate.

## The Idea

The EVAL.md (created 2026-03-23) identified four meaningful gaps between gridctl's current practice and SDD best practices per Gartner G00846981 and GitHub spec-kit:

1. **No CONSTITUTION.md** — AGENTS.md is mutable guidance, not immutable governance. No formal boundary exists between "this is a rule" and "this is advice."
2. **Skills lack acceptance criteria** — Skills in the registry are trust-based. No Given/When/Then scenarios document expected behavior; no validation gate exists before publishing.
3. **CI/CD validate not wired** — `gridctl validate` exists with exit-code support, but is not invoked in `gatekeeper.yaml` against repo example stacks.

> **On "feature spec artifacts" (originally Gap 2, removed):** In infrastructure and developer tooling, "spec" refers to protocol/provider specifications — MCP spec, agentskills.io spec, Terraform provider schemas, Kubernetes CRDs. A `specs/` directory would collide with that established meaning. Pre-implementation design work in gridctl already lives in GitHub Issues and PRs, which is the right place for it. No new directory is warranted.

**Note**: This evaluation is about gridctl's *own development practices*, not user-facing features. The existing `spec-driven-development` evaluation (2026-03-12) covers the user-facing SDD tooling (validate command improvements, plan command, visual wizard, skill dependency management). These gaps are complementary — internal alignment to practice what the product enables.

## Project Context

### Current State

gridctl is a mature MCP orchestration platform (Go backend + React frontend, 75 Go test files, 232 TypeScript tests). It has:
- A comprehensive `AGENTS.md` (architectural reference, evolvable)
- A `CLAUDE.md` (workflow conventions in ~/.claude/)
- A `gatekeeper.yaml` CI pipeline (lint, test, integration, build, coverage gates, Podman matrix)
- A Skills system (`pkg/registry/`) implementing the agentskills.io spec with `Validate()` on `AgentSkill`
- An existing `gridctl validate` CLI command with exit-code support

### Integration Surface

| Gap | Files Touched |
|-----|--------------|
| CONSTITUTION.md | New file: `CONSTITUTION.md` at repo root |
| Spec template | New directory: `specs/TEMPLATE/` with `spec.md`, `plan.md`, `tasks.md` |
| Skills acceptance criteria | `pkg/registry/types.go` (new field), `pkg/registry/validate.go` (display in errors), `cmd/gridctl/skill.go` (show in `skill info`) |
| CI validate gate | `.github/workflows/gatekeeper.yaml` (new step) + any `examples/` or `docs/` stack YAML files |

### Reusable Components

- `AgentSkill.Validate()` / `ValidateSkill()` in `pkg/registry/` — already does structural validation; acceptance criteria display can hook here
- `ItemState` pattern — gridctl already extends agentskills.io spec; `acceptance_criteria` follows that precedent
- Existing gatekeeper CI patterns — vulnerability check step as a model for adding validate step with `continue-on-error: false`
- AGENTS.md as model document — CONSTITUTION.md adopts the same format but marks rules as immutable

## Market Analysis

### Competitive Landscape

- **GitHub spec-kit**: Nine-article constitutional framework is immutable and explicitly non-negotiable. The Gartner doc calls this out as the reference implementation.
- **Amazon Kiro**: "Steering" files serve a similar function — separated from implementation guidance, focused on agent behavior constraints.
- **Anthropic**: Model constitution concept is the origin of the pattern — rules the model cannot override.
- **Cursor / Windsurf**: `.cursorrules` / `.windsurfrules` — project-level immutable rule files are standard in AI-native tooling.

Every mature SDD tool separates immutable constitutional rules from mutable guidance. Gridctl conflates both in a single mutable AGENTS.md.

### Market Positioning

This is internal governance — not a visible feature. Market positioning is irrelevant. What matters: **credibility alignment**. A tool that enables SDD for users but doesn't practice it internally has a coherence gap. The Gartner doc (March 2026) cites spec-kit and gridctl's AGENTS.md explicitly — the bar is now public.

### Demand Signals

- Gartner March 2026 survey: 71% of engineers use AI agents usually or always. Governance artifacts are no longer optional.
- Gartner explicitly names `AGENT.md`, `SKILL.md`, and `constitution.md` as spec gardening best practices.
- spec-kit's constitutional framework is cited as a reference implementation in a Gartner analyst note.

## User Experience

These changes affect contributors and AI coding sessions, not end users.

**CONSTITUTION.md**: AI agents starting a coding session in gridctl read AGENTS.md + CLAUDE.md. A CONSTITUTION.md at repo root creates a hard stop: "these rules cannot be overridden, no matter what the prompt says." This directly prevents assumption traps and contextual drift — both risks named in the Gartner doc.

**Spec template**: Contributors using `/feature-dev` or `/feature-scout` currently have no canonical place to put pre-implementation specs. Adding `specs/TEMPLATE/` gives a clear home. Can be referenced from CONTRIBUTING.md.

**Skill acceptance criteria**: Surfaced in `gridctl skill info <name>` as human-readable scenarios. During `gridctl skill validate`, missing acceptance criteria for executable skills generates a warning (not an error — backwards compatible). No behavioral change to skill execution.

**CI validate gate**: Invisible to end users. PR authors see a new gatekeeper step. Catches regressions in example `stack.yaml` files that currently have no automated validation.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Without governance boundaries, AI drift compounds as the codebase grows with AI-assisted development |
| User impact | Narrow + Deep | Contributors and AI sessions only; no end-user impact — but deep impact on code quality over time |
| Strategic alignment | Core mission | "Eat your own cooking" — gridctl enables SDD; practicing it internally validates the approach |
| Market positioning | Maintain | Internal practice, not visible externally; prevents credibility erosion |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Three items are markdown; one is a 5-line CI YAML addition |
| Effort estimate | Small | CONSTITUTION.md + spec template: 1-2h; acceptance_criteria field: 2-3h; CI gate: 30min |
| Risk level | Low | No runtime behavioral changes; purely additive; backwards compatible |
| Maintenance burden | Minimal | Constitution is immutable by design; template requires no maintenance |

## Recommendation

**Build.** This is the highest value-to-effort ratio in the EVAL.md gap list. All four gaps close in a single session. No user-facing risk. The recommendation is to treat these as documentation infrastructure — not a feature — and ship them as a single PR.

**Scope boundaries (critical):**
- `acceptance_criteria` is stored as a YAML `[]string` array in skill frontmatter — human-readable Given/When/Then scenarios. It is **not** an executable test harness. A test runner is a separate, future feature.
- The CI validate gate runs `gridctl validate` against `examples/` stack YAML files only. It does not validate arbitrary user stacks or require Docker to be running.
- CONSTITUTION.md contains ≤15 articles. It does not replace AGENTS.md — it supplements it with the immutable layer.
- The spec template is a contributor tool, not a required gate. No PR policy enforcement in this pass.

**Relationship to existing `spec-driven-development` evaluation:**
That evaluation (Build, Very Large) covers user-facing features that will take months to deliver in phases. This evaluation covers the governance foundation that should exist *before* those features are built — it's a prerequisite, not a follow-on.

## References

- Gartner G00846981: *Assessing Spec-Driven Development for Agentic Coding* — Erin Khoo, March 2026
- GitHub spec-kit: https://github.com/github/spec-kit
- gridctl EVAL.md — /Users/william/code/gridctl/EVAL.md (created 2026-03-23)
- Existing spec-driven-development evaluation — /Users/william/code/prompt-stack/prompts/gridctl/spec-driven-development/feature-evaluation.md
- agentskills.io specification: https://agentskills.io/specification
- Gartner spec gardening guidance: "AGENT.md, SKILL.md, constitution.md" as spec artifact standards
