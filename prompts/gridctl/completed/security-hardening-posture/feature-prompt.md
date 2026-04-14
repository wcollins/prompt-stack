# Feature Implementation: Security Hardening Posture

## Context

Gridctl is an open source Go CLI tool (Apache 2.0) with a React/TypeScript frontend. It orchestrates container-based network stacks and exposes an MCP gateway. The project uses GitHub Actions for CI, GoReleaser for releases, golangci-lint for static analysis, and govulncheck for Go vulnerability scanning. The repository is at `github.com/wcollins/gridctl`.

**Tech stack:**
- Go 1.24, Cobra CLI framework
- React 19 + TypeScript frontend in `web/`
- GitHub Actions CI in `.github/workflows/`
- golangci-lint v2.11.3 configured in `.golangci.yml`
- GoReleaser in `.goreleaser.yaml`

The project has strong foundational governance (CONSTITUTION.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md) and a security-first architectural philosophy, but is missing formalized vulnerability disclosure and has some CI enforcement gaps.

## Evaluation Context

- Research showed that `SECURITY.md` + GitHub private vulnerability reporting is table stakes for mature Go open source projects (Helm, Cobra, goreleaser all use this pattern)
- govulncheck and npm audit currently run with `continue-on-error: true` — they produce no signal because failures are suppressed. This must be fixed for the tooling to serve any purpose
- gosec integrates directly into golangci-lint with zero additional tooling overhead
- Dependabot for Go modules is a native GitHub feature requiring only a config file
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/security-hardening-posture/feature-evaluation.md`

## Feature Description

Establish a complete, production-grade security posture: formalize vulnerability disclosure via `SECURITY.md` and GitHub's private reporting feature, enforce security vulnerability checks in CI (remove silent pass behavior), add security-focused static analysis (gosec), enable automated dependency vulnerability tracking (Dependabot), and strengthen the test policy statement in CONTRIBUTING.md.

## Requirements

### Functional Requirements

1. Create `SECURITY.md` at the repository root that:
   - Instructs reporters NOT to open public GitHub issues for security vulnerabilities
   - Directs reporters to GitHub's private vulnerability reporting (Security tab → "Report a vulnerability")
   - Commits to an initial response within 14 days
   - Briefly describes the fix and disclosure process (patch → advisory publication)
   - Is concise (under 80 lines)
   - Links to or references CONSTITUTION.md security articles for architectural commitments

2. Remove `continue-on-error: true` from the govulncheck step in `.github/workflows/gatekeeper.yaml` so that discovered Go vulnerabilities fail the build

3. Remove `continue-on-error: true` from the npm audit step in `.github/workflows/gatekeeper.yaml` so that high-severity npm vulnerabilities fail the build

4. Add `gosec` to the enabled linters list in `.golangci.yml`. Add any required exclusions for known-acceptable patterns (e.g. G304 for config file reads, G204 for intentional subprocess execution in a CLI tool)

5. Create `.github/dependabot.yml` that enables:
   - Go modules ecosystem scanning (directory: `/`)
   - npm ecosystem scanning (directory: `/web`)
   - Weekly update schedule for both
   - Conventional commit prefix format (`chore:`)

6. Update `CONTRIBUTING.md` to strengthen the testing requirements section — the policy statement should explicitly say that new functionality must include tests, not just new exported functions. Current text says "New exported functions must have tests"; update to make the policy unambiguous for any major new feature or behavior change.

7. Add a link to `SECURITY.md` in the `README.md` (alongside the existing license badge or in a relevant section).

### Non-Functional Requirements

- `SECURITY.md` must be discoverable: GitHub surfaces it automatically in the Security tab when placed at the repo root or in `.github/`; root is preferred
- No changes to the gridctl binary or its behavior
- No new external CI tooling dependencies — all changes use existing tools or native GitHub features
- Dependabot PR titles must follow the project's conventional commits format so cliff.toml changelog generation handles them correctly

### Out of Scope

- Artifact signing (cosign/sigstore) — evaluated as a separate future improvement
- SBOM generation — future scope
- CodeQL configuration — govulncheck + gosec covers the immediate gap; CodeQL can be added later
- Go fuzzing test implementation — separate feature requiring deep per-function analysis
- Changing the vulnerability response SLA below 14 days — keep it achievable for a solo maintainer

## Architecture Guidance

### Recommended Approach

Implement in this order to manage risk:

1. **SECURITY.md + README link** — pure documentation, zero risk, immediately visible
2. **Dependabot config** — new file, no CI changes, starts passively scanning
3. **gosec in golangci-lint** — run `golangci-lint run` locally first to see if existing code produces warnings; add exclusions as needed before committing
4. **Remove `continue-on-error`** — do this last, after verifying govulncheck and npm audit currently produce no blocking findings. If they do, fix those findings first, then remove the flag

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `.github/workflows/gatekeeper.yaml` | Main CI pipeline; govulncheck (line 49-53) and npm audit (line 162-163) are the two steps to harden |
| `.golangci.yml` | Linter config; gosec goes in the `linters.enable` list alongside `errcheck`, `govet`, etc. |
| `CONTRIBUTING.md` | Testing requirements section (lines 97-108) needs the policy strengthened |
| `CONSTITUTION.md` | Articles XII-XIII contain security principles; SECURITY.md should reference these |
| `README.md` | Add security policy link, likely near the existing badges at the top |
| `.goreleaser.yaml` | Read-only for context — release pipeline, no changes needed |

### Integration Points

**`.github/workflows/gatekeeper.yaml`** — two edits:

```yaml
# Line 50: Remove this line
continue-on-error: true

# Line 162: Remove this line
continue-on-error: true
```

**`.golangci.yml`** — add gosec to the linters list:
```yaml
linters:
  enable:
    - errcheck
    - govet
    - ineffassign
    - staticcheck
    - unused
    - gosec  # add this

linters-settings:
  gosec:
    excludes:
      - G304  # File path provided as taint input — acceptable for CLI config file reads
      - G204  # Subprocess launched with variable — acceptable for CLI tools that exec containers
```

**`.github/dependabot.yml`** — new file:
```yaml
version: 2
updates:
  - package-ecosystem: gomod
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: "chore"

  - package-ecosystem: npm
    directory: /web
    schedule:
      interval: weekly
    commit-message:
      prefix: "chore"
```

### Reusable Components

- CONSTITUTION.md Articles XII-XIII — quote or reference these in SECURITY.md rather than restating principles
- Existing issue template structure in `.github/ISSUE_TEMPLATE/` — SECURITY.md should explicitly say "do NOT use issue templates for vulnerabilities"
- `cliff.toml` — verify `chore` commit type is in the changelog config so Dependabot PRs generate clean changelog entries

## UX Specification

**SECURITY.md structure:**
1. Short intro (1-2 sentences): what this file is and when to use it
2. "Reporting a Vulnerability" section: private reporting link, what to include in a report
3. "Response Timeline" section: initial acknowledgment ≤14 days, fix timeline (best effort)
4. "Disclosure Policy" section: patch first, then GitHub Security Advisory publication
5. "Security Design" section: 2-3 sentences referencing the CONSTITUTION's security principles and linking to it

Keep the tone direct and professional — match the style of CONTRIBUTING.md.

**Dependabot PRs** will appear as `chore: bump <package> from x.y.z to a.b.c` in conventional commits format. The PR checklist in `.github/pull_request_template.md` already covers "no secrets/credentials" and "tests pass" — Dependabot PRs need minimal review for patch/minor bumps.

## Implementation Notes

### Conventions to Follow

- All new files use the same header style as existing docs (no emojis unless matching the file's existing style — CONTRIBUTING uses emoji headers; SECURITY.md should be plain and professional like the LICENSE)
- No `Co-Authored-By` trailers in commits
- Commit message format: `docs: add security policy and vulnerability disclosure process`
- Branch naming: `docs/security-hardening-posture`

### Potential Pitfalls

1. **gosec false positives on subprocess execution**: gridctl is a CLI tool that deliberately exec's Docker/Podman processes. gosec G204 (subprocess with variable args) will fire on legitimate code. Add the exclusion before the first CI run.

2. **govulncheck may find current vulnerabilities**: Before removing `continue-on-error: true`, run `govulncheck ./...` locally. If it finds anything, update affected dependencies first. Check: `go get -u <module>@latest && go mod tidy`.

3. **npm audit may find current vulnerabilities**: Run `npm audit --audit-level=high` in `web/` before removing `continue-on-error`. If findings exist, run `npm audit fix` or manually upgrade the affected packages.

4. **Dependabot and cliff.toml**: Confirm that `chore` type commits appear in the CHANGELOG. If cliff.toml excludes `chore` commits, either update the config or use a different prefix for Dependabot.

### Suggested Build Order

1. Create `SECURITY.md` + add README link → commit as `docs: add security policy and vulnerability disclosure process`
2. Create `.github/dependabot.yml` → commit as `chore: enable dependabot for go and npm dependencies`
3. Run govulncheck and npm audit locally, fix any findings → commit as `chore: resolve flagged dependency vulnerabilities` (if needed)
4. Add gosec to `.golangci.yml`, run lint locally, add exclusions → commit as `chore: add gosec security linter`
5. Remove `continue-on-error` from both CI steps → commit as `chore: enforce govulncheck and npm audit in CI`
6. Update CONTRIBUTING.md test policy wording → commit as `docs: clarify test policy for new functionality`

## Acceptance Criteria

1. `SECURITY.md` exists at the repository root and is surfaced in GitHub's Security tab
2. `SECURITY.md` contains a private reporting link, a ≤14 day response commitment, and a disclosure policy
3. `README.md` links to `SECURITY.md`
4. `.github/dependabot.yml` exists and configures weekly scans for both Go modules and npm
5. `.golangci.yml` includes `gosec` in the enabled linters list
6. The gatekeeper CI workflow passes with govulncheck running without `continue-on-error`
7. The gatekeeper CI workflow passes with npm audit running without `continue-on-error`
8. `CONTRIBUTING.md` test policy explicitly states that new functionality (not just new exported functions) requires tests
9. All CI checks pass on a PR containing these changes

## References

- [GitHub: Adding a Security Policy](https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository)
- [GitHub: Private Vulnerability Reporting](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)
- [gosec: Go Security Checker](https://github.com/securego/gosec)
- [golangci-lint linter configuration](https://golangci-lint.run/docs/configuration/)
- [Dependabot configuration options](https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/configuration-options-for-the-dependabot.yml-file)
- [Cobra SECURITY.md (reference example)](https://github.com/spf13/cobra/blob/main/SECURITY.md)
- [govulncheck documentation](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)
