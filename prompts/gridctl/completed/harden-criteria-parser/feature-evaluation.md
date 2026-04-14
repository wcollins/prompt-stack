# Feature Evaluation: Harden Acceptance Criteria Parser

**Date**: 2026-04-04
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

The `gridctl test` command silently skips malformed GIVEN/WHEN/THEN criteria and exits 0, producing false greens in CI pipelines. This undermines `gridctl activate`'s role as a quality gate. The fix is surgical: validate criteria format at activate time, add `--dry-run` to show parse results, and add exit code 3 for "criteria present but none parseable."

## The Idea

**Feature**: Harden the acceptance criteria parser to surface malformed criteria before they create false greens.

**Problem**: Criteria that don't match the `GIVEN ... WHEN ... THEN` regex are silently skipped. A typo like `GIVN a context WHEN ...` causes the criterion to be invisibly ignored — the test command reports "0 failed" (technically true), `gridctl test` exits 0, and CI pipelines show green. There is no validation at `gridctl activate` time that criteria are well-formed; only that the list is non-empty.

**Who benefits**: Every team using gridctl skills in CI pipelines. Skills with acceptance criteria are the primary mechanism for verifying skill behavior before promotion — a false green there defeats the purpose.

**Three proposed additions**:
1. Strict-mode enforcement at `activate` time — reject skills with zero parseable criteria before promotion
2. `gridctl test --dry-run` — shows which criteria would parse and which would be skipped without invoking any MCP tools
3. Exit code 3 for "criteria found but none were parseable" — distinct from exit 1 (test failures) and exit 2 (infrastructure errors)

## Project Context

### Current State

gridctl is a mature MCP orchestration platform (~8,400 lines of Go in the registry package). The acceptance criteria system was added in a recent feature sprint and is working as designed — the silent-skip behavior is explicitly documented. The problem is that "working as designed" is a footgun in practice.

**The exact failure chain:**

1. Author writes `["GIVN a context WHEN called THEN response contains ok"]` (typo: GIVN)
2. `gridctl activate my-skill` → checks `len(AcceptanceCriteria) > 0` → passes (list has one entry)
3. `gridctl test my-skill` → `ParseCriterion()` returns nil → criterion logged as WARN, marked Skipped
4. All criteria skipped → "Skill status: UNTESTED (no parseable criteria)"
5. **Exit code: 0** → CI pipeline shows green

There is also a secondary false green: when some criteria parse and some don't, `printTestResult` currently emits "Skill status: PASSING" — the skipped criteria are not surfaced in the status line.

**Current exit codes in `test.go`:**
- 0: all criteria passed (or all skipped — the bug)
- 1: one or more criteria failed (or no criteria defined)
- 2: infrastructure error (gateway unreachable, skill not found)

### Integration Surface

| File | Lines | Role |
|------|-------|------|
| `pkg/registry/tester.go` | 199 | `ParseCriterion()`, `RunAcceptanceCriteria()`, silent-skip at line 128 |
| `cmd/gridctl/test.go` | 179 | CLI test command, exit codes, `--dry-run` flag goes here |
| `cmd/gridctl/activate.go` | 57 | Activation gate, format validation goes here |
| `pkg/registry/validator.go` | 332 | `ValidateSkillFull()`, where a new `WarnMalformedCriteria` constant fits |
| `internal/api/registry.go` | ~570 | HTTP API mirrors CLI logic — activation check at line 200 needs parallel update |
| `pkg/registry/tester_test.go` | 308 | Existing tests including `TestRunAcceptanceCriteria_Skipped` — needs updating |

### Reusable Components

- `ParseCriterion()` — already exported from `pkg/registry`; activation gate can call it directly
- `suggestFromSet()` in `validator.go` — Levenshtein helper, can be extended to suggest correct keywords (GIVEN, WHEN, THEN) for typo detection
- `--dry-run` pattern — already implemented in `link.go`, `unlink.go`, `skill.go`; same Cobra flag pattern applies
- `parseCriterionDisplay()` in `test.go` — can drive the dry-run output without any new parsing logic

## Market Analysis

### Competitive Landscape

All mature BDD tools fail hard on undefined/malformed steps by default:

- **Behave (Python)**: Undefined steps are unconditional failures — no "silent skip" mode exists
- **Cucumber JS**: `strict: true` is the default; undefined steps cause non-zero exit; `--dry-run` is a first-class flag that shows parse/skip results without executing
- **Cucumber Ruby**: `--strict` promotes pending steps to failures; exit 2 reserved for "unable to run at all"
- **pytest-bdd**: Unmatched steps are collection errors — never silently skipped

None of the comparable tools have a "silent skip" as their default for malformed criteria.

### Market Positioning

**Table-stakes**. The ability to trust that a passing test run means something was actually tested is baseline behavior for any test runner. Gridctl's current behavior is actively below the floor set by Behave (2007), Cucumber (2008), and pytest. This is not a differentiator opportunity — it is a gap that erodes trust in the overall quality gate mechanism.

### Ecosystem Support

No external library needed. `ParseCriterion()` already exists and is exported. The changes are additive to existing code.

### Demand Signals

The feature request originates from observed CI pipeline behavior ("0 failed" on a skill with only malformed criteria). The silent-skip behavior is described as intentional in AGENTS.md, but the practical consequence — false greens — makes it a reliability issue rather than a design choice. The go test ecosystem has the same known weakness (`go test -run TYPO` exits 0 with "[no tests to run]") and it is a frequently cited pain point.

## User Experience

### Interaction Model

**`gridctl activate` (strict check — default behavior):**
```
$ gridctl activate my-skill

Validating acceptance criteria...

  [1] ✓  GIVEN a context WHEN the skill is called THEN is not empty
  [2] ✗  "GIVN a context WHEN called THEN response contains ok"
         does not match GIVEN ... WHEN ... THEN (did you mean GIVEN?)
  [3] ✓  GIVEN no inputs WHEN the skill is called THEN is not empty

✗ Cannot activate "my-skill": 1 of 3 criteria failed to parse.
  Fix the malformed criteria and re-run: gridctl activate my-skill
```

**`gridctl test --dry-run`:**
```
$ gridctl test my-skill --dry-run

Dry-run: acceptance criteria parse results for skill: my-skill

  GIVEN a context
  WHEN  the skill is called
  THEN  is not empty
  → would run (tool: my-skill)

  "GIVN a context WHEN called THEN response contains ok"
  → would skip: does not match GIVEN ... WHEN ... THEN

2 of 3 criteria would run, 1 would be skipped.
Run without --dry-run to execute.
```

**Exit code 3 (new — "all skipped"):**
```
$ gridctl test my-skill; echo $?
...
Skill status: UNTESTED (no parseable criteria)
3
```

### Workflow Impact

- **Reduces friction** for teams debugging false green CI builds — `--dry-run` gives immediate visibility into which criteria are problematic without needing a live gateway
- **Adds one blocking gate** at activate time — teams with currently-malformed-but-activated skills will hit the new gate on re-activation only (no retroactive enforcement)
- **Fixes the silent lie** in `printTestResult` where partial-skip scenarios report "PASSING"

### UX Recommendations

1. At activate time, list all criteria with their parse result (not just the failures) so authors can see the full picture
2. Apply "did you mean" keyword suggestion to the three fixed keywords (GIVEN, WHEN, THEN) using the existing `suggestFromSet` Levenshtein helper
3. The dry-run output should show `resolveToolName()` resolution per criterion — this surfaces a secondary class of silent bugs where the WHEN clause resolves to the wrong tool
4. Do NOT use `--strict` as a flag on `activate` — the format validation should be the default, not an opt-in. Skills with zero parseable criteria should not activate. (The backwards-compat risk is low: any skill that was passing the old gate has at least one string in its criteria list; the only new failure case is all-malformed lists.)

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | False green in CI = primary safety mechanism silently bypassed |
| User impact | Narrow+Deep | Affects all gridctl skill authors; for them this is the core trust mechanism |
| Strategic alignment | Core mission | `gridctl activate` exists as a quality gate; this restores that guarantee |
| Market positioning | Catch up | Below the floor set by all mature BDD tools since 2007 |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | `ParseCriterion()` already exported; changes are additive to 4-5 files |
| Effort estimate | Small | No new abstractions; clear implementation path |
| Risk level | Low | Hardening existing behavior; no new systems; HTTP API needs parallel update |
| Maintenance burden | Minimal | No new runtime dependencies introduced |

## Recommendation

**Build.** This is a correctness fix masquerading as a feature. The problem is critical (false greens in CI defeat the purpose of the quality gate), the implementation is small and surgical (exported `ParseCriterion()` does all the heavy lifting), and the market standard is clear (no mature BDD tool silently skips malformed criteria).

The one design clarification from the original proposal: use **exit code 3** (not 2) for "criteria present but none parseable." Exit code 2 in `test.go` is already defined and documented as infrastructure errors. Reusing it would conflate two distinct failure modes that CI pipelines need to distinguish. Exit 3 = "skill is reachable and criteria exist, but none are in a testable state" — this maps cleanly to pytest's exit 5 ("no tests collected") and golangci-lint's exit 5 ("no files to analyze").

## References

- pytest exit code documentation: https://docs.pytest.org/en/stable/reference/exit-codes.html
- Cucumber JS dry-run documentation: https://github.com/cucumber/cucumber-js/blob/main/docs/dry_run.md
- golangci-lint exit codes: `pkg/exitcodes/exitcodes.go` in the golangci-lint repository
- Jest `--passWithNoTests` flag documentation
- ESLint `--pass-on-no-patterns` and `--max-warnings` flags
- go test false green: `go test -run DOES_NOT_EXIST` exits 0 with `[no tests to run]`
