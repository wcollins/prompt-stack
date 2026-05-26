# Bug Fix: Make `handleStackAppend` Safe (yaml.Node + lock + TOCTOU + atomic write)

## Context

gridctl is a Go-based MCP gateway daemon (`v0.1.0-beta.7`) at `/Users/william/code/grid/gridctl`. Tech stack:
- Go 1.x, `gopkg.in/yaml.v3`, stdlib `net/http`
- HTTP API in `internal/api/`, served by a single `*Server` (defined in `internal/api/api.go`)
- Stack config in `pkg/config/`, validated by `pkg/config/health.go:ValidateStackFile`
- Frontend in `web/` (TypeScript). Wizard calls the API via `web/src/lib/api.ts`.
- CI: `.github/workflows/gatekeeper.yaml` runs `golangci-lint`, `go test -race -coverprofile`, `govulncheck`, build, integration tests, and a 64%-coverage gate.

There is an in-house, battle-tested pattern for safely editing the live stack YAML in `internal/api/stack_edit.go` (`setServerTools` + `patchServerTools` + `atomicWrite` + `stackFileLock`). This fix ports `handleStackAppend` onto that pattern. **Read `stack_edit.go` and `stack_edit_test.go` end-to-end before writing any code** — they are the template.

## Investigation Context

- **Root cause confirmed**: `internal/api/stack.go:631` (`handleStackAppend`) reads the stack via `config.ValidateStackFile` (struct round-trip → drops comments + key order), mutates the struct, marshals back with `yaml.Marshal`, and writes with `os.WriteFile` (non-atomic, no lock, no TOCTOU guard, hard-coded `0o644`).
- **Repro confirmed**: comment-loss is deterministic on every call; TOCTOU race is deterministic in tests via the existing between-reads-hook pattern; non-atomic crash is observable via injected I/O failure (mirrors `TestAtomicWrite_LeavesOriginalOnWriteFailure` at `stack_edit_test.go:151`).
- **Risk mitigation baked in**: fix must reuse the existing `stackFileLock`, `atomicWrite`, and sentinel errors from `stack_edit.go`. Do **not** introduce new locking/atomic-write helpers. Do **not** modify `config.ValidateStackFile`'s signature.
- **Full investigation**: `prompts/gridctl/unsafe-stack-append-rewrite/bug-evaluation.md`.

## Bug Description

`POST /api/stack/append` (the wizard's deploy endpoint, and the planned backing call for upcoming UI toggles) silently destroys hand-written comments and key ordering on every successful call, and on a concurrent external edit silently overwrites it. On a crash mid-write the stack file can be left truncated.

- **Affected callers today**: `web/src/components/wizard/steps/ReviewStep.tsx:88` → `web/src/lib/api.ts:650 appendToStack`. One call site per deploy.
- **Affected callers soon**: per-resource UI toggles will fire this endpoint on every click. Comment-loss becomes visible during normal editing and the TOCTOU race window per session widens dramatically.
- **Expected behavior**: append succeeds while preserving comments, key ordering, and file mode; concurrent on-disk edits cause a 409 Conflict instead of a silent overwrite; crash mid-write leaves the original file intact.

## Root Cause

`internal/api/stack.go:631-698`:

| Line | Problem |
|---|---|
| 654 | `config.ValidateStackFile(s.stackFile)` returns only the parsed `*config.Stack`. Comments and key order are discarded at the read; nothing downstream can restore them. |
| 683 | `yaml.Marshal(stack)` re-emits canonical YAML from the struct. Comments and original ordering are gone. |
| 688 | `os.WriteFile(s.stackFile, out, 0o644)` is non-atomic (partial-write risk on crash), takes no lock (concurrent calls can interleave), performs no TOCTOU check (external edits between line 654 and line 688 are silently lost), and forces mode `0o644` regardless of the original. |

The correct logic is the one already implemented for `setServerTools` (`internal/api/stack_edit.go:81`): take the per-path lock, read the file as bytes, hash the bytes, patch the bytes via `yaml.Node` (preserves comments), re-read and re-hash before write to detect external mutations, and write atomically via `atomicWrite`.

## Fix Requirements

### Required Changes

1. **Add `patchAppendResource(source []byte, resourceType string, snippet []byte) ([]byte, error)`** in `internal/api/stack_edit.go` (or a new sibling file `internal/api/stack_append.go` if you prefer to keep `stack_edit.go` focused on tools-edits). It must:
   - Parse `source` into a `yaml.Node` document (mirror `patchServerTools` at `stack_edit.go:120-168`).
   - Validate the document is a top-level mapping.
   - Parse `snippet` into a `yaml.Node` (the to-be-appended item).
   - Find the appropriate top-level sequence — `mcp-servers` for `resourceType == "mcp-server"`, `resources` for `resourceType == "resource"` — using the existing `findMappingValue` helper (`stack_edit.go:173`).
   - If the sequence is missing or `null`, create it as an empty sequence appended to the document mapping (mirror the missing-field handling in `replaceOrInsertTools` at `stack_edit.go:189-215`).
   - Append the snippet node to the sequence.
   - Re-emit via `yaml.NewEncoder` with `SetIndent(2)` (matches `stack_edit.go:158-167`).
   - Return the new bytes.
2. **Refactor `handleStackAppend`** (`internal/api/stack.go:631-698`) to:
   - Keep the existing precondition check on `s.stackFile == ""` returning 503.
   - Keep the existing 1 MB body cap and JSON parse with the `{yaml, resourceType}` shape.
   - **Remove** the call to `config.ValidateStackFile` for the persistence path. Replace with the lock + read pattern from `setServerTools`:
     ```go
     mu := stackFileLock(s.stackFile)
     mu.Lock()
     defer mu.Unlock()

     original, err := os.ReadFile(s.stackFile)
     if err != nil { /* 500 */ }
     originalHash := sha256.Sum256(original)
     ```
   - **Validate the snippet** by `yaml.Unmarshal`-ing it into the appropriate typed struct (`config.MCPServer` or `config.Resource`) — preserves the existing 400-on-bad-YAML behavior. Reject empty/missing `name` with 400 (matches the spirit of existing validation).
   - **Validate the post-append stack semantically** by parsing `original` into a `*config.Stack` (a fresh `yaml.Unmarshal`, since `ValidateStackFile` is no longer invoked here), appending the snippet to the in-memory struct, and running validation. If validation fails, return 422 with the validation result. Choose the validation entry point that matches what `ValidateStackFile` did — likely `config.ValidateStack(*Stack)` or equivalent; if no such pure function exists, **add one** by extracting the validation portion of `ValidateStackFile` into `func ValidateStack(*Stack) (*ValidationResult, error)` and have `ValidateStackFile` call it. This is the smallest viable refactor; do not change `ValidateStackFile`'s signature.
   - **Patch the bytes** via `patchAppendResource(original, req.ResourceType, []byte(req.YAML))`.
   - **Fire the between-reads hook** (see test hooks below).
   - **Re-read and hash-check**:
     ```go
     current, err := os.ReadFile(s.stackFile)
     if err != nil { /* 500 */ }
     if sha256.Sum256(current) != originalHash {
         writeJSONError(w, "stack file was modified on disk since read; reload before retrying", http.StatusConflict)
         return
     }
     ```
   - **Atomic write** via `atomicWrite(s.stackFile, updated)`. Map error to 500 with the existing `writeJSONError` style.
   - Return the same success JSON as today: `{success, resourceType, resourceName}`. The resource name comes from the typed-struct unmarshal step.
3. **Test hooks**: either generalize the existing `setServerToolsBetweenReadsHook` into a single shared `stackEditBetweenReadsHook` (preferred — single integration point) or add a sibling `appendBetweenReadsHook` with the same `atomic.Value` + `swapBetweenReadsHook`-style API (`stack_edit.go:33-57`). Whichever path: ensure the hook is fired between the initial read and the pre-write re-read in the new handler.
4. **Tests** in `internal/api/stack_test.go` (or a new `stack_append_test.go` in the same package — implementer's call). Required cases — model on `stack_edit_test.go:95-166`:
   - `TestHandleStackAppend_PreservesCommentsAndOrder`: stack file with a top-of-file comment, an inline comment on a key, and a non-canonical key order; append; assert all three survive in the on-disk bytes by string-matching (not by struct round-trip — that'd hide the bug).
   - `TestHandleStackAppend_ConflictWhenDiskChanged`: install the between-reads hook to write a different version mid-handler; assert 409 status, error body mentions "modified on disk" or similar, original-plus-external-edit content remains, intended append did not land.
   - `TestHandleStackAppend_AtomicOnWriteFailure`: point `s.stackFile` at a path whose parent directory does not exist (mirrors `stack_edit_test.go:151-166`), or otherwise force `atomicWrite` to fail; assert the original file is untouched and no `.tmp.*` left behind in the parent directory.
   - `TestHandleStackAppend_SerializesConcurrentCallers`: launch two concurrent `httptest` requests against the same file; assert both resources land, file is parseable, no interleaving. With the per-path lock this should pass; this test is the regression guard.
5. **Keep existing tests green** (`stack_test.go:307-395`): `TestHandleStackAppend_MCPServer`, `_Resource`, `_NoStackFile`, `_InvalidResourceType`, `_InvalidYAML`. The 503 / 400 contracts must not change.

### Constraints

- **Do not modify** `pkg/config/health.go:ValidateStackFile`'s signature. If you need a pure `ValidateStack(*Stack)` function, extract one alongside it and have `ValidateStackFile` call it. No callers outside this fix should change.
- **Do not introduce** a new locking, hashing, or atomic-write helper. Reuse `stackFileLock`, `atomicWrite`, and `sha256.Sum256` exactly as `setServerTools` does.
- **Do not change** the success-response JSON shape; keep `{success: true, resourceType, resourceName}`.
- **Do not change** the request body shape (`{yaml, resourceType}`).
- **Preserve** all current error contracts: 503 when `s.stackFile == ""`, 400 on bad JSON / unsupported `resourceType` / invalid snippet YAML.
- **Use `gopkg.in/yaml.v3`** exclusively. Do not add new YAML libraries.

### Out of Scope

- Fixing `internal/api/stack.go:103` (`handleStacksSave`) — different code path (writes raw user YAML to a fresh library file in `~/.gridctl/stacks/`), no struct round-trip, lower severity. Track separately.
- Adding an `If-Match: <sha256>` precondition header. The handler's own read-twice TOCTOU pattern is sufficient for the current callers; the upcoming-toggles feature can add `If-Match` cheaply on top if its UX needs it.
- Frontend wrapper update at `web/src/lib/api.ts:650`. The wizard's deploy flow treats any non-2xx as a terminal error, which is acceptable for the new 409. The toggles PR will need a richer handler; do that there.
- Changing the response shape on 409 to include the latest hash. The toggles work can add it; not needed today.
- Reworking `config.ValidateStackFile` to return raw bytes or mtime. The handler reads bytes itself, mirroring `setServerTools`.

## Implementation Guidance

### Key Files to Read

| File | Why |
|---|---|
| `internal/api/stack_edit.go` | Reference implementation. Read all 282 lines. The fix is a near-mechanical port of `setServerTools` + `patchServerTools` + `atomicWrite`. |
| `internal/api/stack_edit_test.go` | Reference tests. Read all 166 lines. Mirror these patterns for the new tests. |
| `internal/api/stack.go:631-698` | The handler being replaced. Note the exact existing error messages and status codes — preserve them on the unchanged paths. |
| `internal/api/stack.go:1-120` | Package imports, the validating regex, and the sibling `handleStacksSave` pattern. |
| `internal/api/api.go` | The `*Server` definition, `s.stackFile`, route registration at line ~264. Do not change the route. |
| `pkg/config/health.go:177-200` | `ValidateStackFile` definition. Read to understand what `ValidateStack(*Stack)` would need to do if you extract one. |
| `pkg/config/` | The `Stack`, `MCPServer`, and `Resource` struct definitions, so you know what the typed snippet unmarshal should look like. |
| `internal/api/stack_test.go:307-395` | Existing append tests. Keep these green; add new ones beside them. |
| `web/src/lib/api.ts:650-664` | Caller contract. Confirms the request shape this fix must preserve. |

### Files to Modify

- `internal/api/stack.go` — rewrite `handleStackAppend` (lines 631-698).
- `internal/api/stack_edit.go` — add `patchAppendResource`. If you choose to put it in a new file, name it `internal/api/stack_append.go` and keep the package-level `stackFileLocks`, `atomicWrite`, and sentinel errors in `stack_edit.go` (do not duplicate).
- `internal/api/stack_test.go` (or new `internal/api/stack_append_test.go`) — add the four new tests; keep existing tests passing.
- `pkg/config/health.go` — possibly extract `ValidateStack(*Stack) (*ValidationResult, error)` if no equivalent exists. Keep `ValidateStackFile`'s signature and behavior unchanged.

### Reusable Components

- `stackFileLock(path)` — `internal/api/stack_edit.go:59`.
- `atomicWrite(path, data)` — `internal/api/stack_edit.go:237`.
- `findMappingValue(node, key)` — `internal/api/stack_edit.go:173`.
- `errStackFileEmpty`, `errStackModified` — `internal/api/stack_edit.go:18-22`. Reuse `errStackModified` semantics (translate to HTTP 409 in the handler).
- `swapBetweenReadsHook(fn)` and the `atomic.Value` test-injection pattern — `internal/api/stack_edit.go:33-57`. Generalize or duplicate; prefer generalize.
- `writeJSON` and `writeJSONError` — established in `internal/api/`. Use them.

### Conventions to Follow

- **Comments**: terse, in the style of `stack_edit.go`. One- or two-line block comments above non-obvious functions; inline only for genuine subtleties (the "narrow window" comment at `stack_edit.go:103-105` is a good model).
- **Error wrapping**: `fmt.Errorf("X: %w", err)` for I/O errors (matches `setServerTools`).
- **Sentinel errors**: keep them sentinel — never `fmt.Errorf` over them. The handler does the HTTP status mapping.
- **Tests**: `testify/require` for fatal preconditions, `testify/assert` for assertions (matches `stack_edit_test.go`). Use `t.TempDir()` for fixtures. Write the input stack with `0o600` to match the existing tests.
- **HTTP status codes**: 400 input validation, 409 TOCTOU conflict, 422 semantic validation failure (post-append stack invalid), 500 I/O failure, 503 no stack configured. Match the existing handler's existing-path status codes exactly; do not change 503 → something else.
- **Race-detector clean**: CI runs `-race`. The per-path lock plus `atomic.Value` hook keep the existing handler clean; do the same.

## Regression Test

### Test Outline

All four tests live in `internal/api/`. Use `httptest.NewRecorder` and call the handler directly — same style as the existing `TestHandleStackAppend_*` tests at `stack_test.go:307-395`.

1. **`TestHandleStackAppend_PreservesCommentsAndOrder`**
   - Fixture: a stack file containing `# top-of-file comment`, an inline `env: # do not expand` comment, and `transport: http` listed before `url:`.
   - Action: POST a valid `mcp-server` snippet via `httptest`.
   - Assert: handler returns 200; on-disk file string-contains the top-of-file comment, the `do not expand` comment, and `transport: http\n    url:` (in that order, as the original).
   - Assert: the new resource is in the file (`name: <new-name>`).

2. **`TestHandleStackAppend_ConflictWhenDiskChanged`**
   - Fixture: same as `stack_edit_test.go:115` adapted — write a baseline stack file.
   - Inject the between-reads hook to write a modified version of the file.
   - Action: POST any valid append.
   - Assert: 409 status; error body mentions modification / reload; on-disk file contains the externally-injected change; the append did not land.

3. **`TestHandleStackAppend_AtomicOnWriteFailure`**
   - Fixture: stack file at `dir/stack.yaml`. Configure `s.stackFile` to a non-existent subdirectory or otherwise force `atomicWrite` to fail (mirrors `stack_edit_test.go:151-166`).
   - Action: POST any valid append.
   - Assert: 500; original file untouched; no `.tmp.*` files left in the parent directory.

4. **`TestHandleStackAppend_SerializesConcurrentCallers`**
   - Fixture: stack file with both `mcp-servers` and `resources` sequences.
   - Action: launch two `httptest` requests in goroutines against the same `*Server` — one appending an MCP server, one appending a resource. Wait on a `sync.WaitGroup`.
   - Assert: both responses are 200; the on-disk file parses; both new entries are present; the file is well-formed YAML.

### Existing Test Patterns

- File: `internal/api/stack_test.go` and `internal/api/stack_edit_test.go`.
- Style: table-driven where useful, otherwise one test per scenario. `testify/require` for fatal, `testify/assert` for non-fatal.
- Fixtures inline as `const` strings (see `exampleStack` at `stack_edit_test.go:14`).
- Server construction: existing tests build `*Server` directly with `s.stackFile` set to a `t.TempDir()` path. Match that.

## Potential Pitfalls

- **`yaml.Node` snippet parsing**: when `yaml.Unmarshal([]byte(snippet), &node)` produces a `DocumentNode`, the actual content is at `node.Content[0]`. Append `node.Content[0]` to the target sequence, not `&node` itself — otherwise you nest a document inside a sequence.
- **Missing top-level sequence key**: if the user's stack has `resources` but not `mcp-servers` (or vice versa), `findMappingValue` returns nil. Create the sequence and append it as a new key/value pair to the top-level mapping, mirroring `replaceOrInsertTools` (`stack_edit.go:189-215`).
- **Null-valued sequence**: if the user wrote `mcp-servers: ` (empty), `yaml.v3` parses it as a scalar null node, not a `SequenceNode`. Detect `Kind == yaml.ScalarNode && Tag == "!!null"` (or `Value == ""`) and replace with a fresh `SequenceNode`.
- **Empty `resourceType`**: existing handler returns 400 via the `default:` branch in the switch. Preserve this exact behavior.
- **Resource-name conflict**: the existing handler does not check for duplicate names. Do not add this check in this fix — different concern, easy to add later, and adding it now broadens the diff. Document in the commit message that name-conflict handling is unchanged.
- **Validation entry point**: if extracting `ValidateStack(*Stack)` proves more invasive than expected (e.g. it currently inlines path-relative file resolution), consider keeping the validation call as `config.ValidateStackFile` after the atomic write — i.e. write first, validate second. **Do not** do this. Validate before write so a bad snippet doesn't land. If extraction is genuinely hard, surface that to the reviewer rather than reordering.
- **Mode preservation**: `atomicWrite` already handles this (`stack_edit.go:264-266`). Do not re-implement; do not pass an explicit mode.
- **Hash-check ordering**: must be "read → hash → patch → re-read → re-hash → compare → atomicWrite". The hook fires between the initial hash and the re-read. Do not reorder.
- **Concurrency test flake**: if `TestHandleStackAppend_SerializesConcurrentCallers` is flaky under `-race`, the cause is almost certainly missing `mu.Lock()`/`Unlock()` around the read-patch-write, or hashing the wrong bytes. Re-check against `setServerTools` line by line.

## Acceptance Criteria

1. `handleStackAppend` no longer calls `yaml.Marshal(stack)` or `os.WriteFile(s.stackFile, ...)` directly.
2. `handleStackAppend` takes `stackFileLock(s.stackFile)`, hashes the original bytes, calls `patchAppendResource`, re-reads + re-hashes before write, and writes via `atomicWrite`.
3. `patchAppendResource` exists and uses `yaml.Node` round-tripping; comments and key order survive the round-trip on a fixture that includes both.
4. New test `TestHandleStackAppend_PreservesCommentsAndOrder` passes.
5. New test `TestHandleStackAppend_ConflictWhenDiskChanged` passes; handler returns HTTP 409 in that case.
6. New test `TestHandleStackAppend_AtomicOnWriteFailure` passes; original file untouched, no leftover `.tmp.*`.
7. New test `TestHandleStackAppend_SerializesConcurrentCallers` passes under `go test -race`.
8. All five existing tests at `stack_test.go:307-395` still pass with no behavioral changes (status codes, response shapes).
9. `golangci-lint` clean.
10. `go test -race ./...` passes.
11. No new dependencies in `go.mod`.
12. `pkg/config/ValidateStackFile`'s exported signature is unchanged. If a `ValidateStack(*Stack)` was extracted, it is exported and `ValidateStackFile` calls it.
13. Frontend (`web/`) is unchanged. (The 409 case is reachable but the wizard's deploy flow surfaces it as a terminal error today; that is acceptable.)

## References

- Investigation: `prompts/gridctl/unsafe-stack-append-rewrite/bug-evaluation.md`
- Reference implementation (read first): `internal/api/stack_edit.go`
- Reference tests (read first): `internal/api/stack_edit_test.go`
- yaml.v3 Node API docs: <https://pkg.go.dev/gopkg.in/yaml.v3#Node>
- Bug site: `internal/api/stack.go:631-698`
