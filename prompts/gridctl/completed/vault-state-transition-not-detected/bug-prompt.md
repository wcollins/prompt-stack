# Bug Fix: Vault encryption-state transition not detected by daemon

## Context

`gridctl` is a Go-based CLI/daemon tool. The `pkg/vault` package implements a
secrets store backed by either a plaintext `secrets.json` file or an
encrypted `secrets.enc` file in the user's vault directory. The same vault
can be accessed by two long-lived contexts at once:

- A daemon process (`gridctl serve`, served from `internal/api/`) which
  holds a single `*vault.Store` and serves HTTP `/api/vault/...` endpoints
  plus an MCP tool execution sandbox that resolves vault values.
- The CLI (`cmd/gridctl/vault.go`) which spins up its own short-lived
  `*vault.Store` for each invocation of `gridctl vault {set,get,lock,unlock,...}`.

PR #576 (commit 12fe971) added a "reload-on-read" mechanism to the daemon's
`Store` so that CLI writes to the vault file are picked up automatically on
the daemon's next read. Each read method calls a private
`reloadIfChanged()` that stats the active backing file and re-loads when
mtime or size has advanced.

The vault state has two relevant flags:

- `s.encrypted` — true when the vault is currently backed by `secrets.enc`.
- `s.locked` — true when encrypted and the in-memory passphrase isn't known
  (so plaintext can't be served).

## Investigation Context

- **Root cause confirmed**: `reloadIfChanged()` at `pkg/vault/store.go:616-630`
  uses `s.activePathLocked()` (line 590-595), which selects the file path
  based on the **stale** `s.encrypted` flag. When CLI lock swaps
  `secrets.json` → `secrets.enc`, the daemon stats the now-missing
  `secrets.json`, hits ENOENT, returns `nil` (no-op), and continues serving
  stale plaintext from `s.secrets`.
- **Risk mitigations baked in**: the fix must keep the existing
  "missing-file → no-op" semantics for the case where **both** files are
  briefly absent (in-flight writes — covered by
  `TestStore_ReloadIgnoresMissingFile` at `pkg/vault/store_test.go:917`).
  Only the cross-file-replacement case should change behavior.
- **Reproduction confirmed**: deterministic via two `*vault.Store` instances
  pointed at the same `baseDir`, mirroring existing
  `TestStore_ReloadsOnExternalWrite_*` tests.
- **Severity**: High — silent confidentiality regression. Daemon serves
  plaintext after lock until restart.
- **Full investigation**:
  `~/code/prompt-stack/prompts/gridctl/vault-state-transition-not-detected/bug-evaluation.md`

## Bug Description

When a user runs `gridctl vault lock` while `gridctl serve` is running:

1. CLI's `Store.Lock()` writes `secrets.enc` and removes `secrets.json`.
2. Daemon's next vault read calls `reloadIfChanged()` →
   `activePathLocked()` → returns `secretsPath()` (because `s.encrypted` is
   still false) → `os.Stat(secretsPath())` → ENOENT → no-op.
3. Daemon's `IsLocked()` returns false, in-memory `s.secrets` retains the
   pre-lock plaintext, and `/api/vault` endpoints + MCP tool sandbox
   bindings continue to hand out plaintext secrets.

The same defect exists in reverse (encrypted → plaintext on disk), but no
current CLI command exercises that direction. The fix should still handle
it correctly because:

- It costs nothing extra (the symmetric branch falls out of the same
  detection logic).
- A future "convert vault to plaintext" command, manual file manipulation,
  or backup-restore flow would otherwise re-introduce the same gap.

## Root Cause

**File:line**: `pkg/vault/store.go:616-630` (`reloadIfChanged`) and
`pkg/vault/store.go:590-595` (`activePathLocked`).

The current `reloadIfChanged()` answers "did the active file change?" by
stat-ing whichever file the daemon currently *believes* is active. But the
daemon's belief about which file is active is exactly what an external
lock/unlock changes. The function is asking the wrong question.

Correct question: "What is the current shape of the vault on disk, and
does the daemon's in-memory state still match it?"

## Fix Requirements

### Required Changes

1. Rewrite `reloadIfChanged()` so that it inspects both `secrets.enc` and
   `secrets.json` on every call, in this order:

   a. If `secrets.enc` exists:
      - If `s.encrypted` is currently false → **plaintext-to-encrypted
        transition**. Set `s.encrypted = true`, `s.locked = true`, clear
        `s.passphrase = ""`, clear `s.secrets` and `s.sets` to fresh empty
        maps (so plaintext is no longer in memory), stamp mtime/size from
        `secrets.enc`'s `os.FileInfo`. Return nil — no `loadLocked()` call,
        because we don't have the passphrase.
      - Else (`s.encrypted` already true): existing logic — if mtime or size
        advanced past the cached baseline, call `loadLocked()`; otherwise
        no-op. Note the `s.encrypted && s.locked` early-out can stay for
        this branch.

   b. Else if `secrets.json` exists:
      - If `s.encrypted` is currently true → **encrypted-to-plaintext
        transition**. Set `s.encrypted = false`, `s.locked = false`, clear
        `s.passphrase = ""`, then call `loadLocked()` (which will read the
        plaintext file and stamp mtime).
      - Else (`s.encrypted` already false): existing logic — if mtime or
        size advanced past the cached baseline, call `loadLocked()`;
        otherwise no-op.

   c. Else (neither file exists): preserve current "no-op, retain in-memory
      state" behavior. This covers the in-flight write window already
      protected by `TestStore_ReloadIgnoresMissingFile`.

2. Update `IsLocked()` and `IsEncrypted()` (`pkg/vault/store.go:389-401`)
   so they observe fresh disk state. The simplest correct approach: take
   the write lock, call `reloadIfChanged()`, then read the flag. (These
   accessors currently take an RLock — a transition reload requires the
   write lock, so this is a real change in lock acquisition. Document in a
   short comment.) Alternatively, if performance matters, factor the
   transition-detection out into a helper that runs with the write lock and
   have the accessors call it before re-acquiring an RLock; the simpler
   version is preferable unless benchmarks justify otherwise.

3. Update doc comments on `reloadIfChanged()`, `activePathLocked()`,
   `IsLocked()`, and `IsEncrypted()` to reflect the new semantics. Keep them
   short — one line on each.

### Constraints

- **Must not** break the "missing-file → no-op" semantic when both files
  are absent. `TestStore_ReloadIgnoresMissingFile` must continue to pass.
- **Must not** break the corrupt-file resilience covered by
  `TestStore_ReloadIgnoresCorruptFile` (`pkg/vault/store_test.go:889`) —
  parse errors during `loadLocked()` must not wipe in-memory secrets.
  Achieved by `parseSecretsData()` returning fresh maps that the caller
  swaps in atomically; do not regress that pattern.
- **Must not** clear in-memory state on the encrypted-to-plaintext
  transition until `loadLocked()` succeeds (avoid wiping live data on a
  parse failure).
- **Must not** introduce file-watching, polling goroutines, inotify, or
  FSEvents. Reload-on-read is the chosen pattern; preserve it.
- **Must not** change the public API of `*vault.Store` beyond doc-comment
  updates.
- The fix touches code on the hot path of every vault read; keep the extra
  work to two `os.Stat` calls per read (acceptable; same order as the
  current single stat).

### Out of Scope

- File watching / inotify / FSEvents.
- Cross-process passphrase sharing (after CLI re-locks with a new
  passphrase, the daemon legitimately doesn't know it; locked state is the
  correct response).
- A new CLI command to convert encrypted → plaintext on disk.
- Race window between stat and read (same race exists today).
- Refactoring the `locked`/`encrypted` flags into a single state enum (a
  cleanup worth doing later but unrelated to this defect).

## Implementation Guidance

### Key Files to Read

- `pkg/vault/store.go` — the entire file. Pay attention to:
  - `Store` struct (lines 16-28) — the in-memory state being kept fresh.
  - `Load()` (line 41) — the original load logic; the transition path
    should match its file-precedence behavior (encrypted first, then
    plaintext).
  - `loadLocked()` (line 538) — the existing in-place reload; reused by
    the encrypted-to-plaintext transition path.
  - `Lock()` (line 404) and `Unlock()` (line 448) — for cross-checking that
    the new state assignments match what these methods produce.
  - `activePathLocked()` (line 590) and `stampMtimeLocked()` (line 601) —
    the helpers being changed/used.
  - `reloadIfChanged()` (line 616) — the function being rewritten.
- `pkg/vault/store_test.go` — the existing reload tests as templates,
  especially `TestStore_ReloadsOnExternalWrite_Plaintext` (line 765) and
  `TestStore_ReloadsOnExternalWrite_Encrypted` (line 815). The new tests
  should follow the same two-Store pattern.
- `internal/api/vault.go` — `handleVaultStatus` (line 30) and
  `handleVaultLock` (line 85) to confirm what the API surface depends on.
- `cmd/gridctl/vault.go` — `runVaultLock` (line 526) and `runVaultUnlock`
  (line 553), to confirm the on-disk effects of CLI commands.

### Files to Modify

- `pkg/vault/store.go` — rewrite `reloadIfChanged()` (line 616-630),
  update `IsLocked()` and `IsEncrypted()` (lines 389-401), refresh related
  doc comments.
- `pkg/vault/store_test.go` — add regression tests (see "Regression Test"
  section).
- `internal/api/vault_test.go` — *optional* integration-level test that
  `handleVaultStatus` reflects an externally-locked vault. Skip this if it
  duplicates the unit-level test value.

### Reusable Components

- `s.encryptedPath()` (line 531) and `s.secretsPath()` (line 526) — use
  these directly for the dual-stat instead of going through
  `activePathLocked()`.
- `s.stampMtimeLocked()` (line 601) — reuse it after toggling `s.encrypted`
  so it stamps against the correct file.
- `s.loadLocked()` (line 538) — reuse for the encrypted-to-plaintext
  transition (it already handles plaintext loading and mtime stamping).
- `parseSecretsData()` (line 84) — the atomic-swap pattern is critical;
  don't bypass it.

### Conventions to Follow

- Pure-stdlib testing. No testify, no mocking framework. Use `t.TempDir()`,
  `t.Fatalf`, `t.Errorf`. Tests in `pkg/vault/store_test.go` use a
  `must(t, err)` style — match the surrounding style of the file.
- Doc comments are short, one-line where possible. Multi-line only when
  there's a non-obvious invariant to capture (the existing comments on
  `parseSecretsData`, `stampMtimeLocked`, and `reloadIfChanged` are good
  references).
- Errors wrap with `fmt.Errorf("...: %w", err)`. No bare returns of
  unannotated errors.
- All vault state mutations happen under `s.mu` (write lock for mutations,
  read lock for accessors that don't trigger reload). The new
  reload-on-status logic in `IsLocked()`/`IsEncrypted()` switches them to
  the write lock; that's intentional.
- Match the existing commit-message style for this repo. Per
  `~/.claude/CLAUDE.md`: type prefix (`fix:`), imperative subject under 50
  chars, sign with `-S`, no Co-authored-by, no Claude mention.

## Regression Test

### Test Outline

Add at minimum these tests to `pkg/vault/store_test.go`:

1. `TestStore_ReloadDetectsPlaintextToEncryptedTransition`
   - Daemon loads plaintext vault, sets a key, asserts `IsLocked() == false`.
   - CLI Store loads, calls `Lock(pass)`.
   - Daemon `IsLocked()` must now be true; `List()` must be empty;
     `Get(...)` must return `(_, false)` for the previously-set key.

2. `TestStore_ReloadDetectsEncryptedToPlaintextTransition`
   - Daemon loads an encrypted vault (via `Lock` then a fresh Store
     `Load`), asserts `IsLocked() == true`.
   - Simulate the disk-side transition by calling
     `os.WriteFile(secrets.json, plaintextJSON, 0600)` and
     `os.Remove(secrets.enc)` directly (no current CLI command does this,
     so the test exercises the symmetric branch via direct manipulation).
   - Daemon's next read must surface the new plaintext secrets and
     `IsLocked()` must be false.

3. `TestStore_IsLockedReflectsExternalLock`
   - Daemon loads plaintext.
   - CLI `Lock(pass)`.
   - Daemon `IsLocked()` must be true **without** any preceding read call
     (verifies the `IsLocked()` reload-on-call change).

### Existing Test Patterns

- Tests live in the same package (`package vault`) as the implementation.
- Each test gets `dir := t.TempDir()`.
- Two-Store pattern: `daemon := NewStore(dir); cli := NewStore(dir)`,
  each with their own `Load()` call.
- Assertions use `t.Errorf` / `t.Fatalf` with format-string messages; no
  testify or assertion helper library.
- Reference `TestStore_ReloadsOnExternalWrite_Plaintext` (line 765) and
  `TestStore_ReloadsOnExternalWrite_Encrypted` (line 815) as templates.

## Potential Pitfalls

- **Order of state mutation matters on plaintext-to-encrypted**: clear
  `s.secrets`/`s.sets` to fresh empty maps **before** anything that could
  early-return. A panic or future change that exits between flag toggle
  and map clear would leave plaintext in memory with `locked=true`
  reported externally. Best practice: do the full state reset
  (`encrypted=true`, `locked=true`, `passphrase=""`, fresh maps,
  `stampMtimeLocked()`) as a single uninterrupted sequence.
- **Encrypted-to-plaintext transition under failure**: if `loadLocked()`
  fails (e.g. plaintext file is malformed), don't leave the store in a
  half-transitioned state. Either roll back the flag changes or trust
  `parseSecretsData()`'s atomic-swap behavior (existing pattern). The
  simplest correct approach: toggle the flags first, then call
  `loadLocked()`; if `loadLocked()` returns an error, the in-memory
  secrets are still the previous ones (the swap inside
  `loadLocked()`/`parseSecretsData()` doesn't happen on failure). Acceptable.
- **`stampMtimeLocked()` uses `activePathLocked()`**: after toggling
  `s.encrypted`, calling `stampMtimeLocked()` will stamp against the new
  active file. Confirm this is what you want (yes — the new file is the
  one we want to track for future change detection).
- **`Lock()` and `Unlock()` already stamp mtime correctly** for in-process
  transitions. The new `reloadIfChanged()` logic handles the
  cross-process equivalent. Don't accidentally interfere with the
  in-process paths.
- **`ChangePassphrase()` (line 486)** writes a new `secrets.enc` while the
  vault is already encrypted — already handled by the existing
  same-file-mtime-advance branch; verify the rewrite still covers it.
- **Tests that don't call `Load()`**: a few existing tests rely on the
  `NewStore` zero state. Make sure the new `IsLocked()`/`IsEncrypted()`
  reload behavior (which will now stat the disk) doesn't surprise them.
  Stat'ing a non-existent dir returns ENOENT for both files, hitting the
  "neither exists → no-op" branch, so this should be fine — confirm by
  running the full vault test suite.

## Acceptance Criteria

1. `gridctl vault lock` from the CLI, while `gridctl serve` is running,
   results in the daemon's next vault read returning a locked response
   (`/api/vault` shows locked status, no plaintext returned).
2. `IsLocked()` returns `true` after an external lock without requiring a
   preceding read.
3. The encrypted-to-plaintext direction is handled symmetrically (verified
   by unit test using direct file manipulation).
4. All three new regression tests above pass.
5. `TestStore_ReloadIgnoresMissingFile` continues to pass — neither-file
   case is still a no-op.
6. `TestStore_ReloadIgnoresCorruptFile` continues to pass — corrupt-file
   case still preserves in-memory state.
7. All other existing tests in `pkg/vault/` and `internal/api/` continue to
   pass: `go test -race ./pkg/vault/... ./internal/api/...`.
8. `golangci-lint run ./...` is clean for the touched files.
9. No new goroutines, file watchers, or polling timers are introduced.
10. No new public API on `*vault.Store`.

## References

- Bug investigation document:
  `~/code/prompt-stack/prompts/gridctl/vault-state-transition-not-detected/bug-evaluation.md`
- PR #576 / commit 12fe971 — the reload-on-read fix this is a follow-up to.
- Defect site: `pkg/vault/store.go:616-630` (`reloadIfChanged`).
- Helper to update: `pkg/vault/store.go:590-595` (`activePathLocked`).
- Accessors to update: `pkg/vault/store.go:389-401`
  (`IsLocked` / `IsEncrypted`).
- Existing reload tests as templates: `pkg/vault/store_test.go:765`,
  `:815`, `:855`, `:889`, `:917`.
- CLI commands: `cmd/gridctl/vault.go:526` (`runVaultLock`), `:553`
  (`runVaultUnlock`).
- API handlers consuming the state: `internal/api/vault.go:30`
  (`handleVaultStatus`), `:85` (`handleVaultLock`).
