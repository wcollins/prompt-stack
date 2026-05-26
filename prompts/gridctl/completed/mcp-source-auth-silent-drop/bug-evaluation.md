# Bug Investigation: MCP Source Auth Silent Drop

**Date**: 2026-04-28
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Medium

## Summary

The web wizard and the README both promise that MCP server `source` blocks support private-repo authentication via `${vault:KEY}` references, but the Go `config.Source` struct has no `Auth` field. YAML written from the wizard has its `source.auth` block silently discarded by `yaml.Unmarshal`, the build path then attempts an unauthenticated clone, and the user sees an opaque "authentication required" failure with no indication that their configured credentials were dropped. This is a partial-ship: PR #505 added the wizard UI for both skills *and* MCP source forms, PR #506/#508 documented both as working, but the MCP backend was never wired. The skills registry path is the reference implementation; the fix is a mechanical port.

## The Bug

A user opens the gridctl web wizard, configures an MCP server with `source.type = git` pointing at a private repository, expands the "Repository Authentication" subsection, and pastes a `${vault:GIT_TOKEN}` reference into the credential field. The wizard serializes a stack.yaml that includes:

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

**Expected**: `gridctl apply stack.yaml` resolves `GIT_TOKEN` from the vault and clones the private repo using HTTPS Basic auth.

**Actual**: The `auth:` block is dropped during YAML unmarshal because `config.Source` has no `Auth` field. The build path receives only `URL/Ref/Path/Dockerfile`. `pkg/builder/git.go` calls `gitpkg.Clone` with `Auth: nil`. go-git makes an unauthenticated request, the private repo returns 401, and the user sees:

```
error building image: cloning repository: ... 401 Unauthorized
```

with no hint that their configured credentials were silently discarded.

**How discovered**: Code review of MCP server source auth claims in README.md against the `config.Source` struct definition.

## Root Cause

### Defect Location

The bug spans five layers, all of which need to be fixed for the documented feature to work end-to-end:

| Layer | File:Line | Defect |
|---|---|---|
| Config struct | `pkg/config/types.go:330-337` | `Source` has no `Auth` field |
| Loader | `pkg/config/loader.go:45` | `yaml.Unmarshal` is permissive (no `KnownFields(true)`); unknown `auth:` block silently dropped |
| Builder | `pkg/builder/git.go:15`, `:35-39` | `CloneOrUpdate(url, ref, logger)` has no auth parameter; calls `gitpkg.Clone` with `Auth: nil` |
| Orchestrator | `pkg/runtime/orchestrator.go:359-369` | `BuildOptions` is populated from URL/Ref/Path/Dockerfile only; no Auth field exists |
| CLI | `cmd/gridctl/apply.go:55-69` | No `--auth-token` / `--vault-key` flags (parity gap with `gridctl skill add`) |

Bonus (not blocking the backend fix but flagged): `web/src/lib/yaml-builder.ts:443-554` (`parseYAMLToForm`) doesn't read `source.auth` back, so the wizard can't re-edit a saved stack with auth — the form state drops the field on load.

### Code Path

```
wizard (yaml-builder.ts:195-201)
  → stack.yaml on disk with source.auth block
  → gridctl apply stack.yaml
  → config.LoadStack (loader.go:33)
    → yaml.Unmarshal(data, &stack)  ← auth block DROPPED here (Source has no Auth field)
  → orchestrator.startMCPServer (orchestrator.go:332)
  → BuildOptions{URL, Ref, Path, Dockerfile, ...}  ← no Auth
  → builder.Build (orchestrator.go:371)
  → prepareGitSource (builder.go:85)
  → CloneOrUpdate(url, ref, logger)  ← no auth parameter
  → cloneRepo (git.go:35)
  → gitpkg.Clone(destPath, CloneOptions{URL, Ref}, logger)  ← Auth: nil
  → gogit.PlainClone with no Auth
  → 401 Unauthorized for private repos
```

### Why It Happens

This is a partial-ship. The auth feature was rolled out in four PRs:
- #502 — feat: add git auth primitives
- #504 — feat: wire git auth through importer, CLI, and skills API
- **#505 — feat: add git auth UI to skill wizard and MCP source form**
- #506 — docs: document private git auth + add clone integration tests
- #508 — docs: sync private-git-auth docs + add skills.yaml example

PR #505 added the wizard UI for both the skills wizard *and* the MCP source form. PR #506/#508 then documented both as working features in the README and config-schema docs. But none of these PRs touched `pkg/config/types.go` to add an `Auth` field to `Source`, nor `pkg/builder/git.go` to thread auth through the clone, nor `pkg/runtime/orchestrator.go` to populate it. The result is a UI and a docs surface that promise a feature the backend doesn't implement.

The skills registry path (`pkg/skills/`) is fully wired: `SourceAuth` declarative type at `pkg/skills/config.go:24-33`, `AuthConfig` runtime type at `pkg/skills/importer.go:14-27`, `BuildAuther` constructor, `resolveAuther` with `GITHUB_TOKEN` ambient fallback, and an authenticated clone in `pkg/skills/remote.go`. The MCP server source path needs a parallel implementation.

### Similar Instances

The skills path is *not* a similar defect — it's the working reference. There are no other places in the codebase with the same partial-ship pattern. However, the fix should be careful not to introduce a third copy of the auth concept; either:
- Mirror skills' separation (declarative `config.SourceAuth` for YAML + `pkg/skills/AuthConfig` for runtime), accepting some duplication; **or**
- Extract a shared `pkg/auth` package — recommended as a follow-up, **not blocking** this fix.

## Impact

### Severity Classification

**High.** The class is "documented feature silently no-ops with confusing downstream error." Not Critical (no data corruption, no security regression — raw tokens never reach disk because they're never resolved in the first place). Not Medium (the docs and wizard explicitly guide users into the broken flow; the failure mode masquerades as user error).

### User Reach

| User category | Impact |
|---|---|
| MCP servers from public repos | None |
| MCP servers from private repos via wizard | **Full** — wizard guides them straight into the broken flow |
| MCP servers from private repos via hand-written stack.yaml | **Full** — README:347 explicitly tells them this works |
| `gridctl skill add` for skills | None (skills path is fully wired) |
| Pre-built image MCP servers | None |

### Workflow Impact

Core path blocker for the private-MCP-from-source workflow. Public-repo MCP sources, skills, and pre-built images are unaffected.

### Workarounds

| Workaround | Works | Documented | Security | Effort |
|---|---|---|---|---|
| URL-embedded vault ref: `url: "https://${vault:GIT_TOKEN}@github.com/..."` | Yes — `expandStackVars` does expand `Source.URL` (loader.go:182) | No | Lower (vault ref appears in URL string; logs are scrubbed by `git.RedactURL` but on-disk state holds the reference) | Low |
| Ambient `GITHUB_TOKEN` env var | No — the MCP builder path has no fallback (skills' `resolveAuther` does, builder doesn't) | No | Weak | Low |
| Pre-clone repo, use `source.type: local` | Yes | No | High | Medium |
| Pre-build image, use `image:` | Yes | Standard practice | High | High |

URL embedding is the only workaround that preserves the wizard's no-raw-tokens promise. It's undocumented and weaker than the intended `auth.credential_ref` flow.

### Urgency Signals

- README claim is recent: PR #506 merged ~7 days before this investigation.
- Wizard UI shipped in PR #505 and is live in the bundled web app.
- No `examples/` files demonstrate the broken MCP-private-source flow (good — nothing else to fix), but `examples/registry/skills.yaml` *does* demonstrate the working skills-path flow, which makes the asymmetry sharper for users comparing the two.
- No CHANGELOG entry yet for "MCP source auth" — the feature was advertised in README/wizard but not formally released, which gives a small grace period to fix without a deprecation story.

### No Open Issues

`gh issue list` was not authenticated in this session, so the public issue tracker was not consulted. Worth a quick check before starting work — but the bug is clearly real either way.

## Reproduction

### Minimum Reproduction Steps

**Path A — Pure Go unit test (recommended for first reproduction):**

1. Write a stack.yaml fixture with an `mcp-server.source.auth.{method,credential_ref}` block.
2. Call `config.LoadStack(path)`.
3. Assert `stack.MCPServers[0].Source.Auth != nil`.

This fails today because `config.Source` has no `Auth` field — the assertion can't even be expressed without first adding the field. The test is the fix's first acceptance criterion.

**Path B — End-to-end integration test (mirror `tests/integration/skills_private_git_test.go`):**

1. Use `initPrivateBareRepo` + `startAuthedGitHTTPServer` from the existing skills integration test helpers.
2. Author a stack with `source.auth.credential_ref = "correct-token"` (or vault ref + mock vault).
3. Run `gridctl apply` (or call orchestrator directly).
4. Without fix: clone fails 401. With fix: clone succeeds.

### Affected Environments

- All platforms (pure Go config struct issue; no OS-specific code).
- All workflows: `validate`, `plan`, `apply`. Validate/plan don't error visibly because they don't call the builder; apply errors at clone time.
- All git transports: HTTPS+token and SSH+key both broken (the field doesn't exist; method doesn't matter).

### Non-Affected Environments

- Skills registry workflows (`gridctl skill add`, `gridctl skill update`, `gridctl skill try`) — fully wired auth.
- Public-repo MCP sources — never needed auth.
- API-server MCP server CRUD (`internal/api/`) — operates on already-running servers, doesn't re-clone.

### Failure Mode

Build fails cleanly before any container is created; no partial state. The cache directory at `~/.gridctl/cache/repos/<hash>` may contain a failed clone artifact that next attempts will retry from. User-visible error originates in go-git, wraps through `pkg/builder/git.go:41` (`fmt.Errorf("cloning repository: %w", err)`) and `pkg/runtime/orchestrator.go:373` (`fmt.Errorf("building image: %w", err)`):

```
error building image: cloning repository: authentication required
```

No log line, no warning, no hint that the configured `source.auth` block was silently dropped during YAML load.

## Fix Assessment

### Fix Surface

| File | Change |
|---|---|
| `pkg/config/types.go:330-337` | Add `Auth *SourceAuth` to `Source`. Define new `config.SourceAuth` declarative type with yaml tags only — `Method`, `CredentialRef`, `SSHUser`, `SSHKeyPath`. Mirror `pkg/skills/config.go:24-33` exactly; do **not** reuse `skills.AuthConfig` (which has transient `Token`/`SSHPassphrase` that must never serialize). |
| `pkg/config/types.go` | Add `ToAuthConfig()` method on `config.SourceAuth` that returns a `pkg/skills/AuthConfig` (or refactor `AuthConfig` into a shared place — follow-up). |
| `pkg/config/loader.go:181-185` | If desired, expand string values inside `Source.Auth` (`SSHKeyPath` may want tilde expansion; `CredentialRef` should pass through unchanged so `${vault:KEY}` reaches the resolver). |
| `pkg/builder/types.go` | Add `Auth transport.AuthMethod` to `BuildOptions`. |
| `pkg/builder/git.go:15`, `:35-39` | Change `CloneOrUpdate(url, ref string, logger)` → `CloneOrUpdate(url, ref string, auth transport.AuthMethod, logger)`. Pass through to `gitpkg.CloneOptions{Auth: auth}`. Also update `updateRepo` to pass auth into `gitpkg.Fetch`. |
| `pkg/builder/builder.go:85-95` | `prepareGitSource` accepts and forwards `opts.Auth`. |
| `pkg/runtime/orchestrator.go:359-369` | If `server.Source.Auth != nil`, resolve `CredentialRef` via the orchestrator's vault, build an `AuthConfig`, call `skills.BuildAuther`, populate `BuildOptions.Auth`. Verify the orchestrator already has a vault handle; if not, thread one in via `controller.Config`. |
| `cmd/gridctl/apply.go` | Add `--auth-token` / `--vault-key` / `--ssh-key` flags for parity with `gridctl skill add`. Lower priority — `${vault:KEY}` works without them. |
| `web/src/lib/yaml-builder.ts:443-554` | Extend `parseYAMLToForm` to read `source.auth.method` and `source.auth.credential_ref` back into form state. |
| `docs/config-schema.md` | Add an "MCP server source auth" section mirroring the skills source auth docs. |
| `pkg/config/loader_test.go` | Add round-trip test asserting `source.auth` survives load. |
| `pkg/builder/git_test.go` | Add test asserting `CloneOrUpdate` accepts and forwards auth. |
| `tests/integration/mcp_private_git_test.go` (new) | Mirror `tests/integration/skills_private_git_test.go` for the MCP server source path. Reuse `initPrivateBareRepo`, `startAuthedGitHTTPServer`, `isolateGridctlHome` helpers. |

### Risk Factors

- **Low** overall. Auth defaults to nil; public-repo flows unchanged. The skills path is the reference and has integration tests.
- The `CloneOrUpdate` signature change is the largest breakage surface — it's only called from `pkg/builder/builder.go:prepareGitSource`. Quick grep confirms no other callers.
- Vault handle threading into the orchestrator: confirm `controller.Deploy` already passes a `VaultLookup` down the call chain. If not, this is a small additional refactor.
- Permissive YAML loader stays permissive: this fix does **not** flip `KnownFields(true)`. That's a separate decision out of scope here.

### Regression Test Outline

Three tests, in priority order:

1. **`TestLoadStack_SourceAuth_PreservedRoundTrip`** in `pkg/config/loader_test.go` — load a stack.yaml fixture with `source.auth.{method,credential_ref}`, assert the loaded `Source.Auth` is non-nil and fields match.
2. **`TestCloneOrUpdate_ForwardsAuth`** in `pkg/builder/git_test.go` — call `CloneOrUpdate` with a non-nil auth, assert it reaches `gitpkg.Clone`. Use a stub `gitpkg` or a recorder.
3. **`TestMCP_PrivateGit_WithAuth_Succeeds`** in `tests/integration/mcp_private_git_test.go` — full e2e mirror of `skills_private_git_test.go`. Reuse the existing helpers.

The first test alone catches the silent-drop and would have caught this in CR. The second locks the builder contract. The third gives parity with skills.

## Recommendation

**Fix immediately.** This is a documented, advertised feature with a UI surface in production that silently fails for the exact use case it promises to support. The fix is mechanical (skills path is the reference), bounded (≈10 files, well-scoped), and low-risk (Auth defaults to nil for unaffected paths).

Suggested PR scoping:

- **PR 1 (the fix)**: types.go + loader.go (with `ToAuthConfig`) + builder/types.go + builder/git.go + builder/builder.go + orchestrator.go + the three regression tests + docs/config-schema.md update. This delivers a working backend for `${vault:KEY}` auth on MCP source clones.
- **PR 2 (CLI parity)**: `cmd/gridctl/apply.go` `--auth-token` / `--vault-key` / `--ssh-key` flags. Optional polish; ship if there's bandwidth.
- **PR 3 (web parity)**: `web/src/lib/yaml-builder.ts` `parseYAMLToForm` read-back. Sized to ride along in PR 1 if time allows.
- **Follow-up issue**: extract a shared `SourceAuth` / `AuthConfig` package across `pkg/config` and `pkg/skills`. Track but do not block.

Validator strict-mode (warn on unknown stack.yaml keys) is a tempting orthogonal hardening but **explicitly out of scope** — flipping go-yaml's `KnownFields(true)` would break unrelated workflows and is unrelated to this defect.

## References

- Wizard YAML emit: `web/src/lib/yaml-builder.ts:185-204`
- Wizard form types: `web/src/lib/yaml-builder.ts:18-30`
- Wizard form UI: `web/src/components/wizard/steps/MCPServerForm.tsx:647-660`, `:1702-1710`
- Wizard serialization test: `web/src/__tests__/MCPServerForm.test.tsx:501-549`
- Config Source struct (defect): `pkg/config/types.go:330-337`
- YAML loader (silent drop): `pkg/config/loader.go:45`
- Variable expansion (Source fields): `pkg/config/loader.go:181-185`
- Source validator: `pkg/config/validate.go:506-531`
- Builder Clone (no auth): `pkg/builder/git.go:13-57`
- Shared git layer (does support auth): `pkg/git/clone.go:20-65`
- Orchestrator BuildOptions construction: `pkg/runtime/orchestrator.go:332-374`
- Apply CLI (no auth flags): `cmd/gridctl/apply.go:55-69`
- Skills SourceAuth declarative type (reference): `pkg/skills/config.go:14-48`
- Skills AuthConfig runtime type (reference): `pkg/skills/importer.go:14-66`
- Skills authenticated clone (reference): `pkg/skills/remote.go:141-156`, `pkg/skills/importer.go:137-150`
- Skills CLI flags (reference for apply parity): `cmd/gridctl/skill.go:39-49`, `:144-161`
- Skills integration test (reference): `tests/integration/skills_private_git_test.go:123-237`
- README claim: `README.md:345-372`
- Config schema docs (skills only, MCP gap): `docs/config-schema.md:637-688`
- Originating PRs: #502 (auth primitives), #504 (skills wiring), **#505 (UI for both, no MCP backend)**, #506 (docs + skills integration tests), #508 (docs sync)
