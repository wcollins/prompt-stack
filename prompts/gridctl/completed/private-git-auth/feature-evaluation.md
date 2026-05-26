# Feature Evaluation: Private Git Repository Authentication

**Date**: 2026-04-20
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium

## Summary

gridctl today can only clone **public** git repositories — both for skill imports (`pkg/skills/remote.go`) and for MCP server source builds (`pkg/builder/git.go`). The only auth mechanism is a hardcoded `GITHUB_TOKEN` env var, and the MCP builder has no auth at all. Adding private-repo support via Personal Access Tokens (HTTPS) and SSH-via-agent is table-stakes for 2026-era dev tooling and unblocks a large class of enterprise and team use cases. The existing vault + `${vault:KEY}` resolver pattern can carry credentials end-to-end without building new infrastructure. Build it, but scope tightly and refactor the duplicated clone paths before adding auth.

## The Idea

Let gridctl users interact with private git repositories when importing skills or cloning MCP server source — same functionality as today's public skill import, but authenticated.

**Problem solved**: Any user with private skills (internal team libraries, proprietary MCP servers, self-hosted GitLab/Bitbucket/Gitea) is completely blocked today. The tool surfaces a cryptic go-git error and stops.

**Who benefits**:
- Individual developers with private repos
- Teams sharing internal skill libraries
- Enterprises on self-hosted Git (GitLab EE, Bitbucket Data Center, Gitea, Azure DevOps)
- Consultants working across multiple client orgs
- Anyone building MCP servers from private source

## Project Context

### Current State

- **Maturity**: v0.1.0-beta.6, actively developed, ~42% test coverage, production signals (OpenSSF badge, SECURITY.md, gatekeeper CI).
- **Git surfaces**: Two — `pkg/skills/remote.go` (skill imports, has `GITHUB_TOKEN` via `http.BasicAuth`) and `pkg/builder/git.go` (MCP source cloning, has **no auth at all**). The two files contain ~130 LOC of near-duplicate clone/update/checkout logic.
- **Vault**: gridctl has a mature local secret store (`pkg/vault/store.go`, XChaCha20-Poly1305 + Argon2id, 85% test coverage) with a clean `${vault:KEY}` resolver (`pkg/config/expand.go`, 88.5% coverage). The resolver is currently only wired into config/stack loading, not git operations.
- **UI**: `SecretsPopover` and `VaultSetSelector` already provide proven "pick a vault key or create one" UX reused in `MCPServerForm.tsx` for OpenAPI auth. The existing skill import wizard (`SkillImportWizard.tsx`, 4 steps) does not have any auth UI yet.
- **CLI**: `gridctl skill add` exposes `--ref/--path/--trust/--force/--rename` flags — an extensible, idiomatic pattern.

### Integration Surface

| Layer | File | Change |
|------|------|--------|
| Shared git library (new) | `pkg/git/auth.go`, `pkg/git/clone.go` | Extract duplicated clone logic, add `Auther` interface |
| Skill import | `pkg/skills/remote.go`, `pkg/skills/importer.go` | Use new `pkg/git`, extend `ImportOptions` with `Auth` |
| MCP source builder | `pkg/builder/git.go` | Use new `pkg/git`, accept auth context from builder |
| Origin sidecar / lockfile | `pkg/skills/origin.go`, `pkg/skills/lockfile.go` | Add optional `CredentialRef` (stores the `${vault:KEY}` reference, never the raw value) |
| HTTP API | `internal/api/skills.go` | Accept `auth` object in preview/add/check/update requests |
| CLI | `cmd/gridctl/skill.go` | Add `--auth-token` and `--vault-key` flags |
| Skill wizard | `web/src/components/wizard/steps/AddSourceStep.tsx` | Inline collapsible auth card, auto-expand on auth-class error |
| MCP wizard | `web/src/components/wizard/steps/MCPServerForm.tsx` | Auth subsection in Source block |
| Config schema | `pkg/skills/config.go`, `docs/config-schema.md` | Optional `auth` block on `SkillSource` |
| Redaction | `pkg/git/redact.go` (new) | URL/error/log scrubbing helpers |

### Reusable Components

- `config.Resolver` / `VaultLookup` interfaces (`pkg/config/expand.go`) — thread through git operations exactly how they thread through stack loading.
- `config.OpenAPIAuth` struct (`pkg/config/types.go`) — precedent for multi-mechanism auth with `TokenEnv`/`PasswordEnv` fields. Mirror its philosophy.
- `SecretsPopover` and `VaultSetSelector` React components — zero new UI primitives needed.
- `go-git v5.18.0` already pulls in `xanzy/ssh-agent`, `ProtonMail/go-crypto`, `golang.org/x/crypto/ssh` transitively — SSH support is one wiring away.

## Market Analysis

### Competitive Landscape

**Dominant 2026 pattern**: defer to the ambient git environment. Go modules, Terraform, pip, Cargo, and Claude Code's plugin marketplace all rely on whatever credential machinery the user has already configured (ssh-agent, `~/.netrc`, credential helpers, `gh auth`). If `git clone` works in the user's shell, the tool should work too.

On top of that baseline, mature tools layer a declarative credential store for cases where ambient git is not available (CI, containerized, web-only). Argo CD, Flux CD, Helm chart repos all converge on a two-option model: HTTPS (username/password or PAT) OR SSH (private key).

### Market Positioning

**Catch up, not leap ahead.** Private-repo support is table-stakes for a serious dev tool in 2026:

- Argo CD, Flux CD, Helm, Renovate, Dependabot, Backstage all support it.
- Claude Code's plugin marketplace supports private repos (though users filed bugs that it defaulted to SSH — see issues #26588, #28012).
- Terraform, npm, pip, Go modules all have documented private-repo paths.

Not shipping this keeps gridctl in the "toy / public-only tool" perception bucket.

### Ecosystem Support

- **go-git v5.18+** has complete SSH support (`transport/ssh`), including agent, private keys, known_hosts.
- `golang.org/x/crypto/ssh` already in the dependency tree.
- `zalando/go-keyring` (simple) or `99designs/keyring` (broader backends, used by aws-vault) are available for OS-keychain fallback if that becomes a v2 scope.

### Demand Signals

- gridctl's positioning as an MCP gateway for "real workflows" implies private/internal assets.
- Every comparable tool has this feature — its absence shows up the moment anyone tries to import an internal skill.
- HTTPS+PAT is trending over SSH even for power users (simpler for CI, fine-grained PAT scopes, shorter lifetimes). Claude Code got bug reports for defaulting to SSH.

### Timing

**Now.** gridctl is in beta; auth model decisions made now will be much cheaper to iterate than after GA. The two git surfaces already carry duplication debt that worsens each week — extracting a shared `pkg/git` module before adding auth is the cheapest refactor window this feature will ever have.

## User Experience

### Interaction Model

**Discovery**
- Web wizard: when a private-repo URL fails to scan, auto-expand an inline "Authentication" card with a clear CTA and the vault picker. Tip card in empty state explains supported auth.
- CLI: `gridctl skill add --help` lists the new flags; error output on a private-repo failure includes an actionable next step (e.g., `private repository detected — use --vault-key GIT_TOKEN or --auth-token <PAT>`).
- Docs: README gets a "Private repositories" section; `docs/config-schema.md` documents the new `auth` block on `SkillSource`.

**Activation (three paths)**
1. **Ambient git (zero-config)**: SSH URLs (`git@github.com:org/repo.git`) use the user's ssh-agent and `~/.ssh/known_hosts`. No gridctl configuration needed.
2. **Vault-backed PAT (recommended)**: user stores a PAT in gridctl's vault (`gridctl vault set GIT_TOKEN ghp_...`), then references it via `--vault-key GIT_TOKEN` (CLI) or the wizard vault picker (UI). Stored in origin/lockfile as `${vault:GIT_TOKEN}` reference, never raw.
3. **Direct token**: `--auth-token <PAT>` for one-shot / CI use. Not persisted to origin or lockfile.

**Interaction**
- Auth card collapsed by default (common case is public). Opens inline on demand or on auth-class error.
- The `SecretsPopover` component already covers "pick existing / create new" — no new component needed.
- Auto-detect protocol: SSH vs HTTPS inferred from URL scheme.

**Feedback**
- On auth failure, error is classified (`unauthenticated`, `forbidden`, `not_found`, `ssh_agent_missing`, `host_key_mismatch`) and a matching hint is shown.
- On success: origin sidecar shows `credentialRef: ${vault:GIT_TOKEN}` in `gridctl skill info`. Reproducible updates use the same ref.

**Error states**
- Auth-required surfaces as a structured error, not raw go-git text.
- Host-key mismatch surfaces as a security warning, not a generic clone error.
- Missing ssh-agent surfaces an instruction, not a silent failure.

### Workflow Impact

**Removes friction** for the private-repo case, which today is a full block. Adds zero friction for public repos — the auth card is closed by default and never appears unless the user opens it or an auth error is raised.

### UX Recommendations

- Inline collapsible auth card in `AddSourceStep.tsx`. Do not add a new wizard step.
- Reuse `SecretsPopover` verbatim; do not introduce a new "git credentials" picker.
- Mirror the inline-auth pattern in `MCPServerForm.tsx` Source subsection for parity.
- Add an auth-status footer line to `gridctl skill info` output: `Authenticated via ${vault:GIT_TOKEN}`.
- Do **not** build a gridctl-managed SSH key store. Rely on `~/.ssh` and ssh-agent.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Hard block for private/internal use; not annoyance-level |
| User impact | Broad + Deep | Teams, enterprise, self-hosted Git, consultants |
| Strategic alignment | Core mission | MCP gateway for real workflows implies private assets |
| Market positioning | Catch up | Table-stakes among comparable tools |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Two duplicate git surfaces; threading a resolver through importer/API/CLI/UI |
| Effort estimate | Medium | ~400 LOC Go + ~250 LOC React + ~300 LOC tests + docs |
| Risk level | Medium | Credential leakage in logs is the main hazard; mitigated by redaction utility + vault-only storage |
| Maintenance burden | Moderate | Extracting shared `pkg/git` reduces existing duplication; adding new auth types later is additive |

## Recommendation

**Build with caveats.** The value is high (unblocks a major class of users, core to the tool's mission, table-stakes for 2026), the cost is moderate, and the risk is controllable with disciplined scoping.

**Caveats**:

1. **Refactor first, then add.** Extract duplicated clone/fetch/checkout code from `pkg/skills/remote.go` and `pkg/builder/git.go` into a new `pkg/git/` package with an `Auther` interface before wiring SSH or PAT. Skipping this step doubles maintenance cost from day one.
2. **Scope the first cut tightly.** Ship HTTPS+PAT (vault + env + direct flag) and SSH via ambient ssh-agent + `~/.ssh`. Do NOT ship a gridctl-managed SSH key store, OAuth device flow, GitHub App tokens, or 1Password-CLI passthrough in v1. Design the `Auther` interface so those are additive later.
3. **Fix `pkg/builder/git.go` silently.** MCP source cloning has no auth today — this is effectively a latent bug. Add auth parity in the same change.
4. **Log redaction is non-negotiable.** Implement URL/error/log redaction helpers before any auth code lands. `logger.Info("cloning repository", "url", url)` must not leak `https://TOKEN@host/...` style URLs. Use structured logging with a dedicated `url_hash` field for error paths.
5. **Host-key TOFU by default.** Use `StrictHostKeyChecking=accept-new` semantics, writing to the user's `~/.ssh/known_hosts`. Never `StrictHostKeyChecking=no`.
6. **Test coverage floor.** Skills package is at 43% coverage today. This change must not lower that. Add at minimum: (a) HTTPS+PAT success path, (b) SSH-agent success path, (c) auth-error classification, (d) log-redaction unit tests.
7. **Origin/lockfile stores only the reference.** Never persist raw credentials. Add optional `CredentialRef string` (the `${vault:KEY}` token) to both structs for reproducibility.

**What would move this from "Build with caveats" to "Build" unconditionally**: a committed owner, the refactor done as a prerequisite PR, and a redaction helper landed before auth code.

## References

- [Go Modules Reference — private modules](https://go.dev/ref/mod#private-modules)
- [Argo CD — Private Repositories](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)
- [Flux CD — GitRepository spec](https://fluxcd.io/flux/components/source/gitrepositories/)
- [Claude Code — Plugins](https://code.claude.com/docs/en/plugins)
- [Claude Code issue #26588 — Marketplace should default to HTTPS](https://github.com/anthropics/claude-code/issues/26588)
- [Claude Code issue #37886 — SSH unlock loop](https://github.com/anthropics/claude-code/issues/37886)
- [go-git v5 transport/ssh](https://pkg.go.dev/github.com/go-git/go-git/v5/plumbing/transport/ssh)
- [GitHub CLI auth documentation](https://cli.github.com/manual/gh_auth_login)
- [git-credential-manager](https://github.com/git-ecosystem/git-credential-manager)
- [zalando/go-keyring](https://github.com/zalando/go-keyring)
- [99designs/keyring](https://github.com/99designs/keyring)
- [OWASP ASVS — Secret Management](https://owasp.org/www-project-application-security-verification-standard/)
- [NIST SP 800-63B Digital Identity Guidelines](https://pages.nist.gov/800-63-3/sp800-63b.html)
- [HashiCorp — SSH keys for HCP Terraform modules](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/settings/ssh-keys)
- [CVE-2024-32002 — git submodule RCE](https://nvd.nist.gov/vuln/detail/CVE-2024-32002)
