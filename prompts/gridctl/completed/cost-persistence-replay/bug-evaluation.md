# Bug Investigation: Cost Persistence and Replay

**Date**: 2026-05-07
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Medium

## Summary

Cost data — both cumulative counters and per-minute time-series buckets — is never written to the on-disk metrics persistence file and never rehydrated on daemon restart. The cost layer (PR #565 `4347130`) and cost UI surfaces (PR #567 `e772fcd`, shipped 2026-05-07) ship without the matching persistence/replay path that token persistence (PR #563 `519cd76`) added explicitly. After any restart the Cost KPI and Cost Over Time chart silently misrepresent pre-restart spend as `$0`. Fix is additive and symmetric to the existing token implementation.

## The Bug

**Defect**: After a daemon restart with `persist_metrics: true`, all cost data accumulated before the restart is silently lost. The Cost KPI card shows `$0.00` (or `—` when `costUsage` is `null`), the Cost Over Time chart renders dots at the y=0 line, and per-server / per-client cost columns read zero — even when the *same* persisted minutes show non-zero token totals.

**Expected behavior**: Mirror token persistence. The Cost KPI should show the pre-restart cumulative total. The Cost Over Time chart should show pre-restart hourly cost continuously alongside live data, the same way the Token Usage Over Time chart does (designed-for behavior per `pkg/metrics/accumulator.go:1226-1238`).

**How it was discovered**: User reported "Lines and data are no longer showing up on the graph for persistent data" on the Metrics tab after a restart. Investigation confirmed the cost path is structurally absent from persistence. The reporter's specific data file had `$0` cost so the symptom was latent in their screenshots, but a regression test would surface it immediately for any priced call followed by a restart.

## Root Cause

### Defect Location

The persistence pipeline handles tokens but not cost across four call sites:

- `pkg/telemetry/metrics.go:27-33` — `MetricsSnapshotLine` schema has only `TokenCounts` for `Diff` and `Total`. No cost fields.
- `pkg/telemetry/metrics.go:205-283` — `flushOnce` snapshots tokens (`f.acc.Snapshot()`) but never reads `CostSnapshot()`. Nothing ever writes cost to disk.
- `pkg/metrics/accumulator.go:1239-1248` — `ReplaySnapshot(serverName, ts, inputTokens, outputTokens)` has no cost parameters and never calls `addCostToBucket` / `addCostToServerBucket`.
- `pkg/metrics/accumulator.go:1199-1224` — `Restore(perServer map[string]TokenCounts)` only handles tokens. There is no `RestoreCost` function. Cumulative cost atomic counters (`sessionInputCostMicroUSD`, etc., `pkg/metrics/accumulator.go:290-293`) and per-server cost counters (`pkg/metrics/accumulator.go:178-181`) are never restored.

### Code Path

Live cost recording (works correctly):
1. Tool call lands → `RecordCostWithClient` (`pkg/metrics/accumulator.go:529`)
2. Updates session/per-server/per-client cost counters
3. Writes cost to bucket: `addCostToBucket(now, totalMicro)` and `addCostToServerBucket`

Persist (broken — cost never reaches disk):
1. `flushOnce` ticks every `DefaultMetricsFlushInterval` (60s, `pkg/telemetry/metrics.go:20`)
2. Snapshots tokens only via `f.acc.Snapshot()` (`pkg/telemetry/metrics.go:209`)
3. Writes `MetricsSnapshotLine` with `Diff: TokenCounts{...}` — cost fields don't exist on the struct, so they cannot be serialized

Restart + rehydrate (broken — cost never replayed):
1. `seedMetricsFromDisk` (`pkg/controller/gateway_builder.go:286`) calls `f.telemetry.metricsFlusher.SeedFromFile`
2. `SeedFromFile` (`pkg/telemetry/metrics.go:315`) parses NDJSON, builds `series` with token diffs only, calls `ReplaySnapshot(server, ts, input, output)` per line
3. `Restore(latest)` is called with token-only `TokenCounts` map; cost atomics remain zero

Query (renders incorrect data):
1. `QueryCost` (`pkg/metrics/accumulator.go:967-1014`) reads `costMicroUSD` from buckets
2. Token replay populated buckets with `costMicroUSD = 0` (the default for the bucket struct), so each bucket emits a `CostDataPoint{USD: 0}` at the right timestamp — visually a dot at $0 instead of an empty point
3. `CostSnapshot()` reads atomic counters that were never restored; emits zeros

### Why It Happens

PR #563 (`519cd76`, "fix: telemetry persistence write and seed gaps") deliberately added `Restore` for cumulative tokens and `ReplaySnapshot` for token time-series so the chart "shows pre-restart history continuously alongside live data instead of resetting to a single post-restart point" (comment at `pkg/metrics/accumulator.go:1228-1230`).

PR #565 (`4347130`, "feat: cost layer foundation") added cost atomics + cost buckets + `RecordCost` + `QueryCost` — but only the *live recording* path. PR #566 (`2c88d85`) and PR #567 (`e772fcd`) wired cost to the API and the UI.

None of these PRs extended `MetricsSnapshotLine`, `flushOnce`, `SeedFromFile`, `Restore`, or `ReplaySnapshot` to carry cost. The persistence code remains token-shaped while the in-memory accumulator is now token+cost shaped — a structural asymmetry.

### Similar Instances

- The same asymmetry exists for **per-client cost** if/when per-client persistence is added later. Currently per-client is not in `MetricsSnapshotLine` at all (the file is keyed by server). Out of scope for this fix, but worth flagging in a comment so the next persistence PR doesn't repeat the omission.
- Cost ring buffer for clients (`clientBufs`, `pkg/metrics/accumulator.go:273-274`) is never persisted. Same structural omission as server cost — not fixed here, but should be tracked.

## Impact

### Severity Classification

High — silent data loss on a just-shipped, user-visible feature. Bug class: regression / data loss. Hits universally on any restart of any daemon with `persist_metrics: true` plus priced calls.

### User Reach

Every user adopting the cost feature shipped 2026-05-07. The cost UI just landed today (`e772fcd`); first restart loses all pre-restart cost. The cost-attribution table at `pkg/metrics/accumulator.go:179` shows cost has been recordable since 2026-05-05ish (PR #565 was merged before the fix-persistence PR). Anyone whose stack has been writing token persistence files since then has been silently dropping cost on every restart.

### Workflow Impact

Critical-path blocker for the stated PR #567 use case ("cost KPI, cost-over-time chart, top clients panel"). The Cost Over Time chart's value proposition is *historical* spend visualization — losing all history on restart defeats the feature. Top Clients also reads per-client cost; same issue.

### Workarounds

None. Users cannot opt into a different persistence path. Disabling `persist_metrics` would lose token history too. The only mitigation is "never restart the daemon," which is not a viable workaround.

### Urgency Signals

- Cost UI shipped today (2026-05-07). Adoption begins immediately.
- The token persistence PR (`519cd76`) was explicit that pre-restart history is a user-visible expectation; the cost PR violates that contract silently.
- Misleading rendering: token-only buckets emit `USD: 0` dots, which look like "the user genuinely spent $0 before the restart" — a faithful-looking lie that's harder to debug than an empty chart.
- No log warning when the gap fires; it just looks like the user did nothing priced before.

## Reproduction

### Minimum Reproduction Steps

1. Configure a stack with at least one server that has both `persist_metrics: true` and a model whose pricing is configured (so `RecordCost` increments).
2. Start `gridctl run` (or whatever subcommand starts the daemon).
3. Make at least one priced tool call. Confirm `/api/metrics/cost` returns non-zero data and the Cost KPI shows the spend.
4. Wait ≥ 60 seconds (so `flushOnce` runs at least once with non-zero diff) — or trigger a clean shutdown so the final flush runs.
5. Stop the daemon.
6. Start it again.
7. Open the Metrics tab.

### Affected Environments

Universal. The bug is in shared persistence/replay code (`pkg/telemetry`, `pkg/metrics`). Not OS- or runtime-specific.

### Non-Affected Environments

- Sessions with no restart — cost displays correctly while the daemon is alive.
- Sessions where no priced call ever happened pre-restart — no data to lose, so the bug isn't visible (this is the reporter's case).
- Stacks with `persist_metrics: false` — nothing persisted, so nothing to lose. Cost rebuilds from scratch each session.

### Failure Mode

Silent. Cost KPI reads `$0.00` (or `—`), Cost Over Time chart shows dots at y=0 aligned with token timestamps. No error, no log. Token chart and KPIs continue to work correctly — increasing the chance the user trusts the rendered cost as truth.

## Fix Assessment

### Fix Surface

- `pkg/telemetry/metrics.go` — extend `MetricsSnapshotLine` with optional cost fields (`omitempty` to keep old token-only files parseable); update `flushOnce` to read `CostSnapshot()` and emit cost diffs; update `SeedFromFile` to feed cost into `Restore` + `ReplaySnapshot`.
- `pkg/metrics/accumulator.go` — extend `ReplaySnapshot` (or add `ReplayCostSnapshot`) to populate cost buckets; extend `Restore` (or add `RestoreCost`) to restore cumulative cost atomics for session and per-server.
- `pkg/telemetry/seed_test.go` — add `TestEndToEnd_CostPersistAndReseed` mirroring the existing token e2e test.
- `pkg/telemetry/metrics_test.go` — extend the unit tests covering `MetricsSnapshotLine` round-tripping and `flushOnce` to assert cost is written.
- `pkg/metrics/accumulator_test.go` (or wherever `Restore`/`ReplaySnapshot` are tested) — add the cost-replay unit tests.
- `CHANGELOG.md` — note the persistence-format extension and the user-visible fix.

### Risk Factors

- **Backward-compatible reads**: existing token-only files must continue to load. Solved by making the cost fields `omitempty` — JSON unmarshal yields zeroes which map cleanly to "no pre-restart cost," matching today's effective behavior.
- **Forward-compatible writes**: new files written by the patched daemon must not crash older daemons. They won't — older daemons unmarshal `MetricsSnapshotLine` and silently ignore unknown fields. (Verify by attempting to parse a new file with the old struct; expect tokens to round-trip cleanly.)
- **Cost-only minutes**: in tests `RecordCost` can fire without `Record` (a fixture priced without token attribution). The flush path must not skip such minutes just because the *token* diff is zero. This already is gated by a token-only zero check at `pkg/telemetry/metrics.go:242` — must change to also consider cost diff.
- **Atomic accuracy**: cost is stored as int64 micro-USD on the wire and in atomics; serializing as float USD on disk would lose precision. Persist micro-USD (or stick with the same `CostBreakdown` shape `RecordCost` accepts) to keep round-trip accuracy.
- **Component split**: `RecordCost` accepts a 4-component `CostBreakdown` (Input/Output/CacheRead/CacheWrite). The persistence layer can either preserve the split (faithful but bulkier) or persist the rolled-up total (cheaper but loses the cost-attribution breakdown for `CostSnapshot.Session.InputUSD` etc.). Recommend preserving the split — `Restore` rebuilds the per-component atomics directly, matching what `CostSnapshot()` reads.
- **Reset semantics**: cost should follow the same Reset/Diff convention as tokens. First line per-server is Reset with full cost snapshot; subsequent lines carry diffs.

### Regression Test Outline

Two new tests:

1. **End-to-end cost persist + reseed** (`pkg/telemetry/seed_test.go`):
   - Build accumulator + flusher (`time.Hour` interval, drive `flushOnce` manually)
   - Record token + cost (`Record` + `RecordCost` with non-zero `CostBreakdown`)
   - `flushOnce` once
   - More token + cost
   - `flushOnce` again
   - Construct fresh accumulator + flusher; `SeedFromFile`
   - Assert `CostSnapshot().Session.TotalUSD == sum of recorded costs`
   - Assert `QueryCost(time.Hour).Points` has `USD > 0` summing to the second-flush diff
   - Record one more priced call, `flushOnce`, assert next on-disk line has correct cost diff and is not a Reset

2. **Backward-compat read** (`pkg/telemetry/metrics_test.go`):
   - Hand-write a `metrics.jsonl` line in the *old* format (no cost fields)
   - `SeedFromFile`
   - Assert `Restore` succeeded for tokens and `CostSnapshot()` returns zero (legacy file = no cost history, expected)
   - Assert no parse errors logged

## Recommendation

**Fix immediately.** Severity-High, Risk-Low, Confidence-High, Complexity-Medium. The fix is additive, symmetric to existing token persistence, and structurally clear.

Land as a single PR mirroring `519cd76` ("fix: telemetry persistence write and seed gaps") — the same author, the same files, the same shape. Title suggestion: `fix: persist and replay cost data alongside tokens`.

Optionally bundle a small UX touch in the same PR: when `costData.data_points.length === 0` but `metricsData.data_points.length > 0` *and* a persisted-from marker is showing, render a one-line note ("Cost data not available for persisted history") so users with mid-stream restarts during the rollout window understand the gap. Out of scope if it adds friction; the underlying bug fix is the value.

## References

- PR #563 `519cd76` — token persistence write + seed gaps fix; the model this fix should mirror
- PR #565 `4347130` — cost layer foundation (in-memory only)
- PR #567 `e772fcd` — cost UI surfaces (Cost KPI, Cost Over Time, Top Clients) shipped 2026-05-07
- `pkg/metrics/accumulator.go:1226-1238` — comment block explaining the user-visible expectation that pre-restart history shows continuously
- User screenshot — Metrics tab on 7d view showing 1 token point + 1 cost dot at $0; on-disk verification at `~/.gridctl/telemetry/daily/atlassian/metrics.jsonl` confirms the chart render is faithful for tokens (only 2 active minutes were flushed) but cost is structurally absent
