# Bug Investigation: Unsafe Stack-Append YAML Rewrite

**Date**: 2026-05-04
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

`handleStackAppend` (`internal/api/stack.go:631`) round-trips the user's `stack.yaml` through Go structs and writes it non-atomically with no lock and no TOCTOU guard. This silently destroys hand-written comments, re-orders keys, and can clobber concurrent edits or leave a truncated file on crash. The companion handler `setServerTools` in `internal/api/stack_edit.go` already implements the correct pattern (yaml.Node round-trip + per-path lock + hash-checked TOCTOU + `atomicWrite`), so the fix is mostly mechanical: add a `patchAppendResource` helper and rewire the handler. The bug must land before the planned per-resource UI toggles ship, because those toggles will fire this same code path on every click and turn a rare hazard into a normal one.

## The Bug

`POST /api/stack/append` is the wizard's "deploy" endpoint. It is also slated to back upcoming UI toggles. Today the handler:

1. Calls `config.ValidateStackFile(s.stackFile)` (`stack.go:654`), which reads the file and unmarshals straight into a `*config.Stack` struct — discarding all comments and any non-canonical key ordering at the read.
2. Mutates the struct in memory.
3. Calls `yaml.Marshal(stack)` (`stack.go:683`) to re-emit canonical YAML from the struct.
4. Calls `os.WriteFile(s.stackFile, out, 0o644)` (`stack.go:688`).

**Expected behavior**: a wizard-driven append that leaves the user's hand-edits, comments, key order, and file mode intact, and that fails loudly rather than silently overwriting concurrent edits.

**Actual behavior**: comments and key order are lost on every successful call; the file mode is forced to `0o644`; a crash or signal between `WriteFile`'s open and write can leave the stack file truncated; and any external edit landing between the handler's read and write is silently overwritten.

**How discovered**: code review while planning UI toggles that would call this endpoint on every click. The reviewer correctly noted that adding a high-frequency caller turns the latent hazard into a routine one.

## Root Cause

### Defect Location

`internal/api/stack.go:631-698` — specifically:

- `stack.go:654` — read into struct via `config.ValidateStackFile`, which (`pkg/config/health.go:177-200`) returns only the parsed `*Stack` and never the original bytes/hash.
- `stack.go:683` — `yaml.Marshal(stack)` cannot produce comments or original ordering because they were never preserved in the struct.
- `stack.go:688` — `os.WriteFile(s.stackFile, out, 0o644)`: non-atomic, no lock, no TOCTOU check, hard-coded mode.

### Code Path

```
web/src/components/wizard/steps/ReviewStep.tsx:88  handleDeploy()
  → web/src/lib/api.ts:650                         appendToStack(yaml, resourceType)
  → POST /api/stack/append                         (registered at internal/api/api.go:264)
  → internal/api/stack.go:631                      handleStackAppend
       stack.go:654    config.ValidateStackFile     (struct round-trip — drops comments)
       stack.go:661    append to stack.MCPServers / stack.Resources
       stack.go:683    yaml.Marshal                 (canonical re-emit)
       stack.go:688    os.WriteFile                 (non-atomic, 0o644, no lock)
```

### Why It Happens

`config.ValidateStackFile` was designed to return a validated struct, not a round-trippable representation of the file. Comments and key order live only in the source bytes; once the handler discards them at the read, no marshaling strategy can restore them. The non-atomicity, missing lock, and missing TOCTOU guard reflect the same omission: the handler treats `s.stackFile` as a daemon-private file rather than a user-owned document that the user may simultaneously be editing in another tool.

### Similar Instances

The codebase already contains the correct pattern next door:

- `internal/api/stack_edit.go:81` `setServerTools` — the full lock + read + hash + patch + re-read + hash-check + `atomicWrite` flow.
- `internal/api/stack_edit.go:120` `patchServerTools` — `yaml.Node` round-trip that preserves comments, ordering, and unrelated formatting.
- `internal/api/stack_edit.go:237` `atomicWrite` — temp file + fsync + rename + parent directory fsync; preserves original file mode.
- `internal/api/stack_edit.go:18-22` sentinel errors `errStackModified`, `errStackFileEmpty`, `errServerNotFound`.
- `internal/api/stack_edit.go:33` `setServerToolsBetweenReadsHook` + `swapBetweenReadsHook` (line 35) — test-only race-injection used by `TestSetServerTools_ConflictWhenDiskChanged` (`stack_edit_test.go:115`).

A separate, lower-severity instance lives at `internal/api/stack.go:103` `handleStacksSave`. It writes the user's raw YAML directly (no struct round-trip) but is still non-atomic. Different code path, different fix scope; **not in scope for this bug**, but worth a follow-up.

## Impact

### Severity Classification

**High — data loss + race + crash-non-atomic.** Three independent failure modes in one handler, all silent:
- Data loss: comments and key order destroyed on every successful call.
- Race: concurrent external edits overwritten with no error to either party.
- Crash-non-atomic: `WriteFile` interrupted by signal/power loss can leave a truncated YAML file the daemon can no longer parse.

### User Reach

Every wizard "deploy" hits this today (only one call site so far, but exercised by every UI deployment). The planned per-resource UI toggles will multiply call frequency to once-per-click, making the comment-loss visible on a normal interaction and dramatically widening the TOCTOU race window per editing session.

### Workflow Impact

Common path. The wizard is the primary UI for adding to a running stack. Operators who keep comments in `stack.yaml` (the canonical use case for documenting why a particular MCP server is pinned, why a port is unusual, etc.) will lose those comments the first time they use the wizard.

### Workarounds

None that preserve current functionality:
- "Edit only via CLI" defeats the wizard.
- "Don't keep comments" is a regression of basic editor behavior and inconsistent with the rest of the project, where `stack_edit.go` already preserves them.
- "Lock the file at the OS level before opening" is unrealistic for hand-editors.

### Urgency Signals

- Project is `v0.1.0-beta.7` (CHANGELOG.md). Pre-stable; behavior changes are still cheap.
- Bug report explicitly frames this as a **prerequisite** for the upcoming UI-toggles feature — fixing after would be doing it under user load.
- CI runs `go test -race` (`.github/workflows/gatekeeper.yaml`), so the concurrency portion of the fix lands with race detection from day one.

## Reproduction

### Minimum Reproduction Steps

**Comment / key-order loss** (deterministic):
1. Write `stack.yaml` with a top-of-file comment and an inline comment on a key (`env: # do not expand`), plus any non-canonical key order (e.g. `transport:` listed before `url:`).
2. `curl -X POST http://localhost:<port>/api/stack/append -d '{"yaml":"name: x\nurl: http://x\ntransport: http","resourceType":"mcp-server"}'`
3. Re-read the file. Comments are gone; keys re-emitted in struct order.

**TOCTOU lost-update** (deterministic in tests via the existing between-reads hook; observable in production any time an external editor saves between the handler's two reads):
1. Handler reads `stack.yaml`.
2. External editor saves a different version of `stack.yaml`.
3. Handler writes its in-memory mutation. The external save is gone, with no error to either side.

**Non-atomic crash** (deterministic via injected I/O failure):
1. Make the underlying `WriteFile` fail mid-write (signal, ENOSPC).
2. With current code, `stack.yaml` is truncated. With `atomicWrite`, the rename never happens and the original file remains intact.

### Affected Environments

All. POSIX `os.Rename` is atomic on the same filesystem; Windows `os.Rename` is best-effort but still strictly better than `os.WriteFile`. No platform exemptions.

### Non-Affected Environments

The endpoint `setServerTools` (`POST /api/stack/server-tools`) is not affected — it already uses the correct pattern. The library save endpoint `handleStacksSave` (`POST /api/stacks`, `stack.go:103`) writes raw user YAML to a fresh file and so does not lose comments, but it is still non-atomic; out of scope here.

### Failure Mode

Silent. No error returned to the caller; the user notices only when re-opening the file in an editor and finding their content gone, or when the daemon fails to start after a crash because the YAML was truncated mid-write.

## Fix Assessment

### Fix Surface

- `internal/api/stack.go:631-698` — refactor `handleStackAppend` onto the lock + hash-check + `atomicWrite` pattern.
- `internal/api/stack_edit.go` — add a new exported-within-package helper `patchAppendResource(source []byte, resourceType, raw string) ([]byte, error)` modeled on `patchServerTools`. (Or place it in a new file `internal/api/stack_append.go` — implementer's call.)
- `internal/api/stack_test.go:307-395` — augment with comment-preservation, TOCTOU, atomicity, and concurrency tests modeled on `stack_edit_test.go:95-166`.
- `internal/api/api.go:264` — no route change; HTTP contract unchanged except the new 409 case.

### Risk Factors

Low overall. Specific things to watch:
- The yaml.Node patch must handle the case where `mcp-servers:` or `resources:` is absent or `null` and must create the sequence node, mirroring `replaceOrInsertTools` (`stack_edit.go:189`) which already handles the missing-field case correctly.
- Validation must continue to run on the full post-append stack so semantically invalid additions still fail at 400. The current handler does this implicitly via `yaml.Unmarshal(req.YAML, &res)` on the snippet plus the struct append; the new code should both parse the snippet for validation and patch the bytes via `yaml.Node`.
- The frontend `appendToStack` wrapper at `web/src/lib/api.ts:650` does not currently handle 409. The wizard's deploy flow can treat 409 as a terminal error (the user just clicked deploy on stale state); the upcoming-toggles work will want richer handling, but that is its concern.

### Regression Test Outline

Mirror `stack_edit_test.go` patterns:
- `TestHandleStackAppend_PreservesCommentsAndOrder` — input with top-of-file comment, inline comment, non-canonical key order; assert all three survive in the on-disk bytes.
- `TestHandleStackAppend_ConflictWhenDiskChanged` — install a between-reads hook (use the same pattern as `setServerToolsBetweenReadsHook` — either generalize the hook or add a sibling); assert 409 + `errStackModified`-equivalent; assert the caller's intended write did not land.
- `TestHandleStackAppend_AtomicOnWriteFailure` — point at an unwritable directory; assert original file untouched; assert no `.tmp.*` left behind.
- `TestHandleStackAppend_SerializesConcurrentCallers` — fire two appends concurrently against the same file; assert both resources land and the file is not interleaved.

## Recommendation

**Fix immediately**, in a single PR landing before the per-resource UI-toggles feature. Caveats:

- **API contract**: introduce a 409 response when the file changed on disk between the handler's two reads. Frontend wrappers should be updated in this PR (or the toggles PR) to surface "the stack file changed on disk — reload before retrying."
- **Optional `If-Match: <sha256>` precondition**: cheap to add now while the handler is being refactored, lets the upcoming toggle UI pass the hash it last saw so 409 fires only on real conflicts. Treat as out of scope unless the toggles design requires it; the read-twice pattern in `setServerTools` is already TOCTOU-safe without it.
- **Out of scope for this fix**: the parallel non-atomic write at `stack.go:103` (`handleStacksSave`) — different code path, different fix; worth a separate small follow-up. Also out of scope: changing `config.ValidateStackFile` to return raw bytes/hash; the handler can read the file directly, matching `setServerTools`.

If this is deferred, the toggles feature should not ship.

## References

- `internal/api/stack.go:631-698` — defect site
- `internal/api/stack_edit.go:81-282` — reference implementation
- `internal/api/stack_edit_test.go:95-166` — reference tests
- `pkg/config/health.go:177-200` — `ValidateStackFile` contract
- `web/src/lib/api.ts:650-664` — frontend caller
- `web/src/components/wizard/steps/ReviewStep.tsx:85-96` — UI trigger
- `internal/api/api.go:264` — route registration
- `.github/workflows/gatekeeper.yaml` — CI gates (`-race`, 64% coverage)
- `CHANGELOG.md` — current release: `v0.1.0-beta.7`
