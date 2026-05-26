# Bug Fix: Vault Stale Cache on CLI Write

## Context

gridctl is a Go CLI/daemon tool (think Docker Compose for MCP servers) at `/Users/william/code/gridctl`. It runs as a long-lived daemon (`gridctl serve`) that exposes a web UI, and ships a CLI that can directly mutate the user's vault on disk (`~/.gridctl/vault/secrets.json` or `secrets.enc`). The vault is implemented in `pkg/vault/store.go` as a mutex-protected `Store` with an in-memory `secrets` map. Both the daemon and the CLI instantiate their own `Store` against the same `baseDir`. Cross-process write coordination uses a file lock via `state.WithLock("vault", ...)`. Atomic writes are done with `atomicWrite` (rename-based).

The architecture relevant to this fix:
- `Store.Load()` populates the in-memory map from `secrets.json` (or `secrets.enc` if encrypted)
- All write methods (`Set`, `Delete`, `Import`, etc.) call `loadLocked()` before mutating, so they self-heal against external writes
- All read methods (`List`, `Get`, `Has`, `Values`, `ListSets`, `GetSetSecrets`) read from `s.secrets` under `RLock` without ever consulting disk after the initial load

## Investigation Context

- **Root cause confirmed**: read methods on `vault.Store` never reload from disk. The daemon's Store is loaded once at startup and serves stale data forever (see `pkg/vault/store.go:166-176` for `List`, `:93-102` for `Get`).
- **Repro**: 100% deterministic — start `gridctl serve`, run `gridctl vault import .vars` from a separate shell, refresh the UI, observe stale state. Restart fixes it.
- **Affects both**: plaintext (`secrets.json`) and encrypted (`secrets.enc`) vaults; daemon and `--foreground` mode.
- **Secondary impact**: same stale `Get()` is used by `internal/api/skills.go` (skill source credential resolution at request time) and `pkg/config/expand.go:36` (`${vault:KEY}` expansion). The fix incidentally resolves both.
- **Risk mitigations baked into the fix**:
  - Encrypted vault must use an mtime gate (avoid running Argon2id KDF on every UI refresh)
  - Reload must be a no-op when `s.encrypted && s.locked` (no passphrase available)
  - Reload-on-read must NOT take `state.WithLock("vault", ...)` — that primitive is for cross-process write coordination and would serialize all reads against any writer
- **Full investigation**: `prompts/gridctl/vault-stale-cache-on-cli-write/bug-evaluation.md`

## Bug Description

When `gridctl serve` is running and the user runs CLI vault writes (`gridctl vault import .vars`, `gridctl vault set KEY VALUE`, `gridctl vault rm KEY`) from another shell, the writes succeed on disk but the running server's Vault UI continues to show the pre-write state until the server is restarted. Specifically, the CLI logs `Imported secrets count=4`, but `GET /api/vault` returns the stale list. The same staleness affects:

- The Vault UI (`web/src/components/vault/VaultPanel.tsx`) showing "0 secrets / No secrets stored" after a successful CLI import
- Skill source credential resolution (`internal/api/skills.go:154,275,405,410`) — newly added/rotated tokens are not visible to the running server until restart
- `${vault:KEY}` expansion in stack reload (`pkg/config/expand.go:36`)

## Root Cause

`Store` reads serve from an in-memory `secrets map[string]Secret` populated at startup. The map is only refreshed when the same Store instance writes (write methods call `loadLocked()` first), so external writes from another process never propagate. The fix is to reload from disk on read, gated by an mtime check so we don't redundantly re-decrypt or re-parse on every call.

## Fix Requirements

### Required Changes

1. **Add a `reloadIfChanged()` helper to `Store`** in `pkg/vault/store.go` that:
   - Stats the active backing file (`encryptedPath()` if `s.encrypted`, otherwise `secretsPath()`)
   - Compares the file's `ModTime` against a new `mtime time.Time` field cached on `Store`
   - If the file is missing, treats it as unchanged (don't clear in-memory state on a transient stat error — return nil)
   - If `s.encrypted && s.locked`, returns nil (we have no way to decrypt; preserve locked status)
   - If changed, calls `loadLocked()` and updates the cached `mtime` on success
   - Caller must hold the write lock (mirrors `loadLocked()` contract)
2. **Update `Store.loadLocked()`** to set `s.mtime` after a successful read, and to set it on initial `Load()` as well so the first read after startup is a cheap no-op.
3. **Convert read-only methods to call `reloadIfChanged()`** before reading. Affected methods (all in `pkg/vault/store.go`):
   - `Get(key string) (string, bool)` (`:93`)
   - `List() []Secret` (`:166`)
   - `Has(key string) bool` (`:223`)
   - `Values() []string` (`:232`)
   - `Keys() []string` (`:211`)
   - `Export() map[string]string` (`:199`)
   - `ListSets() []SetSummary` (`:275`)
   - `GetSetSecrets(setName string) []Secret` (`:346`)
   These currently use `RLock`. They must take the write lock instead (so reload can mutate state). For a vault sized in dozens of secrets this is acceptable — there is no read-heavy concurrent workload. Document this trade-off in a brief comment on `reloadIfChanged()`.
4. **Do NOT modify** `IsLocked()`, `IsEncrypted()` — those reflect Store-level state, not vault contents, and reloading on each call is unnecessary churn.
5. **Add a regression test** in `pkg/vault/store_test.go` covering the multi-process scenario:
   - Create two `Store` instances against the same `t.TempDir()`
   - Both call `Load()`
   - One writes via `Set`/`Import`
   - The other observes the writes via `List` and `Get`
   - Cover both the plaintext path and the encrypted path (use `Lock`/`Unlock` to set up encryption, share the passphrase between both Stores)
   - Add a test that confirms the mtime gate avoids redundant work — instrument by stubbing the load (e.g., a counter on the file path) or asserting that two consecutive reads without external write don't re-parse. Simplest: track call count of `parseSecretsData` via a test-only hook OR verify equivalent behavior through observable state.
6. **Add a handler-level test** in `internal/api/vault_test.go` that creates a `Store`, wires it to `Server` via `SetVaultStore`, then writes through a *second* `Store` against the same baseDir, then asserts `GET /api/vault` returns the new state.

### Constraints

- Do NOT introduce a file watcher (fsnotify) or background goroutine. The user-selected approach is read-through with mtime gating; keep it that way.
- Do NOT take the cross-process `state.WithLock("vault", ...)` from read paths. That lock is for write coordination; using it on reads would serialize every UI refresh behind any in-flight write across processes.
- Do NOT change the wire format of `secrets.json` or `secrets.enc`.
- Do NOT change the behavior of write methods. They already call `loadLocked()`; no edit required there beyond ensuring `loadLocked()` updates `s.mtime` consistently.
- Encrypted-locked path must remain a no-op for reload — do not attempt to decrypt without a passphrase.
- Preserve the existing public API of `Store`. No new exported method other than (optionally) the helper if it must be exported for tests.

### Out of Scope

- Live UI push (websocket/SSE) for vault changes — UI still updates on next browser refresh, not in real time.
- File watcher infrastructure for vault — explicitly rejected in favor of mtime-gated reload.
- Routing CLI vault commands through the daemon's HTTP API — larger refactor, separate decision.
- Documenting or changing behavior when the user manually edits `secrets.json` with a text editor — the same fix happens to make this work, but it's not a supported flow and shouldn't be advertised.
- Changes to the React Vault panel — frontend is fine; the bug is server-side.

## Implementation Guidance

### Key Files to Read

- `pkg/vault/store.go` — the file you'll be modifying. Pay special attention to `Load` (`:37`), `loadLocked` (`:505`), `Set` (`:104`) for the existing reload-before-write pattern, and the read methods listed above.
- `pkg/vault/store_test.go` — existing test patterns for `Store`, including how plaintext vs encrypted is set up and how the temp dir / state.WithLock interaction works.
- `internal/api/vault.go` — the HTTP handlers that call read methods. No edits needed; just understand the call site.
- `internal/api/api.go:141-144` — `Server.SetVaultStore` for wiring in tests.
- `pkg/state/locks.go` (or wherever `state.WithLock` lives) — confirms the file-lock semantics so you don't accidentally use it on reads.

### Files to Modify

- `pkg/vault/store.go`:
  - Add `mtime time.Time` field to `Store` struct (`:16-24`)
  - Add `reloadIfChanged()` method (place near `loadLocked` for proximity, around `:505`)
  - Update `loadLocked()` to set `s.mtime` after successful read
  - Update `Load()` to call into the same path (`Load` already takes the lock; consider whether to factor `Load` to call `loadLocked` to avoid divergence — currently they share `parseSecretsData` but not the mtime stamping)
  - Replace `RLock` with `Lock` and prepend `s.reloadIfChanged()` in: `Get`, `Has`, `Values`, `Keys`, `Export`, `List`, `ListSets`, `GetSetSecrets`
- `pkg/vault/store_test.go`:
  - Add `TestStoreReloadsOnExternalWritePlaintext`
  - Add `TestStoreReloadsOnExternalWriteEncrypted`
  - Add `TestStoreReloadMtimeGateAvoidsRedundantWork` (or fold into one of the above)
- `internal/api/vault_test.go`:
  - Add `TestVaultListReflectsExternalWrites` exercising the HTTP path

### Reusable Components

- `loadLocked()` already handles plaintext, encrypted-unlocked, and encrypted-locked correctly. Don't duplicate that logic — call it.
- `state.WithLock("vault", ...)` exists for write coordination — leave it alone.
- `parseSecretsData()` (`pkg/vault/store.go:67-90`) handles the legacy/new wire formats. The new helper does not need to know about formats.
- `os.Stat` for the mtime check.

### Conventions to Follow

- gridctl uses concise inline comments only when behavior is non-obvious (per the project's CLAUDE.md). Limit comments on new code to a one-liner on `reloadIfChanged` explaining the mtime-gate intent and the locked-encrypted no-op.
- Tests use the standard `testing` package with `t.TempDir()` and table-driven style where applicable. Match the existing style of `store_test.go`.
- Errors: wrap with `fmt.Errorf("...: %w", err)` per the existing pattern (e.g., `"reading vault: %w"`).
- `Store` write methods follow a consistent contract: `state.WithLock` → `s.mu.Lock()` → `loadLocked()` → mutate → `saveLocked()`. Read methods after this fix follow: `s.mu.Lock()` → `reloadIfChanged()` → return data.

## Regression Test

### Test Outline

```go
// pkg/vault/store_test.go

func TestStoreReloadsOnExternalWritePlaintext(t *testing.T) {
    dir := t.TempDir()

    server := vault.NewStore(dir)
    require.NoError(t, server.Load())

    cli := vault.NewStore(dir)
    require.NoError(t, cli.Load())
    require.NoError(t, cli.Set("API_KEY", "abc123"))
    require.NoError(t, cli.Import(map[string]string{"DB_URL": "postgres://x", "TOKEN": "t1"}))

    secrets := server.List()
    require.Len(t, secrets, 3)

    val, ok := server.Get("API_KEY")
    require.True(t, ok)
    require.Equal(t, "abc123", val)

    require.True(t, server.Has("DB_URL"))
}

func TestStoreReloadsOnExternalWriteEncrypted(t *testing.T) {
    dir := t.TempDir()
    pass := "test-passphrase"

    server := vault.NewStore(dir)
    require.NoError(t, server.Load())
    require.NoError(t, server.Set("INITIAL", "v0"))
    require.NoError(t, server.Lock(pass))
    require.NoError(t, server.Unlock(pass)) // server holds passphrase

    cli := vault.NewStore(dir)
    require.NoError(t, cli.Load())
    require.NoError(t, cli.Unlock(pass))
    require.NoError(t, cli.Set("API_KEY", "abc123"))

    secrets := server.List()
    require.Len(t, secrets, 2)

    val, ok := server.Get("API_KEY")
    require.True(t, ok)
    require.Equal(t, "abc123", val)
}

// internal/api/vault_test.go

func TestVaultListReflectsExternalWrites(t *testing.T) {
    dir := t.TempDir()

    serverStore := vault.NewStore(dir)
    require.NoError(t, serverStore.Load())

    srv := newTestServer(t)
    srv.SetVaultStore(serverStore)

    cli := vault.NewStore(dir)
    require.NoError(t, cli.Load())
    require.NoError(t, cli.Set("EXTERNAL", "value"))

    rec := httptest.NewRecorder()
    srv.handleVaultList(rec, httptest.NewRequest("GET", "/api/vault", nil))

    require.Equal(t, http.StatusOK, rec.Code)
    var entries []map[string]any
    require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &entries))
    require.Len(t, entries, 1)
    require.Equal(t, "EXTERNAL", entries[0]["key"])
}
```

### Existing Test Patterns

- `pkg/vault/store_test.go` uses `t.TempDir()` and verifies cross-`Store` persistence via `Load`/`Save` cycles (single-instance pattern). The new tests extend that to multi-instance.
- Encrypted-vault setup is exercised via `Lock`/`Unlock` calls; mirror the existing fixtures.
- Concurrency stress test exists for in-process readers/writers — useful reference for lock semantics but not directly applicable here.
- `internal/api/vault_test.go` uses `httptest.NewRecorder` and a helper to construct a `Server` with a pre-populated `Store`. Use the same harness.

## Potential Pitfalls

- **Lock upgrade**: switching read methods from `RLock` to `Lock` is a real semantic change. It must be done together with adding `reloadIfChanged()` (which mutates) — don't leave a window where a read holds `RLock` while reload tries to mutate.
- **mtime resolution on macOS/Linux**: file `ModTime` resolution is high enough for this use case (1ns on Linux, ~1µs on HFS+), but a write followed immediately by a read in the same nanosecond on Linux is theoretically possible. In practice the writer goes through `atomicWrite` → rename, which is enough latency. If a flaky-test concern arises, fall back to comparing both `ModTime` and `Size`.
- **Stat error handling**: a transient `os.Stat` error (e.g., file deleted out from under us) should not nuke in-memory state. Return nil from `reloadIfChanged` on stat error rather than calling `loadLocked()`.
- **Initial mtime**: on first `Load`, file may not exist (empty vault). Set `s.mtime` to zero time and let the first real write trigger reload. Or stamp `time.Now()` and rely on the `os.IsNotExist` short-circuit. Either is fine; pick one and be consistent.
- **Encrypted-locked window**: if the daemon is started with an encrypted vault and no `GRIDCTL_VAULT_PASSPHRASE`, the Store stays locked. CLI writes during this window will not be visible — but read methods on a locked encrypted vault already short-circuit (UI shows "locked"), so this is fine. Don't try to decrypt without a passphrase.
- **`atomicWrite` and file replacement**: an atomic rename creates a new inode, so any stat-based detection should use a path-based stat (the existing implementation does), not a held file descriptor.
- **Don't double-stamp mtime**: be careful that `Load` and `loadLocked` don't both set `s.mtime` in conflicting ways. Pick one place to stamp it (after a successful read).

## Acceptance Criteria

1. After applying the fix, the manual reproduction steps no longer reproduce: `gridctl serve` then `gridctl vault import .vars` then browser refresh shows the imported secrets without a server restart.
2. `pkg/vault/store_test.go` contains a test that creates two `Store` instances against the same `baseDir`, has one write, and asserts the other sees the write via `List` and `Get`. Test passes.
3. The above test exists for both plaintext and encrypted vaults. Both pass.
4. `internal/api/vault_test.go` contains a test exercising the same scenario through `handleVaultList`. Passes.
5. `make test` (or `go test -race ./...`) is green.
6. `make build` succeeds.
7. No new file watcher, goroutine, or HTTP endpoint is introduced.
8. Read methods do not call `state.WithLock("vault", ...)`.
9. The encrypted-locked vault remains locked through any number of read calls (no spurious unlock attempts).
10. Browser-side: refreshing the Vault panel after CLI changes shows the new state. CLI add (`vault set`), remove (`vault rm`), and bulk import all reflect.
11. Skill source credential resolution (`POST /api/skills/sources` flows that resolve `${vault:KEY}`) successfully resolves a key added via CLI without restarting the server. Spot-verify via the existing skills test harness if available, or via a manual smoke test.

## References

- `pkg/vault/store.go` — file under modification
- `pkg/vault/store_test.go` — existing test patterns
- `internal/api/vault.go` — read handlers that benefit from the fix
- `internal/api/skills.go:154,275,405,410` — secondary callers fixed by the same change
- `pkg/config/expand.go:36` — `${vault:KEY}` expansion through the same path
- `pkg/controller/controller.go:117-125,140-148,217-231` — Store init sites
- `examples/secrets-vault/README.md` — documented bulk import flow this fix unblocks
- Investigation report: `prompts/gridctl/vault-stale-cache-on-cli-write/bug-evaluation.md`
