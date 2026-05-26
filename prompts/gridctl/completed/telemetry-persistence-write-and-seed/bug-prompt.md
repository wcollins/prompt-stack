# Bug Fix: Telemetry Persistence Write & Seed Failures

## Context

gridctl is a Go-based control plane for MCP (Model Context Protocol) servers. It manages "stacks" of MCP servers, exposes a daemon with HTTP API + embedded web UI, and provides per-server telemetry (logs, metrics, traces) backed by in-memory ring buffers.

Issue #550 introduced **opt-in disk persistence** for those three signals. The implementation landed across PRs #551–#555 (schema, backends, API, frontend, CLI) and shipped in v0.1.0-beta.8 on 2026-05-05.

Persistence layout:
```
~/.gridctl/telemetry/<stack>/<server>/{logs,metrics,traces}.jsonl
```

Files are NDJSON, written via lumberjack rotation, mode 0600, dir 0700. Resolvers `MCPServer.PersistLogs/PersistMetrics/PersistTraces(stack)` gate per-server activation with stack-default fallback.

The acceptance criterion you must restore: **"Restart with persistence on seeds the Logs/Metrics/Traces tabs with pre-restart data on first load."**

Tech stack: Go 1.22+, `log/slog`, OpenTelemetry SDK, `natefinch/lumberjack`. Frontend is React but does not need changes.

## Investigation Context

Two independent defects were confirmed by reading code and on-disk evidence (all 12 `.jsonl` files at 0 bytes after a real session):

- **Bug A (logs write-path)**: `pkg/mcp/gateway.go:900` constructs every per-server logger with `g.logger.With("server", cfg.Name)`, but `pkg/telemetry/logs.go:201-217` `LogRouter.resolveComponent` only recognizes the `"component"` attribute. Records never match a registered server, so the per-server file fan-out is silently skipped. The 0-byte files are a side effect of `touchMode0600` creating empty files at startup.
- **Bug B (metrics seed gap)**: `pkg/logging/buffer.go:107` and `pkg/tracing/buffer.go:235` both expose `SeedFromFile`, and `pkg/controller/gateway_builder.go` calls `seedLogsFromDisk` (line 195) and `seedTracesFromDisk` (line 499). There is no `MetricsFlusher.SeedFromFile` and no `seedMetricsFromDisk` — metrics are never replayed on restart, regardless of whether they were written successfully.

Risk mitigations baked into the fix requirements:
- Bug A must be fixed on the **router side**, not the producer side. Changing `gateway.go:900` would break any external consumer parsing the existing `"server"` attribute. The router-side fix is purely additive.
- Bug B must seed both the accumulator's totals **and** the flusher's `prev` map, otherwise the first post-restart flush will emit a Reset and re-record the seeded history as new live data.

Reproduction confirmed:
- Bug A reproduces on every server registration (`gateway.go:881,897` always emits records); `logs.jsonl` is always 0 bytes regardless of activity.
- Bug B is structural — the seed code does not exist.

Full investigation: `prompts/gridctl/telemetry-persistence-write-and-seed/bug-evaluation.md`

## Bug Description

Telemetry persistence shipped in v0.1.0-beta.8 (issue #550) does not work end-to-end:

1. Per-server `logs.jsonl` files stay at 0 bytes during runtime; no log records are ever written even though all wiring appears correct.
2. After daemon restart, the Metrics tab shows "No token data yet" because there is no seed-from-disk path for metrics, so pre-restart history is unrecoverable.

Expected: every record/event/sample tagged for a persistence-enabled server lands in the corresponding NDJSON file during the session, and on next daemon start the in-memory ring buffers (and therefore the UI tabs) are populated with the recent on-disk history.

Affected: every user who opts into persistence. Both demand segments named in #550 (indie debugging, enterprise audit) are blocked. Default-off users are unaffected.

## Root Cause

**Bug A — log routing key mismatch**
- `pkg/mcp/gateway.go:900`: `clientLogger := g.logger.With("server", cfg.Name)`
- `pkg/telemetry/logs.go:201-217`: `resolveComponent` iterates `record.Attrs` for `a.Key == "component"` only.
- `pkg/telemetry/logs.go:243-256`: `WithAttrs` sets `derived.component` only when `a.Key == "component"`.
- The router still routes the record to the inner buffer (UI live-tail works), but the per-server file fan-out is gated on a non-empty `component`, so the file write path is silently skipped.

The correct fix: have the router accept either `"component"` or `"server"`, with `"component"` taking precedence (it is the documented canonical key per `pkg/telemetry/logs_test.go:35`).

**Bug B — metrics has no seed path**
- `pkg/telemetry/metrics.go` has no `SeedFromFile` method. The flusher writes lines of type `MetricsSnapshotLine` (`pkg/telemetry/metrics.go:25-31`), but no code ever reads them back.
- `pkg/metrics/accumulator.go` exposes only incremental APIs (`Record`, `RecordReplica`); there is no way to set absolute totals, which is what NDJSON lines record (`Total` field).
- `pkg/controller/gateway_builder.go` has `seedLogsFromDisk` (line 242) and `seedTracesFromDisk` (line 263) but no metrics equivalent.

The correct fix: add `MetricsFlusher.SeedFromFile`, add an absolute-restore API on the accumulator, and call a new `seedMetricsFromDisk` early in `Build` (before any tool calls run) — and seed the flusher's `prev` map to the seeded totals so subsequent diffs are correct.

## Fix Requirements

### Required Changes

1. **Extend `LogRouter.resolveComponent` and `LogRouter.WithAttrs` in `pkg/telemetry/logs.go`** to recognize the `"server"` attribute as a fallback when `"component"` is absent. `"component"` takes precedence when both are present (preserves the existing canonical contract). Apply the same fallback in `WithAttrs` so `.With("server", name)` propagates the routing key just like `.With("component", name)` does today.

2. **Add `MetricsFlusher.SeedFromFile(path string, n int) error` in `pkg/telemetry/metrics.go`** that:
   - Opens `path`. Returns `nil` if the file does not exist or is empty (graceful, like the logs/traces seed functions).
   - Reads the last `n` NDJSON lines (use the same scan-and-window pattern as `LogBuffer.SeedFromFile` / `tracing.Buffer.SeedFromFile`).
   - Skips lines whose `reset: true` form indicates a counter reset; treat the most recent post-reset line's `Total` as authoritative for that server.
   - For each server with a final `Total`, calls a new accumulator API (see #3) and writes the same totals into the flusher's `prev` map under the flusher mutex so the next `flushOnce` computes a diff from the seeded baseline.
   - Logs (via the flusher's slog logger) but does not return an error for malformed lines — match the resilience pattern used by the log/trace seeders.

3. **Add `Accumulator.Restore(perServer map[string]TokenCounts)` (or an equivalent absolute-set method) in `pkg/metrics/accumulator.go`.** Pick a name that fits the existing API style. The method must atomically replace the per-server totals and any associated ring-buffer state used by the UI/API layer to render historical token usage. If the existing internal storage is purely incremental, you may need to expose a separate "seeded totals" baseline that `Snapshot` adds on top of recorded deltas — choose whichever shape requires the smaller refactor while keeping `Snapshot` correct.

4. **Add `seedMetricsFromDisk(handler slog.Handler)` in `pkg/controller/gateway_builder.go`** mirroring `seedLogsFromDisk` (line 242) and `seedTracesFromDisk` (line 263). Iterate `b.stack.MCPServers`, gate on `srv.PersistMetrics(b.stack)`, build the path with `state.TelemetryServerPath(b.stack.Name, srv.Name, "metrics")`, and call `MetricsFlusher.SeedFromFile(path, telemetrySeedLimit)`. Log warnings on error using the same pattern as the existing seeders.

5. **Wire the call in `Build`** somewhere between flusher construction (line 469 region) and any code path that could record live metrics. Choose a position consistent with the existing ordering (logs are seeded before registry init at line 195; traces are seeded after `tracingProvider.Init`). Document the placement with a short comment matching the existing style.

6. **Tests**:
   - Add `TestLogRouter_RoutesByServerAttribute` in `pkg/telemetry/logs_test.go` asserting that `logger.With("server", "github").Info(...)` routes to the github file.
   - Add `TestLogRouter_ComponentTakesPrecedenceOverServer` for the both-present case.
   - Add `TestPersistedLogsArriveOnDisk` in `pkg/controller/gateway_builder_test.go`: build a gateway with one server having `PersistLogs` true, emit one record via the canonical `g.logger.With("server", name)` pattern, flush handlers if needed, assert the corresponding `logs.jsonl` is non-empty.
   - Add `TestMetricsFlusher_SeedFromFile` in `pkg/telemetry/metrics_test.go` covering: missing file (no-op), empty file, single line, multiple lines including a Reset sentinel mid-stream, malformed line skip.
   - Extend `pkg/telemetry/seed_test.go` with `TestEndToEnd_MetricsPersistAndReseed`: write metrics via a flusher, close, build a fresh accumulator + flusher, seed from disk, assert the new accumulator's snapshot reports the pre-restart totals AND that the next live `flushOnce` produces a correct diff (i.e., the `prev` map was seeded too).

### Constraints

- **Do not modify `pkg/mcp/gateway.go:900`**. The producer-side attribute key must remain `"server"`. The fix is router-side only. Touching the producer would risk breaking external log consumers and is out of scope.
- **Do not change the on-disk file format.** Every existing NDJSON line in `logs.jsonl`, `metrics.jsonl`, `traces.jsonl` must remain valid going forward. New code only reads — it does not migrate.
- **Do not change the public API of `MCPServer.PersistLogs/PersistMetrics/PersistTraces`** — the resolvers are correct.
- **Do not introduce new dependencies.** Reuse `lumberjack`, `bufio`, `encoding/json`, and the existing slog scaffolding.
- **Performance**: seeding runs once at startup. Use the same `telemetrySeedLimit = 500` constant defined at `gateway_builder.go:236`.
- **Concurrency**: any mutation of `MetricsFlusher.prev` must hold `f.mu`. Any mutation of accumulator state must respect its existing locking conventions.

### Out of Scope

- Producer-side cleanup of the `"server"` vs `"component"` convention divergence. File a follow-up issue for a future repo-wide convention pass.
- Schema or resolver changes. Both are correct.
- Frontend changes. The bug is entirely in the Go daemon; the UI will populate correctly once the buffers are seeded.
- CLI parity changes (`gridctl telemetry status|wipe|tail`). These are unaffected.
- Migration of existing 0-byte files. Lumberjack will append normally; no migration needed.
- Refactoring the telemetry seed functions into a shared helper. The three seeders are short enough that copy-paste-with-variation is more readable; refactor only if it falls out naturally.

## Implementation Guidance

### Key Files to Read

Read these first to internalize the patterns the fix must match:

- `pkg/logging/buffer.go:97-147` — `LogBuffer.SeedFromFile`. Reference for graceful empty-file handling, line-window scanning, and JSON unmarshal resilience.
- `pkg/tracing/buffer.go:226-299` — `tracing.Buffer.SeedFromFile`. Closer parallel to metrics because the on-disk format is OTLP-JSON envelopes (multi-line semantics).
- `pkg/controller/gateway_builder.go:233-278` — the two existing seed functions and the `telemetrySeedLimit` constant. Mirror exactly.
- `pkg/controller/gateway_builder.go:469-644` — the metrics flusher construction and the per-server registration loop in `applyTelemetryConfig`. The new seed call belongs in this region.
- `pkg/telemetry/metrics.go` (full file, ~300 lines) — the flusher implementation. The new `SeedFromFile` method belongs here.
- `pkg/telemetry/logs.go:140-270` — the `LogRouter` handler, `resolveComponent`, `WithAttrs`. The Bug A fix is local to these functions.
- `pkg/telemetry/logs_test.go:15-85` — existing log-routing tests. New cases follow the same shape.
- `pkg/telemetry/seed_test.go` — existing roundtrip tests for logs and traces. The new metrics roundtrip mirrors these line-for-line.
- `pkg/metrics/accumulator.go` — the accumulator. Identify the smallest API addition that lets `SeedFromFile` hydrate totals without breaking `Snapshot` semantics.
- `pkg/state/state.go:245-270` — path helpers (already correct, just reuse).

### Files to Modify

- `pkg/telemetry/logs.go` — Bug A: extend `resolveComponent` (lines 201-217) to fall back to `"server"`; extend `WithAttrs` (lines 243-256) to set `derived.component` when `a.Key == "server"` and the existing `"component"` was not previously set.
- `pkg/telemetry/logs_test.go` — add Bug A regression cases.
- `pkg/telemetry/metrics.go` — Bug B: add `SeedFromFile` method.
- `pkg/telemetry/metrics_test.go` — add unit tests for the new method.
- `pkg/telemetry/seed_test.go` — extend with metrics roundtrip.
- `pkg/metrics/accumulator.go` — add the absolute-restore API.
- `pkg/controller/gateway_builder.go` — add `seedMetricsFromDisk` and a single call in `Build` near the metrics flusher initialization.
- `pkg/controller/gateway_builder_test.go` — add the integration test that ties Bug A's fix to real gateway logging.
- `CHANGELOG.md` — single entry under a new `## [Unreleased]` or beta-9 section: `fix: telemetry persistence write and seed gaps (#550 follow-up)`.

### Reusable Components

- `state.TelemetryServerPath(stackName, serverName, signal)` — already exists, returns the canonical path.
- `state.EnsureTelemetryServerDir` — for ensuring directory existence (already used by `applyTelemetryConfig`).
- `bufio.Scanner` with a custom buffer size or the existing `lastNLines` helper used by the logs seeder (check `pkg/logging/buffer.go`).
- `slog.New(handler).Warn(...)` for non-fatal seed errors, matching the existing seeders.

### Conventions to Follow

- Comment style: terse, intent-focused. Match the surrounding files (e.g., explain *why* the seed runs early in `Build`, not *what* the lines do).
- Error handling: graceful no-op on missing/empty files (return `nil`); log-and-continue on per-line parse errors; never return errors that would abort daemon startup.
- Tests: table-driven where it fits; assert via `t.Errorf` not `t.Fatalf` unless the failure cascades; use `t.TempDir()` for filesystem fixtures.
- Sign all commits with `-S`.
- No mention of Claude or AI in commit messages, PR titles, branch names, or code comments.
- Branch name: `fix/telemetry-persistence-write-and-seed`.
- Single PR. Single CHANGELOG entry. Single GitHub issue (open one before starting if one does not already exist for this regression).

## Regression Test

### Test Outline

**`TestLogRouter_RoutesByServerAttribute`** (`pkg/telemetry/logs_test.go`):
- Set up a router with one registered server (`github`).
- Emit `logger.With("server", "github").Info("hit")`.
- Assert the github file contains exactly one line and the message is `"hit"`.

**`TestLogRouter_ComponentTakesPrecedenceOverServer`** (`pkg/telemetry/logs_test.go`):
- Register both `github` and `weather`.
- Emit a record with both `component=github` and `server=weather`.
- Assert the github file gets the line; the weather file stays empty.

**`TestPersistedLogsArriveOnDisk`** (`pkg/controller/gateway_builder_test.go`):
- Build a `GatewayBuilder` with a stack containing one server, `PersistLogs(stack) == true`, telemetry dir under `t.TempDir()`.
- Build the gateway, emit a record using the same pattern as `gateway.go:900`: `slog.New(handler).With("server", srv.Name).Info(...)`.
- Trigger handler close/flush.
- Stat the corresponding `logs.jsonl`; assert size > 0 and the message round-trips through JSON unmarshal.

**`TestMetricsFlusher_SeedFromFile`** (`pkg/telemetry/metrics_test.go`):
- Cases: missing file (no error, no state change); empty file (no error); single line with one server's totals (accumulator now reports those totals; flusher's `prev` map has the same totals); multi-line with a Reset sentinel mid-stream (only post-reset totals seeded); malformed line in the middle (skipped, surrounding lines applied).

**`TestEndToEnd_MetricsPersistAndReseed`** (`pkg/telemetry/seed_test.go`):
- Build accumulator A, flusher F1 → record some token usage → flush → close.
- Build accumulator B, flusher F2 → seed from the same file → assert B's `Snapshot` matches A's pre-close `Snapshot` for relevant per-server totals.
- Then record additional tokens via B → flush F2 → assert the new NDJSON line's `Diff` is the *additional* tokens only (proves `prev` was seeded correctly, no double-counting).

### Existing Test Patterns

- Table-driven tests are common in `pkg/config/telemetry_test.go`. Use the same shape if the matrix is wide.
- File assertions: read with `os.ReadFile`, split on `\n`, unmarshal each non-empty line into the expected type.
- Temp directories: `dir := t.TempDir()`. Path-build with `filepath.Join`.
- Avoid `time.Sleep`. Use `flusher.flushOnce(time.Now())` directly to deterministically trigger a snapshot.

## Potential Pitfalls

- **Double-counting metrics on restart**: if `SeedFromFile` updates the accumulator but does *not* update `MetricsFlusher.prev`, the next `flushOnce` will compute `Diff = current - 0` and emit a `Reset` line plus the entire historical totals as if they were new. Both updates must be atomic together.
- **Reset sentinels in the file**: lines like `{"reset":true,"ts":...,"server":...}` (no `Diff`/`Total`) are valid NDJSON and must be parsed without erroring; they signal that any earlier totals for that server should be discarded by the seed logic. Make the parser tolerant of two distinct shapes.
- **Empty file detection**: a 0-byte file must be a no-op, not an error. Check via `os.Stat` size or by handling EOF on first read.
- **WithAttrs ordering for Bug A**: when `WithAttrs` receives a slice containing both `"component"` and `"server"`, `"component"` must take precedence. Iterate explicitly and prefer `"component"` if present; fall through to `"server"` only if `"component"` is empty.
- **Slog record attrs vs handler attrs**: `WithAttrs` accumulates handler-level attrs; `record.Attrs` enumerates record-level attrs. The fix must check both surfaces in both methods, exactly as the existing code does for `"component"`.
- **Test isolation**: tests that touch `~/.gridctl/telemetry/...` would pollute the user's machine. Use `t.TempDir()` and a stack with `Name` derived from the test, or inject the telemetry root via existing `state.SetRoot`-style helpers.
- **Self-log filter**: `LogRouter.isSelfLog` (line 223) must continue to short-circuit records tagged `subsystem=telemetry`. Verify the new `"server"` fallback does not accidentally route self-logs.

## Acceptance Criteria

1. Running gridctl with persistence enabled, performing any MCP server registration, and waiting for handler flush results in a non-empty `logs.jsonl` for that server.
2. After a daemon restart with persistence enabled, the Logs tab in the UI shows pre-restart records on first load.
3. After a daemon restart with persistence enabled and prior tool-call activity, the Metrics tab shows pre-restart token usage on first load (no "No token data yet" empty state).
4. The first post-restart `flushOnce` writes a `Diff` line containing only the new activity since restart — no Reset sentinel, no re-emission of seeded totals.
5. All new tests pass; all existing telemetry tests still pass; `go test -race ./...` succeeds.
6. `golangci-lint run` is clean.
7. CHANGELOG has a single fix entry referencing #550.
8. No changes to `pkg/mcp/gateway.go`, `pkg/config/types.go`, or any frontend file.
9. PR description summarizes both bugs in two short bullets and links the investigation report.

## References

- Issue #550: https://github.com/gridctl/gridctl/issues/550
- Related PRs: #551 (schema), #552 (backends), #553 (API), #554 (frontend), #555 (CLI), #556 (docs)
- v0.1.0-beta.8 release notes (CHANGELOG.md, dated 2026-05-05)
- OpenTelemetry OTLP File Exporter spec: https://opentelemetry.io/docs/specs/otel/protocol/file-exporter/
- natefinch/lumberjack: https://github.com/natefinch/lumberjack
- Investigation report: `prompts/gridctl/telemetry-persistence-write-and-seed/bug-evaluation.md`
