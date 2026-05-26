# Bug Investigation: Vault encryption-state transition not detected by daemon

**Date**: 2026-05-08
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High (security-adjacent regression)
**Fix Complexity**: Small (~20-40 lines in `pkg/vault/store.go` plus regression tests)

## Summary

The reload-on-read mechanism merged in PR #576 (commit 12fe971) picks up content
changes to the active vault file but does not detect transitions between
plaintext (`secrets.json`) and encrypted (`secrets.enc`). When a user runs
`gridctl vault lock` while `gridctl serve` is running, the daemon silently
continues serving plaintext secrets from its in-memory cache, contradicting
the lock semantics promised by `IsLocked()`. Recommended action: fix in the
same area of code, with a regression test that simulates the cross-process
lock scenario.

## The Bug

After `gridctl vault lock` runs in the CLI while a `gridctl serve` daemon is
up:

- **Expected**: Daemon's next read sees the vault as encrypted+locked.
  `IsLocked()` returns `true`, in-memory plaintext is dropped, vault reads
  return empty/locked responses.
- **Actual**: Daemon retains `s.encrypted=false`, `s.locked=false`, and the
  pre-lock plaintext secrets in `s.secrets`. `IsLocked()` returns `false`.
  The HTTP `/api/vault` endpoints, the MCP tool sandbox bindings, and any
  vault-resolving code path continue to serve plaintext.

Discovered as a follow-up to PR #576 by reading the implementation: the
reload-on-read fix stats only the file path that matches the daemon's
**stale** in-memory `s.encrypted` flag, so the file rename from
`secrets.json` → `secrets.enc` is invisible to it.

The same gap exists in reverse (encrypted → plaintext on disk), though no
current CLI command exercises that direction — see "Reproduction" below.

## Root Cause

### Defect Location

`pkg/vault/store.go:616-630` — `reloadIfChanged()`:

```go
func (s *Store) reloadIfChanged() error {
    if s.encrypted && s.locked {
        return nil
    }
    info, err := os.Stat(s.activePathLocked())   // <-- uses stale s.encrypted
    if err != nil {
        return nil                                // <-- silently no-op on ENOENT
    }
    if !info.ModTime().After(s.mtime) && info.Size() == s.size {
        return nil
    }
    return s.loadLocked()
}
```

`pkg/vault/store.go:590-595` — `activePathLocked()`:

```go
func (s *Store) activePathLocked() string {
    if s.encrypted {                              // stale flag drives path choice
        return s.encryptedPath()
    }
    return s.secretsPath()
}
```

### Code Path

1. Daemon starts with plaintext vault: `Load()` sets `s.encrypted=false`,
   `s.locked=false`, populates `s.secrets`.
2. CLI runs `gridctl vault lock` (`cmd/gridctl/vault.go:526` `runVaultLock`):
   - Loads vault into a separate `Store` instance.
   - Calls `Store.Lock(pass)` (`pkg/vault/store.go:404`).
   - `Lock` writes `secrets.enc` (line 432) and removes `secrets.json` (line 437).
3. Daemon receives a read request (e.g. `handleVaultStatus` →
   `internal/api/vault.go:30`, or any `Get`/`List`/`Has`/`Keys`/`Values`/
   `Export`/`ListSets`/`GetSetSecrets` call):
   - Each read method calls `reloadIfChanged()`.
   - `activePathLocked()` returns `secretsPath()` because `s.encrypted` is
     still `false`.
   - `os.Stat(secretsPath())` returns ENOENT → function returns `nil`.
   - In-memory state is unchanged. Daemon serves stale plaintext.

### Why It Happens

The defect is conceptual: `reloadIfChanged()` was designed to detect
**content** changes within the active vault file, not **state-shape**
changes (which file is the active one). It uses the in-memory encryption
state to decide which file to consult, but the in-memory encryption state
is exactly what an external lock/unlock invalidates. The function is asking
the wrong question.

A second contributing factor: a missing active file is currently treated as
a benign no-op (intentional, per `TestStore_ReloadIgnoresMissingFile` at
`pkg/vault/store_test.go:917`). That heuristic is correct for transient
write-in-progress states but wrong for a deliberate file-replacement transition.
The fix must distinguish "active file briefly absent during a write" from
"active file permanently replaced by the other file".

### Similar Instances

`IsLocked()` and `IsEncrypted()` (`pkg/vault/store.go:389-401`) do **not**
call `reloadIfChanged()`. Even after the core defect is fixed, callers that
check lock state without first triggering a read (e.g.
`handleVaultStatus`) will see stale state until the next read request.
This is a smaller follow-on of the same root cause and should be addressed
in the same fix.

## Impact

### Severity Classification

**High** — security-adjacent. The lock action is a confidentiality boundary.
A user who runs `gridctl vault lock` reasonably expects the vault to no
longer hand out plaintext from any process holding it. The current behavior
silently violates that boundary for the duration of the daemon's lifetime.

### User Reach

Anyone using the documented dual-mode pattern (long-running `gridctl serve`
plus CLI vault commands). Per `examples/secrets-vault/README.md`, this is
the expected usage. Bug is fully deterministic when the conditions are met.

### Workflow Impact

- **Critical-path** for the lock-while-serving workflow.
- Not a crash, no data corruption on disk — disk state is correct, only the
  daemon's in-memory cache is stale.
- Fully recoverable by restarting the daemon; the user just doesn't know
  they need to.

### Workarounds

1. Restart `gridctl serve` after every CLI lock — defeats the purpose of
   the long-running daemon and the friction PR #576 was designed to remove.
2. Lock via the daemon's HTTP API (`POST /api/vault/lock`,
   `internal/api/vault.go:85`) instead of the CLI — works correctly because
   the daemon mutates its own state.

Neither workaround is documented; users following the example README will
encounter the bug.

### Urgency Signals

- PR #576 merged today (commit 12fe971). Fixing this gap in the same release
  window prevents users from forming expectations on the partial behavior.
- The current behavior contradicts the documented semantics of
  `IsLocked()` (`pkg/vault/store.go:389`).
- Confidentiality regressions versus the pre-PR-#576 baseline: before
  reload-on-read existed, the daemon ignored everything until restart, and
  users knew that. Now they reasonably expect external changes to be picked
  up — but lock state is the one that isn't.

## Reproduction

### Minimum Reproduction Steps (Direction A — lock while daemon up)

1. Empty/plaintext vault on disk: `~/.gridctl/secrets.json` exists,
   `secrets.enc` does not.
2. Start daemon: `gridctl serve` (loads vault; `s.encrypted=false`).
3. Add a secret via CLI or API so the in-memory cache is non-empty.
4. From a separate terminal: `gridctl vault lock` (creates `secrets.enc`,
   removes `secrets.json`).
5. Hit a daemon read endpoint:
   - `curl http://localhost:PORT/api/vault` returns plaintext.
   - `IsLocked()` returns `false`.
   - `mcp__gridctl__execute` JS that resolves a vault var still returns the
     plaintext value.

This can be reproduced entirely as a unit test using two `*vault.Store`
instances pointed at the same `baseDir`, mirroring the existing
`TestStore_ReloadsOnExternalWrite_*` tests at
`pkg/vault/store_test.go:765` and `:815`.

### Direction B — unlock while daemon up

The bug report cites a "same gap in reverse" for unlock. On audit, the
existing CLI `runVaultUnlock` (`cmd/gridctl/vault.go:553`) does **not**
write anything to disk — `Unlock()` only mutates the CLI's own in-memory
state. There is no current CLI command that converts `secrets.enc` back
into plaintext `secrets.json` on disk. The reverse-direction bug is
therefore latent: it is implied by symmetry of the defect but is not
triggered by any current CLI flow. The fix should still handle it
correctly so future commands (or manual file manipulation) don't
silently break.

### Affected Environments

All platforms. The defect is purely logical — no FS-specific behavior is
involved.

### Non-Affected Environments

- Single-process usage (CLI-only or daemon-only).
- Users who lock through the daemon's HTTP API rather than the CLI.

### Failure Mode

Silent. No error, no log message. Daemon serves stale plaintext indefinitely
until restart. System state on disk is correct; only the daemon's
in-memory cache and state flags are stale. **No data loss.**

## Fix Assessment

### Fix Surface

- `pkg/vault/store.go` — `reloadIfChanged()` rewrite to stat both files
  and detect transitions; secondary update to `IsLocked()`/`IsEncrypted()`
  to also reload (or expose a read-locked variant of `reloadIfChanged()`).
- `pkg/vault/store_test.go` — add regression tests for
  plaintext→encrypted transition, encrypted→plaintext transition (synthetic,
  via direct file manipulation since no CLI exercises this), and
  `IsLocked()` freshness after external lock.
- `internal/api/vault_test.go` — optional handler-level integration test for
  `handleVaultStatus` reflecting an external lock.

### Risk Factors

- The fix must clear `s.secrets`/`s.sets` on plaintext→encrypted transition.
  Failing to do so leaves plaintext in memory — same security gap, different
  layer. Existing tests don't cover this case.
- `loadLocked()` only resets mtime/size on success; the transition path
  must restamp against the **new** active file (`secrets.enc`) even though
  it doesn't load secrets (no passphrase known). A naive reuse of
  `stampMtimeLocked()` after toggling `s.encrypted` does this correctly,
  but the ordering matters.
- The "missing file is no-op" heuristic (preserved by
  `TestStore_ReloadIgnoresMissingFile`) must be retained for the case where
  **both** files are missing (transient write window). Only the
  cross-file-replacement case should change behavior.
- Concurrency: `reloadIfChanged()` runs under the write lock; transitions
  happen in the same critical section as reads, so no extra synchronization
  is needed.

### Regression Test Outline

```go
func TestStore_ReloadDetectsPlaintextToEncryptedTransition(t *testing.T) {
    dir := t.TempDir()
    const pass = "test-passphrase"

    // Daemon loads plaintext vault and primes in-memory state.
    daemon := NewStore(dir)
    must(t, daemon.Load())
    must(t, daemon.Set("API_KEY", "abc123"))
    if daemon.IsLocked() { t.Fatal("expected unlocked at start") }

    // CLI (separate Store) locks the vault.
    cli := NewStore(dir)
    must(t, cli.Load())
    must(t, cli.Lock(pass))

    // Daemon's next read must reflect the lock.
    if !daemon.IsLocked() {
        t.Fatal("daemon did not detect external lock; serving stale plaintext")
    }
    if got := daemon.List(); len(got) != 0 {
        t.Errorf("daemon List() after external lock = %d secrets; want 0", len(got))
    }
    if _, ok := daemon.Get("API_KEY"); ok {
        t.Error("daemon Get(API_KEY) returned a value after external lock")
    }
}
```

Plus a complementary test that flips `secrets.enc` → `secrets.json` via
direct file manipulation to cover the reverse direction, and a test that
`IsLocked()` alone (no preceding read) reports fresh state.

## Recommendation

**Fix immediately.** The bug is a confidentiality regression against the
just-shipped #576 feature. Root cause is precisely understood, the fix is
small and local to `pkg/vault/store.go`, and the existing test suite
provides a clear template for the regression test. Ship the fix in the next
release; do not wait.

## References

- PR #576 / commit 12fe971 — the reload-on-read fix this bug is a
  follow-up to.
- Defect: `pkg/vault/store.go:616-630` (`reloadIfChanged`),
  `pkg/vault/store.go:590-595` (`activePathLocked`).
- Existing reload tests as templates: `pkg/vault/store_test.go:765`
  (`TestStore_ReloadsOnExternalWrite_Plaintext`), `:815`
  (`TestStore_ReloadsOnExternalWrite_Encrypted`), `:855`
  (`TestStore_LockedEncryptedReadIsNoop`), `:917`
  (`TestStore_ReloadIgnoresMissingFile`).
- Documented dual-mode usage: `examples/secrets-vault/README.md:95-102`.
