# Bug Fix: Cost Persistence and Replay

## Context

`gridctl` is a Go-based MCP gateway that aggregates multiple downstream MCP servers behind a single endpoint. It exposes a Web UI (Vite + React, under `web/`) that talks to the daemon's HTTP API (`internal/api/api.go`). One key panel is the **Metrics tab** — token usage + cost over time, KPI cards, per-server and per-client breakdowns.

Telemetry persistence is opt-in per server (`persist_metrics: true` in stack config) and writes per-server `metrics.jsonl` files under `~/.gridctl/telemetry/<stack>/<server>/`. On daemon startup, those files are read back so the in-memory accumulator (`pkg/metrics.Accumulator`) reflects pre-restart state — both cumulative counters (KPI cards) and per-minute time-series ring buffers (charts).

The cost layer (`pkg/metrics/accumulator.go` `RecordCost`, `Snapshot`/`CostSnapshot`, `QueryCost`) was added incrementally:
- PR #565 `4347130` — in-memory cost recording + atomics + ring buckets
- PR #566 `2c88d85` — per-client cost attribution + cost API
- PR #567 `e772fcd` — Web UI cost surfaces (Cost KPI, Cost Over Time chart, Top Clients panel) — shipped 2026-05-07

Token persistence/replay was added in PR #563 `519cd76` ("fix: telemetry persistence write and seed gaps") with explicit care for "pre-restart history continuously alongside live data." This bug is that the cost path was never extended to match.

## Investigation Context

- Root cause confirmed: persistence pipeline (`pkg/telemetry/metrics.go`) and accumulator restore/replay (`pkg/metrics/accumulator.go`) handle tokens only. `MetricsSnapshotLine` has no cost fields; `flushOnce` doesn't read `CostSnapshot()`; `SeedFromFile` doesn't replay cost; `Restore`/`ReplaySnapshot` have no cost variants.
- Symptom is silent: after restart, Cost KPI reads `$0.00` and Cost Over Time chart renders dots at `$0` (because token-replay-populated buckets carry `costMicroUSD = 0`). No log warning.
- Reproduction confirmed: any restart of any daemon with `persist_metrics: true` plus priced calls drops all cost data.
- Risk mitigations: schema change must remain backward-compatible (old token-only `metrics.jsonl` files keep parsing); cost diffs must persist as int64 micro-USD to preserve precision; cost-only minutes must not be skipped by the token-zero gate at `pkg/telemetry/metrics.go:242`.
- Full investigation: `~/code/prompt-stack/prompts/gridctl/cost-persistence-replay/bug-evaluation.md`

## Bug Description

After daemon restart with `persist_metrics: true`, all cost data accumulated before the restart is silently lost.

- The Cost KPI card shows `$0.00` (or `—` when `costUsage` is `null`)
- The Cost Over Time chart renders dots aligned to token timestamps but stuck at the $0 baseline
- Per-server cost columns and per-client cost columns are zero/missing
- Same minutes show non-zero token totals (token persistence works)

This is a regression against the user-visible expectation set by PR #563: pre-restart history should display continuously alongside live data. Cost shipped without the matching persistence/replay path.

## Root Cause

Four call sites are token-only and need cost equivalents:

1. **`pkg/telemetry/metrics.go:27-33`** — `MetricsSnapshotLine` schema:
   ```go
   type MetricsSnapshotLine struct {
       Time   time.Time            `json:"ts"`
       Server string               `json:"server"`
       Reset  bool                 `json:"reset,omitempty"`
       Diff   metrics.TokenCounts  `json:"diff"`
       Total  metrics.TokenCounts  `json:"total"`
   }
   ```
   No cost fields. Cost cannot serialize.

2. **`pkg/telemetry/metrics.go:205-283`** — `flushOnce` calls `f.acc.Snapshot()` (tokens only). `CostSnapshot()` is never read. Even if we added cost fields to the struct, they would always be zero on disk.

3. **`pkg/metrics/accumulator.go:1239-1248`** — `ReplaySnapshot(serverName, ts, inputTokens, outputTokens int64)`. No cost params. Calls `addToBucket` + `addToServerBucket` (tokens only). No `addCostToBucket`/`addCostToServerBucket` call.

4. **`pkg/metrics/accumulator.go:1199-1224`** — `Restore(perServer map[string]TokenCounts)`. Restores `sessionInput`/`sessionOutput` and per-server `inputTokens`/`outputTokens` atomic counters. Cost atomics (`sessionInputCostMicroUSD`/`sessionOutputCostMicroUSD`/`sessionCacheReadCostMicroUSD`/`sessionCacheWriteCostMicroUSD` at `pkg/metrics/accumulator.go:290-293` and per-server `inputCostMicroUSD`/`outputCostMicroUSD`/`cacheReadCostMicroUSD`/`cacheWriteCostMicroUSD` at `pkg/metrics/accumulator.go:178-181`) stay at zero.

## Fix Requirements

### Required Changes

1. **Extend `MetricsSnapshotLine`** at `pkg/telemetry/metrics.go:27` with optional cost fields. Use `omitempty` so old files without cost continue to parse and new files without cost activity stay compact.
   - Persist cost as the 4-component `CostBreakdown` (Input / Output / CacheRead / CacheWrite) using int64 micro-USD per component (matching the in-memory atomic representation; preserves precision). Add a small typed struct, e.g., `CostMicroUSDCounts`, to keep the line schema readable.
   - Add `CostDiff` and `CostTotal` fields with `omitempty` semantics — when all four components are zero, the field omits cleanly.
   - Document the schema choice in a comment block alongside the existing `MetricsSnapshotLine` comment.

2. **Update `flushOnce`** at `pkg/telemetry/metrics.go:205` to:
   - Call `f.acc.CostSnapshot()` alongside `f.acc.Snapshot()`
   - Track `prevCost` per server in addition to `prev` (extend `MetricsFlusher.prev` shape OR add a parallel `prevCost map[string]<components>` map under the same mutex)
   - Compute the cost diff per server analogously to the token diff (handle reset via `isCostCounterReset` mirroring `isCounterReset` at `pkg/telemetry/metrics.go:288-292`)
   - Skip the line only when **both** the token diff and the cost diff are zero — change the gate at `pkg/telemetry/metrics.go:242-244` accordingly
   - Populate `CostDiff`/`CostTotal` on the planned line; on a reset line set `CostDiff = currentCost`

3. **Add `Accumulator.RestoreCost`** in `pkg/metrics/accumulator.go` near `Restore` (around `:1199`):
   - Signature: `RestoreCost(perServer map[string]CostMicroUSDCounts)` (or whatever struct PR adds in step 1, used symmetrically)
   - For each server, write the four per-component atomics on `serverCounters` (`inputCostMicroUSD`/`outputCostMicroUSD`/`cacheReadCostMicroUSD`/`cacheWriteCostMicroUSD`)
   - After populating per-server, recompute session totals as the sum across all servers (matching `Restore`'s invariant on tokens) and store on `sessionInputCostMicroUSD`/`sessionOutputCostMicroUSD`/`sessionCacheReadCostMicroUSD`/`sessionCacheWriteCostMicroUSD`
   - Document that format-savings has no cost equivalent (no-op there)

4. **Extend `Accumulator.ReplaySnapshot`** at `pkg/metrics/accumulator.go:1239` (or add a sibling `ReplayCostSnapshot`) to populate cost buckets:
   - Preferred: extend the existing function so token + cost replay stays a single call site in `SeedFromFile`. Signature suggestion: `ReplaySnapshot(serverName string, ts time.Time, inputTokens, outputTokens int64, costMicro int64)` where `costMicro` is the *total* (sum of components) — mirrors `addCostToBucket(now, totalMicro)` at `pkg/metrics/accumulator.go:570`. Bucket cost is rolled up; component split lives only on the cumulative atomics.
   - Inside, after `addToBucket`/`addToServerBucket`, call `addCostToBucket(bucket, costMicro)` and `addCostToServerBucket(serverName, bucket, costMicro)` when `costMicro != 0`.
   - Update the doc comment to mention cost.
   - Acceptable alternative: keep `ReplaySnapshot` token-only and add a sibling `ReplayCostSnapshot(serverName, ts, costMicro)` called immediately after `ReplaySnapshot` in `SeedFromFile`. Slightly more verbose but avoids the param creep.

5. **Update `SeedFromFile`** at `pkg/telemetry/metrics.go:315`:
   - Parse the new `CostDiff`/`CostTotal` fields from `MetricsSnapshotLine`
   - Build a `latestCost map[string]<components>` alongside `latest`
   - Build `series` entries that carry the cost total (sum of components) so `ReplaySnapshot` can hydrate cost buckets
   - Call `f.acc.RestoreCost(latestCost)` after `f.acc.Restore(latest)`
   - Seed `f.prevCost` (or whatever shape step 2 chose) under the lock so the first post-seed `flushOnce` produces a clean diff against the seeded baseline (no double-count, no reset)
   - Skip Reset lines for the cost time-series replay too — same reason as tokens (Reset Diff is a full carryover, replaying would create a synthetic spike)

6. **Add regression tests** (see "Regression Test" below).

7. **CHANGELOG.md** — add a `fix:` line in the Unreleased section noting the persistence-format extension and the user-visible fix. Keep it short, e.g.:
   > - **Fix:** Cost data now persists across daemon restarts. Previously the cost KPI and Cost Over Time chart silently reset to $0 after restart even when pre-restart cost was non-zero. The on-disk `metrics.jsonl` schema is extended additively (cost fields are `omitempty`) and remains forward-compatible with files written by older versions.

### Constraints

- **Backward-compatible reads**: a `metrics.jsonl` file written by the current daemon (token-only) MUST continue to load via `SeedFromFile` without warnings, parse errors, or partial restore. Cost atomics simply remain zero in that case (correct behavior — there is no historical cost to restore).
- **Forward-compatible reads**: a file written by the patched daemon MUST be parseable by the current `MetricsSnapshotLine` struct (older daemons should silently ignore the new cost fields; verify with a small unit test that round-trips a new-format line through the old struct).
- **No double-counting**: `Restore` + `RestoreCost` must restore atomics exactly once; subsequent live recording must accumulate on top, and the next `flushOnce` must emit a real diff (not a reset, not a re-flush of the seeded total). Mirror the existing token invariant covered by `TestEndToEnd_MetricsPersistAndReseed` at `pkg/telemetry/seed_test.go:155`.
- **Precision**: persist cost as int64 micro-USD on disk. Do not serialize as float64 USD.
- **No additional flushes**: do not change the flush cadence or add a second writer. Cost rides the existing token flush cycle.
- **No new public packages**. Keep changes inside `pkg/metrics` and `pkg/telemetry`.

### Out of Scope

- Per-client cost persistence (`clientBufs`, `pkg/metrics/accumulator.go:273-274`). The persistence layer is keyed by server today; per-client cost over time is reconstructed live from the in-memory ring. Adding per-client persistence is a bigger schema change and a separate PR — note in a comment so the next persistence PR doesn't repeat the omission.
- UI changes. The fix is server-side; the existing chart will populate correctly once the API returns historical cost. Do not modify `web/`.
- Telemetry inventory format (`pkg/telemetry/inventory.go`). The "persisted from" marker reads file modtimes — unrelated.
- Format-savings persistence (deliberately not persisted today per `pkg/metrics/accumulator.go:1196-1198` comment).

## Implementation Guidance

### Key Files to Read

- `pkg/telemetry/metrics.go` — full file. Read top-to-bottom: schema, flusher state, `flushOnce`, `SeedFromFile`. The fix mirrors `flushOnce`'s token logic for cost and extends `SeedFromFile` symmetrically.
- `pkg/metrics/accumulator.go:1199-1248` — `Restore` and `ReplaySnapshot` functions. Comment blocks above each explain the user-visible contract; the cost equivalents must satisfy the same contract.
- `pkg/metrics/accumulator.go:521-575` — `RecordCost` / `RecordCostWithClient`. Confirms how cost atomics + cost buckets are populated live, which `RestoreCost` and the extended `ReplaySnapshot` must reproduce on disk.
- `pkg/metrics/accumulator.go:158-167` — `bucket` struct (cost field is `costMicroUSD int64`).
- `pkg/metrics/accumulator.go:178-194` — `serverCounters` and `replicaCounters` cost components. Replicas are not persisted; ignore them.
- `pkg/telemetry/seed_test.go:155-249` — `TestEndToEnd_MetricsPersistAndReseed`. The new cost test mirrors this exactly.
- `pkg/telemetry/metrics_test.go` — existing flush + reset + reseed unit tests. New cost assertions slot in here.
- `pkg/controller/gateway_builder.go:280-301` — `seedMetricsFromDisk`. Confirms the call site that triggers `SeedFromFile` on startup. No changes needed in this file.
- The existing token-replay PR `519cd76` (`git show 519cd76`) — reference implementation. The cost PR should look stylistically identical.

### Files to Modify

| File | Change |
|------|--------|
| `pkg/telemetry/metrics.go` | Extend `MetricsSnapshotLine`; update `flushOnce`; update `SeedFromFile`; add `prevCost` tracking and `isCostCounterReset` helper |
| `pkg/metrics/accumulator.go` | Add `RestoreCost`; extend `ReplaySnapshot` (or add `ReplayCostSnapshot`); export a `CostMicroUSDCounts` struct (or reuse an existing shape) for the `RestoreCost` parameter |
| `pkg/telemetry/metrics_test.go` | Add unit tests: cost diff written on flush; cost reset semantics; backward-compat read of token-only files |
| `pkg/telemetry/seed_test.go` | Add `TestEndToEnd_CostPersistAndReseed` |
| `pkg/metrics/accumulator_test.go` (or wherever `Restore` is unit-tested) | Add `TestAccumulator_RestoreCost` and `TestAccumulator_ReplaySnapshot_Cost` |
| `CHANGELOG.md` | Add fix line under Unreleased |

### Reusable Components

- `bucketKey(t time.Time)` (`pkg/metrics/accumulator.go:154`) — already used by `ReplaySnapshot`. Reuse for cost.
- `addCostToBucket` and `addCostToServerBucket` (`pkg/metrics/accumulator.go:636`, `:711`) — already exist for the live `RecordCost` path. Reuse from the extended replay function.
- `usdToMicro` / `microToUSD` (`pkg/metrics/accumulator.go:123`, `:130`) — keep persistence in micro-USD; do not introduce new conversion helpers.
- `isCounterReset` (`pkg/telemetry/metrics.go:288`) — model the new `isCostCounterReset` after this function (a strictly-less check on any of the four components).

### Conventions to Follow

- File-level `// Package` and function-level `// FuncName` doc comments are required and detailed in this codebase. Match the existing tone (operational reasoning, not boilerplate). The `Restore`/`ReplaySnapshot` comment blocks at `pkg/metrics/accumulator.go:1189-1238` are good models — explain the user-visible contract, not just the mechanics.
- Tests use `testing.T` directly (no testify, no ginkgo). Look at `pkg/telemetry/seed_test.go` for style: descriptive failure messages with both got/want values.
- Use `t.Run` subtests sparingly — the existing tests favor flat top-level functions named `Test<Subject>_<Behavior>`.
- Keep imports grouped: stdlib, third-party, internal — separated by blank lines.
- Atomic counter writes use `.Store(value)` (not `.Add` for `Restore` — which sets state, not adds to it). Matches `Restore`'s existing pattern.

## Regression Test

### Test Outline

**Test 1: end-to-end cost persist and reseed** — add to `pkg/telemetry/seed_test.go`:

```go
// TestEndToEnd_CostPersistAndReseed mirrors TestEndToEnd_MetricsPersistAndReseed
// for cost. After daemon restart, both cumulative cost (CostKPI) and the cost
// time-series ring (Cost Over Time chart) should reflect pre-restart spend.
func TestEndToEnd_CostPersistAndReseed(t *testing.T) {
    dir := t.TempDir()
    path := filepath.Join(dir, "metrics.jsonl")

    // Instance 1: record token + cost across two flushes
    acc1 := metrics.NewAccumulator(100)
    f1 := NewMetricsFlusher(acc1, time.Hour)
    if err := f1.AddServer("github", path, LogOpts{}); err != nil { t.Fatalf("AddServer: %v", err) }

    acc1.Record("github", 100, 50)
    acc1.RecordCost("github", -1, metrics.CostBreakdown{Input: 0.05, Output: 0.10})
    f1.flushOnce(time.Now())

    acc1.Record("github", 25, 10)
    acc1.RecordCost("github", -1, metrics.CostBreakdown{Input: 0.02, Output: 0.04, CacheRead: 0.01})
    f1.flushOnce(time.Now())

    // Close instance 1 writers
    f1.mu.Lock()
    for _, lj := range f1.writers { _ = lj.Close() }
    f1.mu.Unlock()

    // Instance 2: reseed
    acc2 := metrics.NewAccumulator(100)
    f2 := NewMetricsFlusher(acc2, time.Hour)
    if err := f2.AddServer("github", path, LogOpts{}); err != nil { t.Fatalf("AddServer: %v", err) }
    if err := f2.SeedFromFile(path, 100); err != nil { t.Fatalf("SeedFromFile: %v", err) }

    // Cumulative cost: 0.05 + 0.10 + 0.02 + 0.04 + 0.01 = 0.22
    cs := acc2.CostSnapshot()
    wantTotal := 0.05 + 0.10 + 0.02 + 0.04 + 0.01
    if !approxEq(cs.Session.TotalUSD, wantTotal) {
        t.Errorf("seeded session cost = %.6f; want %.6f", cs.Session.TotalUSD, wantTotal)
    }
    if !approxEq(cs.PerServer["github"].TotalUSD, wantTotal) {
        t.Errorf("seeded github cost = %.6f; want %.6f", cs.PerServer["github"].TotalUSD, wantTotal)
    }

    // Time-series cost: only the second flush's diff should appear (Reset is skipped),
    // analogous to the token assertion in TestEndToEnd_MetricsPersistAndReseed.
    ts := acc2.QueryCost(time.Hour)
    points := ts.PerServer["github"]
    if len(points) == 0 {
        t.Errorf("github cost time-series points = 0 after seed; chart would be empty")
    }
    var seriesUSD float64
    for _, p := range points { seriesUSD += p.USD }
    wantSeries := 0.02 + 0.04 + 0.01 // second flush diff only
    if !approxEq(seriesUSD, wantSeries) {
        t.Errorf("seeded cost series total = %.6f; want %.6f (only the non-reset Diff)", seriesUSD, wantSeries)
    }

    // Live activity post-restart: next flush emits a real cost diff, no reset.
    acc2.RecordCost("github", -1, metrics.CostBreakdown{Input: 0.001, Output: 0.002})
    f2.flushOnce(time.Now())
    data, err := os.ReadFile(path)
    if err != nil { t.Fatalf("read: %v", err) }
    lines := splitNonEmpty(string(data))
    var last MetricsSnapshotLine
    if err := json.Unmarshal([]byte(lines[len(lines)-1]), &last); err != nil { t.Fatalf("unmarshal: %v", err) }
    if last.Reset { t.Errorf("post-seed cost flush emitted reset=true") }
    // Assert last.CostDiff sums to ~0.003 (whatever the chosen schema field is named)
}
```

**Test 2: backward-compat read of token-only files** — add to `pkg/telemetry/metrics_test.go`:

```go
// TestSeedFromFile_LegacyTokenOnly verifies that metrics.jsonl files written
// before cost persistence shipped (no CostDiff / CostTotal fields) continue
// to load cleanly. Token state restores; cost state stays zero.
func TestSeedFromFile_LegacyTokenOnly(t *testing.T) {
    // Hand-write the OLD format (no cost fields) to a file...
    // Call SeedFromFile, assert no error.
    // Assert acc.Snapshot().Session.TotalTokens matches the persisted total.
    // Assert acc.CostSnapshot().Session.TotalUSD == 0.
}
```

**Test 3: unit tests for the new accumulator surface** — add to whatever file currently tests `Restore` and `ReplaySnapshot`:

- `TestAccumulator_RestoreCost`: build an accumulator, call `RestoreCost` with a known map, assert all four per-component atomics + session totals match.
- `TestAccumulator_ReplaySnapshot_Cost` (or `TestAccumulator_ReplayCostSnapshot`): replay a known cost into a known timestamp, then `QueryCost` and assert the bucket lands at the right minute with the right total.

### Existing Test Patterns

- Tests live in `_test.go` files alongside the implementation.
- File-scoped helpers (e.g., `splitNonEmpty`, `writeMetricsLine`) are already defined in `seed_test.go` and `metrics_test.go` — reuse them.
- Float comparisons in cost tests must allow for the int64 ↔ float64 round-trip via `usdToMicro`/`microToUSD`. A small `approxEq(got, want, eps)` helper with `eps = 1e-9` covers it (or reuse `math.Abs(got-want) < 1e-9` inline). Do not introduce a new dependency.
- Package import group: stdlib, then `github.com/gridctl/gridctl/...`, then any external. Match existing files.

## Potential Pitfalls

- **Skip-zero gate at `pkg/telemetry/metrics.go:242-244`** is currently `if line.Diff.InputTokens == 0 && line.Diff.OutputTokens == 0 && line.Diff.TotalTokens == 0 { continue }`. Change to also test cost diff being zero — otherwise a minute with a priced fixture but zero token attribution would fail to flush. After the change: skip only if **both** token diff is zero AND cost diff is zero across all four components.
- **Reset detection** today only inspects token counters (`isCounterReset`). A monotonic cost can in principle drop if `ClearCost` is invoked or if a server is removed and re-added. Mirror the token detection: any of the four cost components going strictly down indicates a reset. Use `isTokenCounterReset(...) || isCostCounterReset(...)` to set `line.Reset = true`.
- **Flusher state shape**: `MetricsFlusher.prev map[string]metrics.TokenCounts` carries the previous *token* snapshot. Adding `prevCost` as a parallel map is the cleanest extension — both are guarded by `f.mu`. Avoid widening the value type to a struct holding both; that would force a partial-update race window during seeding (token written before cost or vice versa). Two parallel maps update independently under the same lock and stay consistent for the next flush.
- **Schema field naming**: pick names that make `omitempty` behave as intended for legacy compatibility. JSON `omitempty` for struct-typed fields requires the struct to be the zero value — use a pointer (`*CostMicroUSDCounts`) **or** a value type with an explicit `IsZero()` check before setting. Pointer is simpler. Names like `cost_diff` / `cost_total` (snake_case JSON, matching the existing `diff` / `total` style) read consistently with the existing schema.
- **Bucket replay rollup**: live `RecordCost` calls `addCostToBucket(now, totalMicro)` with the *sum* of the four components — not the breakdown. Replay should match. Cost component split lives only on the cumulative atomics (`RestoreCost`), not on the time-series ring. This is consistent and correct; do not try to preserve per-component cost on the bucket.
- **Per-replica cost** (`replicaCounters.inputCostMicroUSD` etc., `pkg/metrics/accumulator.go:191-194`): not persisted today, same as per-replica tokens. Stay symmetric — do not start persisting replica cost in this PR.
- **Per-client cost ring** (`a.clientBufs`, `pkg/metrics/accumulator.go:273-274`): not persisted today. Stay symmetric. The Top Clients UI reads from in-memory `CostSnapshot().PerClient` — that's the cumulative path, which `RestoreCost` does not touch (per-client atomics are a separate map). Restoring per-client cost is a follow-up PR; out of scope here, but note it in a code comment so it isn't forgotten.

## Acceptance Criteria

1. `MetricsSnapshotLine` carries optional cost fields. New files written by the patched daemon include cost when non-zero; legacy files (no cost fields) parse without warnings.
2. After a restart with priced calls in the persisted file, `acc.CostSnapshot().Session.TotalUSD` equals the pre-restart sum (down to `1e-9` tolerance) — covered by `TestEndToEnd_CostPersistAndReseed`.
3. After the same restart, `acc.QueryCost(time.Hour).PerServer[serverName]` returns non-zero `USD` totals matching the second-flush diff (Reset diff is skipped, mirroring tokens) — covered by the same test.
4. The first post-seed `flushOnce` emits a `MetricsSnapshotLine` whose `CostDiff` reflects only the post-restart cost activity (not the seeded baseline), and `Reset` is `false`.
5. Legacy token-only files load cleanly via `SeedFromFile` with `acc.CostSnapshot().Session.TotalUSD == 0` and no error logged — covered by `TestSeedFromFile_LegacyTokenOnly`.
6. `flushOnce` writes a line for any minute where **either** token diff is non-zero OR cost diff is non-zero (no longer skipped on token-zero alone).
7. `Accumulator.RestoreCost` populates per-server cost atomics for all four components and recomputes session totals as their sum — covered by `TestAccumulator_RestoreCost`.
8. `Accumulator.ReplaySnapshot` (or sibling `ReplayCostSnapshot`) populates `costMicroUSD` on the aggregate and per-server buckets at the correct minute key — covered by `TestAccumulator_ReplaySnapshot_Cost`.
9. `go test ./pkg/metrics/... ./pkg/telemetry/... -race` passes locally.
10. `golangci-lint run` and `go build ./...` pass.
11. CHANGELOG.md gains a `fix:` entry under Unreleased referencing this fix.
12. No `web/` changes — fix is server-side only.

## References

- Investigation: `~/code/prompt-stack/prompts/gridctl/cost-persistence-replay/bug-evaluation.md`
- Reference PR for shape and style: `git show 519cd76` (token persistence + replay)
- Cost layer foundation: `git show 4347130`
- Cost UI: `git show e772fcd`
- Comment block setting the user-visible contract for replay: `pkg/metrics/accumulator.go:1226-1238` ("Used by telemetry.MetricsFlusher.SeedFromFile to rehydrate per-minute bucket history from each persisted Diff line — the chart shows pre-restart activity continuously alongside live data instead of resetting to a single post-restart point.")
