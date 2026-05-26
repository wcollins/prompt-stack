# Feature Implementation: Private Git Repository Authentication

## Context

**gridctl** is a Go (1.25+) CLI + React web app that acts as an MCP gateway manager. Key architecture:

- **Backend**: Go, organized under `pkg/` (public packages: `skills`, `builder`, `vault`, `config`, `registry`, `mcp`, `controller`) and `internal/` (API, probe).
- **Frontend**: React + TypeScript under `web/`, with a 4-step skill-import wizard and a separate MCP server form.
- **Local state**: `~/.gridctl/` with an encrypted vault, skill registry, lockfile, and origin sidecars.
- **Git cloning happens in two places today**:
  - `pkg/skills/remote.go` — clones for skill imports (uses `go-git/v5`, authenticates via `GITHUB_TOKEN` env var over HTTPS).
  - `pkg/builder/git.go` — clones for MCP server source builds (uses `go-git/v5`, **no auth at all**).
  - The two files contain near-duplicate clone/update/checkout logic (~130 LOC of duplication).
- **Vault**: `pkg/vault/store.go` is a local encrypted secret store (XChaCha20-Poly1305 + Argon2id). Config values already support `${vault:KEY}` references resolved via `pkg/config/expand.go`. The resolver pattern is clean but currently only wired into stack/config loading, not into git operations.
- **Resolver pattern**: `config.Resolver` = `func(name string) (string, bool)`. `config.VaultResolver(vault)` returns a resolver that checks vault then env. `config.ExpandString(s, resolver)` expands `${...}` references.
- **Secrets UI**: `web/src/components/wizard/SecretsPopover.tsx` and `VaultSetSelector.tsx` are reusable pickers. `MCPServerForm.tsx` already uses them for OpenAPI auth — the same pattern applies here.

## Evaluation Context

This feature was evaluated as **Build with caveats** (High value, Medium effort, Medium risk). Key evaluation findings that shaped this prompt:

- **Market insight**: HTTPS + Personal Access Token is the dominant 2026 default across comparable tools (Go modules, Argo CD, Flux, Renovate, Claude Code plugins). SSH remains first-class but is being displaced as the default recommendation. Claude Code got explicit user bug reports (#26588, #28012) for defaulting to SSH.
- **UX decision rationale**: Inline collapsible auth card (not a dedicated wizard step) — public repos are the common case, and auth-required failures auto-expand the card. Reuse `SecretsPopover`; do not build a new credentials picker.
- **Risk mitigations baked in**:
  - Log/URL/error redaction lands **before** auth wiring.
  - Raw credentials never enter origin sidecar or lockfile — only the `${vault:KEY}` reference is persisted.
  - Host-key TOFU (`accept-new`) by default, never `StrictHostKeyChecking=no`.
  - A shared `pkg/git` module is extracted **before** auth is added, to stop duplication from doubling maintenance cost.
- **Scope discipline**: v1 is HTTPS+PAT + SSH-via-agent. Not in v1: gridctl-managed SSH key store, OAuth device flow, GitHub App tokens, 1Password-CLI passthrough, OS keychain integration. The `Auther` interface is designed so those are additive later.

Full evaluation: `prompts/gridctl/private-git-auth/feature-evaluation.md`

## Feature Description

Let gridctl clone private git repositories for two workflows:

1. **Skill import** — `gridctl skill add <repo>` and the web wizard can import SKILL.md files from private GitHub/GitLab/Bitbucket/self-hosted repos.
2. **MCP server source** — the builder can clone private repos when building MCP servers from source.

Credentials come from one of three sources, in priority order:

1. **Explicit flag / UI input** (ephemeral): `--auth-token <PAT>` on the CLI, or a "paste token" field in the UI. Not persisted.
2. **Vault reference** (persistent, recommended): `--vault-key GIT_TOKEN` on the CLI, or the vault picker in the UI. The reference `${vault:GIT_TOKEN}` is stored in origin/lockfile; the raw value stays in the encrypted vault.
3. **Ambient environment** (zero-config): SSH URLs use ssh-agent + `~/.ssh/known_hosts`. HTTPS URLs fall through to `GITHUB_TOKEN` env var if set, preserving current behavior.

Auto-detect SSH vs HTTPS from the URL scheme and select the right auth method accordingly.

## Requirements

### Functional Requirements

1. **Shared `pkg/git` package**: Extract clone/update/checkout logic currently duplicated in `pkg/skills/remote.go` and `pkg/builder/git.go` into a new `pkg/git/` package. Both existing surfaces must be refactored to use it. This is a prerequisite for (2) and should land as its own PR if feasible.
2. **`Auther` interface**: Define an interface in `pkg/git/auth.go` that produces a `transport.AuthMethod` for go-git based on repo URL and credential material. Implementations: `HTTPSTokenAuth`, `SSHAgentAuth`, `SSHKeyFileAuth`, `NoAuth`.
3. **Protocol detection**: `pkg/git/detect.go` with `DetectProtocol(url string) Protocol` (values: `HTTPS`, `SSH`, `Local`, `Unknown`). Used to pick the right `Auther`.
4. **Credential resolution**: Accept credentials from (a) explicit value, (b) `${vault:KEY}` reference, (c) ambient env/ssh-agent. Resolution uses the existing `config.Resolver` threading, not a new mechanism.
5. **Redaction helpers**: `pkg/git/redact.go` with `RedactURL(url string) string` (strips userinfo), `RedactError(err error) error` (rewrites embedded tokens), and a log-middleware wrapper.
6. **`ImportOptions.Auth`**: Extend `pkg/skills/importer.go` `ImportOptions` with an `Auth AuthConfig` field. `AuthConfig` struct carries: `Method` (`"none"`, `"token"`, `"ssh-agent"`, `"ssh-key"`), `Token` (resolved value, transient), `CredentialRef` (the `${vault:KEY}` token to persist), `SSHKeyPath`, `KnownHostsPath`.
7. **Origin + lockfile**: Add optional `CredentialRef string` field to `pkg/skills/origin.go` `Origin` and `pkg/skills/lockfile.go` `LockedSource`. Persist ONLY the reference, never the raw token.
8. **API endpoints**: Extend request bodies for `POST /api/skills/sources/{name}/preview`, `POST /api/skills/sources`, `POST /api/skills/sources/{name}/check`, `POST /api/skills/sources/{name}/update` to accept an optional `auth` object: `{method, token, credentialRef, sshKeyPath}`. Resolve at the API boundary before passing to the importer.
9. **CLI flags on `skill add`**: `--auth-token <pat>` (ephemeral), `--vault-key <key>` (persistent). Mutually exclusive. If neither provided, try ambient (env for HTTPS, ssh-agent for SSH). Also add these flags to `skill try` for symmetry. `skill update` reuses the stored `CredentialRef` from origin.
10. **Web wizard (AddSourceStep)**: Inline collapsible "Authentication" card below URL/Ref/Path fields. Collapsed by default. Auto-expands when a scan fails with an auth-class error. Two input modes: vault picker (reuse `SecretsPopover`) or paste-token field. Pass selection to `previewSkillSource` and subsequent API calls.
11. **Web wizard (MCPServerForm)**: Add the same auth subsection inside the Source block when source type is `git`.
12. **Error classification**: Map go-git errors to structured types: `ErrAuthRequired`, `ErrAuthFailed`, `ErrNotFound`, `ErrHostKeyMismatch`, `ErrSSHAgentMissing`. Surface class and hint to the API/UI.
13. **Host-key policy**: SSH uses `StrictHostKeyChecking=accept-new` semantics (TOFU). Never `no`. Respect user's `~/.ssh/known_hosts`.
14. **Config schema**: Extend `SkillSource` in `pkg/skills/config.go` with optional `auth` block: `{method, credentialRef, sshKeyPath}`. Update `docs/config-schema.md`.

### Non-Functional Requirements

- **Security**: Raw tokens never written to disk except the vault. All log lines involving git URLs must pass through the redaction helper. Errors surfaced to the UI must be redacted.
- **Backward compatibility**: Existing public-repo flows must continue to work without any changes. `GITHUB_TOKEN` env var continues to work as a fallback for HTTPS.
- **Performance**: No measurable change for the public-repo path. SSH operations use the user's existing ssh-agent rather than spawning new processes.
- **Cross-platform**: macOS and Linux must work. Windows is best-effort (document known limitations).
- **Test coverage**: Skills package coverage must not drop below current ~43%. Add coverage on the new `pkg/git/` package.

### Out of Scope

- gridctl-managed SSH key store (key upload UI, encrypted key storage)
- OS keychain integration (`zalando/go-keyring`, `99designs/keyring`)
- OAuth device-code flow (GitHub/GitLab login dialogs)
- GitHub App installation tokens
- 1Password-CLI / Bitwarden-CLI passthrough
- Credential templates (Argo-style URL-prefix matching across sources)
- Git LFS authentication
- Any change to the vault's encryption scheme or storage format

These are documented as v2 candidates; the `Auther` interface must support them as additive implementations.

## Architecture Guidance

### Recommended Approach

1. **Extract first, extend second.** Land the `pkg/git` refactor as a prerequisite PR with no behavior change, then add auth in a second PR. This bounds review complexity and makes the auth diff readable.
2. **Mirror `config.OpenAPIAuth` philosophy.** That struct handles multi-mechanism auth with `TokenEnv`/`PasswordEnv` fields resolved through the same vault/env resolver. The git `AuthConfig` should feel identical, so users who learned one pattern already know the other.
3. **Thread `config.Resolver` through, do not reinvent.** The importer and builder already have access (or can plumb it). Resolve `${vault:KEY}` at the same layer config does — at the API/CLI boundary before invoking the importer/builder.
4. **Keep `Auther` go-git-agnostic at the interface, implementation-specific at the adapter.** The interface returns `transport.AuthMethod` but callers only depend on `Auther`. If go-git is ever replaced, the interface survives.

### Key Files to Understand

- `pkg/skills/remote.go` — current HTTPS+`GITHUB_TOKEN` auth in `cloneShallow`, `updateExisting`, `FetchAndCompare`. Three call sites to migrate.
- `pkg/builder/git.go` — zero-auth clone; `cloneRepo`, `updateRepo`, `checkoutRef`. Duplicates `remote.go` logic.
- `pkg/skills/importer.go` — orchestrator; holds `ImportOptions` + call flow (clone → discover → validate → scan → save → origin → lockfile).
- `pkg/skills/origin.go`, `pkg/skills/lockfile.go` — where `CredentialRef` needs to land.
- `pkg/config/expand.go` — `Resolver`, `VaultLookup`, `ExpandString`. The pattern to reuse.
- `pkg/config/types.go` — `OpenAPIAuth` as the precedent to mirror.
- `pkg/vault/store.go` — `Get(key)` interface for the resolver.
- `internal/api/skills.go` — HTTP handlers for `/api/skills/*`; extend request schemas here.
- `cmd/gridctl/skill.go` — CLI flag definitions; extend `skillAddCmd.Flags()` and `skillTryCmd.Flags()`.
- `web/src/components/wizard/steps/AddSourceStep.tsx` — the URL scan step; add the auth card here.
- `web/src/components/wizard/steps/MCPServerForm.tsx` — Source block; add auth parity here.
- `web/src/components/wizard/SecretsPopover.tsx` — reuse verbatim for the vault picker.
- `web/src/lib/api.ts` — extend `previewSkillSource`/`addSkillSource` signatures.

### Integration Points

- **`pkg/skills/remote.go:cloneShallow`** (lines ~129–197): Replace the hardcoded `os.Getenv("GITHUB_TOKEN")` branch with `auther.AuthFor(url)`.
- **`pkg/skills/remote.go:FetchAndCompare`** (line ~68): Same replacement.
- **`pkg/skills/remote.go:updateExisting`** (line ~199): Same replacement.
- **`pkg/builder/git.go:cloneRepo` and `:updateRepo`**: Same replacement + gain auth support for the first time.
- **`pkg/skills/importer.go:Import`**: Pass `opts.Auth` into `CloneAndDiscover`; also plumb into `FetchAndCompare` for update-path.
- **`internal/api/skills.go`**: Accept `auth` in request body; resolve `credentialRef` via vault before constructing `ImportOptions`.
- **`cmd/gridctl/skill.go:runSkillAdd`**: Read flags, build `AuthConfig`, pass into `ImportOptions`.
- **`web/src/components/wizard/steps/AddSourceStep.tsx`** (error handler at line ~87–90): Detect auth-class error and auto-expand the auth card.

### Reusable Components

- **`SecretsPopover`** — covers "pick existing secret / create new" including create-on-demand with suggested key names.
- **`config.VaultResolver` / `config.EnvResolver` / `config.ExpandString`** — do not reimplement; the auth layer must use these.
- **`output` package** — consistent CLI output formatting for the new error hints.

## UX Specification

### Discovery

- **CLI**: `gridctl skill add --help` lists `--auth-token` and `--vault-key`. README gains a "Private repositories" section with quickstart.
- **Web**: AddSourceStep shows a subtle "Need to use a private repo?" link under the URL field that expands the auth card. Empty-state tip card mentions vault setup.
- **Docs**: `docs/config-schema.md` documents the `auth` block; `AGENTS.md` records the design.

### Activation

**CLI**:
```bash
# Public repo (unchanged)
gridctl skill add https://github.com/acme/public-skills

# Private repo with vault-stored PAT
gridctl vault set GIT_TOKEN ghp_abc123
gridctl skill add https://github.com/acme/private-skills --vault-key GIT_TOKEN

# Private repo with one-shot PAT (CI)
gridctl skill add https://github.com/acme/private-skills --auth-token $PAT

# Private repo via SSH (ambient ssh-agent)
gridctl skill add git@github.com:acme/private-skills.git
```

**Web**: user pastes URL, clicks Scan. If auth fails, auth card auto-expands with "This repository requires authentication" and two options: "Use vault secret" (opens `SecretsPopover`) or "Paste token" (inline text field). User picks one, retries Scan.

### Interaction

- Auth card is collapsed by default. The URL + Ref + Path + Scan button flow is unchanged for public repos.
- The vault picker is the visually primary option; the paste-token field is secondary and has a "not saved" subtitle.
- SSH URLs (`git@...`) show a small "Using ssh-agent" hint and hide the token fields.

### Feedback

- **Success**: wizard proceeds to Browse step. Origin sidecar shows `credentialRef` in `skill info` output.
- **Auth failure**: red error banner on the auth card: "Authentication failed — the token does not have access to this repository. Try a different credential."
- **Not found vs unauthenticated**: differentiate. Private repos return "not found" to unauth'd users on GitHub — the hint must say "this may be a private repository; add credentials to continue."
- **Host key mismatch** (SSH): prominent warning, not silent. Offer "update known_hosts" explicit action; never auto-accept without user consent.

### Error States

- `ErrAuthRequired` → "This repository requires authentication."
- `ErrAuthFailed` → "The provided credentials were rejected."
- `ErrNotFound` → "Repository not found. If it's private, add credentials."
- `ErrHostKeyMismatch` → "The SSH host key does not match your known_hosts. This could indicate a security issue."
- `ErrSSHAgentMissing` → "No ssh-agent detected. Run `eval \"$(ssh-agent -s)\" && ssh-add` or use `--auth-token` instead."

## Implementation Notes

### Conventions to Follow

- **Go package style**: lowercase package names; tests colocated in `*_test.go`; errors wrapped with `fmt.Errorf("%w", err)`; structured logging via `log/slog`.
- **Naming**: auth types capitalized (`HTTPSTokenAuth`, not `HttpsTokenAuth`). Constants for protocol/method strings in a central file.
- **Error types**: use `errors.Is`-friendly sentinel errors (`var ErrAuthRequired = errors.New(...)`), not `fmt.Errorf` alone.
- **React**: Tailwind classes consistent with the rest of the codebase; `cn()` helper for conditional classes; `showToast` for transient feedback; keep step components under `wizard/steps/`.
- **Commit convention**: `feat: add private git repo auth` etc.; sign commits; no Claude/Co-authored-by trailers.
- **No new dependencies** unless absolutely necessary. go-git and `golang.org/x/crypto/ssh` cover SSH; the vault covers secrets.

### Potential Pitfalls

- **Credential leakage in URLs**: users will paste `https://TOKEN@github.com/...` URLs. Detect and reject this, offering to move the token to vault. Never log the raw URL.
- **go-git's fetch-with-auth vs clone-with-auth inconsistency**: the `FetchOptions` and `CloneOptions` both take `Auth`, but the existing code only sets it on clone. Audit every go-git call and ensure `Auth` is set on every remote operation.
- **go-git's SSH known_hosts handling**: by default go-git uses the user's `~/.ssh/known_hosts`; if the file doesn't exist, the call fails opaquely. Pre-check and emit `ErrSSHAgentMissing`-style errors.
- **Resolver threading into the web API**: the API handler must construct a resolver with the current vault, not a stale one. Make sure it pulls from the live `vault.Store` on every request, since vault contents can change mid-session.
- **Origin SHA in lockfile is reused for auth check**: when `skill update` runs, it needs the stored `CredentialRef` to re-resolve creds. If the vault key was deleted, surface a specific error ("credential `GIT_TOKEN` no longer exists in vault; set it or re-import with different credentials").
- **Double-resolution bug**: avoid calling `ExpandString` twice on the same value. Store the raw `${vault:KEY}` in origin; resolve only at git-operation time.
- **Silent fallback to public clone**: if `AuthConfig.Method == "token"` but the token is empty string, do NOT fall through to unauthenticated clone — that causes confusing "repo not found" errors. Fail loudly with "token is empty".

### Suggested Build Order

1. **Refactor**: Extract `pkg/git/` from the duplicated logic in `pkg/skills/remote.go` and `pkg/builder/git.go`. No behavior change. Ship as its own PR; verify existing tests still pass.
2. **Redaction**: Land `pkg/git/redact.go` with unit tests. Wire into existing log lines.
3. **`Auther` interface**: Define in `pkg/git/auth.go`. Implement `NoAuth`, `HTTPSTokenAuth`, `SSHAgentAuth`, `SSHKeyFileAuth`. Unit-test each with mock go-git remotes or the existing integration test pattern.
4. **Error classification**: Add `pkg/git/errors.go`. Map go-git errors to classes.
5. **Importer integration**: Extend `ImportOptions`; thread `AuthConfig` through `CloneAndDiscover`, `FetchAndCompare`, `updateExisting`. Add origin + lockfile `CredentialRef`.
6. **CLI flags**: `--auth-token`, `--vault-key` on `skill add` / `skill try`.
7. **API**: Extend request schemas; resolve `credentialRef` at the boundary.
8. **Web**: auth card in `AddSourceStep.tsx`; parity in `MCPServerForm.tsx`; extend `previewSkillSource`/`addSkillSource` in `web/src/lib/api.ts`.
9. **Docs**: README, `docs/config-schema.md`, `AGENTS.md`.
10. **Integration tests**: end-to-end private-repo clone against a fixture (use `httptest` for HTTPS or a local bare repo for SSH via `git` daemon if feasible).

## Acceptance Criteria

1. `pkg/git/` package exists with `Auther` interface and four implementations (`NoAuth`, `HTTPSTokenAuth`, `SSHAgentAuth`, `SSHKeyFileAuth`).
2. `pkg/skills/remote.go` and `pkg/builder/git.go` both use `pkg/git/` — no duplicated clone/update/checkout logic remains.
3. `gridctl skill add <private-repo> --vault-key GIT_TOKEN` succeeds (with `GIT_TOKEN` set in vault) and imports skills.
4. `gridctl skill add <private-repo> --auth-token $PAT` succeeds and does NOT persist the token to origin or lockfile (verify: `grep -r "$PAT" ~/.gridctl/` finds nothing).
5. `gridctl skill add git@github.com:user/private-repo.git` succeeds using ssh-agent, with no flags.
6. `gridctl skill update <name>` re-resolves the stored `${vault:KEY}` reference automatically.
7. Web wizard: scanning a private repo with no auth shows an auto-expanded auth card with a clear CTA; selecting a vault secret and re-scanning succeeds.
8. MCP server form: private git source URLs can be configured with auth; clone succeeds at build time.
9. No log line contains a plaintext PAT or SSH key. Verified via a scripted test that runs a failing clone with credentials and greps the stderr output.
10. `gridctl skill info <name>` displays `credentialRef: ${vault:GIT_TOKEN}` when applicable; no raw token appears.
11. `pkg/skills/` test coverage ≥ current baseline. New `pkg/git/` package has ≥ 70% coverage.
12. Host-key mismatch on SSH surfaces `ErrHostKeyMismatch` with a clear, non-auto-dismiss UI warning. Never silently accepts.
13. README has a "Private repositories" section with CLI quickstart and vault-setup example. `docs/config-schema.md` documents the `auth` block.
14. Existing public-repo flows (e.g., the test fixture that imports from a public GitHub URL) pass unchanged.

## References

- [Feature evaluation](./feature-evaluation.md)
- [go-git v5 transport/ssh](https://pkg.go.dev/github.com/go-git/go-git/v5/plumbing/transport/ssh)
- [go-git v5 transport/http](https://pkg.go.dev/github.com/go-git/go-git/v5/plumbing/transport/http)
- [Argo CD — Private Repositories](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)
- [Flux CD — GitRepository Secret schema](https://fluxcd.io/flux/components/source/gitrepositories/#secret-reference)
- [GitHub fine-grained PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [OpenSSH `accept-new` (TOFU)](https://www.openssh.com/txt/release-7.6)
- [OWASP ASVS — Secret Management](https://owasp.org/www-project-application-security-verification-standard/)
- [CVE-2024-32002 — git submodule RCE](https://nvd.nist.gov/vuln/detail/CVE-2024-32002)
- [gridctl `pkg/config/expand.go` resolver pattern](../../../../../gridctl/pkg/config/expand.go)
- [gridctl `pkg/config/types.go` OpenAPIAuth precedent](../../../../../gridctl/pkg/config/types.go)
