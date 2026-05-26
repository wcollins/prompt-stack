# Feature Evaluation: Unified Variable Store (rename `vault` → `var`)

**Date**: 2026-05-18
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Large

## Summary

Expand `gridctl vault` from a secrets-only manager into a unified configuration store (`gridctl var`) that holds both secrets and non-sensitive variables with rich types (string/json/list/number/bool). The same store backs `${var:KEY}` references in stack YAML — secrets are encrypted-at-rest and redacted in logs; plaintext variables are visible. The headline UX is portable stack.yaml files that can be checked into git unchanged across dev/staging/prod, with environment-specific values living in the local var store. Recommended as a flagship feature with caveats: ship in two PRs, add schema versioning to the vault file, and soft-alias `${vault:KEY}` in YAML during beta.

## The Idea

Today, `gridctl vault` is a secrets-only store. Stack YAMLs can reference `${vault:KEY}` for sensitive values, but non-sensitive but environment-specific values (REGION, CLUSTER_ID, account IDs, CORS origins) must be hardcoded in the YAML or supplied via shell env vars at apply time. Two consequences:

1. Stack YAMLs aren't truly portable — checking one into git either leaks environment-specific config or requires a parallel `.env`-style sidecar.
2. Users misuse the vault for non-secrets to get persistence, then suffer "masking fatigue" — logs become unreadable because everything from vault is treated as sensitive.

The proposal: one store, two sensitivity classes (`--secret` default, `--plaintext` opt-out), with rich types. Stack YAMLs reference `${var:KEY}` uniformly; the store decides whether to redact. JSON-typed variables can expand directly into YAML mapping/sequence fields (object expansion).

**Who benefits**: every gridctl user with a stack.yaml. Pervasive but shallow per-session impact.

## Project Context

### Current State

gridctl is at v0.1.0-beta.9, governed by an explicit Constitution (Article VIII semver, Article IX stack.yaml BC, Article XII secure defaults). The vault subsystem is mature:

- `pkg/vault/types.go` defines a tiny `Secret` struct (`Key`, `Value`, `Set`). Storage is JSON-on-disk with optional XChaCha20-Poly1305 + Argon2id envelope encryption.
- `pkg/vault/store.go` (740 LOC) handles load/save, encryption state machine, atomic writes, external-write detection (mtime/size gate). Recent PRs #579/#577 (May 2026) hardened encryption-state transitions.
- `pkg/config/expand.go` defines a single-pass regex expander that resolves `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR:+replacement}`, `${vault:KEY}`. **All resolution returns strings.**
- `pkg/config/loader.go::expandStackVars` is a hand-written, field-by-field switchboard that calls `expand(string)` on every string slot in the Stack struct.
- Set machinery: `gridctl vault sets {list,create,delete}` exists; `secrets.sets:` in stack YAML auto-injects all set members into every MCPServer/Resource env at load time.
- Test coverage is excellent: 1.56:1 in `pkg/vault/`, 1.89:1 in `pkg/config/`.

### Integration Surface

Files this feature must touch:

- `pkg/vault/types.go` — extend `Secret` (rename to `Variable`) with `Type`, `IsSecret`; add `storeData.Version`.
- `pkg/vault/store.go` — backward-compatible loading; filter `Values()` by `IsSecret`; round-trip new fields.
- `cmd/gridctl/vault.go` (rename file or add `cmd/gridctl/var.go`) — new top-level `var` command tree; deprecation handler for `vault`.
- `pkg/config/expand.go` — accept `${var:KEY}` as canonical; keep `${vault:KEY}` parsed with deprecation log in beta. (PR 1 only — still string-returning.)
- `pkg/config/loader.go` — `expandStackVars` rewritten to yaml.Node tree walk for object expansion. (PR 2.)
- `pkg/logging/redact.go` — no change needed; filtering in `Store.Values()` is sufficient.
- `internal/api/vault.go` — extend REST handlers with type/visibility fields; rename routes to `/api/var/*` with deprecated `/api/vault/*` aliases.
- `examples/secrets-vault/*.yaml` — update to use `${var:KEY}`; add a new portability example.
- `docs/config-schema.md` — replace "Variable Expansion" section content.
- `CHANGELOG.md` — Breaking + Feature entries.
- `AGENTS.md` and `CONSTITUTION.md` Article IX/XII update if needed.

### Reusable Components

- **Atomic write pattern in `store.go`** — keep verbatim.
- **`vault.Set` (groups) struct** — orthogonal to sensitivity; reuse unchanged.
- **`output.Printer` for table rendering** — extend with TYPE + VISIBILITY columns; no new dependency.
- **`RedactingHandler` in `pkg/logging`** — needs no changes; just feed it the filtered slice.
- **Existing `.env` and `--format json` import/export** — extend; don't rewrite.

## Market Analysis

### Competitive Landscape

| Tool | Model | Flag/Syntax |
|---|---|---|
| Terraform | One concept + `sensitive=true` HCL attr | HCL only, not CLI flag |
| Pulumi Config | One store + `--secret`/`--plaintext` | **Closest CLI idiom** |
| Pulumi ESC (GA Sept 2024) | YAML environments, `fn::secret`, composition via `imports` | **Closest architectural twin** |
| AWS SSM Parameter Store | One store, `--type String\|StringList\|SecureString` | Cautionary: type overloads format AND sensitivity |
| GCP Parameter Manager | Config store that references Secret Manager | Newest convergence model |
| Doppler | Unified, "secret" everywhere, `--visibility` levels | Marketing positioning matters |
| GitHub Actions | Two APIs: `vars.*` and `secrets.*` (Jan 2023) | **Strongest industry signal** |
| Kubernetes ConfigMap/Secret | Two kinds, near-identical APIs | Two-bucket model survives |
| Toolhive (gridctl's closest MCP competitor) | `thv secret` separate from `-e` | Split model, not unified |

### Market Positioning

This puts gridctl in line with the **modern unified-store-with-sensitivity-flag** pattern that won the IaC space. **No MCP competitor has unified config + secrets** — Toolhive uses the split model. The combination of unified store + typed expansion + portable stack YAML is moderately differentiating within MCP-orchestration tooling, though not a moat.

### Ecosystem Support

The pattern is publicly proven at scale:
- **GitHub Actions added `vars.*` in Jan 2023 specifically because users were misusing `secrets.*` for things like `AWS_REGION`** — verbatim rationale from GitHub's blog: "didn't allow for easy storage and retrieval of non-sensitive configuration data such as compiler flags, usernames, and server names." This is the exact problem the proposal targets.
- **Pulumi ESC (GA Sept 2024)** reports >90% duplication reduction by unifying config + secrets in versioned YAML environments. Closest architectural twin.

### Demand Signals

**MCP-specific (moderate):**
- [anthropics/claude-code#28942](https://github.com/anthropics/claude-code/issues/28942) — "Support `envFile` in `.mcp.json`" — open, marked priority. Direct user quote: *"This creates an impossible choice: commit secrets or don't share config."*
- [anthropics/claude-code#2065](https://github.com/anthropics/claude-code/issues/2065) — "How to securely provide env variables to MCP servers?"
- [anthropics/claude-code#57131](https://github.com/anthropics/claude-code/issues/57131) — Production bug where `claude mcp remove` reformatted `.mcp.json` and exposed LangSmith + Jira creds in git.
- [LogicWeave: mcp.json is the new .env](https://www.logicweave.ai/mcp-config-is-new-env/) — npm worm explicitly targets `~/.claude/mcp.json`.

**Industry-wide (strong):**
- Helm complaints: [helm/helm#5257](https://github.com/helm/helm/issues/5257) "best practices for multi-environment deployments" — long-running pain.
- Docker Compose interpolation footguns: [docker/compose#9980](https://github.com/docker/compose/issues/9980).
- Terraform `sensitive=true` over-marking is documented anti-pattern in HashiCorp's own tutorials.

**Honest caveat**: the MCP-specific demand is for *interpolation that lets me commit my stack.yaml without leaking secrets* — which gridctl already partially solves via `${vault:KEY}`. The unification piece is an inferred need, not a screaming one. The strongest validation comes from the broader IaC industry direction, not MCP-specific user demand.

## User Experience

### Interaction Model

**Discovery**: existing `gridctl vault` users get a deprecation message pointing to `gridctl var`. New users see `gridctl var` in `gridctl --help` directly.

**Workflow** — set values:
```bash
gridctl var set REGION us-east-1 --plaintext              # public
gridctl var set CLUSTER_ID prod-01 --plaintext            # public
gridctl var set DB_PASSWORD 'secret'                      # default: secret
gridctl var set CORS_ORIGINS '["https://app.example.com"]' --type json --plaintext
gridctl var set DB_HOST db.example.com --set production --plaintext
```

**Workflow** — use values in stack:
```yaml
name: my-mcp-stack
mcp-servers:
  - name: api
    image: ghcr.io/me/api:latest
    env:
      REGION: ${var:REGION}              # public, plain in logs
      DB_PASSWORD: ${var:DB_PASSWORD}    # secret, redacted in logs
gateway:
  allowed_origins: ${var:CORS_ORIGINS}   # ← object expansion (PR 2): array unmarshaled directly
secrets:
  sets:
    - production
```

**Workflow** — list:
```
$ gridctl var list
╭────────────────┬────────┬────────────┬────────────╮
│ KEY            │ TYPE   │ VISIBILITY │ SET        │
├────────────────┼────────┼────────────┼────────────┤
│ REGION         │ string │ plaintext  │            │
│ CLUSTER_ID     │ string │ plaintext  │            │
│ DB_PASSWORD    │ string │ secret     │            │
│ CORS_ORIGINS   │ json   │ plaintext  │            │
│ DB_HOST        │ string │ plaintext  │ production │
╰────────────────┴────────┴────────────┴────────────╯
```

### Workflow Impact

- **Adds friction**: existing users must learn `--secret`/`--plaintext` flag (default = secret preserves Article XII secure-defaults; no migration needed for existing secrets — they auto-upgrade to `IsSecret=true`).
- **Reduces friction**: no more juggling `.env` files alongside vault. Stack YAMLs become committable. Logs become legible (non-secret values not masked).
- **Net win** for any user with more than one environment to deploy to.

### UX Recommendations

1. **Pulumi-idiom flags**: `--secret` (default), `--plaintext` (explicit opt-out). Do not use `--public`/`--private` (overpromises a visibility model gridctl doesn't have).
2. **Don't conflate `--type` with sensitivity** (AWS SSM cautionary lesson). Keep `--type {string,json,list,number,bool}` orthogonal to `--secret`/`--plaintext`.
3. **`var get`** auto-displays plaintext values plainly; secret values stay masked unless `--plain`. Small but real DX win.
4. **Companion `gridctl var doctor`** — scans project stack.yaml files, reports unresolved `${var:KEY}` references and stored-but-unreferenced keys. Highest leverage UX feature you can ship alongside this; Pulumi/TF/GH Actions all have variants.
5. **`gridctl var migrate-from-env`** — imports `.env` with per-key `--secret`/`--plaintext` prompt or `--all-secret` / `--all-plaintext` flag. Lowers onboarding cliff.
6. **`.env` round-trip** uses leading comment markers (`# @type=json`, `# @public`) to preserve metadata without breaking vanilla `.env` parsers.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Real MCP secret-leak incidents; industry-wide masking fatigue documented |
| User impact | Broad + Shallow | Every gridctl user touched; small per-session improvement |
| Strategic alignment | Core mission | Extends stack.yaml portability — central to gridctl's value prop |
| Market positioning | Catch up + slight leap | Parity with Toolhive's secrets coverage; small differentiation via unification + typed expansion |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Significant | Storage/CLI changes are trivial. yaml.Node tree walker (PR 2) is a meaningful rewrite of `expandStackVars`. Hard CLI rename touches every doc/example/test. |
| Effort estimate | Large | ~2 weeks of focused work for a flagship-quality release. PR 1: ~1 week. PR 2: ~1 week. |
| Risk level | Medium | Concentrated in PR 2's yaml.Node expander. Existing encryption-state corner cases (recent PRs #579/#577) mean storage format changes need care. Mitigated by two-PR sequencing. |
| Maintenance burden | Moderate | yaml.Node walker is *less* maintenance long-term than the field-by-field switch. Object expansion adds a real test matrix. |

## Recommendation

**Build with caveats.** This is a high-value, on-trend, architecturally healthy feature that aligns gridctl with the modern unified-store pattern proven by Pulumi ESC and GitHub Actions. The MCP-specific user pull is moderate (not screaming) but the broader IaC validation is overwhelming. Worth the ~2-week investment if framed as a flagship release.

**Three caveats baked into the implementation plan:**

1. **Sequence the build to land value early. Ship in two PRs:**
   - **PR 1 (foundation):** Rename `vault → var`, add `IsSecret`/`Type` fields with `--secret`/`--plaintext`/`--type` flags, filter `Values()` for redaction, update import/export round-trip. **No object expansion** — `${var:KEY}` still string-replace. This PR alone is shippable and delivers most user-visible value.
   - **PR 2 (object expansion):** Rewrite `expandStackVars` to yaml.Node tree walker. Add object/array unmarshal for `type=json|list`. Architectural lift isolated from PR 1's storage/CLI work.
   - Optional **PR 3 (UX polish):** `gridctl var doctor`, `gridctl var migrate-from-env`, JSON schema export.

2. **Add explicit schema versioning to the vault file in PR 1.** Current `storeData` has no version field — format detection is implicit. Add `"version": 2` to mark the new shape. Future migrations need it; PR #579 was almost a regression because of this gap.

3. **Soft-alias `${vault:KEY}` in stack YAML during beta** even though we hard-rename the CLI. Stack YAMLs are committed artifacts in user repos and every example file in this repo — they take longer to update than CLI muscle memory. Remove the YAML alias at v1.0. This is a pragmatic exception to the user's "no alias" decision and the only way to ship without breaking every user's existing stack the day they update.

## References

- [Terraform variables](https://developer.hashicorp.com/terraform/language/values/variables)
- [Terraform sensitive tutorial](https://developer.hashicorp.com/terraform/tutorials/configuration-language/sensitive-variables)
- [Pulumi config set CLI](https://www.pulumi.com/docs/cli/commands/pulumi_config_set/)
- [Pulumi ESC GA announcement (Sept 2024)](https://www.pulumi.com/blog/pulumi-esc-ga/)
- [Pulumi ESC interpolations syntax](https://www.pulumi.com/docs/esc/environments/syntax/interpolations-and-references)
- [GitHub Actions vars changelog (Jan 10 2023)](https://github.blog/changelog/2023-01-10-github-actions-support-for-configuration-variables-in-workflows/)
- [GitHub Actions vars + required workflows blog](https://github.blog/enterprise-software/devops/introducing-required-workflows-and-configuration-variables-to-github-actions/)
- [AWS SSM Parameter Store vs Secrets Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-vs-secrets-manager.html)
- [GCP Parameter Manager overview](https://docs.cloud.google.com/secret-manager/parameter-manager/docs/overview)
- [Doppler secret visibility](https://docs.doppler.com/docs/secret-visibility)
- [Vercel Sensitive variables](https://vercel.com/docs/environment-variables/sensitive-environment-variables)
- [Kubernetes Secrets docs](https://kubernetes.io/docs/concepts/configuration/secret/)
- [anthropics/claude-code#28942 — envFile request](https://github.com/anthropics/claude-code/issues/28942)
- [anthropics/claude-code#57131 — mcp remove leaked secrets](https://github.com/anthropics/claude-code/issues/57131)
- [Stacklok Toolhive secrets management](https://docs.stacklok.com/toolhive/guides-cli/secrets-management)
- [mcp-agent configuration reference](https://docs.mcp-agent.com/reference/configuration)
- [LogicWeave: mcp.json is the new .env](https://www.logicweave.ai/mcp-config-is-new-env/)
- [Helm multi-env best practices issue #5257](https://github.com/helm/helm/issues/5257)
- [Docker Compose env var precedence](https://docs.docker.com/compose/how-tos/environment-variables/envvars-precedence/)
