# Bug Investigation: Telemetry Persistence Write & Seed Failures

**Date**: 2026-05-06
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

The telemetry persistence feature shipped in v0.1.0-beta.8 (issue #550) is broken in two independent places: log write fan-out is silently skipped due to an attribute-key mismatch, and the metrics signal has no seed-from-disk implementation at all. Together they nullify the feature's headline acceptance criterion ("Restart with persistence on seeds the Logs/Metrics/Traces tabs with pre-restart data on first load"). Both fixes are small, low-risk, and high-confidence; ship them together in v0.1.0-beta.9 before any v0.2 stable cut.

## The Bug

With per-server telemetry persistence toggled ON for all four servers (atlassian, github, gitlab, zapier), the user observed the Metrics tab showing "No token data yet" after restarting the gridctl daemon. Inspection of the on-disk telemetry directory (`~/.gridctl/telemetry/daily/{server}/`) revealed all twelve `.jsonl` files (4 servers × 3 signals) at exactly 0 bytes, all created at the same timestamp (daemon startup).

Expected: per-server `logs.jsonl`, `metrics.jsonl`, and `traces.jsonl` accumulate NDJSON entries during runtime; on daemon restart, the in-memory ring buffers backing the UI Logs/Metrics/Traces tabs are seeded from those files so users see pre-restart history on first load.

Actual: log files never receive records (stay 0 bytes); even when metrics records are written, they are never read back into the UI on restart.

The bug was discovered by the issue author themselves while testing the just-shipped feature.

## Root Cause

### Defect Location

Two independent defects:

**Bug A — log write path: attribute-key mismatch**
- Producer: `pkg/mcp/gateway.go:900`
- Router: `pkg/telemetry/logs.go:201-217` (`resolveComponent`)

**Bug B — metrics seed-from-disk missing**
- Missing method: would belong on `MetricsFlusher` in `pkg/telemetry/metrics.go`
- Missing call: would belong in `pkg/controller/gateway_builder.go` next to the existing `seedLogsFromDisk` (line 242) and `seedTracesFromDisk` (line 263)

### Code Path

**Bug A — log write trace:**

1. `pkg/mcp/gateway.go:900` — every per-server MCP client logger is constructed as:

   ```go
   clientLogger := g.logger.With("server", cfg.Name)
   ```

2. The gateway builder wires a `LogRouter` as the slog handler and registers each server (`pkg/controller/gateway_builder.go:528-643`).

3. When records arrive at the router, `LogRouter.Handle` calls `resolveComponent` (`pkg/telemetry/logs.go:201-217`):

   ```go
   record.Attrs(func(a slog.Attr) bool {
       if a.Key == "component" {
           component = a.Value.String()
           return false
       }
       return true
   })
   ```

   The resolver only inspects the `"component"` key. Records carry `"server"` instead, so `component` returns empty and no per-server file handler is selected. The record still lands in the inner buffer (UI live-tail keeps working), but the file fan-out is skipped.

4. The empty 0-byte files are explained by `touchMode0600` (`pkg/telemetry/metrics.go:296`, called from `MetricsFlusher.AddServer` and the equivalent log path) which creates the file at startup with mode 0600. After that, no producer ever writes to it.

**Bug B — metrics seed trace:**

1. On startup, `gateway_builder.go:195` calls `seedLogsFromDisk(...)` and `gateway_builder.go:499` calls `seedTracesFromDisk(...)`.
2. There is no `seedMetricsFromDisk(...)` anywhere in the file.
3. There is no `SeedFromFile` method on `MetricsFlusher` (compare `LogBuffer.SeedFromFile` at `pkg/logging/buffer.go:107` and `tracing.Buffer.SeedFromFile` at `pkg/tracing/buffer.go:235`).
4. The `metrics.Accumulator` (`pkg/metrics/accumulator.go`) exposes `Record`/`RecordReplica` (incremental) but no `Restore`/`SetTotals` for absolute hydration from disk.
5. Result: even when `metrics.jsonl` contains data, it is never read back, and the Metrics tab is empty after restart.

### Why It Happens

**Bug A**: Two contracts diverged silently. The canonical pattern in `pkg/telemetry/logs_test.go:35` is `logger.With("component", "github").Info(...)`, and the LogRouter was implemented to that contract. But the MCP gateway, which predates the LogRouter, has always tagged its per-server clients with `"server"` (`pkg/mcp/gateway.go:900`). The persistence implementation in #552 wired the router into the gateway without aligning the two attribute keys. There is no integration test in `pkg/controller/gateway_builder_test.go` that drives a real log through the actual gateway logger and asserts file content; the existing `logs_test.go` uses the canonical key directly and so passes.

**Bug B**: An implementation gap. The author wrote SeedFromFile + a startup seed call for logs and traces but did not write the equivalent for metrics. The reason is plausibly that metrics carry distinct semantics (cumulative counters vs. event records) and require an absolute `Restore` API on the accumulator that did not exist. The work was shipped without the missing piece, and `seed_test.go`'s `TestEndToEnd_PersistAndReseed` covers logs and traces but not metrics, so CI never noticed.

### Similar Instances

No other instances of either pattern. Both bugs are localized to the new telemetry persistence code paths added across PRs #551–#555.

## Impact

### Severity Classification

- Bug class: silent feature defect (no crash, no corruption, but advertised durability is fictional)
- Severity: **High** — this is the headline feature of v0.1.0-beta.8 and is referenced as a v0.2 stable gate. Not Critical because it is opt-in and does not affect users who haven't enabled persistence.

### User Reach

Every user who opts into telemetry persistence is affected. Because v0.1.0-beta.8 just shipped and the feature is opt-in, the absolute number of affected users is small today, but it includes every early adopter who specifically enabled persistence to evaluate it — i.e., the highest-signal early-adopter cohort.

### Workflow Impact

Core path failure. Both demand segments named in issue #550 are fully blocked:
- **Indie devs debugging MCP failures**: log files are 0 bytes, so post-mortem investigation after a crash has no data.
- **Enterprise audit/compliance**: metrics history is silently lost on every daemon restart, and log files are durable in name only.

### Workarounds

Limited and unsatisfactory:
- Disable persistence (negates the feature).
- Use `gridctl telemetry tail` directly on disk files — but logs.jsonl is empty, so this only mitigates the metrics-seed gap.
- Run an OTel collector sidecar — heavyweight, out of scope for indie users.

### Urgency Signals

- Beta-8 just shipped (yesterday relative to investigation date) advertising this feature in the changelog.
- v0.2 stable explicitly references this feature as a gate.
- The compliance angle in #550's problem statement makes silent log loss a trust risk.

## Reproduction

### Minimum Reproduction Steps

**Bug A (logs)**:
1. Configure any MCP server in a stack with `telemetry.persist.logs: true` (stack-level or per-server).
2. Start the gridctl daemon.
3. The MCP server registration alone emits records (`gateway.go:881,897`).
4. Inspect `~/.gridctl/telemetry/<stack>/<server>/logs.jsonl` — always 0 bytes.

**Bug B (metrics)**:
1. Configure `telemetry.persist.metrics: true`.
2. Start daemon, perform several MCP tool calls so the accumulator records token usage.
3. (Optionally) verify `metrics.jsonl` is non-empty.
4. Restart daemon, open the Metrics tab — shows "No token data yet" instead of pre-restart history.

### Affected Environments

All platforms, all transports, all Go versions. The defects are pure logic errors not dependent on OS, filesystem, or runtime.

### Non-Affected Environments

Users who haven't enabled persistence (the default) see no change in behavior.

### Failure Mode

- Bug A: silent total data loss for log persistence. Files exist with mode 0600 but never receive bytes.
- Bug B: silent total data loss for the metrics signal across restarts, even if writes succeed.

System state remains recoverable. No corruption. After the fix, lumberjack will append to existing 0-byte files normally.

## Fix Assessment

### Fix Surface

Bug A — minimal:
- `pkg/telemetry/logs.go` — extend `resolveComponent` to recognize either `"component"` or `"server"`, with `"component"` taking precedence (preserves the existing canonical contract).
- `pkg/telemetry/logs_test.go` — add a case asserting `"server"` also routes correctly.

Bug B — additive:
- `pkg/telemetry/metrics.go` — add `MetricsFlusher.SeedFromFile(path string, n int) error` mirroring `tracing.Buffer.SeedFromFile`.
- `pkg/metrics/accumulator.go` — add `Restore(perServer map[string]TokenCounts)` (or equivalent absolute-set API) so seeded totals don't double-count when live recording resumes.
- `pkg/controller/gateway_builder.go` — add `seedMetricsFromDisk` mirroring `seedLogsFromDisk`/`seedTracesFromDisk`; call it once early in `Build` before the flusher starts.
- `pkg/telemetry/seed_test.go` — extend `TestEndToEnd_PersistAndReseed` with a metrics roundtrip case.
- `pkg/telemetry/metrics_test.go` — unit-level `TestMetricsFlusher_SeedFromFile`.

### Risk Factors

- **Bug A**: lowest possible risk. Preferring `"component"` and falling back to `"server"` is purely additive and preserves the test-evidenced contract. Touching the producer side (`gateway.go:900`) instead would risk breaking any external log consumer parsing `"server"`; do not take that route.
- **Bug B**: needs care to avoid double-counting. The seed must hydrate absolute totals (last `Total` field of each NDJSON line) into the accumulator's per-server state; the flusher's `prev` map must also be initialized to those totals so the first post-restart `Diff` is computed against the seeded baseline rather than zero. Otherwise the first post-restart flush would emit a "Reset" line and re-record the entire history as if it were new.

### Regression Test Outline

- `pkg/controller/gateway_builder_test.go` — new `TestPersistedLogsArriveOnDisk`: build a gateway with persistence on for one server, emit one log via the canonical `g.logger.With("server", name)` pattern, assert the corresponding `logs.jsonl` is non-empty after handler flush.
- `pkg/telemetry/seed_test.go` — new `TestEndToEnd_MetricsPersistAndReseed`: write metrics via flusher, close, build a fresh accumulator + flusher, seed from disk, assert the accumulator reports the pre-restart totals.
- `pkg/telemetry/metrics_test.go` — `TestMetricsFlusher_SeedFromFile` covering: empty file, single line, multiple lines including a Reset sentinel, malformed line skip, missing file (graceful no-op).

## Recommendation

Fix both bugs in a single PR targeting v0.1.0-beta.9. They are tightly co-located (same feature, same package neighborhood), share the regression-test scaffolding (gateway-builder integration), and motivate a single CHANGELOG entry framed as "fix: persistence write and seed gaps in telemetry (#550 follow-up)." Splitting them would only churn reviewers across two PRs that touch the same files.

Avoid the temptation to fix Bug A by changing the producer side (`gateway.go:900`). The router-side fix is strictly additive and does not affect any other log consumer. Hold the producer-side change for a future cleanup that explicitly aligns the conventions repo-wide.

For Bug B, ensure the flusher's `prev` map is seeded alongside the accumulator so the first post-restart write produces a real `Diff` against the seeded baseline. Add an assertion to that effect in the new roundtrip test.

## References

- Issue #550 (feature request and acceptance criteria): https://github.com/gridctl/gridctl/issues/550
- Implementing PRs: #551 (schema/resolvers), #552 (backends), #553 (API), #554 (frontend), #555 (CLI), #556 (docs/changelog)
- v0.1.0-beta.8 release: shipped 2026-05-05
- OTel File Exporter spec (informs metrics NDJSON format): https://opentelemetry.io/docs/specs/otel/protocol/file-exporter/
