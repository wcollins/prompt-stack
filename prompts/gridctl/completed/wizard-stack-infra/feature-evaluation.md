# Feature Evaluation: Wizard Stack Infrastructure Fields

**Date**: 2026-04-10
**Project**: gridctl
**Recommendation**: Build (logging) / Defer (extends, advanced networks)
**Value**: Medium
**Effort**: Small (logging only)

## Summary

The StackForm is missing three infrastructure-level fields: a `logging` section (file rotation config), an `extends` field (stack composition), and advanced network mode (`networks[]` array). Of these, only logging warrants immediate build — it's four simple optional fields with zero validation complexity and direct production value (disk safety). The `extends` field is underdocumented and has no GUI equivalent in any comparable tool. Advanced networks were already evaluated and deferred in a prior scout. This evaluation covers only the logging build.

## The Idea

Add a "Logging" accordion section to the StackForm with four optional fields:
- `logging.file` — path to the log file
- `logging.maxSizeMB` — max file size before rotation (default: 100)
- `logging.maxAgeDays` — days to retain rotated files (default: 7)
- `logging.maxBackups` — number of compressed backup files to keep (default: 3)

When `file` is set, gridctl writes logs to both the in-memory ring buffer (web UI) and the file simultaneously. The other three fields only matter when `file` is set.

## Project Context

### Current State

The `LoggingConfig` struct (`types.go` lines 21–32) is complete. All fields are `omitempty` — the entire section is optional. There is no validation in `validate.go` for logging fields. No test in the loader tests exercises logging config. No logging fields appear in `StackFormData` or `buildStack()` in yaml-builder.ts.

No examples in the `examples/` directory use logging config.

### Integration Surface

- `web/src/lib/yaml-builder.ts` — add `logging?: { file?: string; maxSizeMB?: number; maxAgeDays?: number; maxBackups?: number }` to `StackFormData`; add logging block to `buildStack()`
- `web/src/components/wizard/steps/StackForm.tsx` — add "Logging" Section accordion (new section after Network, before Secrets, or after Secrets)
- `web/src/__tests__/StackForm.test.tsx` — add visibility and serialization tests

### Reusable Components

- `Section` accordion (same pattern as Gateway, Network, Secrets sections)
- Number input pattern (same as Port in MCPServerForm)
- `text-[10px] text-text-muted` helper text for defaults

## Market Analysis

### Competitive Landscape

No infrastructure GUI tool exposes log rotation fields as first-class labeled form inputs. Portainer exposes log driver options as raw key-value pairs. Docker Desktop requires editing `daemon.json`. Nomad has an open GitHub issue requesting this very feature (issue #23709). This is a genuine gap in the market.

### Market Positioning

**Differentiator.** Labeled, validated log rotation config in a wizard is absent everywhere. It's a small feature but one that production operators consistently need to configure to avoid unbounded disk growth — and consistently forget to configure because it's hidden in config files.

### Demand Signals

- Nomad GitHub issue #23709 (open, 2024) explicitly requests configurable log rotation defaults in UI
- Any gridctl user running a long-lived stack that generates verbose MCP logs will eventually hit disk growth issues without this config
- The backend already supports it — no work needed there

## User Experience

### Interaction Model

- Discovery: "Logging" accordion collapsed by default in StackForm
- Activation: user expands section, enters a log file path — the other three fields appear or become meaningful
- All four fields always visible once section is expanded (no further conditional rendering needed)
- Interaction: `file` is a text input with monospace font (it's a path); the three number fields use numeric inputs with placeholder showing the default value
- Helper text under each number field: "Default: X"

### Workflow Impact

No impact on existing workflows — collapsed by default. Users who don't need file logging never see it.

### UX Recommendations

1. Make `file` field conditional for badge count — only count it if non-empty (the three number fields are meaningful only when `file` is set)
2. Show `maxSizeMB`, `maxAgeDays`, `maxBackups` always once section is expanded — don't gate them behind `file` being set (it's cleaner and there are only 3 fields)
3. Placeholder text: `./gridctl.log` or `/var/log/gridctl.log`
4. Number fields in a 3-column grid to save vertical space

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Production disk safety; operators have no other way to configure this from the wizard |
| User impact | Narrow+Deep | Production operators; but impacts every long-running stack once encountered |
| Strategic alignment | Core mission | Wizard completeness |
| Market positioning | Differentiator | No tool has labeled log rotation UI; small but genuinely different |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | 4 optional fields, no validation, no dependencies |
| Effort estimate | Small | ~30 lines of form UI, ~8 lines of serialization |
| Risk level | Low | Pure addition |
| Maintenance burden | Minimal | Stable log rotation config |

## Deferred Items

### Stack `extends`

**Defer.** The `extends` field (file path to a parent stack for composition) is not documented in `config-schema.md`. It has complex path resolution semantics (resolved relative to the child file's directory, circular dependency detection, 10-level depth limit). No GUI tool offers visual stack inheritance anywhere. Revisit when: (a) it's documented, and (b) there's user demand.

### Advanced Network Mode (`networks[]` array)

**Defer (confirmed from prior evaluation).** Requires mutual exclusivity enforcement with the single `network` field, a dynamic array builder UI, and downstream changes to MCPServerForm and ResourceForm to add required per-server network selectors. Warrants its own PR.

## References

- `pkg/config/types.go` — `LoggingConfig` (lines 21–32), `Stack.Logging` (line 13)
- `pkg/config/validate.go` — no logging validation (runtime-only)
- [Nomad log rotation feature request #23709](https://github.com/hashicorp/nomad/issues/23709)
- [Portainer advanced container settings (logging drivers)](https://docs.portainer.io/user/docker/containers/advanced)
