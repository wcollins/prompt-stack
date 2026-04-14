# Feature Evaluation: Security Hardening Posture

**Date**: 2026-03-28
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

Gridctl has strong foundational security practices (Apache 2.0 license, golangci-lint, govulncheck, GPG-signed commits, no-secrets policy) but is missing a formal vulnerability disclosure process and several CI enforcement gaps. Adding a `SECURITY.md`, enabling GitHub's private vulnerability reporting, and tightening CI tooling brings the project's stated security-first values into visible, verifiable practice.

## The Idea

Establish a complete, production-grade security posture for an open source Go CLI tool: formalize vulnerability disclosure, enforce static security analysis in CI, and introduce automated dependency vulnerability tracking. This closes gaps between what the project's CONSTITUTION mandates philosophically and what is actually enforced or documented.

## Project Context

### Current State

Gridctl is a mature open source Go CLI tool (Apache 2.0) with a React/TypeScript frontend. It has a robust CI/CD pipeline via GitHub Actions (lint, test with race detection, coverage thresholds, integration tests for both Docker and Podman runtimes). The project has a CONSTITUTION.md with 15 immutable architectural articles — including explicit security-first principles — and detailed CONTRIBUTING.md, CODE_OF_CONDUCT.md, and well-structured issue/PR templates.

Security tooling in CI:
- `golangci-lint` v2.11.3 with `errcheck`, `govet`, `staticcheck`, `ineffassign`, `unused`
- `govulncheck` (transitive Go vulnerability detection) — but runs with `continue-on-error: true`
- `npm audit --audit-level=high` — also runs with `continue-on-error: true`

No `SECURITY.md` exists at the project root. Private vulnerability reporting is undocumented. There is no gosec integration. No Dependabot or Renovate configuration exists.

### Integration Surface

| File | Change Type | Notes |
|------|-------------|-------|
| `SECURITY.md` | Create | New file at repository root |
| `.github/workflows/gatekeeper.yaml` | Modify | Remove `continue-on-error: true` from govulncheck and npm audit; optionally add govulncheck as a blocking step |
| `.golangci.yml` | Modify | Add `gosec` linter with appropriate exclusions |
| `.github/dependabot.yml` | Create | Enable automated dependency scanning for Go modules and npm |
| `CONTRIBUTING.md` | Modify | Strengthen test policy statement to explicitly reference new functionality |
| `CHANGELOG.md` | Modify | Add convention for security fix entries |

### Reusable Components

- Existing CI job structure in `gatekeeper.yaml` — govulncheck step already present, just needs `continue-on-error` removed
- Existing `.golangci.yml` linter config — gosec slots in as an additional linter
- CONSTITUTION.md Article XII-XIII (security principles) — SECURITY.md should reference these to maintain consistency with existing governance docs

## Market Analysis

### Competitive Landscape

Major Go CLI tools and libraries have converged on a standard security posture:
- **Helm, Cobra, goreleaser**: All have `SECURITY.md` with GitHub private vulnerability reporting as the primary intake channel
- **Kubernetes**: Full security committee with tiered response SLAs, public advisories via GitHub Security Advisories
- **Terraform**: Private reporting + 90-day coordinated disclosure window
- **Standard pattern**: Do not open public issues for vulnerabilities → private report → patch → GitHub Security Advisory publication

### Market Positioning

`SECURITY.md` + private vulnerability reporting is **table stakes** for mature open source projects in the Go/cloud-native ecosystem. Its absence is a visible gap to security-conscious contributors and enterprise users evaluating the project.

gosec and Dependabot are differentiators at the small project scale but expected by the time a project reaches production use.

### Ecosystem Support

- **gosec**: First-class golangci-lint integration, zero additional tooling required
- **GitHub Private Vulnerability Reporting**: Native GitHub feature, no third-party tooling
- **Dependabot**: Native GitHub feature, configured via `.github/dependabot.yml`
- **govulncheck**: Already installed, just needs enforcement strengthened

### Demand Signals

Security-first defaults are increasingly demanded by enterprise users of CLI tooling. CONSTITUTION Article XII already commits to this direction — the codebase governance anticipates it. Formalizing the disclosure process prevents future ambiguity when a vulnerability is actually discovered.

## User Experience

### Interaction Model

**Security researchers**: The primary new interaction. They visit the repository, see `SECURITY.md` in the root, follow the private reporting link to GitHub Security Advisories. No new tooling required.

**Contributors**: See `gosec` lint errors if they accidentally introduce common vulnerability patterns (hardcoded creds, weak random, unsafe file ops). Dependabot generates automated PRs for dependency updates that contributors review normally.

**Maintainer (William)**: Receives private vulnerability reports via GitHub's advisory system. govulncheck and npm audit now block CI on medium+ severity findings instead of silently passing.

### Workflow Impact

- **Reduced friction** for responsible disclosure: researchers have a clear, private path
- **Slightly increased friction** for CI: govulncheck and npm audit will now fail builds when vulnerabilities are found (currently they silently pass with `continue-on-error: true`). This is correct behavior but means existing vulnerable dependencies (if any) must be resolved before enabling enforcement
- **Negligible friction** for contributors: gosec warnings are rare in well-written Go; new exclusions can be added for acceptable patterns

### UX Recommendations

1. Keep `SECURITY.md` concise — under 80 lines. Verbose security docs are skipped.
2. Link `SECURITY.md` from `README.md` and `CONTRIBUTING.md` for discoverability
3. Before removing `continue-on-error` from govulncheck, run it once manually to confirm there are no current blocking findings
4. When adding gosec, run locally first and add any required exclusions to `.golangci.yml` before committing

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Missing vuln disclosure process is a real operational gap; enforcement gaps let vulnerabilities pass CI silently |
| User impact | Broad+Shallow | Affects all contributors and security researchers; most won't use it but its absence is conspicuous |
| Strategic alignment | Core mission | CONSTITUTION Articles XII-XIII mandate security-first; this implements what the governance already commits to |
| Market positioning | Catch up | Table stakes for mature open source; absence is a visible gap to enterprise evaluators |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | New SECURITY.md file, ~5 CI config line changes, small linter config addition |
| Effort estimate | Small | 4-6 files changed, no architectural changes, no binary behavior changes |
| Risk level | Low | No changes to the gridctl binary; CI tightening is reversible |
| Maintenance burden | Minimal | SECURITY.md rarely needs updating; Dependabot runs automatically; gosec exclusions are stable |

## Recommendation

**Build.** The gaps are small and the changes are low-risk. The most critical change is creating `SECURITY.md` with GitHub private vulnerability reporting — this is a single file that closes a MUST-have gap for any serious open source project. The CI enforcement changes (removing `continue-on-error`) are equally important: silently passing govulncheck defeats its purpose. gosec and Dependabot round out the posture with minimal ongoing maintenance cost.

Suggested order: SECURITY.md first (highest visible impact, zero risk), then CI enforcement (verify no current blocking issues), then gosec + Dependabot.

## References

- [GitHub: Adding a Security Policy](https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository)
- [GitHub: Private Vulnerability Reporting](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)
- [gosec: Go Security Checker](https://github.com/securego/gosec)
- [golangci-lint linter list](https://golangci-lint.run/docs/linters/)
- [Cobra SECURITY.md example](https://github.com/spf13/cobra/blob/main/SECURITY.md)
- [Dependabot: Go modules support](https://docs.github.com/en/code-security/dependabot/ecosystems-supported-by-dependabot/supported-ecosystems-and-repositories)
- [OpenSSF Best Practices Badge criteria](https://www.bestpractices.dev/en/criteria/0)
- [Go native fuzzing guide](https://go.dev/doc/security/fuzz/)
