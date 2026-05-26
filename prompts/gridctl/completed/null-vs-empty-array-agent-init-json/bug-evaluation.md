# Bug Investigation: null vs Empty Array in `agent init --format json`

**Date**: 2026-05-11
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Medium
**Fix Complexity**: Trivial

## Summary

`gridctl agent init --format json` emits `"created": null` (and symmetrically `"skipped": null`) instead of `[]` when the corresponding slice is empty. The defect violates the JSON CLI contract documented in `proto/agent-runtime/TEST.md:65-71` and breaks standard consumer idioms like `jq '.created | length'`. Root cause is a single map-literal emit site backed by an unitialized Go slice. Fix is a one-line struct initializer at the scaffold layer plus a regression test.

## The Bug

**What is wrong:** When `gridctl agent init --format json` runs against a directory where all starter files already exist, the JSON output contains `"created": null` instead of `"created": []`. The symmetric case — running against a fresh directory — produces `"skipped": null`.

**Expected behavior:** Both fields should always be JSON arrays (zero-or-more elements). `proto/agent-runtime/TEST.md:65-71` documents the contract:
```json
{ "skill": "hello-ts", "created": [], "skipped": ["SKILL.md", "skill.ts", "agent.json"] }
```

**How it manifests:** Consumers piping through `jq '.created | length'`, iterating with `jq '.created[]'`, or doing the equivalent in Python/Node (`for x in result["created"]`, `result.created.map(...)`) error out or behave incorrectly because `null` is not iterable.

**Discovery:** Found while validating the `proto/agent-runtime/TEST.md` walkthrough for the recently-merged PR #600. The binary fails its own documented acceptance test.

## Root Cause

### Defect Location

**Primary site:** `cmd/gridctl/agent.go:213-220`

```go
if strings.EqualFold(agentInitFormat, "json") {
    _ = json.NewEncoder(cmd.OutOrStdout()).Encode(map[string]any{
        "dir":     dir,
        "flavor":  flavor,
        "created": res.Created,   // nil when nothing created → "created":null
        "skipped": res.Skipped,   // nil when nothing skipped → "skipped":null
    })
```

**Source of nil-ness:** `pkg/agent/dev/scaffold/scaffold.go:69`

```go
res := Result{}        // both Created and Skipped left as nil slices
```

### Code Path

1. CLI invocation: `gridctl agent init --format json` → `runAgentInit` (`cmd/gridctl/agent.go:185`)
2. `runAgentInit` calls `scaffold.Scaffold(dir, opts)` (line 205)
3. `Scaffold` initializes `res := Result{}` — both `Created` and `Skipped` are nil slices (`scaffold.go:69`)
4. Loop appends to `res.Skipped` or `res.Created` based on whether each starter file existed (`scaffold.go:78, 87`). Slices that receive no appends remain nil.
5. `runAgentInit` packages `res.Created` and `res.Skipped` into a `map[string]any` literal and JSON-encodes it (`agent.go:213-220`).
6. `encoding/json` marshals nil slices as `null`, not `[]`. Wire output contains `"created": null` or `"skipped": null` accordingly.

### Why It Happens

Go's `encoding/json` package marshals nil slices as JSON `null` and only marshals initialized empty slices (`[]string{}`, len=0) as JSON `[]`. The `scaffold.Result` struct leaves both slice fields at their zero value (nil) until something is appended. The CLI emit site uses a `map[string]any{}` literal — which has no `omitempty` mechanism — so nil values are emitted directly as `null`.

### Similar Instances

**None.** The codebase was audited; this is the only JSON emit site with the defect. The two adjacent commands that also support `--format json`:

- `runAgentValidate` (`agent.go:347-409`) emits an `agentValidateReport` struct with `omitempty` tags on `Errors` and `Warnings`. Nil/empty slices are omitted from the wire shape, not emitted as `null`. Different contract ("absent when empty"), not the same defect.
- `runAgentBuild` paths emit `agentBuildReport` (`agent.go:337-345`), also struct-with-`omitempty`. Same as validate.

`agent init` is the outlier because it's the only emitter using a bare `map[string]any{}` literal.

## Impact

### Severity Classification

**Medium — output contract violation.** Not a crash, security issue, or data corruption. The system functions correctly; only the wire shape of the JSON output is wrong. Severity is elevated above "cosmetic" because:
- The contract is explicitly documented (TEST.md).
- `--format json` exists specifically for programmatic consumers, who are exactly the population that breaks on `null`.
- The `null`-vs-`[]` distinction is a well-known foot-gun and most CLI tools (`gh`, `kubectl`, `aws`, `gcloud`) treat it as a defect.

### User Reach

Anyone scripting `gridctl agent init --format json`. The defect surfaces whenever a slice is empty:
- Re-running `agent init` against an existing skill (the idempotency case) → `created: null`
- Running `agent init` against a fresh directory → `skipped: null`

### Workflow Impact

Common path for the target user (script consumers). The whole point of `--format json` is to enable downstream automation; that automation breaks on `null`.

### Workarounds

Yes, in every consumer:
- `jq '(.created // []) | length'`
- Python: `result.get("created") or []`
- Node: `result.created ?? []`

Trivial per-consumer, but the contract exists to remove that burden. Every consumer must independently learn the gotcha.

### Urgency Signals

- Code is fresh (PR #600 just merged) — no external integrations to migrate.
- TEST.md is the documented acceptance spec; the binary currently fails its own walkthrough.
- No live production user reported it (you found it during your own walkthrough), so this is "fix before it bites someone," not a hotfix.

## Reproduction

### Minimum Reproduction Steps

**Repro A — `created: null` (the originally-reported case):**
```bash
mkdir /tmp/repro-a && cd /tmp/repro-a
gridctl agent init --name hello-ts                       # populate
gridctl agent init --name hello-ts --format json         # everything skipped
# → {"created":null,"dir":"...","flavor":"ts","skipped":["SKILL.md","skill.ts","agent.json"]}
```

**Repro B — `skipped: null` (symmetric, less visible):**
```bash
mkdir /tmp/repro-b && cd /tmp/repro-b
gridctl agent init --name hello-ts --format json         # fresh dir, nothing to skip
# → {"created":["SKILL.md","skill.ts","agent.json"],"dir":"...","flavor":"ts","skipped":null}
```

### Affected Environments

All — Go's `encoding/json` behavior is platform-independent. Affects every flavor (`ts`, `go`, `prompt-only`).

### Non-Affected Environments

None. Deterministic across all build configurations.

### Failure Mode

Field is emitted with JSON value `null` instead of `[]`. The defect is purely in the wire shape — files were/weren't written correctly, idempotency holds, no state corruption. The output is consumable by lenient parsers but breaks standard array-iteration idioms.

## Fix Assessment

### Fix Surface

- **Primary fix:** `pkg/agent/dev/scaffold/scaffold.go:69` — initialize `Result.Created` and `Result.Skipped` to `[]string{}` instead of leaving them as nil. One line.
- **Test:** `cmd/gridctl/agent_test.go` — add two tests asserting JSON output shape for the empty-`created` and empty-`skipped` cases.

### Risk Factors

- **Risk: Low.** The change is type-preserving — `[]string{}` is still `[]string` with len=0. `len(nil) == 0` and `range nil` is a no-op in Go, so all existing Go callers see identical behavior.
- The only behavioral change is the JSON wire shape, which is the bug being fixed.
- No external API surface affected (scaffold is an internal package).

### Rejected Alternative

Fixing at the CLI layer (`cmd/gridctl/agent.go:213-220`) by coercing nil → `[]string{}` before encoding is also viable but inferior:
- Doesn't remove the foot-gun for future emit sites.
- Spreads JSON-contract concerns into multiple files instead of fixing the data structure once.
- Slightly more code (3 lines vs 1).

### Regression Test Outline

Two test cases in `cmd/gridctl/agent_test.go`:

```go
func TestRunAgentInit_JSONContract_EmptyCreatedIsArray(t *testing.T) {
    // Pre-populate, then re-init with --format json.
    // Decode output. Assert got["created"] is []any with len 0, NOT nil.
    // The []any type assertion is the lever — null fails it.
}

func TestRunAgentInit_JSONContract_EmptySkippedIsArray(t *testing.T) {
    // Run --format json against fresh dir.
    // Assert got["skipped"] is []any with len 0.
}
```

The `[]any` type assertion is the load-bearing check: if `created` is `null`, the assertion to `[]any` fails because the value's actual type is `<nil>`.

## Recommendation

**Fix immediately.** Trivial one-line change at the scaffold layer plus a two-case regression test. No migration risk, no external consumers, contract is already documented. The fix-while-warm window is now — PR #600 just merged, no pipelines to update.

**Out of scope (do not bundle into this fix):**
- Missing `"skill"` field in `agent init` JSON output — separate defect (code-vs-doc divergence) flagged during discovery but distinct from the null/array contract issue.
- Extra `"dir"` field in `agent init` JSON output — undocumented but functional; doc-only follow-up.
- Codebase-wide audit of other JSON emit sites — already verified safe via the struct + `omitempty` pattern.

## References

- `cmd/gridctl/agent.go:213-220` — defect site (JSON emit)
- `pkg/agent/dev/scaffold/scaffold.go:22-30` — `Result` struct definition
- `pkg/agent/dev/scaffold/scaffold.go:69` — uninitialized slices (recommended fix site)
- `cmd/gridctl/agent.go:326-345` — adjacent JSON emitters (`agentValidateReport`, `agentBuildReport`) demonstrating the `omitempty` pattern that keeps them safe
- `cmd/gridctl/agent_test.go:146-159` — `resetAgentInitFlagsForTest` (where the format-json test gap originates)
- `proto/agent-runtime/TEST.md:65-71` — the documented JSON contract this bug violates
- Go `encoding/json` docs on slice marshaling: nil slices encode as `null`, non-nil empty slices encode as `[]`
