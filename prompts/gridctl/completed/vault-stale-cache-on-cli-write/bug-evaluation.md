# Bug Investigation: Vault Stale Cache on CLI Write

**Date**: 2026-05-08
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

When `gridctl serve` is running, `gridctl vault import` (and `vault set`, `vault rm`) successfully writes to `~/.gridctl/vault/secrets.json` but the running server's UI continues to show stale state until restart. Root cause is a server-side in-memory cache (`vault.Store.secrets`) that loads once at startup and is never refreshed on read. The fix is small (add reload-on-read with an mtime gate to read methods) and the same change incidentally fixes a latent issue where stale credentials are served to the skill-source credential resolver and `${vault:KEY}` expansion.

## The Bug

**Reported behavior**

```
admin@titan:~$ gridctl serve
gridctl started in stackless mode
  Web UI: http://localhost:8180
  ...

admin@titan:~$ gridctl vault import .vars
14:16:04 INFO Imported secrets count=4 file=.vars
```

In the running web UI, the Vault sidebar continues to display "0 secrets" / "No secrets stored" after a browser refresh. Restarting the server (`gridctl stop && gridctl serve`) makes the imported secrets appear.

**Expected**: After CLI vault writes succeed, the running server's UI should reflect the new state on the next browser refresh (live push not required).

**Discovery**: User report while exercising the documented `gridctl vault import` onboarding flow.

## Root Cause

### Defect Location

The read-only methods on `vault.Store` do not reload state from disk before returning. They serve the in-memory map populated at startup.

- `pkg/vault/store.go:166-176` — `Store.List()` returns `s.secrets` directly under `RLock` without reading disk
- `pkg/vault/store.go:93-102` — `Store.Get()` same pattern
- `pkg/vault/store.go:223-243` — `Has()`, `Values()`
- `pkg/vault/store.go:275-297` — `ListSets()`
- `pkg/vault/store.go:345-358` — `GetSetSecrets()`

By contrast, all write methods (`Set`, `SetWithSet`, `Delete`, `Import`, `SetSecretSet`, `CreateSet`, `DeleteSet`) call `s.loadLocked()` (`pkg/vault/store.go:505-540`) before mutating. So write paths self-heal; read paths do not.

### Code Path

1. `gridctl serve` starts, calls `StackController.Serve` → `runStacklessDaemonChild`
2. `pkg/controller/controller.go:117-125` (and `:140-148`, `:217-231` for deploy mode) creates `vault.NewStore(state.VaultDir())` and calls `Load()` exactly once
3. The Store is injected into the API server via `Server.SetVaultStore` (`internal/api/api.go:141-144`)
4. From a separate shell, `gridctl vault import .vars` runs `runVaultImport` (`cmd/gridctl/vault.go:394-417`) which creates a *different* Store instance against the same `baseDir` and calls `Store.Import()` — atomically writes `secrets.json` correctly
5. Browser refresh issues `GET /api/vault` → `Server.handleVaultList` (`internal/api/vault.go:114-136`) → `s.vaultStore.List()` → returns the server's stale in-memory map → UI shows 0 secrets

### Why It Happens

The server holds a single `*vault.Store` instance that owns an in-memory `map[string]Secret`. The only mechanism that refreshes that map is `loadLocked()`, which is called from write paths and from `Load()` at startup. There is:

- No file watcher on `secrets.json` / `secrets.enc`
- No reload API endpoint
- No notification from CLI writers to the running server
- No mtime check on reads

The CLI process correctly takes the cross-process file lock (`state.WithLock("vault", ...)`), so concurrent writes are safe — but read coherency between processes is missing.

### Similar Instances

The same pattern (read methods that don't reload) exists for every read-only accessor on `Store`. All become correct with one helper.

The codebase already has a similar synchronization pattern done correctly elsewhere — `pkg/reload/watcher.go` watches stack files via `fsnotify` and `pkg/reload/reload.go` re-loads `gridctl.yaml` on change. That mechanism is wired only for stack configuration, not vault state.

## Impact

### Severity Classification

- **Bug class**: Stale-read / cache-coherency. Two processes that share a file-backed store disagree about its contents.
- **Reasoning for High (not Critical)**: The on-disk source of truth is correct. Restarting the server fully recovers state. No data corruption.
- **Reasoning for High (not Medium)**: Manifests on a primary documented onboarding flow, affects every CLI write while daemon is up, and silently serves stale credentials to runtime systems (skill source auth, `${vault:KEY}` expansion). Silent inconsistency is worse than a loud failure.

### User Reach

Every user who runs `gridctl vault import` / `set` / `rm` while a `gridctl serve` daemon is running. Given that `gridctl serve` is the persistent mode and CLI vault writes are the documented mechanism for adding secrets, this is the common path.

### Workflow Impact

- UI shows stale vault state until server restart
- Skill source credential resolution (`internal/api/skills.go:154,275,405,410` → `resolveCredentialRef` → `vaultStore.Get`) uses the stale cache; tokens added/rotated via CLI are unavailable to the running server
- `${vault:KEY}` expansion (`pkg/config/expand.go:36`) on stack reload sees stale values

### Workarounds

- `gridctl stop && gridctl serve` after CLI vault changes — works, undocumented
- Use the API/UI to add secrets instead of CLI — works for `set` and individual operations, but the UI does not expose `import` (`web/src/components/vault/VaultPanel.tsx` shows CLI instructions only)

### Urgency Signals

- 100% reproducible
- Active user report (this investigation)
- Touches credential rotation correctness (security posture)
- The documented "bulk import" flow in `examples/secrets-vault/README.md` runs head-first into this bug

## Reproduction

### Minimum Reproduction Steps

1. `gridctl serve` (daemon or `--foreground`)
2. From a separate shell, prepare `.vars` with a few `KEY=VALUE` lines
3. `gridctl vault import .vars` — observe `Imported secrets count=N`
4. In the running browser UI, refresh the Vault panel — observe "0 secrets stored"
5. `gridctl stop && gridctl serve` — observe secrets now appear

### Affected Environments

- All operating systems (logic is platform-agnostic)
- Both daemon and `--foreground` mode
- Both plaintext (`secrets.json`) and encrypted (`secrets.enc`) vaults
- All gridctl versions that have CLI vault writes + persistent server (current `0.1.0-beta.8`)

### Non-Affected Environments

- Single-process flows where the same server-owned Store performs the write (e.g., adding a secret via the UI's `POST /api/vault`)
- One-shot CLI commands without a running daemon — no cache, no problem

### Failure Mode

- Silent: CLI reports success, UI lies. Server logs show nothing wrong.
- Recoverable: on-disk vault is correct; restart heals state.
- Side effect on runtime: stale `Get()` results from skill auth and `${vault:KEY}` resolution.

## Fix Assessment

### Fix Surface

- `pkg/vault/store.go` — the primary change. Add an mtime-gated reload helper and call it from each read method.
- `pkg/vault/store_test.go` — add a regression test covering "two `Store` instances against the same `baseDir`, second sees first's writes."
- Optionally `internal/api/vault_test.go` — handler-level test exercising the stale-read scenario via the HTTP layer.

### Risk Factors

- Encrypted vault re-decrypt cost on read: must be mtime-gated, otherwise every UI refresh re-runs Argon2id KDF. The user-selected approach explicitly requires the gate.
- Lock semantics: read methods currently take `RLock`. Reload mutates state, so it needs the write lock. Cleanest implementation: take `Lock` at the top of each read, do mtime check, optionally reload, then proceed. Or: stat first under no lock, take write lock only when stat indicates change.
- Locked-vault behavior: if `s.encrypted && s.locked`, the server cannot reload encrypted contents (no passphrase in memory). The reload path must be a no-op in this state, preserving the locked status (read methods that surface secret values must already short-circuit on `IsLocked`).
- Cross-process file lock: reads should not contend for `state.WithLock("vault", ...)` — that's a write coordination primitive. Reload-on-read should rely solely on atomic file writes already done by writers, plus a stat to detect changes. Atomic writes (rename) on POSIX are observed atomically by readers.

### Regression Test Outline

```go
func TestStoreReloadsOnExternalWrite(t *testing.T) {
    dir := t.TempDir()

    server := vault.NewStore(dir)
    require.NoError(t, server.Load())

    // Simulate CLI process: separate Store instance, same baseDir
    cli := vault.NewStore(dir)
    require.NoError(t, cli.Load())
    require.NoError(t, cli.Set("API_KEY", "abc123"))

    // Server-side read should now see the CLI's write
    secrets := server.List()
    require.Len(t, secrets, 1)
    require.Equal(t, "API_KEY", secrets[0].Key)

    val, ok := server.Get("API_KEY")
    require.True(t, ok)
    require.Equal(t, "abc123", val)
}
```

A second test should exercise the encrypted-vault path (CLI writes through `secrets.enc` while server has the passphrase cached), and a third should assert the mtime gate avoids redundant reloads (e.g., spy on file open count).

## Recommendation

**Fix immediately, in the next release.** Implement mtime-gated reload-on-read in `vault.Store` so all read methods (`List`, `Get`, `Has`, `Values`, `ListSets`, `GetSetSecrets`) refresh from disk when the underlying file has changed. This is the chosen approach because:

1. It eliminates the bug at the source: any future writer (CLI, manual edit, sibling tools) is automatically reflected in the server.
2. It composes with both plaintext and encrypted vaults — the only nuance is the mtime gate for the encrypted path to avoid Argon2id cost on every refresh.
3. It does not introduce a goroutine, watcher lifecycle, or new dependency.
4. It transparently fixes the secondary issue with stale credentials in skill source auth and `${vault:KEY}` expansion.

The fix should ship with a regression test covering the multi-Store scenario (no such test exists today) and a brief AGENTS.md / README note acknowledging that vault state is now coherent across CLI and daemon.

## References

- pkg/vault/store.go — Store implementation, all read/write methods
- internal/api/vault.go — HTTP handlers calling stale read methods
- internal/api/skills.go — credential resolution against same stale Store
- pkg/config/expand.go — `${vault:KEY}` expansion against same stale Store
- pkg/reload/watcher.go — pattern for fsnotify-based reload (alternative, not chosen)
- examples/secrets-vault/README.md — documented bulk import flow that hits the bug
