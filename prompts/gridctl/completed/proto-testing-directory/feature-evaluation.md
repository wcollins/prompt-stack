# Feature Evaluation: Proto Testing Directory

**Date**: 2026-04-11
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

Create a gitignored `proto/` directory at the project root containing one folder per major testable feature of gridctl. A root `run.sh` dispatcher automates CLI-testable features; UI feature folders get step-by-step `TEST.md` manual test instructions. This fills a real gap — today there is no single place to smoke-test the full feature surface before or after a release.

## The Idea

A personal, version-control-excluded testing workspace that organizes smoke tests for every user-facing feature of gridctl. CLI-testable features get a shell script that deploys, exercises, and cleans up. UI features get a `TEST.md` with explicit numbered click-by-click instructions. A top-level `run.sh` lets you invoke all tests or a specific domain with a single command. Not to be documented in AGENTS.md — purely personal.

## Project Context

### Current State

gridctl is a Go + React MCP orchestration gateway with a substantial and growing feature surface: ~39 CLI commands and ~35 UI panels/components. It has solid unit test coverage (64% minimum enforced in CI), integration tests for runtime/transport, and a frontend Vitest suite — but no comprehensive manual smoke test coverage for the full CLI + UI surface as a user would experience it.

A `plan/` directory already exists (gitignored) with 9 PR-specific smoke test scripts covering features from PRs #229–#255. That directory validated the pattern but is PR-organized (not feature-organized), incomplete, and has no top-level dispatcher.

### Integration Surface

- `proto/` lives at the repo root, gitignored — zero impact on source
- Scripts invoke the locally built `./gridctl` binary
- UI tests reference `http://localhost:8180`
- Fixtures are standalone YAML stacks in `proto/<feature>/`
- Mock servers are started via the existing `plan/ensure-mock-servers.sh`

### Reusable Components

- `plan/ensure-mock-servers.sh` — builds and starts mock MCP servers; proto scripts should source it
- `plan/*.yaml` — 12 existing YAML fixtures reusable as-is or adapted
- `plan/run-*.sh` pattern — deploy → exercise → print manual steps → wait → cleanup; already proven ergonomic
- `examples/` directory — 15 categorized example stacks usable as proto fixtures

## Market Analysis

### Competitive Landscape

Comparable CLI + UI tools (kubectl, helm, Docker CLI, HashiCorp vault/terraform) consistently use a `scripts/` or `hack/` directory with per-feature test scripts and a dispatcher. Feature-organized structures scale better than PR-organized ones for long-lived projects.

### Market Positioning

Table-stakes for any actively developed tool with both a CLI and a UI surface. The pattern is well-established; there's nothing novel to invent here.

### Ecosystem Support

No external libraries needed. Bash scripts + YAML fixtures are sufficient. The existing `make build` + `./gridctl` workflow is the right foundation.

### Demand Signals

The existence and active use of `plan/` demonstrates real demand. Scripts in that directory have been added alongside every major PR batch since March 2026.

## User Experience

### Interaction Model

```
proto/
├── run.sh                    # Top-level dispatcher
├── stack/                    # apply, destroy, status, plan, validate, reload, export
│   ├── test.sh
│   ├── stack-basic.yaml
│   └── TEST.md               # UI: Spec tab, drift overlay, wizard
├── vault/                    # set, get, list, delete, import, export, lock, unlock, sets
│   ├── test.sh
│   └── TEST.md               # UI: Vault panel
├── skills/                   # add, list, update, remove, pin, info, validate, try
│   ├── test.sh
│   └── TEST.md               # UI: Registry sidebar, skill editor
├── link/                     # link, unlink (all supported clients)
│   └── test.sh
├── traces/                   # traces command + Traces UI tab
│   ├── test.sh
│   └── TEST.md
├── pins/                     # list, verify, approve, reset + Pins panel
│   ├── test.sh
│   └── TEST.md
├── metrics/                  # Metrics tab, status bar token counter
│   ├── test.sh
│   └── TEST.md
├── wizard/                   # Creation wizard: all form types
│   └── TEST.md
├── graph/                    # Canvas: node selection, drag, zoom, wiring mode
│   └── TEST.md
├── playground/               # Playground tab: tool invocation, reasoning waterfall
│   └── TEST.md
└── serve/                    # gridctl serve, web UI startup
    └── test.sh
```

`run.sh` usage:
```bash
./proto/run.sh           # run all CLI tests
./proto/run.sh stack     # run stack domain only
./proto/run.sh vault     # run vault domain only
```

### Workflow Impact

Reduces time-to-smoke-test from "remember which scripts exist in plan/" to "run proto/run.sh". UI tests go from undocumented to explicit, reducing cognitive load before each release.

### UX Recommendations

- Keep domain count to ~12 (not 79 individual features) — maintainable
- Each `test.sh` should print a clear pass/fail summary at the end
- `TEST.md` files should use numbered steps with "→ verify" callouts, matching the plan/ style that's already ergonomic
- `run.sh` should accept an optional domain argument; without it, run all CLI tests sequentially

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | No comprehensive smoke test surface today |
| User impact | Narrow+Deep | Single user, high ROI per release cycle |
| Strategic alignment | Core | Quality tooling for active development |
| Market positioning | Irrelevant | Personal tooling |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | Gitignored, no code changes |
| Effort estimate | Medium | ~12 domains × (test.sh + TEST.md + fixtures) |
| Risk level | Low | No production impact |
| Maintenance burden | Moderate | Scripts drift as features evolve; periodic refresh needed |

## Recommendation

**Build.** High value, low risk, proven pattern. The only cost is writing time. Scope to ~12 feature domains (not 79 individual features) to keep the directory maintainable. Reuse `plan/` fixtures and the `ensure-mock-servers.sh` infrastructure already in place.

## References

- Existing plan/ scripts: `/Users/william/code/gridctl/plan/`
- plan/TESTING.md: comprehensive example of the hybrid CLI+UI test doc pattern
- Docker CLI integration tests: https://github.com/docker/cli/tree/master/e2e
- HashiCorp vault scripts: https://github.com/hashicorp/vault/tree/main/scripts
