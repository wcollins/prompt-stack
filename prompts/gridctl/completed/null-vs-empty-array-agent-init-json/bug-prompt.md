# Bug Fix: null vs Empty Array in `agent init --format json`

## Context

`gridctl` is a Go-based MCP gateway CLI living at `github.com/gridctl/gridctl`. The `gridctl agent init` subcommand scaffolds a runnable starter skill (TS, Go, or prompt-only flavors) into a directory and supports `--format json` for programmatic consumers. The scaffolding library lives in `pkg/agent/dev/scaffold/` and the CLI command body lives in `cmd/gridctl/agent.go`.

**Tech stack:** Go (cobra-based CLI), `encoding/json` for output, no external deps for this fix.

**Build/test:**
- Build: `make build` produces `./gridctl` (use this binary, not the brew-installed one)
- Tests: `go test ./...`
- Format: `gofmt`/`goimports` standard

**Conventions:**
- Commits signed with `-S`, no Claude/co-author trailers
- Branch prefix: `fix/`
- Fork-and-pull workflow (this is a fork; PRs go to `upstream`, not `origin`)

## Investigation Context

Root cause confirmed in `bug-evaluation.md`. Summary of investigation findings that shape this prompt:

- **Defect site:** `cmd/gridctl/agent.go:213-220` JSON-encodes a `map[string]any{"created": res.Created, "skipped": res.Skipped, ...}` literal. Both fields come from a `scaffold.Result` whose slices are nil-by-default (`pkg/agent/dev/scaffold/scaffold.go:69`).
- **Why `null` appears:** Go's `encoding/json` marshals nil slices as JSON `null`. Initialized empty slices (`[]string{}`) marshal as `[]`.
- **Both fields affected:** `created` is `null` when nothing was created (the originally-reported case); `skipped` is `null` when nothing was skipped (symmetric, same root cause).
- **Risk: low.** The change is type-preserving — `[]string{}` is still `[]string` len=0. Existing Go callers see no behavioral change (`len(nil) == 0`, `range nil` is a no-op).
- **Scope: narrow.** Verified no other JSON emit site has the same defect — `agentValidateReport` and `agentBuildReport` use struct types with `omitempty` tags, which is a different (also-correct) contract shape.
- **Reproduction is deterministic** — `go test` in CI will reliably catch the regression once tests are added.

Full investigation: `prompts/gridctl/null-vs-empty-array-agent-init-json/bug-evaluation.md`

## Bug Description

When `gridctl agent init --format json` runs against a directory where every starter file already exists, the output JSON contains `"created": null` instead of `"created": []`. The symmetric case — running against a fresh directory — produces `"skipped": null`.

**Concrete repro:**
```bash
# Repro A: created becomes null
mkdir /tmp/repro-a && cd /tmp/repro-a
./gridctl agent init --name hello-ts                       # populate
./gridctl agent init --name hello-ts --format json
# Actual:   {"created":null,"dir":"...","flavor":"ts","skipped":["SKILL.md","skill.ts","agent.json"]}
# Expected: {"created":[],"dir":"...","flavor":"ts","skipped":["SKILL.md","skill.ts","agent.json"]}

# Repro B: skipped becomes null
mkdir /tmp/repro-b && cd /tmp/repro-b
./gridctl agent init --name hello-ts --format json
# Actual:   {"created":["SKILL.md","skill.ts","agent.json"],"dir":"...","flavor":"ts","skipped":null}
# Expected: {"created":["SKILL.md","skill.ts","agent.json"],"dir":"...","flavor":"ts","skipped":[]}
```

**Why it matters:** `--format json` exists for programmatic consumers. Standard idioms — `jq '.created | length'`, `jq '.created[]'`, Python `for x in result["created"]`, JS `result.created.map(...)` — all error on `null`. The expected contract is documented in `proto/agent-runtime/TEST.md:65-71`.

## Root Cause

**Defect:** `pkg/agent/dev/scaffold/scaffold.go:69` initializes `res := Result{}`, leaving `res.Created` and `res.Skipped` as nil slices. The CLI emit site at `cmd/gridctl/agent.go:213-220` packages those slices into a `map[string]any{}` literal and JSON-encodes it. Go's `encoding/json` marshals nil slices as `null`, not `[]`. The map-literal emit site has no `omitempty` mechanism (unlike struct tags), so `null` propagates to the wire.

**Correct logic:** The `Result` struct represents a fact-list ("here's what scaffold did"). An empty fact-list is `[]`, never absent or null. Initialize both slices to `[]string{}` at the source so every consumer — JSON, tests, future callers — sees a consistent shape.

## Fix Requirements

### Required Changes

1. **Initialize both slices in `scaffold.Scaffold`.** In `pkg/agent/dev/scaffold/scaffold.go`, change line 69 from:
   ```go
   res := Result{}
   ```
   to:
   ```go
   res := Result{Created: []string{}, Skipped: []string{}}
   ```
   This ensures `res.Created` and `res.Skipped` are always non-nil, len-0-or-greater slices.

2. **Add a regression test for empty `created`.** In `cmd/gridctl/agent_test.go`, add a test that:
   - Pre-populates a temp dir by calling `runAgentInit` once.
   - Re-runs `runAgentInit` against the same dir with `agentInitFormat = "json"` and a captured stdout buffer.
   - Decodes the output into `map[string]any`.
   - Asserts `got["created"]` type-asserts to `[]any` (this fails on `null`) and has len 0.

3. **Add a regression test for empty `skipped`.** Same pattern, but against a fresh temp dir so all files are created and `skipped` is the empty one.

### Constraints

- **Must not change `Result` struct signature.** Field names and types stay as `Created []string` and `Skipped []string`. This is a behavioral fix, not a type change.
- **Must not introduce `omitempty` or any other "absent when empty" pattern.** The contract is "always an array" per TEST.md; the field must be present.
- **Must not modify any other JSON emit site.** `agent validate` and `agent build` use a different contract shape (struct + `omitempty`) and are out of scope.
- **Must preserve all existing tests.** The change is type-preserving; no existing assertion should need updating.

### Out of Scope

- **Missing `"skill"` field** in `agent init` JSON output — separate defect (code-vs-doc divergence noted in `proto/agent-runtime/TEST.md`). File a separate issue if desired; do not bundle.
- **Extra `"dir"` field** — undocumented but not broken; doc-only follow-up.
- **Refactoring the `map[string]any{}` literal into a typed `agentInitReport` struct** — a defensible refactor but unnecessary for the fix and would expand scope/diff size. Not required; do not include.
- **Auditing other JSON emit sites** — already done; no other sites have this defect.

## Implementation Guidance

### Key Files to Read

1. `pkg/agent/dev/scaffold/scaffold.go` — Where `Result` is defined (lines 22-30) and constructed (line 69). The fix lives here.
2. `cmd/gridctl/agent.go` — Read lines 165-220 for `runAgentInit` and the JSON emit site. Read lines 320-345 to see the `agentValidateReport` / `agentBuildReport` structs (the *adjacent-but-different* contract shape — DO NOT change the fix to mimic these).
3. `cmd/gridctl/agent_test.go` — Read lines 146-159 (`resetAgentInitFlagsForTest`) and lines 165-203 (`TestRunAgentInit_PromptOnlyFlavor`) for the existing test pattern. Mirror the setup helpers.
4. `pkg/agent/dev/scaffold/scaffold_test.go` — Existing scaffold-layer tests; check whether any assert on nil-ness of `Created`/`Skipped`. They should not, but verify.
5. `proto/agent-runtime/TEST.md` — Read lines 60-72 to confirm the documented contract this fix restores.

### Files to Modify

| File | Change |
|---|---|
| `pkg/agent/dev/scaffold/scaffold.go` | Line 69: `res := Result{}` → `res := Result{Created: []string{}, Skipped: []string{}}` |
| `cmd/gridctl/agent_test.go` | Append two new tests for the JSON-output contract (see test outline below) |

### Reusable Components

- `resetAgentInitFlagsForTest(t)` (`agent_test.go:146`) — call at the start and via `t.Cleanup` for any new test, matching the existing pattern.
- `agentInitCmd.SetOut(&buf)` (idiomatic in this file) — pipe the JSON output into a `bytes.Buffer` for parsing.
- `t.TempDir()` — for the per-test working directory.

### Conventions to Follow

- Test names: `TestRunAgentInit_*` prefix (matches existing tests in this file).
- Use `t.Fatal` for setup failures, `t.Errorf` for assertion failures.
- Decode into `map[string]any` and use type assertions to `[]any` — this is the load-bearing pattern that distinguishes `null` from `[]`.
- No table-driven tests needed; two distinct `func Test...` cases are clearer here.
- Keep imports tidy; `bytes`, `encoding/json` will need to be added if not already present.

## Regression Test

### Test Outline

Add to `cmd/gridctl/agent_test.go`:

```go
func TestRunAgentInit_JSONContract_EmptyCreatedIsArray(t *testing.T) {
    resetAgentInitFlagsForTest(t)
    t.Cleanup(func() { resetAgentInitFlagsForTest(t) })

    dir := t.TempDir()

    // Populate the dir so the second run skips everything.
    if err := runAgentInit(agentInitCmd, []string{dir}); err != nil {
        t.Fatalf("first runAgentInit (populate): %v", err)
    }

    // Reset and re-run with --format json. Same dir, so all files are skipped.
    resetAgentInitFlagsForTest(t)
    var buf bytes.Buffer
    agentInitCmd.SetOut(&buf)
    agentInitFormat = "json"
    if err := runAgentInit(agentInitCmd, []string{dir}); err != nil {
        t.Fatalf("second runAgentInit (json): %v", err)
    }

    var got map[string]any
    if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
        t.Fatalf("unmarshal output %q: %v", buf.String(), err)
    }

    created, ok := got["created"].([]any)
    if !ok {
        t.Fatalf(`"created" must be a JSON array, got %T (value=%v) — null breaks consumer pipelines`, got["created"], got["created"])
    }
    if len(created) != 0 {
        t.Errorf(`"created" must be empty when all files were skipped, got %v`, created)
    }
}

func TestRunAgentInit_JSONContract_EmptySkippedIsArray(t *testing.T) {
    resetAgentInitFlagsForTest(t)
    t.Cleanup(func() { resetAgentInitFlagsForTest(t) })

    dir := t.TempDir() // fresh — nothing to skip

    var buf bytes.Buffer
    agentInitCmd.SetOut(&buf)
    agentInitFormat = "json"
    if err := runAgentInit(agentInitCmd, []string{dir}); err != nil {
        t.Fatalf("runAgentInit (json, fresh dir): %v", err)
    }

    var got map[string]any
    if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
        t.Fatalf("unmarshal output %q: %v", buf.String(), err)
    }

    skipped, ok := got["skipped"].([]any)
    if !ok {
        t.Fatalf(`"skipped" must be a JSON array, got %T (value=%v) — null breaks consumer pipelines`, got["skipped"], got["skipped"])
    }
    if len(skipped) != 0 {
        t.Errorf(`"skipped" must be empty when all files were created, got %v`, skipped)
    }
}
```

The `.([]any)` type assertion is the load-bearing assertion. With the bug present, `got["created"]` is `nil` (untyped) and the assertion fails with `ok=false`, triggering the descriptive `t.Fatalf`. With the fix, the assertion succeeds with len 0.

### Existing Test Patterns

- Existing tests in `cmd/gridctl/agent_test.go` use `resetAgentInitFlagsForTest(t)` at start and via `t.Cleanup`.
- Cobra command flags are set via `agentInitCmd.Flags().Set(...)` for flag values, but package-level vars (`agentInitName`, `agentInitFormat`, etc.) are written directly when convenient — both styles are used in the file. Direct assignment is simpler for `agentInitFormat`.
- Output capture uses `agentInitCmd.SetOut(io.Discard)` in the reset helper; tests override with `agentInitCmd.SetOut(&buf)` before invocation when they need to inspect output.

## Potential Pitfalls

1. **Don't add `omitempty` to a hypothetical `agentInitReport` struct.** The contract is "always an array," not "absent when empty." Mixing in `omitempty` would technically remove `null` but would change the documented contract (TEST.md shows `created: []`, not `created` absent).
2. **Don't fix at the CLI layer instead of the scaffold layer.** Coercing nil → `[]string{}` in `agent.go` works but leaves the foot-gun in place for any future caller of `scaffold.Scaffold`. Fix at the data structure for a single-source-of-truth solution.
3. **Don't break the existing convention used by `agentValidateReport`.** That code uses `append([]string(nil), result.Errors...)` with `omitempty` — DO NOT mimic this pattern here. It's safe only because of `omitempty`, which the `agent init` map-literal emit site cannot use.
4. **Don't widen scope to add a `"skill"` field or remove `"dir"`.** Both are real issues but separate from this contract bug. Bundling them risks scope creep and a noisier diff.
5. **Test isolation.** The two new tests both invoke `runAgentInit`, which mutates package-level cobra flags. The `resetAgentInitFlagsForTest` helper handles this; do not skip the cleanup.
6. **Imports.** `cmd/gridctl/agent_test.go` may already import `bytes` and `encoding/json` for other tests; check before adding to avoid duplicate imports.

## Acceptance Criteria

1. `pkg/agent/dev/scaffold/scaffold.go:69` is changed to `res := Result{Created: []string{}, Skipped: []string{}}` (or semantically equivalent — e.g., explicit assignment after struct literal — provided both slices are non-nil before any append).
2. `cmd/gridctl/agent_test.go` contains a new test (or tests) asserting that `got["created"]` and `got["skipped"]` from `agent init --format json` are JSON arrays (not `null`) in their respective empty cases.
3. The new tests fail without the fix and pass with the fix. (Verify by running them once on the unfixed source, then on the fixed source.)
4. `go test ./...` passes — no existing tests regress.
5. `go vet ./...` and `golangci-lint run` (if configured) pass cleanly.
6. Manual verification: in a fresh temp dir, `./gridctl agent init --name hello-ts --format json` produces `"skipped":[]` (not `null`); after a re-run, the next `--format json` produces `"created":[]` (not `null`). Both should match the contract documented in `proto/agent-runtime/TEST.md:65-71`.
7. Diff is minimal — one line in `scaffold.go`, two new test functions in `agent_test.go`. No other file changes.

## References

- `proto/agent-runtime/TEST.md:65-71` — the documented JSON contract this fix restores
- `cmd/gridctl/agent.go:213-220` — JSON emit site (read-only for this fix; no change needed)
- `cmd/gridctl/agent.go:326-345` — adjacent JSON emitters using `omitempty` (DO NOT mimic; different contract)
- `pkg/agent/dev/scaffold/scaffold.go:22-30` — `Result` struct definition
- `pkg/agent/dev/scaffold/scaffold.go:69` — fix site
- Go `encoding/json` package docs on slice marshaling: nil → `null`, non-nil → `[]`
- Bug investigation: `prompts/gridctl/null-vs-empty-array-agent-init-json/bug-evaluation.md`
