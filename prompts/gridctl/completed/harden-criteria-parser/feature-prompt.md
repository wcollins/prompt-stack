# Feature Implementation: Harden Acceptance Criteria Parser

## Context

gridctl is a Go CLI tool (~8,400 lines in the registry package) for MCP (Model Context Protocol) orchestration. It manages "skills" — composable workflow units defined in `SKILL.md` files with YAML frontmatter. Skills can have acceptance criteria written in `GIVEN ... WHEN ... THEN` format that are tested against live MCP tools via `gridctl test`.

**Tech stack**: Go 1.22+, Cobra CLI, `log/slog`, net/http for gateway communication, `regexp` for criteria parsing.

**Key architectural pattern**: The CLI (`cmd/gridctl/`) calls the registry HTTP API (`internal/api/registry.go`) for test and activate operations. The registry package (`pkg/registry/`) contains the core logic. Changes to business logic in the CLI must be mirrored in the HTTP API.

## Evaluation Context

- **Root cause**: `ParseCriterion()` returns nil for non-matching criteria; `RunAcceptanceCriteria()` treats nil as "skip" rather than "error." This is intentional per AGENTS.md, but produces false greens — `gridctl test` exits 0 when all criteria are skipped.
- **Market standard**: All mature BDD tools (Cucumber, Behave, pytest-bdd) fail hard on malformed/undefined steps. Silent skip is below the industry floor.
- **Exit code design**: The original proposal requested exit code 2 for "no parseable criteria," but exit 2 is already defined and in use in `test.go` for infrastructure errors (gateway unreachable). Use **exit code 3** to keep the codes orthogonal. CI pipelines checking `!= 0` continue to treat it as failure.
- **Backwards compatibility**: The activate gate (blocking all-malformed criteria) is not a breaking change for skills currently in the registry — it only triggers on re-activation of skills whose entire criteria list is malformed. Any skill with at least one valid criterion continues to activate normally.
- Full evaluation: `prompts/gridctl/harden-criteria-parser/feature-evaluation.md`

## Feature Description

Harden the acceptance criteria parser in three concrete changes:

1. **Activation gate** — `gridctl activate` validates that at least one criterion in the list matches the `GIVEN ... WHEN ... THEN` pattern before allowing promotion to active state. Skills whose entire criteria list is malformed are rejected with an actionable error message.

2. **`--dry-run` on `gridctl test`** — Without invoking any MCP tools or hitting the gateway, shows each criterion's parse result: which ones would run, which would be skipped and why. Useful for debugging criteria before deploying to a live gateway.

3. **Exit code 3** — `gridctl test` exits 3 when criteria are present but every one is unparseable (the "UNTESTED" case). This is distinct from exit 1 (tests ran and failed) and exit 2 (infrastructure error).

**Bonus (if time allows)**: Fix `printTestResult` to report "PASSING (N skipped)" rather than "PASSING" when some criteria were skipped in a live run — partial-skip is currently a silent secondary false green.

## Requirements

### Functional Requirements

1. `gridctl activate <skill>` must call `ParseCriterion()` on each entry in `AcceptanceCriteria` and reject activation if zero entries parse successfully.
2. The activation error message must list each malformed criterion with its index, the raw criterion text, and a human-readable reason ("does not match GIVEN ... WHEN ... THEN").
3. The activation error message must include the retry command (`gridctl activate <skill>`).
4. `gridctl test --dry-run` must output each criterion's parse result without calling the gateway or any MCP tools.
5. The dry-run output must use the same display format as `printTestResult` (GIVEN/WHEN/THEN lines) for parseable criteria, and print the raw text for unparseable ones.
6. The dry-run exit codes must be: 0 = all criteria would run, 3 = zero criteria would run (none parseable), 1 = some criteria would be skipped.
7. `gridctl test` (live run) must exit 3 when `result.Passed == 0 && result.Failed == 0 && result.Skipped > 0` (all criteria were skipped).
8. The `Long` docstring for `testCmd` must be updated to document exit code 3.
9. The `Long` docstring for `activateCmd` must be updated to describe the format validation requirement.
10. The HTTP API activation endpoint (`handleRegistrySkillStateChange` in `internal/api/registry.go`) must apply the same parseable-criteria check as the CLI.
11. All new behavior must have corresponding unit tests following the project's table-driven test pattern.

### Non-Functional Requirements

- No new external dependencies.
- The dry-run flag must not make any network connections (no HTTP calls to the gateway).
- Error messages must not expose the raw regex pattern — use "does not match GIVEN ... WHEN ... THEN" consistently.
- The `suggestFromSet` Levenshtein helper in `validator.go` may be extended (or a new `suggestKeyword` helper written) to suggest the correct keyword when a typo is detected (e.g., "GIVN" → "did you mean GIVEN?"). This is optional but recommended.

### Out of Scope

- Retroactive validation of already-activated skills (no migration, no registry scan at startup).
- Changes to the `GIVEN ... WHEN ... THEN` regex itself or the assertion evaluation logic.
- Any changes to how parseable criteria are tested against live tools.
- A `--strict` flag on `activate` — the format gate should be the default, not opt-in.
- Changes to the web UI.

## Architecture Guidance

### Recommended Approach

The implementation is additive — no existing logic needs to be removed or restructured. The key function `ParseCriterion()` is already exported from `pkg/registry` and available to both the CLI and the HTTP API without any import changes.

**Activation gate**: In `runActivate()` (`cmd/gridctl/activate.go`), after the existing `len(AcceptanceCriteria) == 0` check, add a second pass that calls `ParseCriterion()` on each criterion and counts matches. If the parseable count is zero, print the per-criterion report and exit 1. Follow the existing error message style in the same file.

**Dry-run**: In `testCmd`'s `init()`, add a `--dry-run` bool flag. In `runTestCmd()`, branch early when `--dry-run` is set: call `ParseCriterion()` locally on each criterion (the skill's criteria are fetched via the registry API — or, more simply, `--dry-run` can fetch the skill from the registry's skill-detail endpoint to get the criteria list without triggering a test run). Print parse results using a new `printDryRunResult()` helper modeled on `parseCriterionDisplay()`.

**Exit code 3**: After the existing `if result.Failed > 0 { os.Exit(1) }` block in `runTestCmd()`, add:
```go
total := result.Passed + result.Failed + result.Skipped
if total > 0 && result.Passed == 0 && result.Failed == 0 {
    os.Exit(3)
}
```

**HTTP API**: In `handleRegistrySkillStateChange()` (`internal/api/registry.go`, around line 200), add the same parseable-criteria check after the existing `len(AcceptanceCriteria) == 0` guard. Return HTTP 400 with a JSON error body following the existing `writeJSONError` pattern.

### Key Files to Understand

| File | Why |
|------|-----|
| `pkg/registry/tester.go` | `ParseCriterion()` definition (line 44), `RunAcceptanceCriteria()` skip logic (line 128), `SkillTestResult` struct |
| `cmd/gridctl/test.go` | Current exit code structure (lines 102–105), `printTestResult()` (line 119), `parseCriterionDisplay()` (line 111) |
| `cmd/gridctl/activate.go` | Current gate at line 40 — the entire file is 57 lines, very easy to follow |
| `internal/api/registry.go` | `handleRegistrySkillStateChange()` at ~line 191 for the API-side activate gate; `handleRegistrySkillTest()` at ~line 539 for context |
| `pkg/registry/validator.go` | `suggestFromSet()` at line 293 for the Levenshtein helper; error/warning pattern to follow |
| `cmd/gridctl/validate.go` | Reference for 3-tier exit codes (0/1/2) and the `printValidationResult` display pattern |
| `pkg/registry/tester_test.go` | `TestRunAcceptanceCriteria_Skipped` — the existing test of skip behavior; update this to assert exit semantics |

### Integration Points

**`cmd/gridctl/activate.go`** — add after line 47 (after the `len == 0` check):
```go
// Validate that at least one criterion is parseable
parseable := 0
for _, c := range sk.AcceptanceCriteria {
    if registry.ParseCriterion(c) != nil {
        parseable++
    }
}
if parseable == 0 {
    // print per-criterion report, os.Exit(1)
}
```

**`cmd/gridctl/test.go`** — add `--dry-run` flag in `init()`, branch in `runTestCmd()`, new `printDryRunResult()` function, add exit-3 block after the existing exit-1 check.

**`internal/api/registry.go`** — the existing check is at approximately line 200. The new parseable-criteria check goes immediately after it, before the state transition.

**`pkg/registry/tester_test.go`** — the `TestRunAcceptanceCriteria_Skipped` test validates the current behavior. Ensure the test still passes (the skip behavior in `RunAcceptanceCriteria` itself does not change — only the callers respond differently to all-skipped results).

### Reusable Components

- `registry.ParseCriterion(s string) *parsedCriterion` — already exported; use directly in `activate.go` and the dry-run path
- `parseCriterionDisplay()` in `test.go` — reuse for the dry-run output format
- `suggestFromSet()` in `validator.go` — extend or copy for keyword suggestion ("GIVN" → "GIVEN")
- The `--dry-run` flag pattern from `link.go` or `unlink.go` — copy the Cobra flag declaration style

## UX Specification

### `gridctl activate` — when all criteria are malformed

**Discovery**: Happens on every `gridctl activate` call. No new command needed.

**Output (stderr):**
```
✗ cannot activate "my-skill": 0 of 3 criteria match GIVEN ... WHEN ... THEN

  [1] ✗  GIVN a context WHEN the skill is called THEN is not empty
         does not match GIVEN ... WHEN ... THEN (did you mean GIVEN?)
  [2] ✗  the skill is fast
         does not match GIVEN ... WHEN ... THEN
  [3] ✗  GIVEN context WHEN called THEN:
         does not match GIVEN ... WHEN ... THEN

  Fix the malformed criteria and re-run: gridctl activate my-skill
```

**Exit code**: 1 (same as the existing "no criteria defined" failure — both are "can't activate").

### `gridctl test --dry-run`

**Discovery**: `gridctl test --help` shows the flag. Gateway must be running (to fetch the skill's criteria list), but no tool calls are made.

**Output (stdout):**
```
Dry-run: acceptance criteria parse results for skill: my-skill
Gateway: http://localhost:8080

  GIVEN a valid context
  WHEN  the skill is called
  THEN  is not empty
  → would run (tool: my-skill)

  GIVEN no inputs
  WHEN  the skill is called
  THEN  response contains "ok"
  → would run (tool: my-skill)

  "GIVN a context WHEN called THEN response ok"
  → would skip: does not match GIVEN ... WHEN ... THEN

2 of 3 criteria would run, 1 would be skipped.
Run without --dry-run to execute against live tools.
```

**Exit codes**:
- 0: all criteria would run
- 1: some criteria would be skipped (mixed — matches existing exit-1 "not everything passed")
- 3: zero criteria would run (all malformed)
- 2: gateway unreachable (same as live run)

### `gridctl test` — exit code 3 path

**Existing output** (no change to text):
```
Skill status: UNTESTED (no parseable criteria)
```

**Exit code**: 3 (was 0).

### Error states

- Skill not found: unchanged (exit 2)
- Gateway unreachable in dry-run: exit 2 with existing "gateway not reachable" message
- Empty criteria list: unchanged (exit 1 from existing `http.StatusBadRequest` path)

## Implementation Notes

### Conventions to Follow

- Error output goes to `os.Stderr`; normal output to `os.Stdout` — enforced throughout the existing codebase
- `os.Exit()` is called directly (not `return error`) for non-zero exits in the CLI — follow this pattern
- Do not use `fmt.Println` for structured output in new code — use `fmt.Printf` with explicit `\n` (existing style)
- The `Long` docstring for Cobra commands uses a consistent format: first line is a one-sentence description, then a blank line, then "Exit codes:" section — maintain this
- Test helper functions follow the `setupTestServer` / `writeTestSkill` pattern from `tester_test.go`

### Potential Pitfalls

1. **The dry-run needs the skill's criteria list** — the criteria live in the registry, so `--dry-run` still needs to call the registry API to fetch the skill definition. The gateway must be reachable. The only thing dry-run skips is the actual test execution (`POST /api/registry/skills/{name}/test`). Add a `GET /api/registry/skills/{name}` call to retrieve the skill.

2. **Don't change `RunAcceptanceCriteria()` behavior** — the skip logic in `tester.go` should remain unchanged. Only the callers (`test.go` and the HTTP API) change how they respond to an all-skipped result. This keeps the server-side behavior consistent with the HTTP API (which returns 200 with a `SkillTestResult` regardless) and avoids breaking the existing tester tests.

3. **HTTP API mirror** — the activate endpoint in `internal/api/registry.go` must receive the same parseable-criteria check as the CLI. Omitting this leaves a bypass: `curl -X POST /api/registry/skills/my-skill/state` would still activate malformed skills.

4. **Exit code 3 in dry-run** — when implementing dry-run exit codes, the "some would be skipped" case should exit 1 (not 0) to flag CI pipelines that something needs attention, while preserving exit 0 for "everything parses cleanly."

5. **The `parsedCriterion` type is unexported** — `ParseCriterion()` returns `*parsedCriterion` which is a package-private type. The activate gate only needs to check `!= nil`, so this is fine. But if you want to display the resolved GIVEN/WHEN/THEN in the dry-run output, you'll need to either call `parseCriterionDisplay()` (which has its own regex and is in `cmd/`) or export `parsedCriterion`. The cleanest approach: keep everything using `parseCriterionDisplay()` in the CLI layer — it already handles the nil case.

### Suggested Build Order

1. **Exit code 3 in `test.go`** — smallest, most isolated change. Add the block after the existing `result.Failed > 0` check. Update the `Long` docstring. Write a test for the all-skipped path.

2. **Activation gate in `activate.go`** — add the parseable-criteria loop and the per-criterion error output. Update the `Long` docstring. Write tests covering: all-malformed (blocks), some-malformed (passes — at least one parseable), all-valid (passes).

3. **HTTP API mirror in `registry.go`** — the parseable-criteria check mirrors the CLI gate. Add after the existing `len == 0` guard. Add a test in `internal/api/registry_test.go`.

4. **`--dry-run` flag in `test.go`** — add the flag, the early-branch in `runTestCmd()`, the `printDryRunResult()` helper. Write tests for the three exit code paths (all-parse/some-skip/none-parse).

5. **Bonus: fix the partial-skip "PASSING" lie** — in `printTestResult()`, change the status line when `result.Skipped > 0 && result.Failed == 0` to "PASSING (N skipped — check parse errors)". Minimal change, high signal value.

## Acceptance Criteria

1. `gridctl activate my-skill` with a skill whose entire `acceptance_criteria` list is malformed (none match GIVEN/WHEN/THEN) exits 1 and prints a per-criterion error report.
2. `gridctl activate my-skill` with a skill that has at least one valid criterion (and any number of malformed ones) activates successfully.
3. `gridctl activate my-skill` with a skill that has no acceptance criteria continues to exit 1 with the existing "no acceptance criteria" message (no regression).
4. `gridctl test my-skill` when all criteria are skipped (result: 0 passed, 0 failed, N skipped) exits 3.
5. `gridctl test my-skill` when at least one criterion fails exits 1 (no regression).
6. `gridctl test my-skill` when all criteria pass exits 0 (no regression).
7. `gridctl test my-skill --dry-run` prints parse results for each criterion without making any MCP tool calls.
8. `gridctl test my-skill --dry-run` exits 3 when no criteria parse, 0 when all parse, 1 when some parse and some don't.
9. `gridctl test --help` shows exit code 3 in the documented exit code table.
10. `curl -X POST /api/registry/skills/my-skill/state` with a payload transitioning to active state returns HTTP 400 when the skill's entire criteria list is malformed.
11. All existing tests in `tester_test.go`, `registry_test.go`, and `internal/api/registry_test.go` continue to pass.
12. New tests follow the project's table-driven test pattern and use `t.Run()` for subtests.

## References

- pytest exit codes: https://docs.pytest.org/en/stable/reference/exit-codes.html
- Cucumber JS dry-run: https://github.com/cucumber/cucumber-js/blob/main/docs/dry_run.md
- golangci-lint exit codes: `pkg/exitcodes/exitcodes.go` in the golangci-lint repository
- go test false green: `go test -run DOES_NOT_EXIST` exits 0 — cautionary tale to avoid repeating
- Full feature evaluation: `prompts/gridctl/harden-criteria-parser/feature-evaluation.md`
