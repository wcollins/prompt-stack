# Feature Implementation: Config Format Migration (INI → YAML)

## Context

`ipctl` is a Go CLI for managing Itential Platform servers (cobra + viper, ~30k LOC, 35+ resource handlers). The architecture is layered: CLI → Handler → Runner → Resource → Service → Client, with handlers/runners discovered via interfaces (`Reader`, `Writer`, `Copier`, etc.) and YAML descriptors at `internal/cli/descriptors/*.yaml` providing command metadata.

Configuration is loaded via `internal/config/loader.go` using a fluent builder pattern. Multi-format support (INI, YAML, TOML, JSON) was added in commit `0480670`, but **INI is still the default** — this is the problem we're fixing. Profile and repository sections currently use Viper top-level keys with spaces (`"profile default"`, `"repository origin"`) because they were modeled on INI section names. The codebase abstracts config consumption behind a `Provider` interface (`internal/config/interfaces.go`), so handlers/runners are unaffected by format changes.

**Tech stack**: Go 1.25, cobra 1.10, viper 1.19 (target: 1.21), `gopkg.in/yaml.v2` (direct), `gopkg.in/yaml.v3` (indirect via viper), `gopkg.in/ini.v1` (indirect via viper), zerolog 1.34, testify 1.11. Tests use plain `testing` package + testify assertions; no mocking framework. Build via `make build`; tests via `make test` (runs `go fmt`, `go vet`, then unit tests via `scripts/test.sh unittest`).

## Evaluation Context

This is the implementation of **Package M** as scoped in `feature-evaluation.md`. Key decisions baked into this prompt:

- **YAML default, with backward-compat for INI** via `github.com/go-viper/encoding/ini` (the official extracted codec). Viper itself recommends this path in its `UPGRADE.md`. ~10 lines to register.
- **Defer schema flattening** (`profile default:` → `profiles: { default: {...} }`) to a follow-up `schemaVersion: 2` PR. Add `schemaVersion: 1` now as a versioning hook. Rationale: doing two breaking changes at once concentrates user disruption; the space-key shape is functional, just stylistically awkward.
- **`ipctl config migrate` and `ipctl config validate` ship in this PR.** Without `migrate`, existing INI users would have to hand-rewrite their configs — a real activation tax. The codebase has no other tools that read both INI and YAML, so this is genuinely new ground.
- **`ipctl config init` is out of scope** — orthogonal UX feature, not a migration concern.
- **Sequencing**: this PR ships first; PR #193 (Viper bump to 1.21.0) rebases on it.
- **Deprecation timeline**: warn for two minor releases or 6 months (whichever is longer), remove INI in next major. Communicate the removal version inside the warning string so users see it inline.
- Full evaluation: `prompts/ipctl/config-yaml-migration/feature-evaluation.md`.

## Feature Description

Migrate ipctl's primary configuration file format from INI to YAML. Existing INI configs continue to work during a deprecation window via a registered external codec, with a stderr warning that names the removal version and the remediation command. Ship `ipctl config migrate` (INI → YAML, side-by-side by default) and `ipctl config validate` (structured parser-error reporting) so users have a clean upgrade path. Update all six documentation surfaces in the same PR. Add a `schemaVersion: 1` field as a hook for the future schema flattening.

This unblocks the Viper 1.21.0 dependency bump (PR #193) and aligns ipctl with the Go CLI ecosystem (kubectl, helm, gh, goreleaser all use YAML).

## Requirements

### Functional Requirements

1. **Default format is YAML.** `loader.go:261` (`v.SetConfigType("ini")`) becomes `v.SetConfigType("yaml")`. `detectConfigType` (`loader.go:296`) defaults to `"yaml"` for unknown/missing extensions.

2. **External INI codec is registered on every viper instance.** Import `github.com/go-viper/encoding/ini` and register on the new `CodecRegistry` API (`viper.NewWithOptions(viper.WithCodecRegistry(reg))`). Pattern from Viper's `UPGRADE.md`. Existing INI files at `~/.platform.d/config[.ini]` continue to parse correctly.

3. **Content sniffing for files without extension.** When the config path has no extension, peek at the first non-blank character of the file to determine format: `[` → `ini`, `{` → `json`, otherwise attempt `yaml` (which gracefully handles many `key: value` shapes). Existing users with `~/.platform.d/config` (no extension, INI content) must continue to work unchanged.

4. **INI deprecation warning.** When the loader determines the file is INI (by extension or content sniffing), emit exactly one stderr warning per process. Format:
   ```
   warning: INI config format is deprecated and will be removed in v<NEXT_MAJOR>.
            Migrate with: ipctl config migrate
            Docs: https://github.com/itential/ipctl/blob/main/docs/config-migration.md
   ```
   Suppressible via `IPCTL_SUPPRESS_DEPRECATIONS=1` env var or `--quiet` flag. Do NOT use `logging.Warn()` for this — it goes through the structured logger and may be silenced by log-level config; use direct `fmt.Fprintln(os.Stderr, ...)`.

5. **`ipctl config migrate` command.** Subcommand under a new `config` parent.
   - **Default behavior**: read source config, write `<source-stem>.yaml` next to it, leave source untouched.
   - **`--in-place`**: rewrites the source file in place. Always creates `<source>.bak.<unix-timestamp>` first.
   - **`--dry-run`**: prints the YAML that would be written to stdout, exits 0, makes no filesystem changes.
   - **`--from <path>`** and **`--to <path>`**: explicit source/destination paths.
   - Refuses to overwrite an existing destination unless `--force`.
   - Prints to stderr: `note: comments and blank lines from the source file are not preserved` *before* writing, every time.
   - Implementation: load INI via `gopkg.in/ini.v1` (already an indirect dep) → walk sections/keys into `map[string]any` → marshal via `gopkg.in/yaml.v3`. Emit `schemaVersion: 1` as the first key. Preserve the INI section-key-with-space shape for now (`"profile default":`) — schema flattening is a separate PR.

6. **`ipctl config validate` command.** Subcommand under `config`.
   - Loads the config (same path resolution as a normal run).
   - On success: prints `<path>: ok (format: <yaml|ini|toml|json>, schemaVersion: <n>)` and exits 0.
   - On failure: wraps the parser error with file path, line/column when available (yaml.v3 errors include this), the offending line excerpt (read the file fresh and emit the line), and a hint matched to the top three failure modes (tab characters, unquoted special characters at start of value, indentation mismatch). Exit non-zero.

7. **`schemaVersion` field is read-only support.** Loader reads `schemaVersion` (top-level int, default `1` if absent). Stored on `Config` for future use. No behavior depends on the value yet — this is a versioning hook for the next migration. Validation: if `schemaVersion` is not `1`, error with `unsupported schemaVersion: <n>; this version of ipctl supports schemaVersion 1`.

8. **Codec parity snapshot test.** A test that loads a representative INI fixture (the one currently in `loader_test.go:169-200`) through the registered external codec and asserts the resulting `viper.AllSettings()` output matches a snapshot. The snapshot is captured *before* this PR's loader changes (i.e., from Viper 1.19's built-in behavior). Goal: prove the external codec is behaviorally equivalent for our schema.

9. **Documentation updated in the same PR.** All of the following surfaces:
   - `README.md` (lines 33, 61) — quick-start uses YAML; format paragraph leads with YAML.
   - `docs/configuration-reference.md` — table reorders so YAML leads; "Default Format" label moves from INI to YAML; INI section explicitly labeled "Legacy / Deprecated"; add a "Migration" section linking to the new `docs/config-migration.md`.
   - `docs/working-with-repositories.md` — INI examples become YAML.
   - `docs/logging-reference.md` — INI examples become YAML.
   - `internal/config/doc.go` — reorder format examples (YAML first); update prose.
   - `internal/cli/doc.go:33` — reference unchanged (path stays the same).
   - **New**: `docs/config-migration.md` — short doc explaining the deprecation, the `migrate` command, and the sunset timeline. The deprecation warning links here.

10. **Test fixtures updated.** `loader_test.go` currently uses INI fixtures for `TestLoaderLoadWithConfigFile`, `TestLoaderLoadWithProfileFlag`, `TestLoaderLoadWithEnvVars`, `TestConfigLoadingIsThreadSafe`. After this PR, these tests should use **YAML fixtures** (with `.yaml` extension), and **new** parallel tests should be added with INI fixtures (with `.ini` extension) to exercise the deprecation-codec path. Don't delete the INI tests — copy them into INI-named-and-extensioned versions and convert the originals to YAML.

### Non-Functional Requirements

- **Backwards compatibility**: existing users with `~/.platform.d/config` (no extension, INI content) experience no functional change beyond the deprecation warning.
- **Performance**: codec registration adds <1ms per `Load()` call. No measurable impact.
- **Error messages**: at parse-fail, surface the parser's line/column when available, the offending line excerpt, and a brief hint. Don't pass raw library errors through unwrapped.
- **Concurrency**: existing `TestConfigLoadingIsThreadSafe` (`loader_test.go:483`) must continue to pass. Codec registry should be created per-loader (not global) to preserve isolation.
- **Logging**: Migration runner uses the existing `logging` package for informational output during `migrate` execution, but the deprecation warning itself is direct stderr (see Functional Requirement 4).
- **Security**: `migrate --in-place` must preserve the source file's mode bits (commonly `0600`) on the new file. Use `os.Stat` + `os.Chmod` after write.

### Out of Scope

- **Schema flattening** to nested `profiles:` / `repositories:` (defer to `schemaVersion: 2` PR).
- **`ipctl config init`** (interactive scaffolder).
- **`ipctl config show`** (active path / format / schema version).
- **Comment preservation** in `migrate`. INI → Viper → YAML loses comments; honestly disclosed, not engineered around.
- **Removing INI support entirely** — deprecation warning only, no removal in this PR.
- **Updating PR #193**. This PR ships first; #193 rebases on it.
- **AWS-style separation** of credential-bearing fields from non-secret config.

## Architecture Guidance

### Recommended Approach

Follow the existing layered architecture. The migration adds:
- **One handler** (`internal/handlers/config.go`) implementing `Reader`-style interfaces for `Migrate` and `Validate`.
- **One runner** (`internal/runners/config.go`) with `Migrate(*Request) (*Response, error)` and `Validate(*Request) (*Response, error)` methods.
- **One descriptor** (`internal/cli/descriptors/config.yaml`) with parent + subcommand metadata.
- **One pure-logic module** (`internal/config/migrate.go`) with `func MigrateINIToYAML(src io.Reader) ([]byte, error)`. Keep this independent of the runner/handler layers so it's unit-testable in isolation.
- **Loader changes** localized to `internal/config/loader.go` — codec registration in `loadConfigFile`, content sniffing in or alongside `detectConfigType`, deprecation warning emission in a new `warnIfDeprecated(format string)` helper.

The flag-parsing scaffold for `--in-place`, `--dry-run`, `--from`, `--to`, `--force`, `--quiet` lives in a new `internal/flags/config.go` following the existing flag-package convention.

### Key Files to Understand

| File | Why it matters |
|------|----------------|
| `internal/config/loader.go` | Core loading logic. `detectConfigType` (296), `loadConfigFile` (235), profile/repo section parsing (365, 411). The codec registration goes in `loadConfigFile` before `v.ReadInConfig()`. |
| `internal/config/loader_test.go` | 1,107-line comprehensive test suite. Read fixtures used by `TestLoaderLoadWithConfigFile` (169), `TestLoaderLoadWithYAMLConfigFile` (789), `TestLoaderLoadWithTOMLConfigFile` (871). Pattern for new tests. |
| `internal/config/doc.go` | Package-level documentation with format examples. Reorder to YAML-first. Note line 34: "If no extension is provided, INI format is used for backward compatibility" — this assertion changes. |
| `internal/config/config.go` | `Config` struct (28). Add `SchemaVersion int` field. `NewConfig` factory (52) keeps current backward-compat shape. |
| `internal/config/interfaces.go` | `Provider`, `ProfileProvider`, `RepositoryProvider`. Don't add migration concerns to these — keep them config-consumer-focused. |
| `internal/handlers/handlers.go` | `NewHandler` (35-handler factory). Register the new `ConfigHandler` here. |
| `internal/handlers/registry.go` | Interface-based discovery. The new handler registers via the same pattern as existing handlers. |
| `internal/handlers/runner.go` | `CommandRunner` orchestrates flag parsing + runner dispatch. The config handler returns simple text responses; existing patterns apply. |
| `internal/runners/base.go` | `BaseRunner` with shared functionality. The new `ConfigRunner` embeds this. |
| `internal/cli/descriptors/asset.yaml` | Example descriptor. Reference for writing `config.yaml`. |
| `internal/cli/root.go` | Entry point. The new `config` command tree gets added via the existing `loadCommands` flow — no edits needed if the handler registers correctly. |
| `internal/handlers/descriptors.go` | YAML-loading pattern for descriptors via `//go:embed`. Reference if you need to embed any new YAML. |
| `internal/cmdutils/cmdutils.go` | `LoadDescriptor` shows the standard YAML unmarshal pattern (yaml.v2 in the existing code). |
| `internal/utils/encoding.go` | `UnmarshalData` is INI-naïve but shows the JSON-first/YAML-fallback idiom. Don't reuse — this function has the known "calls fatal" issue (CLAUDE.md flagged it). |
| `internal/profile/profile.go`, `internal/repository/repository.go` | Format-agnostic. No changes needed — verify by reading. |
| `internal/flags/` (any existing file) | Flag-package convention. Pattern for `internal/flags/config.go`. |
| `README.md` | Lines 33 and 61 need updating. |
| `docs/configuration-reference.md` | "Supported Configuration Formats" table at line 27 — reorder. |
| `docs/working-with-repositories.md`, `docs/logging-reference.md` | INI examples to convert. |

### Integration Points

- **`Loader.loadConfigFile`** (`loader.go:235`): inject codec registration before `v.ReadInConfig()`. Pattern from Viper UPGRADE.md:
  ```go
  reg := viper.NewCodecRegistry()
  reg.RegisterCodec("ini", ini.Codec{})
  // pass reg to viper.NewWithOptions when creating v in Load()
  ```
  Note: `Load()` currently does `v := viper.New()` at `loader.go:144`. That changes to use `viper.NewWithOptions(viper.WithCodecRegistry(reg))`. Once the bump to Viper 1.21 lands (in PR #193), this is *required*; for now (still on Viper 1.19), Viper's old API is forward-compatible — the `NewCodecRegistry` API exists in 1.19 too.
- **`Loader.detectConfigType`** (`loader.go:296`): change default from `"ini"` to `"yaml"`. Add a sibling `sniffConfigType(filePath string) string` for the no-extension case that reads the first non-blank char.
- **`Config` struct** (`config.go:28`): add `SchemaVersion int` field.
- **`Loader.buildConfig`** (`loader.go:315`): read `v.GetInt("schemaVersion")` (default 1 if absent), validate, store on Config.
- **Handler registration**: `internal/handlers/handlers.go` `NewHandler` factory adds `NewConfigHandler(...)` call. Follow the existing pattern of the 35 handlers verbatim.

### Reusable Components

- **`gopkg.in/ini.v1`** (already an indirect dep) — read INI in the migrate module.
- **`gopkg.in/yaml.v3`** (already an indirect dep via Viper) — write YAML in the migrate module. Use v3, not v2, for YAML 1.2 compliance (avoids Norway Problem). Add as a direct dep.
- **`github.com/go-viper/encoding/ini`** — new direct dep, registered codec.
- **`internal/handlers/descriptors.go`** — YAML-loading pattern reference (uses yaml.v2 — that's fine for descriptors; don't change it).
- **Existing `--config` flag and IPCTL_CONFIG env binding** in `loader.go:170-200` — reused as-is for the migrate command's source.

## UX Specification

### Discovery

- **Existing INI users**: discover the deprecation via stderr warning on every command run after upgrade (until they migrate).
- **New users**: discover YAML as the default via the README and `docs/configuration-reference.md`.
- **All users**: discover `ipctl config migrate` and `ipctl config validate` via `ipctl config --help` and the deprecation warning's remediation line.

### Activation

- `ipctl config migrate --dry-run` previews the migration.
- `ipctl config migrate` writes `config.yaml` side-by-side, leaves original untouched.
- User updates any explicit `--config` references or environment vars to point at the new file (or relies on Viper's default search path picking up the `.yaml` automatically — make sure standard search path matches `config*` not `config.ini`).
- Optionally deletes the old file when comfortable.

### Interaction

- **Migration**: single-shot, idempotent, reversible (the side-by-side default leaves the source intact).
- **Validation**: read-only; safe to run anytime.

### Feedback

- **Deprecation warning**: stderr, named removal version, exact remediation command, docs link. Once per process. Suppressible via env var or flag.
- **Migration**: stderr "note: comments not preserved..." before writing; final stdout line confirms output path: `wrote /Users/foo/.platform.d/config.yaml (schemaVersion: 1)`.
- **Validation success**: `<path>: ok (format: yaml, schemaVersion: 1)`.
- **Validation failure**: `<path>: error: <wrapped error with line/column/excerpt/hint>`. Exit code 1.

### Error States

- `migrate` with destination already exists: error, suggest `--force` or `--to <other-path>`.
- `migrate` with unparseable source: error, point at `validate`.
- `validate` with unparseable source: structured error per Functional Requirement 6.
- `validate` with valid file but unsupported `schemaVersion`: clear error naming the supported versions.
- Loader with unparseable INI (after codec registration): falls through to the existing `viper.ReadInConfig` error path; message wraps with file path.

## Implementation Notes

### Conventions to Follow

- **No `logging.Fatal` in library code** (CLAUDE.md). Return errors. The deprecation warning is direct stderr (not via logging).
- **Errors wrap with `fmt.Errorf("...: %w", err)`** — established pattern throughout the codebase.
- **Tests use plain `testing` + `testify/assert`**. No mocking framework. Fixtures inline as strings (existing `loader_test.go` pattern) when small, `testdata/` when larger.
- **File naming**: `<resource>.go` for impl, `<resource>_test.go` for tests, `descriptors/<resource>.yaml` for descriptors, `templates/<resource>.tmpl` if needed.
- **Function naming**: `New<Type>(...)` factories. `New<Resource>Handler`, `New<Resource>Runner` for the registration pair.
- **No comments unless they explain *why* something non-obvious is happening.** This is a CLAUDE.md emphasis. Most of the code in this PR will not need comments.
- **Commit format**: `<type>: <subject>` (imperative, ≤50 chars, no period). Sign commits (`-S`). No Claude/AI mentions in commits, branches, or PR descriptions. (User CLAUDE.md.)

### Potential Pitfalls

- **The `loadProfiles` / `loadRepositories` parsers** at `loader.go:365` and `:411` iterate `v.AllSettings()` looking for keys starting with `"profile "` and `"repository "`. **Don't change these in this PR.** YAML's `profile default:` shape preserves these flat-keys-with-spaces, which is exactly what we want for now. The schema-v2 PR will refactor these — keep this PR's diff focused.

- **Content sniffing edge cases**: a YAML file that legitimately starts with `[` (a flow-style sequence) would be misclassified as INI. Mitigation: only treat `[` as INI when followed by an identifier-like character before `]` on the same line. Empty files: default to YAML.

- **The loader currently silently ignores missing config files** (`loader.go:278`). Preserve this — the deprecation warning should only fire when an INI file is actually loaded, never when none is found.

- **Codec registry ordering**: register BEFORE calling `v.ReadInConfig()`, AFTER `viper.NewWithOptions` constructs the viper instance. Easy to get backward; existing tests will catch it.

- **`yaml.v2` vs `yaml.v3`**: existing code uses `yaml.v2` for descriptors. Use `yaml.v3` for the new migration code (better error messages, YAML 1.2 compliance). Both can coexist — they're separate modules.

- **Don't introduce `ipctl config show` / `init` accidentally** — this PR is scoped to `migrate` + `validate` only. If the descriptor pattern makes it tempting to scaffold the parent `config` command with all four subcommands, resist — leave hooks but don't ship empty subcommands.

- **`detectConfigType` returning `"yaml"` as default** changes behavior for files with unrecognized extensions. Audit any tests that depended on the old INI default and update accordingly.

- **`gopkg.in/yaml.v2` is currently a direct dep** but rarely used directly outside descriptors. The new code uses `yaml.v3`. Keep `yaml.v2` in `go.mod` (descriptors still need it) and add `yaml.v3` as direct.

- **`migrate --in-place` mode bits**: the source file is commonly `0600` (chmod'd by user per docs). Preserve it on the destination. Test this explicitly — easy to miss.

- **Descriptor wiring**: `internal/handlers/descriptors.go` embeds `internal/cli/descriptors/*.yaml` via `//go:embed`. New `config.yaml` descriptor must be picked up by the embed pattern — verify the pattern is `*.yaml` not an explicit list.

- **Profile validation tests** (`loader_test.go:427`, `:454`) check that profile/repo names with spaces are rejected. These tests use INI fixtures (`[profile my profile]`). After conversion, the YAML equivalent (`profile my profile:`) is still a parseable YAML key — but `loadProfiles` should still reject it via the existing `len(parts) > 2` check. Verify the equivalent YAML test still passes the same logic.

### Suggested Build Order

1. **Add `gopkg.in/yaml.v3` and `github.com/go-viper/encoding/ini` to go.mod** (direct deps). Run `go mod tidy`.
2. **Loader: register the INI codec** in `loadConfigFile`. No behavior change yet — just defensive setup. Run existing tests; all should pass on Viper 1.19.
3. **Loader: flip `detectConfigType` default to `"yaml"`** and update the comment block. Run tests; some will fail (the no-extension/INI-content tests).
4. **Loader: add content sniffing** for no-extension files. Re-run tests; should pass again.
5. **Loader: add deprecation warning emission** with suppression flags. New unit test for the warning + suppression.
6. **Loader: read `schemaVersion` field** with default 1; validate; store on `Config`. Add unit tests for schemaVersion absent, present-and-1, present-and-other.
7. **`internal/config/migrate.go`**: pure function `MigrateINIToYAML`. Unit tests for: simple key/value, sections, profiles with space-keys, repositories, comment loss, mode-bit preservation (test the file-write wrapper separately).
8. **Flag definitions** in `internal/flags/config.go`.
9. **Runner** `internal/runners/config.go` with `Migrate` and `Validate`. Unit tests with fixtures.
10. **Handler** `internal/handlers/config.go` and registration in `internal/handlers/handlers.go`.
11. **Descriptor** `internal/cli/descriptors/config.yaml`.
12. **Convert existing loader tests**: copy INI tests to `*_INI` variants with `.ini` extension; convert originals to YAML fixtures. Add codec parity snapshot test.
13. **Documentation**: README, configuration-reference.md, working-with-repositories.md, logging-reference.md, internal/config/doc.go. Create new `docs/config-migration.md`.
14. **Manual smoke test**: build, run `ipctl config migrate --dry-run` against a known INI fixture, run `ipctl config validate` against good and bad files, verify deprecation warning fires for INI and is suppressed when expected.
15. **`make test`** clean, `golangci-lint` clean (the `licenses` step in CI runs `make test` first — no different from local).
16. **PR description** mentions PR #193 and the rebase plan.

## Acceptance Criteria

1. `make test` passes locally and in CI (no `decoder not found` errors when a config is loaded).
2. The default config type, when no extension is present and content sniffing matches none of `[`, `{`, or YAML-shape, is `yaml`.
3. An existing INI file at `~/.platform.d/config` (no extension) loads successfully and produces an identical `Config` struct as it did with Viper 1.19's built-in INI codec (verified via the codec parity snapshot test).
4. Loading an INI file emits exactly one stderr line beginning `warning: INI config format is deprecated` per process.
5. The warning is suppressed when `IPCTL_SUPPRESS_DEPRECATIONS=1` is set or `--quiet` is passed.
6. `ipctl config migrate --dry-run` against a known INI fixture prints valid YAML to stdout and writes nothing to disk.
7. `ipctl config migrate` against a known INI source writes `<source-stem>.yaml` next to the source, preserves the source unchanged, and the resulting YAML loads to a `Config` equivalent to the source's load (verified via integration test).
8. `ipctl config migrate --in-place` rewrites the source, creates `<source>.bak.<unix-timestamp>`, and preserves the source's mode bits on both files.
9. `ipctl config validate` against a good file exits 0 with `ok (format: yaml, schemaVersion: 1)`.
10. `ipctl config validate` against a bad file exits non-zero with structured error containing path, line/column, offending excerpt, and a hint.
11. Loading a config with `schemaVersion: 2` (unsupported) returns `unsupported schemaVersion: 2; this version of ipctl supports schemaVersion 1`.
12. README (lines 33, 61), `docs/configuration-reference.md`, `docs/working-with-repositories.md`, `docs/logging-reference.md`, and `internal/config/doc.go` lead with YAML examples; INI examples are labeled deprecated.
13. New `docs/config-migration.md` exists and is linked from the deprecation warning.
14. `TestConfigLoadingIsThreadSafe` passes — codec registry isolation per loader.
15. `golangci-lint run` is clean.
16. PR #193 (Viper 1.21.0 bump) rebases on this PR with no manual conflict resolution beyond the obvious version bumps in `go.mod` / `go.sum` / `vendor/`.

## References

- [Viper UPGRADE.md — codec registration recipe](https://github.com/spf13/viper/blob/master/UPGRADE.md)
- [github.com/go-viper/encoding](https://github.com/go-viper/encoding) — INI codec source
- [Viper v1.20.0 release notes](https://github.com/spf13/viper/releases/tag/v1.20.0)
- [gopkg.in/ini.v1 (go-ini/ini)](https://github.com/go-ini/ini)
- [gopkg.in/yaml.v3](https://github.com/go-yaml/yaml/tree/v3)
- [The Norway Problem — why YAML v3 (1.2-compliant) over v2](https://hitchdev.com/strictyaml/why/implicit-typing-removed/)
- [Kubernetes deprecation policy — warning + named removal version pattern](https://kubernetes.io/docs/reference/using-api/deprecation-policy/)
- [buf migrate — schema versioning precedent](https://buf.build/docs/migration-guides/)
- [GitHub CLI config layout — `~/.config/gh/config.yml`](https://cli.github.com/manual/gh_config)
- [Cobra docs — `$HOME/.cobra.yaml` default](https://cobra.dev/)
- ipctl CLAUDE.md — architecture, conventions, common pitfalls
- Full evaluation: `prompts/ipctl/config-yaml-migration/feature-evaluation.md`
