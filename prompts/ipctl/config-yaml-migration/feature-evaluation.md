# Feature Evaluation: Config Format Migration (INI → YAML)

**Date**: 2026-04-28
**Project**: ipctl
**Recommendation**: Build with caveats — Package M (see below)
**Value**: Medium-High
**Effort**: Medium

## Summary

Migrate ipctl's primary configuration file format from INI to YAML, register the external `github.com/go-viper/encoding/ini` codec to keep existing INI files readable during a deprecation window, ship `ipctl config migrate` and `ipctl config validate` commands, and update all documentation. This unblocks the Viper 1.21.0 dependency bump (PR #193) and brings ipctl in line with every comparable Go CLI on format choice. Defer the YAML schema flattening (`profile default:` → `profiles: { default: {...} }`) to a follow-up under `schemaVersion: 2`.

## The Idea

ipctl currently defaults to INI for its config file at `~/.platform.d/config`. Viper 1.20.0 dropped the built-in INI codec (extracted to `github.com/go-viper/encoding/ini`), so PR #193 — the dependabot bump from Viper 1.19.0 → 1.21.0 — currently fails three loader tests with `decoder not found for this format`. Every future Viper bump re-creates this problem unless resolved.

This feature flips the default to YAML, registers the external INI codec to preserve backward compat, ships migration tooling so existing users have a clean upgrade path, and standardizes ipctl on the format used by kubectl, helm, gh, goreleaser, and the rest of the modern Go CLI ecosystem.

**Who benefits**:
- **All ipctl users**: better doc consistency (the Itential platform repo is already YAML-heavy), familiar format, expressive config (multi-line values, lists).
- **Existing INI users**: a clean migration path with a deprecation window, not a hard cut.
- **Maintainers**: drops a structural drag on dependency hygiene; future Viper bumps don't bring this back.

## Project Context

### Current State

- ipctl is built on cobra + viper with a clean `Provider` interface (`internal/config/interfaces.go`) abstracting config from handlers/runners.
- The loader at `internal/config/loader.go` already supports YAML/TOML/JSON — multi-format support landed in commit `0480670`. INI is the *default*, not the only format.
- A YAML test fixture exists in `loader_test.go:789-869` and exercises the full path successfully.
- `gopkg.in/yaml.v2` is already a direct dependency; `gopkg.in/yaml.v3` is indirect via Viper.
- No `ipctl config init` or `ipctl config migrate` command exists today. First-time users hand-edit from the README.
- No automated INI→YAML conversion utility today.

### Integration Surface

**Code (must change)**:
- `internal/config/loader.go:261` — `v.SetConfigType("ini")` default
- `internal/config/loader.go:296-312` — `detectConfigType` defaults to `"ini"` for unknown/missing extensions
- `internal/config/loader.go:235-283` — `loadConfigFile` (codec registration goes here)
- `internal/config/loader_test.go` — test fixtures use INI; need YAML-default test fixtures and a YAML-extension scenario for the no-extension default file (`~/.platform.d/config`)

**Code (new)**:
- `internal/config/migrate.go` — INI→YAML conversion logic (~30 LOC core)
- `internal/runners/config.go` (new) — runner for `config migrate` and `config validate`
- `internal/handlers/config.go` (new) — handler stub registering both subcommands
- `internal/cli/descriptors/config.yaml` (new) — descriptor metadata for the `config` command

**Code (untouched but verified)**:
- `internal/profile/`, `internal/repository/` — format-agnostic, no changes needed
- `internal/handlers/`, `internal/runners/` — consume `config.Provider`, unaffected
- `pkg/client/` — unaffected

**Docs (must update in same PR)**:
- `README.md:33` — quick-start currently shows TOML
- `README.md:61` — mentions "INI, YAML, TOML, and JSON formats"
- `docs/configuration-reference.md` — "Default Format" label is on INI; reorder so YAML leads
- `docs/working-with-repositories.md:27+` — uses INI examples
- `docs/logging-reference.md:46-313` — multiple INI examples
- `internal/config/doc.go` — "INI Format Example" section is first; reorder
- `internal/cli/doc.go:33` — references `~/.platform.d/config`
- `internal/cmdutils/doc.go:146` — same path reference

### Reusable Components

- **YAML loading pattern**: `internal/handlers/descriptors.go` already loads embedded YAML via `//go:embed` + `gopkg.in/yaml.v2`. Same pattern can scaffold any new YAML reads we need.
- **Format-detection scaffolding**: `detectConfigType` in `loader.go:296` — extend to do content sniffing instead of just extension matching.
- **Embedded format-conversion idiom**: `internal/utils/encoding.go:UnmarshalData` does JSON-first/YAML-fallback unmarshaling. Pattern reference for the migrate command.
- **`Provider` interface**: zero-impact migration possible because handlers/runners only see the abstract `Provider`.
- **Descriptor + Handler + Runner pattern**: the codebase has 35+ examples to follow for adding the new `config` subcommand tree.

## Market Analysis

### Competitive Landscape

Of 10 comparable Go CLIs surveyed:

| Tool | Format | Notes |
|------|--------|-------|
| kubectl | YAML | `~/.kube/config` since inception |
| helm | YAML | `repositories.yaml`, `values.yaml` |
| gh (GitHub CLI) | YAML | `~/.config/gh/config.yml` |
| golangci-lint | YAML (4 supported) | YAML is documented default |
| goreleaser | YAML | `.goreleaser.yaml` |
| kustomize | YAML | `kustomization.yaml` |
| buf | YAML | `buf.yaml`, with `version:` schema field |
| Task | YAML | `Taskfile.yml` |
| Terraform / OpenTofu | HCL | HashiCorp's homegrown format |
| Docker | JSON | `~/.docker/config.json` (predates YAML-CLI norm) |

**None use INI.** YAML is decisively the modern default. INI's remaining strongholds in the broader ecosystem (AWS CLI, Git, systemd) are pre-2015 designs locked in by SDK ubiquity — none of which apply to ipctl.

### Market Positioning

**Catch up.** Migration brings ipctl to parity with comparable tools, not differentiation. The "differentiator" framing doesn't apply to config formats — users notice when a tool is *worse* than convention, rarely when it's better.

### Ecosystem Support

- **`github.com/go-viper/encoding/ini`** — official Viper-org codec. Thin wrapper around `gopkg.in/ini.v1` (already an indirect dep). Drop-in behavior with the old built-in. Last meaningful change Feb 2025; minimal surface area.
- **`gopkg.in/ini.v1`** — actively maintained as of April 2026 (`v1.67.1` released 2026-01-10). Despite stale "EOL" claims floating around, the repo is not archived and ships fixes.
- **`gopkg.in/yaml.v3`** — YAML 1.2-compliant; avoids the "Norway Problem" that bit YAML 1.1 parsers. Already in the dep graph.
- **Viper UPGRADE.md** publishes the codec-registration recipe verbatim — ~10 lines.

### Demand Signals

Real and recent. Viper issues #2009, #2018, #2092, #2104 are all users hitting the same `decoder not found` breakage 8+ months after Viper 1.20's release. ipctl's users will encounter identical confusion if INI is dropped without a deprecation path.

### Format-Deprecation Precedent

- **Kubernetes deprecation policy** (gold-standard): deprecated thing keeps working for a defined period, must emit warnings when used.
- **buf**: `buf migrate` for v1beta1 → v1 → v2 inside YAML, with top-level `version:` field.
- **Task**: 4-year deprecation window for v2 schema (introduced 2018, deprecated 2023, removed Dec 2023).
- **Hugo**: soft `config.toml` → `hugo.toml` rename; both still work years later.

The dominant pattern: **keep reading the old format, warn loudly with a removal version, default scaffolding to the new format, ship a one-shot conversion subcommand, sunset on a published timeline.**

## User Experience

### Interaction Model

**New user**: reads README, copies a YAML quick-start, fills in host/credentials, runs a command. Friction is YAML indent traps and unquoted special characters.

**Existing INI user** (highest stakes — file holds production credentials):
1. Upgrades ipctl to a version with the deprecation
2. Runs a command, sees a stderr warning naming the removal version + the exact remediation command (`ipctl config migrate`)
3. Runs `ipctl config migrate --dry-run` to preview
4. Runs `ipctl config migrate` — generates `config.yaml` side-by-side, leaves original `config` untouched
5. Verifies behavior is unchanged with the new file
6. Optionally deletes the old file when ready

**Existing YAML user** (group-3, post-`0480670`): no change today. Eventually receives a follow-up `schemaVersion: 2` migration in a separate PR.

### Workflow Impact

- **New users**: friction *reduced* (YAML is more familiar than INI for the modern audience).
- **Existing INI users**: one-time activation tax (running `migrate`) in exchange for clean future maintenance. Side-by-side output makes the migration zero-risk.
- **CI scripts**: any pinned to `--config ~/.platform.d/config` (no extension) keep working as long as content sniffing is implemented; explicit `--config ~/.platform.d/config.ini` continues to work via the registered codec.

### UX Recommendations

1. **Deprecation warning** — stderr, once per process, suppressible via `IPCTL_SUPPRESS_DEPRECATIONS=1` and `--quiet`. Always include: what's deprecated, named removal version, exact remediation command, docs link.

2. **`ipctl config migrate`** — side-by-side default; `--in-place` flag with `.bak.<timestamp>`; `--dry-run` prints diff; `--from`/`--to` for non-default locations; honest disclosure that comments are not preserved.

3. **`ipctl config validate`** — wraps parser errors with file path, line/column, offending excerpt, hints for top failure modes (tabs, unquoted specials, indent mismatch).

4. **Content-sniffing format detection** — for files without extension, sniff the first non-blank character to disambiguate (`{` → JSON, `[` → INI, else attempt YAML). Don't break existing `~/.platform.d/config` users on the default flip.

5. **Sunset timeline** — deprecate in next minor; warn for **two minor releases or 6 months, whichever is longer**; remove INI support in next major. Communicate the removal version *in the warning string itself*.

6. **Keep `ipctl config init` out of scope** — it's a valuable feature but a separate UX improvement, not a migration concern. Track as a follow-up.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Blocks PR #193; recurring tax on every Viper bump until resolved |
| User impact | Broad+Shallow | Every user touches config; per-user impact is low for new users, moderate one-time tax for existing INI users |
| Strategic alignment | Core mission-adjacent | Aligns with Itential platform's YAML conventions; eliminates dependency-hygiene drag |
| Market positioning | Catch up | Brings parity with kubectl/helm/gh/goreleaser; not differentiation |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Adds new `config` subcommand tree following the existing 35-handler pattern; loader changes are localized |
| Effort estimate | Medium | ~600-900 LOC including tests and doc updates; ~3-5 days of focused work |
| Risk level | Low-Medium | External INI codec drift (mitigable with snapshot tests); content sniffing must be correct; comment-loss disclosure must be done well |
| Maintenance burden | Moderate | Migrate/validate commands need long-term care; deprecation warning must be removed when INI support is dropped |

## Recommendation

**Build — Package M (recommended scope).**

### What Package M includes

1. **Default flip**: `loader.go:261` `"ini"` → `"yaml"`; `detectConfigType` defaults to `"yaml"` for unknown extensions.
2. **Content sniffing**: for files with no extension, sniff first non-blank char to disambiguate INI/JSON/YAML.
3. **External INI codec registration**: import `github.com/go-viper/encoding/ini` and register on every viper instance.
4. **Snapshot test for codec parity**: verify the external codec produces equivalent `viper.AllSettings()` output as Viper 1.19's built-in for representative INI fixtures.
5. **Deprecation warning**: emitted to stderr once per process when an INI file is loaded; names the removal version; includes `ipctl config migrate` as the remediation; suppressible via `IPCTL_SUPPRESS_DEPRECATIONS=1` and `--quiet`.
6. **`ipctl config migrate`**: INI→YAML conversion. Side-by-side default, `--in-place` with `.bak.<timestamp>`, `--dry-run`. Discloses comment loss.
7. **`ipctl config validate`**: parses and surfaces structured errors with line/column/excerpt and hints.
8. **`schemaVersion: 1` field**: read-only support added now (default 1 if absent), so the future v2 schema flattening has a versioning hook ready.
9. **Doc updates**: README, configuration-reference.md, working-with-repositories.md, logging-reference.md, internal/config/doc.go, internal/cli/doc.go — all in the same PR.
10. **Goes first; PR #193 rebases on it.**

### What Package M leaves out

- **Schema flattening** to nested `profiles: { default: {...} }` / `repositories: { ... }`. Track as `schemaVersion: 2` follow-up. Rationale: doing both at once concentrates user disruption; the space-key shape is awkward but functional.
- **`ipctl config init`** (interactive scaffolder). Valuable, but a UX improvement orthogonal to the migration. Track separately.
- **`ipctl config show`**. Same — orthogonal UX feature.
- **AWS-style separation of credential-bearing fields from non-secret config**. Long-term consideration.

### Why not S (minimal)

S unblocks PR #193 but leaves existing INI users with no migration tool. Without `migrate`, every Itential operator with an INI config has to copy the README and re-key their config — a real activation tax that produces support questions. M is the smallest scope that handles existing users gracefully.

### Why not L (one decisive cut)

L bundles the schema flattening into the same change. Two issues: (1) the space-key shape is functional, just stylistically awkward — not a forcing function; (2) two breaking changes in one PR concentrates disruption on existing users, especially the group-3 cohort who already migrated to YAML once. Defer to a follow-up where it can land on a calmer baseline. Adding `schemaVersion: 1` now keeps the door open at near-zero cost.

### Sequencing relative to PR #193

This work ships first as its own PR. Once merged, PR #193 rebases trivially (it becomes a pure dependency bump with no functional impact on the loader). Rationale: keeping the dependency bump separate from the format migration makes each easier to review and revert if needed.

## References

- [Viper v1.20.0 release notes — INI/HCL/properties dropped from core](https://github.com/spf13/viper/releases/tag/v1.20.0)
- [Viper PR #1869 / #1870 — encoding layer rewrite](https://github.com/spf13/viper/pull/1869)
- [Viper UPGRADE.md — codec registration recipe](https://github.com/spf13/viper/blob/master/UPGRADE.md)
- [github.com/go-viper/encoding](https://github.com/go-viper/encoding)
- [gopkg.in/ini.v1 (go-ini/ini)](https://github.com/go-ini/ini)
- [Viper issue #2009 — ini decoder not registered by default](https://github.com/spf13/viper/issues/2009)
- [Viper issue #2092 — outdated documentation for INI/HCL/Java Properties](https://github.com/spf13/viper/issues/2092)
- [Viper PR #2104 — remove dropped formats from SupportedExts](https://github.com/spf13/viper/pull/2104)
- [Kubernetes deprecation policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/)
- [buf migrate](https://buf.build/docs/migration-guides/)
- [Task v2 schema deprecation](https://taskfile.dev/docs/deprecations/version-2-schema)
- [The Norway Problem (StrictYAML)](https://hitchdev.com/strictyaml/why/implicit-typing-removed/)
- [Cobra docs — `$HOME/.cobra.yaml` default](https://cobra.dev/)
- [GitHub CLI config — `~/.config/gh/config.yml`](https://cli.github.com/manual/gh_config)
