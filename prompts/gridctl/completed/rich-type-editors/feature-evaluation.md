# Feature Evaluation: Rich Type Editors for the Variables Workspace

**Date**: 2026-05-23
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium–Large

## Summary

gridctl's Variables workspace already carries full type metadata (`string`, `json`, `list`, `number`, `bool`) end-to-end, but every value is still edited through one plain text input. This feature swaps in type-specific editors — a CodeMirror-based JSON editor with inline validation, a tag-input for lists, a `role="switch"` toggle for booleans, and a text+stepper numeric input. It is the explicitly signposted next increment ("PR 2 will wire type-aware expansion") on the project's most actively developed surface, carries no API or data-model changes, and would put gridctl ahead of nearly every direct peer on value-editing UX. Build it, with two scope adjustments to the original spec and a deliberate dependency exception for the JSON editor.

## The Idea

When creating or editing a variable, the value input adapts to the selected type instead of being a generic text field:

- **`json`** — a syntax-highlighted mini-editor with JSON validation
- **`list`** — a tag-input for adding/removing distinct string tags
- **`bool`** — a toggle switch (true/false)
- **`number`** — a numeric input (text + `inputmode` + optional steppers; not a native spinner — see caveats)

**Problem solved**: Today users must hand-format JSON, guess whether a list is comma-separated or a JSON array, memorize which boolean tokens are accepted, and only discover invalid input at submit time. Type-specific editors remove that friction and surface the backend's existing type system in the UI.

**Who benefits**: Every user of the gridctl web UI's Variables workspace, most deeply those managing `json` and `list` variables.

## Project Context

### Current State

gridctl is a mature pre-1.0 (v0.1.0-beta.10) MCP gateway + skill library: a Go CLI with an embedded React 19 / TypeScript / Vite 8 / Tailwind v4 / Zustand 5 web UI. The Variables workspace (internally the "vault" module) is the project's current hot zone — nearly every recent commit is a Variables feature (secret generator, drag-and-drop import, usage surfacing, recently-edited indicator, promotion to a first-class workspace).

The type infrastructure was laid deliberately as groundwork and is fully wired *except* for the input widgets:

- ✅ Type enum end-to-end: Go `vault.VariableType` (`pkg/vault/types.go`) → `/api/var` → TS `VariableType` (`web/src/lib/api.ts`)
- ✅ `VariableTypeSelector` segmented control, `VariableTypeBadge`, type-aware placeholders
- ✅ `validateVariableInput` in `variableTypeHelpers.ts` (mirrors the Go CLI's `validateAndNormalize`)
- ❌ **Every type still uses one plain `<input type="text|password">`** — in the add form, the inline edit, the wizard popover, and bulk import

The code signposts this exact work: `VariableTypeSelector.tsx` and `types.go` both carry the comment *"PR 1 records the type as metadata only; PR 2 will wire type-aware expansion."*

### Integration Surface

The value input appears in **four** call sites that have already drifted in behavior:

1. `web/src/components/vault/VariableQuickAddForm.tsx` — the add form. Has the `VariableTypeSelector` + a `<form onSubmit>` (Enter submits). Validates only on submit.
2. `web/src/components/vault/SecretItem.tsx` (`isEditing` branch) — inline edit. Type is a fixed **badge** (not changeable during edit). Hard-codes `Enter`→save / `Escape`→cancel.
3. `web/src/components/wizard/VariablesPopover.tsx` — a create form inside a height-constrained portal popover; submit is a plain `<button>` (no native Enter-to-submit).
4. `web/src/components/vault/EnvImportModal.tsx` — bulk import with a per-row type selector but **no value validation today** (rows submit raw).

Supporting files: `web/src/components/workspaces/VaultWorkspace.tsx` (owns `editType`/`editValue` state and save-time validation), `web/src/components/vault/variableTypeHelpers.ts` (the normalization contract), `web/src/lib/api.ts` (`Create/UpdateVariableInput` — unchanged by this feature).

**No backend or API changes are required.** The web build is embedded into the Go binary via `//go:embed all:web/dist` (`cmd/gridctl/embed.go`), so this is a frontend-only change requiring a web rebuild.

### Reusable Components

- `variableTypeHelpers.ts` — `validateVariableInput(type, value)` already produces the exact normalized string the API expects. Rich editors should keep emitting this contract so callers are untouched.
- `tokenize.ts` + `CodeViewer.tsx` — existing read-only JSON/YAML highlighter (relevant context, though the JSON editor will use CodeMirror per the decision below).
- `VariableTypeSelector.tsx` — the existing type selector that drives which editor renders in the add path.
- `SecretGenerator.tsx`, `VariableSecretToggle.tsx` — house patterns for chip/range/segmented controls and the secret/plaintext masking interplay.
- `ajv8` is already installed (via `@rjsf`) and available for JSON-schema validation if ever wanted.

## Market Analysis

### Competitive Landscape

Type-specific value editing splits the market into three tiers:

- **Plain text, no type widgets**: GitHub Actions, GitLab CI (only Variable/File type), Vercel, Netlify, CircleCI, Postman, 1Password.
- **Type *validation* but no widgets**: Doppler (15 value types, parses-on-save — but values, including JSON/YAML, are pasted as plain text).
- **Document-level JSON editor**: HashiCorp Vault UI (form ↔ raw-JSON toggle); Railway RAW editor.
- **Full widget-per-type**: only Retool (JSON Editor, Number Input, Switch, Multiselect-with-chips) — and it's a UI builder, not a variable manager.

Active demand exists even among leaders: Infisical has an open feature request (#2915) for a JSON code editor with highlighting and live error detection.

### Market Positioning

**Differentiator, trending toward table-stakes — not yet baseline.** The dominant pattern across daily-driver tools is plain text. The most advanced secrets-manager behavior in the wild is Doppler's type *validation* and Vault's JSON-editor toggle. Building all four widgets would put gridctl ahead of nearly every direct peer on editing UX. The `list` tag-input is the most novel (no secrets/CI tool has it) and the highest design-risk piece.

### Ecosystem Support

- **JSON editor**: CodeMirror 6 (`@uiw/react-codemirror`, ~50KB gzip, installs clean on React 19) is the right choice. Monaco is a trap — a 4.8KB wrapper that lazy-loads a ~1MB+ engine, unjustifiable for a mini-editor.
- **Tag input / toggle / number**: realistically small in-house components with Tailwind + `lucide-react` + ARIA; the surveyed libraries are either heavyweight (react-select, tagify) or drag transitive deps (react-tag-input → react-dnd; emblor → react-easy-sort).

### Demand Signals

The feature is internally signposted ("PR 2 will wire type-aware expansion"), sits on the project's most active surface, and mirrors a direction competitors are actively moving toward (Doppler validation, Vault JSON editor, the open Infisical request).

## User Experience

### Interaction Model

- **Add / wizard**: the type selector already exists, so swapping the value widget when type changes is discoverable. Reserve a stable min-height container so the form doesn't jump between a 1-line input, a multi-line JSON editor, a wrapping tag row, and a 36px toggle.
- **Inline edit**: type is fixed (badge), so the widget renders purely from `secret.type` — no transition problem.

### Workflow Impact

- **Friction reduced** for `list` (no comma-vs-JSON ambiguity) and `bool` (no token guessing), and for `json` via inline validation instead of submit-time surprises.
- **Enter-to-submit must be reworked per widget** — the single most important behavioral change:
  - JSON editor: Enter inserts a newline; submit via Cmd/Ctrl+Enter or the explicit Add button.
  - Tag input: Enter commits the current tag; form submit moves to the button.
  - `SecretItem`'s hard-coded `Enter`→save must become widget-aware or it will save half-typed JSON / orphan an uncommitted tag.
- **Edit starts blank**: `VaultWorkspace.handleEdit` sets `editValue('')` — editing replaces the whole value rather than modifying it in place. This removes the need to parse a stored JSON-array string back into chips, but forcing a full retype of a list is a UX smell worth fixing (pre-fill current value into the widget, or show it as read-only context).

### UX Recommendations

- **Secret masking**: rich editors can't meaningfully highlight or chip-render a masked value. Gate `json`/`list`/`number` rich editors behind the existing reveal affordance for secrets; always show the `bool` toggle (masking a 2-state bit is pointless).
- **Validation timing**: move `json`/`number` validation to on-blur/on-change (debounced), keep on-submit as the backstop. `list` and `bool` can't be invalid.
- **List round-trip**: hold `string[]` internally and emit `JSON.stringify(tags)` directly (matches the `list` normalizer); dedupe per "distinct tags"; flush any uncommitted input buffer on submit.
- **Accessibility**: `role="switch"` + `aria-checked` + stable label for the toggle; `aria-live` region + labeled per-chip remove buttons for tags; `aria-invalid`/`aria-describedby` on the JSON and number fields; avoid native number spinners (`inputmode` + steppers instead).

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Hand-formatting JSON, comma-vs-JSON ambiguity, bool-token guessing, submit-only errors — recurring friction on the hottest surface. |
| User impact | Broad + Moderate | All web-UI Variables users benefit; deep for json/list, polish for bool/number. |
| Strategic alignment | Core | Signposted next increment on the active development surface; type groundwork already laid. |
| Market positioning | Catch-up → Leap-ahead | Differentiator; ahead of GitHub/GitLab/Vercel/Doppler on editing UX. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Four call sites, secret-mask interplay, Enter-semantics rework, shared-component extraction. No API change. |
| Effort estimate | Medium–Large | Shared `VariableValueInput` + 4 widgets + tests + edit-value reconciliation. JSON editor is the heaviest piece. |
| Risk level | Low–Medium | UI-only, no data/security risk. Medium drivers: JSON editor in compact inline row, Enter-semantics regressions, secret-mask gating. |
| Maintenance burden | Moderate | One new dependency (CodeMirror) + in-house widgets needing tests (existing helpers are currently untested). |

## Recommendation

**Build with caveats.** This is a high-alignment, low-medium-risk feature on the project's active surface, with no API or data-model changes. The caveats are about scope and approach, not whether to build:

1. **Number widget**: the original "numeric spinner" is a 2025 anti-pattern (scroll-wheel mutation, a11y gaps, silent character rejection — GOV.UK dropped native `type="number"`). Use `<input type="text" inputmode="numeric">` with optional +/− stepper buttons. **(Confirmed with user.)**
2. **JSON editor**: build on **CodeMirror 6** (`@uiw/react-codemirror` + `@codemirror/lang-json` + `@codemirror/lint`), not a hand-rolled textarea overlay. The overlay approach is a known trap (scroll-sync fragility, Tab-key hijacking that breaks a11y, per-browser wrapping bugs); CM6 gives bracket-closing, auto-indent, and inline error squiggles for ~50KB. This is a **deliberate, justified exception** to the dependency-minimalism default (`CONSTITUTION.md` Article II) and needs a one-line justification note in the PR. **(Confirmed with user.)**
3. **Shared component**: extract one `VariableValueInput` used by all four call sites — this also closes the bug where `EnvImportModal` submits unvalidated values today.
4. **Secret gating**: rich editors render only when the value is visible; the `bool` toggle always shows.
5. **Scope**: all-in-one (single cohesive PR covering all four widgets + the shared component). **(Confirmed with user.)**

The single most important behavioral risk to get right is Enter-semantics across the JSON editor and tag input — especially `SecretItem`'s hard-coded `Enter`→save. The single most valuable polish beyond the spec is moving validation earlier (on-blur) so users stop hitting submit-time surprises.

## References

- Doppler value types: https://docs.doppler.com/docs/secrets
- Infisical JSON editor request (#2915): https://github.com/Infisical/infisical/issues/2915
- HashiCorp Vault UI JSON editor: https://github.com/hashicorp/vault/pull/24290
- HCP Terraform variables (HCL): https://developer.hashicorp.com/terraform/cloud-docs/variables/managing-variables
- GitLab CI/CD variables: https://docs.gitlab.com/ci/variables/
- Vercel env vars: https://vercel.com/docs/environment-variables/managing-environment-variables
- Retool input components (JSON Editor, Number, Toggle, Multiselect): https://retool.com/blog/new-input-ui-component-library
- CodeMirror lint example: https://codemirror.net/examples/lint/
- Monaco vs CodeMirror weight: https://sourcegraph.com/blog/migrating-monaco-codemirror
- GOV.UK dropping input type=number: https://technology.blog.gov.uk/2020/02/24/why-the-gov-uk-design-system-team-changed-the-input-type-for-numbers/
- W3C APG switch pattern: https://www.w3.org/WAI/ARIA/apg/patterns/switch/
- Inline validation UX: https://smart-interface-design-patterns.com/articles/inline-validation-ux/
- NN/g input steppers: https://www.nngroup.com/articles/input-steppers/
- @uiw/react-codemirror: https://github.com/uiwjs/react-codemirror
