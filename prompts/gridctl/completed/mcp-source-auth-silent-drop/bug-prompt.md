# Bug Fix: MCP Source Auth Silent Drop

## Context

gridctl is a Go CLI + web UI for managing local MCP server stacks. A `stack.yaml` file declares MCP servers, gateway, networks, and resources; `gridctl apply stack.yaml` reads it and starts containers. MCP servers can be defined three ways: a pre-built `image:`, an external `url:`, or a `source:` block that gridctl clones and builds.

Tech stack:
- Go 1.21+ backend (`pkg/`, `cmd/gridctl/`, `internal/api/`)
- React + TypeScript web UI bundled into the binary (`web/`)
- YAML config via `gopkg.in/yaml.v3`
- Git via `go-git/go-git/v5` wrapped in `pkg/git/`
- Vault: encrypted local secrets store, accessed via `config.VaultLookup` and `${vault:KEY}` references in YAML

Architecture relevant to this fix:
- `pkg/config/` — stack.yaml types + loader + validator + variable expansion
- `pkg/builder/` — turns a `Source` config into a built Docker image (clones git repos for git sources, calls Docker BuildKit)
- `pkg/git/` — shared, auth-aware git wrapper (used by both `pkg/builder/` and `pkg/skills/`)
- `pkg/skills/` — separate "skill registry" feature with its own `skills.yaml`, fully wired for private-repo auth — **this is the reference implementation to mirror**
- `pkg/runtime/orchestrator.go` — runs at apply time, calls the builder per MCP server
- `pkg/controller/` — wires the API server, orchestrator, loader, and vault together

## Investigation Context

Full investigation: `/Users/william/code/prompt-stack/prompts/gridctl/mcp-source-auth-silent-drop/bug-evaluation.md`

Key findings that shaped this prompt:

- **Root cause confirmed**: `config.Source` (`pkg/config/types.go:330-337`) has no `Auth` field. The wizard's `source.auth.{method,credential_ref}` block is silently discarded by `yaml.Unmarshal` at `pkg/config/loader.go:45` (permissive mode, no `KnownFields(true)`).
- **Reproduction confirmed**: deterministic — any stack.yaml with `mcp-servers[].source.auth.*` loses the auth block on load. Fails at clone time with an opaque 401 against private repos.
- **Reference implementation exists**: the skills registry path (`pkg/skills/`) has the full pattern — declarative `SourceAuth` with yaml tags, runtime `AuthConfig` with transient fields, a `BuildAuther` constructor, `CredentialResolver` callback, and an authenticated `Clone` call. The MCP source path is missing the entire pipeline.
- **Risk mitigation baked in**: do **not** reuse `pkg/skills/AuthConfig` for the YAML-persisted struct — it has transient `Token`/`SSHPassphrase` fields that must never serialize. Define a separate `config.SourceAuth` declarative type with yaml tags only, mirroring `pkg/skills/config.go:24-33`.
- **Vault is already wired into the loader**: `pkg/controller/controller.go:216` calls `config.LoadStack(..., config.WithVault(vaultStore))`. At orchestrator time, the vault is also reachable (see `pkg/controller/gateway_builder.go:464`). No new plumbing required to get a vault handle to the build path — just thread the existing one in.
- **No other callers of `CloneOrUpdate`**: only `pkg/builder/builder.go:95` calls it. Signature change is safe.

## Bug Description

**What is wrong**: Users follow the README's "Private Repositories" section (README.md:345-372) or use the web wizard's "Repository Authentication" subsection on the MCP server form. Both produce a `stack.yaml` with a `source.auth.method` + `source.auth.credential_ref` block:

```yaml
mcp-servers:
  - name: private-mcp
    source:
      type: git
      url: https://github.com/acme/private-mcp.git
      ref: main
      auth:
        method: token
        credential_ref: "${vault:GIT_TOKEN}"
```

**Expected**: `gridctl apply` resolves `GIT_TOKEN` from the vault and clones the private repo using HTTPS Basic auth.

**Actual**: The `auth:` block is silently dropped during YAML unmarshal because `config.Source` has no `Auth` field. The build path then attempts an unauthenticated clone, which fails with:

```
error building image: cloning repository: authentication required
```

No log line mentions that the configured auth was discarded.

**Who is affected**: Anyone using a private repo as an MCP server source via the wizard or following the README. Public-repo MCP sources, skills (`gridctl skill add`), and pre-built-image MCP servers are unaffected.

**Documentation that lies**: `README.md:347` claims "Both `gridctl skill add` and MCP server `source` blocks can clone private git repositories" and `README.md:370` adds "The same subsection is available in the MCP server form when the source type is `git`." The skills half is true; the MCP half is false until this is fixed.

## Root Cause

The MCP server source path is missing the complete auth pipeline that the skills path has. Five layers are involved:

| Layer | File:Line | Current state |
|---|---|---|
| Config struct | `pkg/config/types.go:330-337` | `Source` struct has no `Auth` field — YAML `auth:` block discarded |
| Loader | `pkg/config/loader.go:45` | Permissive `yaml.Unmarshal`; no warning on unknown keys |
| BuildOptions | `pkg/builder/types.go:6-22` | No `Auth` field to carry credentials to the builder |
| CloneOrUpdate | `pkg/builder/git.go:15-39` | Signature has no auth parameter; calls `gitpkg.Clone` with `Auth: nil` |
| Orchestrator | `pkg/runtime/orchestrator.go:359-369` | Populates `BuildOptions` from URL/Ref/Path/Dockerfile only |

The shared git layer (`pkg/git/clone.go:21-65`) already accepts `transport.AuthMethod` — it just never receives one on the MCP path.

## Fix Requirements

### Required Changes

1. **Add a declarative `SourceAuth` type to `pkg/config`** that mirrors `pkg/skills/config.go:24-33` exactly. YAML tags only, no transient runtime fields:

   ```go
   // SourceAuth is the declarative auth block on an MCP server source.
   // Raw tokens must NOT appear here — use CredentialRef (e.g.
   // "${vault:GIT_TOKEN}") which is resolved against the live vault at
   // clone time. Never add a Token field to this struct.
   type SourceAuth struct {
       Method        string `yaml:"method,omitempty"`
       CredentialRef string `yaml:"credential_ref,omitempty"`
       SSHUser       string `yaml:"ssh_user,omitempty"`
       SSHKeyPath    string `yaml:"ssh_key_path,omitempty"`
   }
   ```

2. **Add `Auth *SourceAuth` to `config.Source`** at `pkg/config/types.go:330-337`:

   ```go
   type Source struct {
       Type       string      `yaml:"type"`
       URL        string      `yaml:"url,omitempty"`
       Ref        string      `yaml:"ref,omitempty"`
       Path       string      `yaml:"path,omitempty"`
       Dockerfile string      `yaml:"dockerfile,omitempty"`
       Auth       *SourceAuth `yaml:"auth,omitempty"`
   }
   ```

3. **Do NOT call `expand(...)` on `Source.Auth.CredentialRef`** in `expandStackVars` at `pkg/config/loader.go:181-185`. The credential reference must remain literal `${vault:KEY}` so the orchestrator can resolve it at clone time. Optionally call `expand(...)` on `SSHKeyPath` to allow env-var path expansion (`$HOME/.ssh/...`), and resolve `~` via `expandTildeAndResolvePath` in `resolveRelativePaths` (mirror the SSH identity file handling at loader.go:231-233).

4. **Add `Auth transport.AuthMethod` to `BuildOptions`** in `pkg/builder/types.go`:

   ```go
   type BuildOptions struct {
       SourceType string
       URL        string
       Ref        string
       Path       string
       Dockerfile string
       Tag        string
       BuildArgs  map[string]string
       NoCache    bool
       Auth       transport.AuthMethod  // NEW: nil for unauthenticated
       Logger     *slog.Logger
   }
   ```

   Import `"github.com/go-git/go-git/v5/plumbing/transport"`.

5. **Change `CloneOrUpdate` signature** at `pkg/builder/git.go:15` to accept auth and forward it to both `gitpkg.Clone` (line 36) and `gitpkg.Fetch` in `updateRepo` (line 68):

   ```go
   func CloneOrUpdate(url, ref string, auth transport.AuthMethod, logger *slog.Logger) (string, error) { ... }
   func cloneRepo(url, ref, destPath string, auth transport.AuthMethod, logger *slog.Logger) (string, error) {
       repo, err := gitpkg.Clone(destPath, gitpkg.CloneOptions{
           URL: url, Ref: ref, Auth: auth,
       }, logger)
       ...
   }
   func updateRepo(repoPath, ref string, auth transport.AuthMethod, logger *slog.Logger) (string, error) {
       ...
       if err := gitpkg.Fetch(repoPath, gitpkg.FetchOptions{Auth: auth}, logger); err != nil { ... }
       ...
   }
   ```

   Update the only caller at `pkg/builder/builder.go:95` to pass `opts.Auth`.

6. **Wire auth resolution into the orchestrator** at `pkg/runtime/orchestrator.go:359-369`. When `server.Source.Auth != nil`, resolve `CredentialRef` via the orchestrator's vault, build a `skills.AuthConfig`, call `skills.BuildAuther`, and put the resulting `transport.AuthMethod` into `BuildOptions.Auth`:

   ```go
   buildOpts := BuildOptions{
       SourceType: server.Source.Type,
       URL:        server.Source.URL,
       Ref:        server.Source.Ref,
       Path:       server.Source.Path,
       Dockerfile: server.Source.Dockerfile,
       Tag:        generateTag(stack.Name, server.Name),
       BuildArgs:  server.BuildArgs,
       NoCache:    opts.NoCache,
       Logger:     o.logger,
   }
   if server.Source.Auth != nil {
       authMethod, err := resolveSourceAuth(server.Source.Auth, server.Source.URL, o.vault)
       if err != nil {
           return nil, fmt.Errorf("resolving source auth for %q: %w", server.Name, err)
       }
       buildOpts.Auth = authMethod
   }
   ```

   `resolveSourceAuth` should:
   - Convert `config.SourceAuth` → `skills.AuthConfig` via a `ToAuthConfig()` method on `config.SourceAuth` (defined alongside the struct).
   - If `CredentialRef != ""`, call the vault to resolve it, store the result in `AuthConfig.Token`. If the vault is nil or the key is missing, return a descriptive error.
   - Call `skills.BuildAuther(authConfig)` to get a `gitpkg.Auther`. Call `.AuthMethod(url)` (or whatever the existing `Auther` interface exposes — verify in `pkg/git/auther.go` or equivalent) to get a `transport.AuthMethod`.
   - **Verify the existing Auther interface**: read `pkg/git/auth*.go` files first. The skills path uses `gitpkg.Auther`; trace how `pkg/skills/remote.go` converts `Auther` → `transport.AuthMethod` and reuse the same conversion.

   The orchestrator needs access to a `config.VaultLookup`. Confirm by reading `pkg/runtime/orchestrator.go` field definitions and `pkg/controller/gateway_builder.go:460-470` for how the vault is held in the controller path. If the orchestrator doesn't already have a vault handle, thread one in via its constructor / options struct, plumbed from `controller.Config`.

7. **Confirm there is exactly one caller of `CloneOrUpdate`** before changing its signature. Run:
   ```
   rg -n "CloneOrUpdate\b" --type go
   ```
   The investigation confirmed only `pkg/builder/builder.go:95` calls it, but verify before editing.

### Constraints

- **Do NOT flip `KnownFields(true)`** on the YAML loader. Strict mode would break unrelated workflows. Permissive loading is the correct trade-off; the fix removes the silent-drop by giving the field a home, not by erroring on unknowns.
- **Do NOT persist raw tokens to YAML.** `config.SourceAuth` must have no `Token` or similar transient field with a yaml tag. Raw tokens live only in `skills.AuthConfig.Token` at runtime.
- **Do NOT add ambient `GITHUB_TOKEN` fallback to the MCP path** unless this PR also documents it. The skills path has this fallback in `resolveAuther` (`pkg/skills/importer.go:55-66`); copying it to the MCP path is reasonable but optional. If you do, document it in the same docs section.
- **Keep public-repo flows unchanged.** When `Source.Auth == nil`, `BuildOptions.Auth` stays nil, `CloneOrUpdate` passes nil through, and `gitpkg.Clone` behaves identically to today.
- **Do not change the validator's strictness.** Adding the `Auth` field to `Source` is enough; the validator does not need to reject unknown fields. Optionally add light validation: if `Auth.Method == "token"` then `Auth.CredentialRef` must be non-empty (mirror skills' validation if it exists; otherwise leave to runtime).

### Out of Scope

- **Validator strict-mode (`KnownFields(true)`)** for stack.yaml. Tempting orthogonal hardening, but unrelated and would break other workflows.
- **Shared `SourceAuth` / `AuthConfig` package** between `pkg/config` and `pkg/skills`. Worthwhile follow-up — file an issue, do not block this fix on the refactor.
- **`gridctl apply --auth-token` / `--vault-key` / `--ssh-key` flags** for parity with `gridctl skill add`. Optional polish in a follow-up PR. With `${vault:KEY}` working end-to-end, these flags are conveniences, not blockers. Mention in the PR description as a known follow-up.
- **Web wizard `parseYAMLToForm` read-back fix** at `web/src/lib/yaml-builder.ts:443-554`. Out of scope for the backend fix unless the implementer has bandwidth to bundle it. If bundling: extend `parseYAMLToForm` to read `source.auth.method` and `source.auth.credential_ref` back into form state. Add a vitest case that round-trips wizard → YAML → form.
- **Docs/wizard text changes** beyond `docs/config-schema.md` (see Implementation Guidance below).

## Implementation Guidance

### Key Files to Read First

1. **`pkg/skills/config.go:14-48`** — declarative `SkillSource` with `Auth *SourceAuth` and the `SourceAuth.ToAuthConfig()` converter. This is the structural template.
2. **`pkg/skills/importer.go:14-66`** — runtime `AuthConfig`, `BuildAuther`, `resolveAuther`. This is the runtime template.
3. **`pkg/skills/remote.go`** (around lines 130-160) — the authenticated clone call that converts `Auther` → `transport.AuthMethod` and passes it to `gitpkg.Clone`. Mirror this conversion in the orchestrator.
4. **`pkg/git/clone.go:20-65`** — the shared git wrapper already supports `Auth: transport.AuthMethod`. No changes needed here.
5. **`pkg/git/`** — read `auther.go` or whichever file defines the `Auther` interface to understand the `Auther → transport.AuthMethod` conversion contract.
6. **`pkg/controller/gateway_builder.go:460-475`** — example of how the vault is held and threaded. Use this as a model for the orchestrator's vault wiring (if it doesn't already have one).
7. **`pkg/controller/controller.go:200-225`** — `LoadStack` is already called with `config.WithVault(vaultStore)`. The vault store is reachable; just plumb it.
8. **`tests/integration/skills_private_git_test.go`** — full e2e template with `initPrivateBareRepo`, `startAuthedGitHTTPServer`, `isolateGridctlHome` helpers. Reuse all of them in the new MCP integration test.
9. **`web/src/lib/yaml-builder.ts:185-204`** — wizard already emits the auth block correctly; do not change. Read for reference only.

### Files to Modify

| File | Change |
|---|---|
| `pkg/config/types.go:330-337` | Add `SourceAuth` declarative type and `Auth *SourceAuth` field on `Source`. |
| `pkg/config/types.go` (alongside `SourceAuth`) | Add `(*SourceAuth).ToAuthConfig() skills.AuthConfig` method (or — cleaner — define the conversion in a small helper to avoid `pkg/config` importing `pkg/skills`; the orchestrator can do the conversion). |
| `pkg/config/loader.go:181-185` | Optionally expand env vars in `Source.Auth.SSHKeyPath`. Do **not** expand `CredentialRef`. |
| `pkg/config/loader.go:223-235` | Optionally tilde-expand `Source.Auth.SSHKeyPath` paths (mirror SSH `IdentityFile` handling). |
| `pkg/config/validate.go:506-531` | Optionally validate `Source.Auth` (e.g. `Method == "token"` ⇒ `CredentialRef != ""`). |
| `pkg/builder/types.go` | Add `Auth transport.AuthMethod` to `BuildOptions`. |
| `pkg/builder/git.go:15-91` | Add `auth` parameter to `CloneOrUpdate`, `cloneRepo`, `updateRepo`. Forward to `gitpkg.Clone` and `gitpkg.Fetch`. |
| `pkg/builder/builder.go:85-96` | Pass `opts.Auth` to `CloneOrUpdate`. |
| `pkg/runtime/orchestrator.go:332-374` | Resolve `Source.Auth` → `transport.AuthMethod` via vault, populate `BuildOptions.Auth`. May require adding a vault field to the orchestrator struct + constructor option. |
| `pkg/controller/controller.go` | Thread the existing vault store into the orchestrator if it isn't already. |
| `docs/config-schema.md` | Add an "MCP server source auth" section mirroring the existing skill source auth docs (around lines 637-688). |
| `pkg/config/loader_test.go` | Add `TestLoadStack_SourceAuth_PreservedRoundTrip`. |
| `pkg/builder/git_test.go` | Add `TestCloneOrUpdate_ForwardsAuth` (or similar). |
| `tests/integration/mcp_private_git_test.go` (new file) | Add `TestMCP_PrivateGit_WithAuth_Succeeds` mirroring `skills_private_git_test.go`. |

### Reusable Components

- **Don't write new auth primitives.** Reuse `pkg/skills/AuthConfig`, `pkg/skills/BuildAuther`, and `pkg/skills/resolveAuther`. If `pkg/config` can't import `pkg/skills` cleanly (cycle risk — verify with `go list -deps`), do the conversion in `pkg/runtime/orchestrator.go` or a new small helper in `pkg/runtime/auth.go`. The conversion is a few lines.
- **Don't write a new vault resolver.** The vault is already a `config.VaultLookup` (look at how `expandStackVars` uses it via `VaultResolver(cfg.vault)` at `pkg/config/loader.go:60-65`). Reuse the same `VaultLookup` type for the orchestrator's resolution call.
- **Don't write new test helpers.** `tests/integration/skills_private_git_test.go` already has `initPrivateBareRepo`, `startAuthedGitHTTPServer`, `isolateGridctlHome`. Either move them to a shared test helper file (e.g. `tests/integration/githelpers_test.go`) or inline-copy with attribution comments. Prefer the move.

### Conventions to Follow

- **Comment style**: this codebase has terse, factual comments — see existing `pkg/skills/config.go` and `pkg/git/clone.go` for tone. The lead comment on `SourceAuth` must explicitly forbid raw tokens (mirror the existing `pkg/skills/config.go:24-27` comment).
- **YAML tag style**: snake_case field names (`credential_ref`, `ssh_user`, `ssh_key_path`). Do not use camelCase in yaml tags.
- **Error wrapping**: use `fmt.Errorf("...: %w", err)` consistently. Existing orchestrator errors at `pkg/runtime/orchestrator.go:373` use this pattern.
- **Logging**: use the orchestrator's existing `o.logger`. Log a one-line `o.logger.Info("resolving source auth", "server", server.Name, "method", server.Source.Auth.Method)` before the resolution call.
- **No raw-token logging**: when logging URLs, use `gitpkg.RedactURL`. The existing builder code already does this.
- **No new packages** unless one is genuinely needed. Add types to existing files where they fit.

## Regression Test

### Test Outline

Three tests, in priority order:

#### 1. `TestLoadStack_SourceAuth_PreservedRoundTrip` (`pkg/config/loader_test.go`)

```go
func TestLoadStack_SourceAuth_PreservedRoundTrip(t *testing.T) {
    content := `
version: "1"
name: test
mcp-servers:
  - name: private-mcp
    source:
      type: git
      url: https://github.com/example/repo.git
      ref: main
      auth:
        method: token
        credential_ref: "${vault:GIT_TOKEN}"
    port: 3000
`
    path := writeTempFile(t, content)
    stack, err := LoadStack(path)
    if err != nil {
        t.Fatalf("LoadStack: %v", err)
    }

    if len(stack.MCPServers) != 1 {
        t.Fatalf("expected 1 MCP server, got %d", len(stack.MCPServers))
    }
    src := stack.MCPServers[0].Source
    if src == nil {
        t.Fatal("expected Source, got nil")
    }
    if src.Auth == nil {
        t.Fatal("BUG: Source.Auth is nil; auth block was silently dropped")
    }
    if src.Auth.Method != "token" {
        t.Errorf("Auth.Method: got %q, want %q", src.Auth.Method, "token")
    }
    if src.Auth.CredentialRef != "${vault:GIT_TOKEN}" {
        t.Errorf("Auth.CredentialRef: got %q, want %q", src.Auth.CredentialRef, "${vault:GIT_TOKEN}")
    }
}
```

The fixture must use `version: "1"` if other tests in the file do; check existing test helpers for the right shape. Use the existing `writeTempFile` helper (search the file for its definition).

This test is the primary acceptance gate: it must fail today before any changes (because `Source.Auth` doesn't exist) and pass after the struct change. Its assertion that `CredentialRef` is preserved as the literal `${vault:GIT_TOKEN}` string also locks in the "do not expand at load time" requirement.

#### 2. `TestCloneOrUpdate_ForwardsAuth` (`pkg/builder/git_test.go`)

Test that `CloneOrUpdate` accepts a non-nil `transport.AuthMethod` and forwards it to `gitpkg.Clone`. The cleanest implementation: spin up a tiny `httptest.Server` that requires Basic auth (similar to `tests/integration/skills_private_git_test.go:startAuthedGitHTTPServer` but the simplest possible inline version), call `CloneOrUpdate(url, ref, basicAuth, logger)` with valid creds, and assert success. Negative case: same call with nil auth fails with `gitpkg.ErrAuthRequired` (or whatever the existing classified error is).

If full-server testing is too heavy for a unit test, fall back to a stub: replace `gitpkg.Clone` with a func var injected for tests, capture the `Auth` argument, assert it equals the input.

#### 3. `TestMCP_PrivateGit_WithAuth_Succeeds` (`tests/integration/mcp_private_git_test.go`)

Mirror `tests/integration/skills_private_git_test.go` end-to-end:

```go
func TestMCP_PrivateGit_WithAuth_Succeeds(t *testing.T) {
    if testing.Short() {
        t.Skip("integration test")
    }
    isolateGridctlHome(t)

    bareParent, bareName := initPrivateBareRepo(t)
    srv := startAuthedGitHTTPServer(t, bareParent, "correct-token")
    defer srv.Close()

    // Mock vault to resolve GIT_TOKEN to the correct token.
    vault := newMockVault(map[string]string{"GIT_TOKEN": "correct-token"})

    stackYAML := fmt.Sprintf(`
version: "1"
name: test-mcp
mcp-servers:
  - name: private
    source:
      type: git
      url: %s/%s
      ref: master
      auth:
        method: token
        credential_ref: "${vault:GIT_TOKEN}"
    port: 3000
`, srv.URL, bareName)

    path := writeTempFile(t, stackYAML)
    stack, err := config.LoadStack(path, config.WithVault(vault))
    require.NoError(t, err)
    require.NotNil(t, stack.MCPServers[0].Source.Auth)

    // Drive the orchestrator's source-prep path with this stack and assert
    // the clone succeeds (write to a temp cache dir; isolateGridctlHome
    // already redirects $HOME).
    // ... (follow the pattern in skills_private_git_test.go)
}
```

Add a negative case `TestMCP_PrivateGit_WrongToken_FailsAuth` that asserts a wrong-token vault entry yields `gitpkg.ErrAuthRequired` (or equivalent).

### Existing Test Patterns

- Integration tests live in `tests/integration/` and gate on `testing.Short()`.
- `isolateGridctlHome(t)` redirects `$HOME` to a per-test temp dir.
- Helpers like `initPrivateBareRepo` and `startAuthedGitHTTPServer` live in `tests/integration/skills_private_git_test.go` — move them to a shared helper file (e.g. `tests/integration/githelpers_test.go`) so the new MCP test can reuse them.
- Unit tests use `testing.T` directly with table-driven cases when they have multiple inputs; this defect's tests don't need tables.
- Use `require.NoError` / `assert.Equal` from `github.com/stretchr/testify` only if the file already imports it; otherwise stick to plain `t.Fatal` / `t.Errorf`.

## Potential Pitfalls

- **Import cycle risk**: if `pkg/config` ends up importing `pkg/skills` (for `AuthConfig` / `BuildAuther`), `go build` will likely fail because `pkg/skills` already imports `pkg/config` indirectly via `pkg/git`. **Mitigation**: keep the conversion in `pkg/runtime` (which is allowed to import both) or `pkg/skills`. `config.SourceAuth` should be a pure-data struct with no methods that reach into other packages.
- **Vault threading**: confirm whether the orchestrator already holds a `config.VaultLookup`. If not, adding one to the constructor signature ripples into `pkg/controller/orchestrator_factory.go` (or wherever it's instantiated). Read those call sites before changing signatures.
- **`updateRepo` path is also auth-sensitive**: a previous unauthenticated successful clone (against a now-private fork, say) cached at `~/.gridctl/cache/repos/...` would be re-`Fetch`ed next apply. Without auth on the `Fetch`, that path also 401s. Make sure `updateRepo` accepts and forwards `auth` to `gitpkg.Fetch` — easy to miss because the bug today only surfaces on first clone.
- **The wizard already emits, but parser doesn't read back**: a user who edits a previously-saved stack via the wizard will lose the auth block on the form side regardless of this backend fix. Document this in the PR description as a known limitation if you don't bundle the parser fix.
- **Existing public-repo cache pollution**: changing `CloneOrUpdate` does not invalidate cached repos. If a user previously failed to clone a private repo (leaving a partial cache dir at `~/.gridctl/cache/repos/<hash>/`), the post-fix `updateRepo` may try to `Fetch` from it. This is fine — `gitpkg.Fetch` with auth will succeed where the previous unauthenticated attempt failed. No cache eviction needed, but if the partial dir is corrupted, the existing fallback at `pkg/builder/git.go:62-65` (re-clone on open failure) kicks in.
- **YAML tag exact match**: the wizard emits `credential_ref` (snake_case) at `web/src/lib/yaml-builder.ts:201`. The yaml tag on `config.SourceAuth.CredentialRef` must exactly match `credential_ref`. A mismatch (e.g. `credentialRef`) will silently re-introduce the bug.
- **Don't conflate `${vault:KEY}` with env-var expansion**: `expandStackVars` does both (`config.ExpandString`). For `CredentialRef`, neither expansion is appropriate at load time — let it pass through verbatim. The vault resolution happens later at clone time.
- **Logger nil-safety**: `BuildOptions.Logger` defaults to `logging.NewDiscardLogger()` (see `pkg/builder/builder.go:27-29`). Don't break this contract.

## Acceptance Criteria

1. `TestLoadStack_SourceAuth_PreservedRoundTrip` passes; the assertion `stack.MCPServers[0].Source.Auth != nil` and field equality check both succeed.
2. `TestCloneOrUpdate_ForwardsAuth` passes (or its stub-based equivalent).
3. `TestMCP_PrivateGit_WithAuth_Succeeds` integration test passes against a local Basic-auth git server fixture.
4. `TestMCP_PrivateGit_WrongToken_FailsAuth` (negative case) returns a classified auth error.
5. All existing tests in `pkg/config/`, `pkg/builder/`, `pkg/runtime/`, `pkg/skills/`, and `tests/integration/` continue to pass.
6. Hand-test: write a stack.yaml with `source.auth.credential_ref: "${vault:GIT_TOKEN}"`, set `GIT_TOKEN` via `gridctl vault set GIT_TOKEN <pat>`, run `gridctl apply` against a private repo, verify the clone succeeds and the MCP server starts.
7. Hand-test negative: same setup with the wrong token in vault → `gridctl apply` fails with a clear auth error (not a generic "building image" error). Acceptable if the error wraps a classified auth error mentioning authentication.
8. `gridctl validate stack.yaml` and `gridctl plan stack.yaml` continue to load and report the auth block without error.
9. `golangci-lint run` passes.
10. `go test -race ./...` passes.
11. `npm run build` (web) passes if the wizard parser fix is bundled; otherwise unchanged.
12. `docs/config-schema.md` has a new "MCP server source auth" section with field reference, security notes, and at least one example. The section mirrors the existing skill source auth docs (lines 637-688) in structure and tone.
13. The PR description notes the deferred follow-ups: CLI flag parity for `apply`, web `parseYAMLToForm` fix (if not bundled), and shared `SourceAuth`/`AuthConfig` package extraction.

## References

- Investigation report: `/Users/william/code/prompt-stack/prompts/gridctl/mcp-source-auth-silent-drop/bug-evaluation.md`
- Skills auth feature PRs (reference for the working pattern): #502 (primitives), #504 (skills wiring), #505 (UI for both wizards), #506 (docs + skills integration tests), #508 (docs sync + example)
- Skills declarative type: `pkg/skills/config.go:14-48`
- Skills runtime auth: `pkg/skills/importer.go:14-66`, `:128-150`, `:459-482`
- Skills authenticated clone: `pkg/skills/remote.go` (search for `gitpkg.Clone`)
- Skills CLI flags (reference for follow-up apply parity): `cmd/gridctl/skill.go:39-49`, `:144-161`, `:232-240`
- Skills integration test (template for new MCP test): `tests/integration/skills_private_git_test.go`
- Shared git wrapper: `pkg/git/clone.go:20-65`
- Vault-loader wiring: `pkg/controller/controller.go:200-225`
- README claim: `README.md:345-372`
- Wizard YAML emit (already correct): `web/src/lib/yaml-builder.ts:185-204`
- Wizard form UI: `web/src/components/wizard/steps/MCPServerForm.tsx:647-660`
- Wizard serialization test (already passing): `web/src/__tests__/MCPServerForm.test.tsx:501-549`
- go-git transport package (for `transport.AuthMethod`): `github.com/go-git/go-git/v5/plumbing/transport`
