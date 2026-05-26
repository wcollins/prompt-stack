# Feature Implementation: Unified Variable Store — `gridctl var` (PR 1)

## Context

gridctl is a Go CLI that orchestrates MCP (Model Context Protocol) server stacks declared in `stack.yaml` files. It runs MCP servers in containers, has a local encrypted vault for secrets, and supports variable interpolation in stack files via `${vault:KEY}` syntax.

**Tech stack**: Go (1.22+), Cobra CLI, `gopkg.in/yaml.v3`, XChaCha20-Poly1305 + Argon2id for vault encryption, `slog` for structured logging, `go-pretty/v6` for table output, `viper`-style config patterns (light use). Web UI in `web/` is React 18 + TypeScript + Vite + Tailwind + Zustand, tested with Vitest.

**Project posture**: pre-1.0 (currently v0.1.0-beta.9) with a written Constitution (`CONSTITUTION.md`) that governs all changes. Articles VIII (semver) and IX (stack.yaml BC), XII (secure defaults), XV (changelog discipline) are directly relevant. Test-to-code ratios in affected packages are 1.5:1+; tests are expected, not optional.

**Working directory**: `/Users/william/code/gridctl`

## Evaluation Context

This is **PR 1 of a planned 2-PR (optionally 3-PR) build** that transforms `gridctl vault` into a unified configuration store. The evaluation that shaped this prompt:

- **Market validation**: GitHub Actions added `vars.*` in Jan 2023 specifically because users were misusing `secrets.*` for non-sensitive config like AWS_REGION. Pulumi ESC (GA Sept 2024) is the closest architectural twin. The unified-store + per-value-sensitivity-flag pattern won the IaC space.
- **Flag idiom decision**: `--secret` (default) + `--plaintext` (opt-out) mirrors Pulumi (the closest IaC-orchestration analog) and respects Article XII (secure defaults). Do NOT use `--public`/`--private` (overpromises a visibility model gridctl doesn't have). Do NOT conflate `--type` with sensitivity (AWS SSM cautionary lesson).
- **Naming decision**: hard rename `vault` → `var` at the CLI level. The user explicitly chose "no CLI alias." However: stack YAML `${vault:KEY}` is parsed-but-warned in beta — every example, doc, and user's existing stack file references it, so a hard YAML break in the same release would be hostile. This soft YAML alias is removed at v1.0.
- **Scope cut**: PR 1 stores `Type` metadata (validation only). PR 2 — a separate, follow-up effort — rewrites `expandStackVars` to a `yaml.Node` tree walker so `type=json`/`type=list` values unmarshal directly into YAML mapping/sequence fields. **Do not attempt object expansion in PR 1.** `${var:KEY}` stays string-replace in this PR even for `type=json` (the JSON-encoded string is interpolated literally).
- **Risk mitigation**: add explicit `"version": 2` schema versioning to the on-disk vault file in this PR. Current format detection is implicit (try new format → fall back to flat array) which is a latent risk that nearly caused a regression in PR #579.

Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/unified-variable-store/feature-evaluation.md`

## Feature Description

Transform `gridctl vault` into `gridctl var` — a unified store that holds both secrets and non-sensitive variables with type metadata. The same store backs `${var:KEY}` references in stack.yaml. Secrets are encrypted-at-rest (existing XChaCha20-Poly1305 + Argon2id flow) and redacted in logs; plaintext variables are visible and not redacted.

**What problem this solves:**
1. **Portability**: users can put environment-specific non-sensitive values (REGION, CLUSTER_ID, account IDs) in the var store and check stack.yaml into git unchanged.
2. **DX consolidation**: one tool for all stateful config, ending the `.env`-vs-vault split.
3. **End of masking fatigue**: only true secrets are redacted in logs; non-secret values stay legible.

**Who benefits**: every gridctl user with a stack.yaml. Pervasive but shallow per-session.

## Requirements

### Functional Requirements

1. **Rename command tree**: introduce `gridctl var` as the new top-level command with these subcommands matching the current `gridctl vault` surface: `set`, `get`, `list`, `delete`, `import`, `export`, `lock`, `unlock`, `change-passphrase`, `sets {list,create,delete}`.

2. **Deprecate `gridctl vault`**: `gridctl vault <anything>` must continue to work for the remainder of the beta cycle, with a one-time-per-session WARN log: `"gridctl vault" is deprecated and will be removed at v1.0. Use "gridctl var" instead.` Use a once-per-process flag (`sync.Once`) — not per-invocation spam. Aliasing strategy: implement once as a thin redirector that hands args to the `var` command tree.

3. **Add `--secret` / `--plaintext` flags to `var set`**:
   - Default behavior: variable stored with `IsSecret=true` (Article XII secure default).
   - `--plaintext` flag stores with `IsSecret=false`.
   - `--secret` flag is accepted but redundant (explicit secure-default). Both flags MUST NOT be passed together — return an error.
   - Both flags omitted → secret by default.

4. **Add `--type` flag to `var set`**: accepts `string` (default), `json`, `list`, `number`, `bool`.
   - **`string`**: no validation beyond non-empty.
   - **`json`**: value must parse as valid JSON via `encoding/json.Unmarshal` into `any`. Stored as-is (the original string), with `Type=json` metadata. PR 1 does not change expansion — the JSON string is still interpolated as-is.
   - **`list`**: comma-separated input is accepted; stored as a JSON-encoded array of strings. (User experience: `gridctl var set TAGS a,b,c --type list` stores `["a","b","c"]`.) `Type=list` metadata recorded.
   - **`number`**: validated by `strconv.ParseFloat`. Stored as the original input string.
   - **`bool`**: validated by `strconv.ParseBool`. Stored as the original input string.
   - Validation errors fail the command with a clear message naming the type and the offending input.
   - `--type` is orthogonal to `--secret`/`--plaintext`.

5. **`var get KEY` display rules**:
   - Variable is secret AND `--plain` flag absent → masked output (existing `maskValue()`).
   - Variable is plaintext OR `--plain` flag present → unmasked output.
   - Show TYPE in the human output line: `KEY = <value-or-mask>  (type: json, secret)`.

6. **`var list` columns**: rename header to `Key | Type | Visibility | Set`. Visibility values: `secret` or `plaintext`. Type values: `string`/`json`/`list`/`number`/`bool`. Maintain existing `--format json` machine-readable output (Article X); JSON output is an array of `{key, type, visibility, set}` — never include `value`.

7. **`var import`** must support new metadata:
   - **`.env` flavor**: a leading comment line of the form `# @type=json` and/or `# @public` (== `IsSecret=false`) immediately preceding a `KEY=VALUE` line applies that metadata. Lines without leading metadata default to `string`/secret. Existing `.env` files import losslessly into secrets with `type=string`.
   - **JSON flavor**: accept either the legacy `{"KEY": "value"}` map (everything imports as secret/string) OR the new `{"variables": [{"key", "value", "type", "is_secret", "set"}]}` shape.

8. **`var export`** must round-trip new metadata:
   - **`.env --plain`**: write `# @type=...` and `# @public` markers as needed.
   - **JSON**: write the new `{"variables": [...]}` shape (NOT the legacy map).
   - Both formats must still respect the existing `--plain` masking flag.

9. **Storage format with explicit versioning**:
   - The on-disk `storeData` (in plaintext `secrets.json` and inside the encrypted blob) gains a `"version": 2` field.
   - On load, if the file matches the new shape (object with `"version"` and `"variables"`), parse as v2. If it matches the existing object shape (`"secrets"` and `"sets"`), parse as v1 and migrate in-memory (every entry gets `IsSecret=true`, `Type="string"`). If it matches the legacy flat array, parse as v0 and migrate.
   - On every save, write v2.
   - The struct should be renamed from `Secret` to `Variable` with the new fields, but the JSON field name on disk continues to use a `"variables"` array key (was `"secrets"` in v1 — note this is a rename in the on-disk shape too, gated by version).

10. **Redaction filtering**: `Store.Values()` (currently returns all values for `RegisterRedactValues`) must filter to only return values where `IsSecret==true`. This is the single integration point that ends masking fatigue.

11. **`${var:KEY}` syntax in stack YAML**:
    - Accept `${var:KEY}` as the canonical form. Both `${var:KEY}` and `${vault:KEY}` resolve through the same lookup.
    - `${vault:KEY}` emits a one-time-per-process WARN log: `"${vault:KEY}" syntax is deprecated, use "${var:KEY}". Removal at v1.0.`
    - Update `pkg/config/expand.go::expandRegex` to accept either prefix in the `(vault|var)` capture group.

12. **API endpoints** (`internal/api/vault.go`):
    - Rename routes to `/api/var/*`. Keep `/api/vault/*` as a thin redirect to `/api/var/*` with the same deprecation header (`Sunset: 2026-12-31` or similar — match existing project convention if there is one).
    - Request/response payloads gain `type` and `is_secret` fields. Old payloads (just `key`/`value`) default to `is_secret=true`, `type="string"`.

13. **Web UI** (`web/src/`):

    **API client** (`web/src/lib/api.ts`):
    - Rename `VaultSecret` interface → `Variable`. Add fields: `type: 'string'|'json'|'list'|'number'|'bool'` and `is_secret: boolean`. Also add `set?: string` if not already present.
    - Rename functions to match new endpoints: `fetchVaultSecrets` → `fetchVariables` (calls `/api/var`), `createVaultSecret` → `createVariable` (gains `type` and `isSecret` params), `updateVaultSecret` → `updateVariable` (can update value/type/isSecret), `getVaultSecret` → `getVariable` (return shape gains `type`/`is_secret`), `deleteVaultSecret` → `deleteVariable`, `fetchVaultSets` → `fetchVariableSets`, etc.
    - The legacy function names are NOT preserved as JS aliases — TypeScript will flag every callsite, which is what we want for the hard rename.
    - `VaultStatus` interface: rename `secrets_count` → `variables_count`. Keep field `locked`/`encrypted` semantics.
    - Type fields on `Variable` payload match Go JSON tags exactly (`is_secret`, `type`, `key`, `value`, `set`).

    **Main panel** (`web/src/components/vault/VaultPanel.tsx`):
    - Rename header label from "Vault" to "Variables". Update empty-state copy and CLI hint (`gridctl vault set` → `gridctl var set`).
    - Add **Type** indicator next to each variable's key (small badge: `string` / `json` / `list` / `number` / `bool`). For `string` (the common case), the badge MAY be omitted to reduce noise — designer's call, but be consistent.
    - Add **Visibility** indicator (lock icon for secret, eye icon for plaintext) next to each variable. Plaintext rows show value unmasked by default; secret rows show bullets unless revealed.
    - Reveal/mask gating: change `revealed[key]` logic so plaintext variables (`is_secret === false`) display value directly without needing to click Reveal. The 10-second auto-hide timer applies only to secrets.
    - Quick-add form: add a **Type** selector (segmented control or dropdown) and a **Secret / Plaintext** toggle. Defaults: `string` + `Secret` (Article XII). For `type=list`, the input accepts comma-separated values. For `type=json`, render an inline validation hint when the input doesn't parse.
    - Edit form: same two new controls (Type + Secret/Plaintext toggle), pre-populated from current value.

    **Detached window** (`web/src/pages/DetachedVaultPage.tsx`):
    - This file is a near-duplicate of `VaultPanel.tsx`. Before changing either, extract the shared item-row and add/edit form into a small set of components in `web/src/components/vault/` (e.g., `VariableItem.tsx`, `VariableForm.tsx`) and have both `VaultPanel.tsx` and `DetachedVaultPage.tsx` import them. Without this dedupe, every change has to be made twice and will drift.
    - After dedupe, apply the same field/label changes here.
    - Rename file to `DetachedVariablesPage.tsx` if you do the route rename below (otherwise leave the filename).

    **Wizard popover** (`web/src/components/wizard/SecretsPopover.tsx`):
    - Rename component to `VariablesPopover.tsx` (and its test file). Update the button title from `Insert vault secret` to `Insert variable`.
    - The popover should surface BOTH secrets and plaintext variables (it's a unified store). Show the visibility indicator inline so the user can tell which kind they're inserting.
    - Emit `${var:KEY}` (not `${vault:KEY}`) in the generated reference string. This is the canonical form going forward.
    - Create-new form gains the same Type selector + Secret/Plaintext toggle as the main panel.

    **YAML builder** (`web/src/lib/yaml-builder.ts`):
    - Update the comment example at line 28 from `${vault:GIT_TOKEN}` to `${var:GIT_TOKEN}`. No code changes — the field stores any reference string opaquely.

    **Window manager / UI store** (`web/src/hooks/useWindowManager.ts`, `web/src/stores/useUIStore.ts`):
    - `DetachableWindow` union type: change `'vault'` → `'var'`. Update `WINDOW_TITLES['var']` to `'Gridctl - Variables'`. Update the window-name string `'gridctl-vault'` → `'gridctl-var'`.
    - In `useUIStore.ts`: rename `vaultDetached` → `varDetached`, `showVault` → `showVariables`. If these keys are persisted in localStorage, add a one-time migration that copies the old key value to the new key on first load (don't strand users with a closed panel post-update).
    - Route in router: `/vault` → `/var`. Add a redirect from `/vault` to `/var` (the React Router equivalent of the API redirect). The redirect runs once and is silent (no toast — that would be UI spam).

    **Routes** (`web/src/routes.tsx`):
    - Replace the `/vault` route with `/var` pointing to `DetachedVariablesPage`. Add a redirect route `/vault` → `/var`.

    **Tests**:
    - `web/src/__tests__/SecretsPopover.test.tsx`: rename to `VariablesPopover.test.tsx`. Update mock API responses to include `type: 'string'` and `is_secret: true` on every variable. Update the expected emitted string from `${vault:API_TOKEN}` to `${var:API_TOKEN}`. Update the button-title selector.
    - Add a new test asserting the popover surfaces a plaintext variable AND a secret variable, and that the visibility indicators differ.
    - Add a `VaultPanel.test.tsx` (or `VariablesPanel.test.tsx`) covering: plaintext variable renders unmasked by default; secret variable renders bullets; clicking Reveal on a secret shows the value; the Type and Secret/Plaintext toggles in the add form work and post the right payload.

    **Copy / labels not to miss** (do a final pass after the structural changes):
    - Command palette entries (`web/src/components/palette/CommandPalette.tsx`, `web/src/hooks/useGlobalCommands.tsx`) — any `Vault` labels.
    - The wizard step that prompts for credentials/secrets — update label copy.
    - Header / window title bars.
    - Error/empty/loading states for vault status calls.

### Non-Functional Requirements

- **Backward compatibility**: every v0/v1 vault file (plaintext or encrypted) must load successfully and behave equivalently (Article IX scope is stack.yaml; we extend the spirit to vault file format).
- **Security**: Article XII — `IsSecret=true` is the default for every code path that creates a `Variable` (CLI, API, import). Test this explicitly.
- **Test coverage**: match existing 1.5:1+ test-to-code ratio. Required tests are enumerated in Acceptance Criteria.
- **Logging**: Article XIV — use `slog`. All new structured log fields must have meaningful names.
- **Performance**: no measurable regression in `gridctl apply` cold-load time (vault load is already fast; this only adds metadata fields).
- **No new top-level dependencies** unless strictly necessary (Article II). The existing toolset (yaml.v3, cobra, go-pretty) covers everything.

### Out of Scope (explicitly for this PR)

- **Object expansion**: `${var:JSON_VAR}` resolving directly into a YAML mapping/sequence field. This is PR 2.
- **`gridctl var doctor`**: scans stack files for unresolved refs / unused vars. This is PR 3 (optional polish).
- **`gridctl var migrate-from-env`**: opinionated bulk `.env` importer with per-key sensitivity prompts. PR 3.
- **JSON Schema export** for IDE linting of `${var:KEY}` references. PR 3.
- **Multiple vaults / environments scoped above sets**: the current `Set` field is the only grouping. Pulumi-ESC-style environments are far-future.
- **External vault backends** (1Password, HashiCorp Vault, AWS Secrets Manager). Not in this PR.

## Architecture Guidance

### Recommended Approach

Keep the architecture close to today's — the existing layering is good. The only structural change is the on-disk schema bump:

1. **`pkg/vault/`** — rename `Secret` struct to `Variable` with new fields; add `version` to `storeData`; teach `parseSecretsData()` to handle v0 (flat array), v1 (current object shape), and v2 (new). Filter `Values()` by `IsSecret`. Everything else stays the same.

2. **`cmd/gridctl/`** — create `var.go` as the new command tree; refactor `vault.go` to a thin deprecation wrapper that delegates. Do not copy-paste — extract the shared run functions into helpers callable from both command trees, but `vault.go` only needs to wire commands; the *implementation* lives behind `var`.

3. **`pkg/config/expand.go`** — extend the regex to accept either `vault` or `var` prefix; log deprecation when `vault` matched. No structural change.

4. **`internal/api/`** — add the new `/api/var/*` routes; redirect `/api/vault/*`.

5. **`web/src/`** — hard rename of vault → var at the route/window/store level; rename `VaultSecret` interface to `Variable` and add Type + Secret/Plaintext UI affordances; dedupe `DetachedVaultPage.tsx` against `VaultPanel.tsx` before touching either (they're near-duplicates and will drift otherwise). UI matches CLI hard-rename — no in-UI alias, but a silent `/vault` → `/var` route redirect for bookmarks.

### Key Files to Understand

Read these in order before writing code:

- `pkg/vault/types.go` — the entire data model fits on one screen. Understand `Secret`, `storeData`, `EncryptedVault`.
- `pkg/vault/store.go` — focus on `Load()`, `parseSecretsData()`, `Save()`, `Values()`. Note the atomic write pattern (temp file + rename) and the mtime/size reload gate (PR #577).
- `pkg/vault/store_test.go` — your test pattern reference. New tests follow this style.
- `cmd/gridctl/vault.go` — the entire existing CLI surface. New `var` command tree mirrors this structure.
- `pkg/config/expand.go` — single regex, single function. Trivial extension point.
- `pkg/config/loader.go` lines 60–82 — where `VaultResolver` is wired into stack loading. Touch lightly.
- `pkg/logging/redact.go` — read but do not modify; understand that `RegisterRedactValues()` is fed by `Store.Values()` and that's where filtering lives.
- `internal/api/vault.go` — handler patterns for the new `/api/var/*` routes.
- `web/src/lib/api.ts` lines 575–644 — the entire vault API client surface. Mirror the rename + new fields here.
- `web/src/components/vault/VaultPanel.tsx` — the main UI panel (~950 lines). Skim to understand the item-row structure, reveal/mask state, quick-add form. Identify dedupe boundaries with `DetachedVaultPage.tsx`.
- `web/src/pages/DetachedVaultPage.tsx` — near-duplicate of `VaultPanel.tsx`. Dedupe BEFORE editing.
- `web/src/components/wizard/SecretsPopover.tsx` — the wizard's variable picker. Emits `${vault:KEY}` today.
- `web/src/hooks/useWindowManager.ts`, `web/src/stores/useUIStore.ts`, `web/src/routes.tsx` — the route/window/store IDs to rename.
- `web/src/lib/yaml-builder.ts` — only the docstring example needs updating; no code change.
- `web/src/__tests__/SecretsPopover.test.tsx` — pattern reference for new UI tests.
- `examples/secrets-vault/vault-basic.yaml`, `examples/secrets-vault/vault-sets.yaml` — update to use `${var:KEY}` in this PR.
- `CONSTITUTION.md` Articles VIII, IX, XII, XV — these constrain the PR; re-read before submitting.
- `CHANGELOG.md` — match the existing entry style; add Breaking + Feature entries.

### Integration Points

- **`Store.Values() []string`** — currently returns every value; change to return only values where `IsSecret==true`. The single line that ends masking fatigue.
- **`pkg/config/expand.go::expandRegex`** — extend `(vault):` to `(vault|var):`. Plumb a deprecation logger when the captured group is `vault`.
- **`cmd/gridctl/root.go`** (or wherever commands register) — add `varCmd` to root; keep `vaultCmd` registered too (as deprecation wrapper).
- **`internal/api/router.go`** — add `/api/var/*` group; redirect `/api/vault/*`.
- **`web/src/lib/api.ts`** — every UI caller of the vault API funnels through these functions. Rename them and tsc will surface every callsite that needs updating.
- **`web/src/hooks/useWindowManager.ts`** — single source of truth for window IDs/titles; mass renames flow from here.

### Reusable Components

- **`pkg/output.Printer`** — existing table writer. Just add columns.
- **`vault.maskValue()`** — keep as is; only changes is when it's called.
- **`atomicWrite()` helper in `store.go`** — reuse for v2 writes.
- **`ensureUnlocked()` in `cmd/gridctl/vault.go`** — move to a shared helper if needed by `var` command tree.
- **All set-related code** (`SetWithSet`, `GetSetSecrets`, `CreateSet`, `DeleteSet`) — unchanged. Sets are orthogonal to sensitivity.

## UX Specification

### Discovery

- `gridctl --help` lists `var` as a top-level command. `vault` is hidden from default `--help` output but still works (use `cobra.Command.Hidden = true`).
- `gridctl var --help` shows full subcommand tree with one-line descriptions.

### Activation

- Existing users running `gridctl vault set FOO bar`:
  - First invocation per shell session: full deprecation paragraph: `"gridctl vault" is deprecated. Use "gridctl var" instead. The old command will be removed at v1.0. See "gridctl var --help".`
  - Subsequent invocations same session: silent passthrough (we'd be sync.Once'd already). If the process is short-lived (which CLI is), every invocation prints — acceptable. Use `slog.Warn(...)` for the warning so it goes to stderr and respects log level.
- New users see `gridctl var` everywhere; no friction.

### Interaction

```bash
# Plaintext (non-sensitive) value
gridctl var set REGION us-east-1 --plaintext
# → "Variable stored" key=REGION visibility=plaintext type=string

# Default: secret
gridctl var set DB_PASSWORD 'pa55w0rd!'
# → "Variable stored" key=DB_PASSWORD visibility=secret type=string

# Typed list
gridctl var set TAGS app,backend,prod --type list --plaintext
# → "Variable stored" key=TAGS visibility=plaintext type=list

# Typed JSON
gridctl var set CORS '["https://a.com","https://b.com"]' --type json --plaintext
# → "Variable stored" key=CORS visibility=plaintext type=json

# Get
gridctl var get REGION
# → REGION = us-east-1  (type: string, plaintext)
gridctl var get DB_PASSWORD
# → DB_PASSWORD = pa****d!  (type: string, secret)
gridctl var get DB_PASSWORD --plain
# → pa55w0rd!

# List
gridctl var list
# (table with Key/Type/Visibility/Set)
```

### Feedback

- Success: structured `printer.Info("Variable stored", "key", ..., "visibility", ..., "type", ...)`.
- Validation failure: clean error message naming the field and the violation.
- Unlock prompts unchanged.

### Error States

- `gridctl var set X y --secret --plaintext` → `Error: --secret and --plaintext are mutually exclusive`.
- `gridctl var set X --type bool --value notabool` → `Error: invalid value for type=bool: "notabool"`.
- `gridctl var get NONEXISTENT` → `Error: variable "NONEXISTENT" not found`.
- Stack with unresolved `${var:X}` → existing error path (`missing vault secret(s): X`). Update wording to `missing variable(s): X. To fix: gridctl var set X`.

## Implementation Notes

### Conventions to Follow

- **Cobra commands** follow the existing pattern in `vault.go`: separate `var<Sub>Cmd` blocks with `RunE` callbacks that delegate to `run<Sub>()` functions taking the key/args as parameters.
- **Test naming**: `TestStore_<Behavior>` for vault tests, `Test<Func>` for config tests. Use `t.Run(name, func(t *testing.T) {})` subtests liberally.
- **Use `t.TempDir()`** for vault tests, not `/tmp`.
- **No `fmt.Println`** in library code (Article XIV) — only in `cmd/gridctl/*` for terminal output.
- **All new structs in `pkg/vault`** must have JSON tags. Use `omitempty` only when the field has a meaningful zero value.
- **Don't add `Variable` as a Go alias for `Secret`**: rename `Secret` → `Variable` cleanly. Bumps the package version conceptually but the on-disk format is what users care about. Internal Go rename has zero user-visible impact and avoids two names for the same thing.
- **CHANGELOG.md (Article XV)**: add entries under `[Unreleased]`:
  - `### Breaking` — `gridctl vault` renamed to `gridctl var` (deprecated alias retained through beta; removed at v1.0). API routes `/api/vault/*` likewise renamed with redirects. Vault on-disk format bumped to v2 (backward-compatible loading; saves always write v2). Web UI route `/vault` redirects to `/var`; `vaultDetached`/`showVault` localStorage keys migrated to `varDetached`/`showVariables`.
  - `### Added` — `gridctl var` command tree with `--secret`/`--plaintext`/`--type` flags. Type metadata: string/json/list/number/bool. New `# @type` / `# @public` `.env` markers. JSON import/export round-trips type and visibility. Web UI: Type indicator + Visibility indicator on every row; Type selector + Secret/Plaintext toggle in add/edit forms.
  - `### Changed` — log redaction now only applies to values stored with `--secret` (default); plaintext variables appear in logs unredacted. Web UI: plaintext variables display unmasked by default; only secret variables require Reveal.
- **web/CHANGELOG.md**: matching entry under `[Unreleased]` with the UI-specific changes. Follow the existing entry style in that file.
- **TypeScript / React conventions**: existing code uses functional components + hooks, Zustand for global state, Tailwind for styling. Match the indent (2-space), import ordering, and prop-typing style of the file you're editing. Do not introduce new state-management libraries or styling systems.

### Potential Pitfalls

- **`Store.Values()` filtering must happen at every callsite of `RegisterRedactValues`**. Search for callers — there may be more than one (controller startup, daemon reload paths). Audit them all.
- **`reloadIfChanged()` in `store.go`** must re-filter after reload. Don't cache `Values()` across reload boundaries with stale `IsSecret` state.
- **The legacy flat-array vault format** (v0) and the current object format (v1) must both still load. Don't drop v0 support; tests for it exist in `store_test.go`.
- **Encryption envelope** (`EncryptedVault`) wraps the *bytes of the inner JSON*. Bumping the inner JSON to v2 does NOT change the envelope format. Don't touch `crypto.go` unless tests force you.
- **`secrets.sets` field in stack YAML**: keep this name unchanged in this PR even though we're renaming everything else. It refers to *sets*, which are still called sets in the new world. Renaming this field is a stack.yaml breaking change (Article IX) for no UX gain. Document this decision in the PR description.
- **`${vault:KEY}` in stack YAML stays parsed but warned.** The deprecation log here MUST be once-per-process, not once-per-occurrence — a stack with 50 `${vault:KEY}` refs should print one warning, not 50.
- **`vault sets create/delete`** in deprecated path: same once-per-session deprecation rule.
- **UI dedupe before edit**: do NOT make the field/label changes inside `VaultPanel.tsx` AND `DetachedVaultPage.tsx` in parallel — extract shared components first. Two-way edits in nearly-identical files reliably drift (someone tweaks one, forgets the other, ships a regression).
- **localStorage migration**: persisted UI store keys (`vaultDetached`, `showVault`) hold user-visible state (panel open/closed). Stranding a user on the old key means their panel silently closes after update. Add the one-time migration and delete the old key after copy.
- **Don't add a UI-level deprecation banner** for the rename. The CLI deprecation log and silent route redirect are enough. A banner in the UI is more annoying than useful and there's no equivalent of "stale shell session" to worry about.
- **Hard rename in TypeScript is your friend**: do NOT add `export { Variable as VaultSecret }` aliases. Let tsc's error list be the to-do list of callsites needing update. The whole point of a hard rename is to force-update every reference.

### Suggested Build Order

1. **Storage layer** (smallest surface, biggest BC risk):
   - Rename `Secret` → `Variable` in `pkg/vault/types.go`. Add `Type`, `IsSecret` fields. Bump `storeData` shape, add `version`.
   - Update `parseSecretsData()` to handle v0/v1/v2 with explicit branching.
   - Write tests FIRST for: v0 load → in-memory has IsSecret=true, Type="string"; v1 load → same; v2 load → preserves; round-trip writes v2.
   - Update `Values()` to filter by `IsSecret`. Test.
   - Update `Set/SetWithSet/Import/Export` signatures only as needed to thread type/visibility through.

2. **CLI** (most visible change):
   - Create `cmd/gridctl/var.go` cloning the structure of `vault.go`. Implement `--secret`/`--plaintext`/`--type` flag handling in `runVarSet`. Type validation lives in a helper `validateAndNormalize(typeName, value string) (normalized string, err error)`.
   - Update `runVarList` columns. JSON output struct.
   - Update `runVarGet` masking decision logic.
   - Update `runVarImport`/`runVarExport` for metadata round-trip.
   - Turn `vault.go` into a deprecation wrapper. Use `sync.Once` for the warning.

3. **Expansion**:
   - Update `expandRegex` to `(vault|var):`. Plumb deprecation log for `vault` prefix; once-per-process via `sync.Once`.
   - Update one example file `examples/secrets-vault/vault-basic.yaml` → rename to `var-basic.yaml`, change refs to `${var:KEY}`. (Keep the old file as a separate `vault-basic-deprecated.yaml` if you want a regression test.)

4. **API**:
   - Add `/api/var/*` routes mirroring `/api/vault/*`. Add `type`/`is_secret` in payloads.
   - Wire `/api/vault/*` as a 308 redirect to `/api/var/*` (or thin proxy if the API conventions prefer that — match what `/sse → /mcp` does today; see how SSE deprecation was handled).

5. **Web UI** (do AFTER backend lands so the dev server actually exercises real responses):
   - **Dedupe first**: extract `VariableItem` and `VariableForm` from `VaultPanel.tsx` and `DetachedVaultPage.tsx` into shared components in `web/src/components/vault/`. Land this as an internal-only commit before any rename/feature changes — keep the diff small and reviewable.
   - **API client rename**: update `web/src/lib/api.ts` (rename interface, functions, endpoints, add fields). TypeScript compile errors will guide you to every callsite. Fix them one by one.
   - **Type selector + Secret/Plaintext toggle**: implement once in the shared `VariableForm`. Both VaultPanel and DetachedPage pick it up automatically.
   - **Mask/reveal gating**: in shared `VariableItem`, branch on `is_secret`. Plaintext displays raw; secret displays bullets unless revealed; auto-hide timer only fires for secrets.
   - **Popover update**: rename `SecretsPopover` to `VariablesPopover`, surface plaintext+secret with distinct icons, emit `${var:KEY}`.
   - **Window/route/store renames**: update `useWindowManager.ts`, `useUIStore.ts`, `routes.tsx`. Add localStorage migration for `vaultDetached`/`showVault` keys. Add silent `/vault` → `/var` redirect.
   - **Test updates**: rename `SecretsPopover.test.tsx`, update mock payloads, add new VaultPanel/Variables tests.
   - **Manual smoke**: `make build && ./gridctl serve --foreground` (per memory: serve daemonizes by default), open the web UI, set a plaintext var, set a secret, verify display, refresh, lock/unlock the vault, restart and confirm persistence.

6. **Examples + docs**:
   - Update `examples/secrets-vault/*` to use `${var:KEY}`. Rename directory if appropriate.
   - Update `docs/config-schema.md` "Variable Expansion" section. Add a new "Variables vs Secrets" section.
   - Update `AGENTS.md` vault command listing. Update `web/AGENTS.md` if vault UI is documented there.
   - Add new `examples/portable-stack/` example demonstrating the headline use case (region/cluster ID as plaintext vars, DB password as secret).

7. **CHANGELOG**: write the entries (Breaking, Added, Changed) in `CHANGELOG.md`. Also add an entry to `web/CHANGELOG.md` for the UI rename + new affordances. Update Article IX scope coverage if the PR description references it.

8. **Test sweep**:
   - All existing vault tests pass unchanged (no semantic regression).
   - All existing config tests pass unchanged.
   - All existing web tests pass after mock-payload updates.
   - New Go and TS tests pass and exercise the boundaries below.
   - `cd web && npm run build && npm test` succeeds.

## Acceptance Criteria

A v0 vault file (legacy flat array `[{"key","value","set"}]`) loads, every entry gets `IsSecret=true` and `Type="string"`, save writes v2 shape, reload as v2 yields identical in-memory state.

A v1 vault file (`{"secrets": [...], "sets": [...]}`) loads, every entry gets `IsSecret=true` and `Type="string"`, save writes v2.

A v2 vault file (`{"version": 2, "variables": [{"key","value","type","is_secret","set"}], "sets": [...]}`) round-trips losslessly.

`gridctl var set FOO bar` stores `FOO` with `IsSecret=true`, `Type=string`.

`gridctl var set FOO bar --plaintext` stores `FOO` with `IsSecret=false`, `Type=string`.

`gridctl var set FOO bar --secret --plaintext` returns a clear error.

`gridctl var set FOO 42 --type number` stores; `--type number --value notanumber` errors.

`gridctl var set FOO 'true' --type bool` stores; arbitrary string errors.

`gridctl var set FOO '{"a":1}' --type json` stores; invalid JSON errors.

`gridctl var set FOO a,b,c --type list` stores `["a","b","c"]` (JSON-encoded array string).

`gridctl var get` masks secrets, shows plaintext values plain by default; `--plain` always shows.

`gridctl var list` prints a table with Key/Type/Visibility/Set; `--format json` omits values.

`gridctl var export --format env --plain` round-trips through `gridctl var import` preserving type and visibility (verified by `var list` JSON diff before/after).

`gridctl var export --format json` round-trips losslessly likewise.

`gridctl vault set FOO bar` still works and logs the deprecation warning exactly once per process.

A stack.yaml using `${var:REGION}` resolves; `${vault:REGION}` resolves with a one-shot deprecation warning per process.

`Store.Values()` returns only values where `IsSecret==true`. Unit-tested directly.

After setting plaintext `REGION=us-east-1` and applying a stack that uses it, `us-east-1` appears unredacted in logs that mention REGION.

After setting secret `DB_PASSWORD=pa55w0rd!` and applying a stack that uses it, `pa55w0rd!` is replaced by `[REDACTED]` in logs.

A vault that's encrypted (locked) and contains v1 data, when unlocked, surfaces as v2 in-memory and re-saves as v2 (with re-encryption preserving the existing key envelope).

`gridctl vault sets create production` still works with the deprecation warning; `gridctl var sets create production` works without it.

`/api/var/*` endpoints serve requests with `type`/`is_secret` in payloads. `/api/vault/*` requests succeed and either redirect or proxy to the new endpoints — match existing project deprecation convention.

CHANGELOG.md `[Unreleased]` has Breaking/Added/Changed entries for the rename, the new flags, and the redaction behavior change. `web/CHANGELOG.md` has a matching entry covering the UI rename and new affordances.

In the web UI, navigating to `/vault` silently redirects to `/var`. The Variables panel renders with the renamed header. The detached window (opened via the detach button) shows the same content; both render through the shared `VariableItem`/`VariableForm` components (no longer a duplicate file).

Creating a plaintext variable via the UI quick-add form (Type=string, Visibility=Plaintext) results in a row that shows the value directly without needing to click Reveal. Creating a secret variable shows bullets and requires Reveal to view the value; the value auto-hides after 10 seconds.

Creating a variable with Type=json + an invalid JSON value surfaces an inline validation error in the UI before submission.

The wizard's Variables popover (renamed from Secrets popover) surfaces both plaintext and secret variables, shows distinct icons for each, and emits `${var:KEY}` (not `${vault:KEY}`) when a variable is selected.

`web/src/lib/api.ts` no longer exports `VaultSecret`, `fetchVaultSecrets`, `createVaultSecret`, etc. — all renamed to `Variable`, `fetchVariables`, `createVariable`, etc. `tsc` finds zero references to the old names.

`cd web && npm run build` produces a clean production build. `cd web && npm test` passes with the updated mocks and new tests.

`go test ./...` passes with `-race`.

`golangci-lint run` passes.

`go build ./...` succeeds.

Updated examples in `examples/` build and pass `gridctl validate`.

## References

- Full feature evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/unified-variable-store/feature-evaluation.md`
- [Pulumi config set CLI — `--secret`/`--plaintext` idiom](https://www.pulumi.com/docs/cli/commands/pulumi_config_set/)
- [Pulumi ESC GA blog (Sept 2024) — closest architectural twin](https://www.pulumi.com/blog/pulumi-esc-ga/)
- [GitHub Actions vars changelog (Jan 10 2023) — rationale for the unified pattern](https://github.blog/changelog/2023-01-10-github-actions-support-for-configuration-variables-in-workflows/)
- [Terraform `sensitive=true` — over-marking anti-pattern](https://developer.hashicorp.com/terraform/tutorials/configuration-language/sensitive-variables)
- [AWS SSM cautionary — don't conflate type and sensitivity](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-vs-secrets-manager.html)
- gridctl `CONSTITUTION.md` — Articles VIII (semver), IX (stack.yaml BC), XII (secure defaults), XV (changelog discipline)
- Recent vault hardening: gridctl PR #579 (encryption-state transitions) and PR #577 (reload-on-read)
