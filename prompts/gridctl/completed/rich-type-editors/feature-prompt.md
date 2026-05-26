# Feature Implementation: Rich Type Editors for the Variables Workspace

## Context

gridctl is a Go CLI (an MCP gateway + skill library) with an embedded React 19 + TypeScript web UI. The web frontend lives in `web/`, is built with Vite 8, styled with Tailwind CSS v4 (semantic tokens like `text-text-muted`, `bg-surface`, `border-border-subtle`, `text-primary`; no CSS modules), uses Zustand 5 for state and `lucide-react` for icons. The built UI is embedded into the Go binary via `//go:embed all:web/dist` (`cmd/gridctl/embed.go`), so this is a **frontend-only** change that requires a web rebuild to ship.

The "Variables workspace" is internally the **vault** module (`web/src/components/vault/`). Variables have a type (`string | json | list | number | bool`) that is already modeled end-to-end (Go `pkg/vault/types.go` → `/api/var` → TS `web/src/lib/api.ts`). Today the type is selectable/displayed, but **every value is edited through one plain `<input type="text|password">`** regardless of type. This feature adds type-specific editors.

Build/test commands (run from `web/`):
- Dev: `npm run dev` (or `make dev` from repo root)
- Build: `npm run build` (`tsc -b && vite build`); full embed via `make build-web`
- Test: `npm test` (`vitest run`); watch via `npm run test:watch`
- Lint: `npm run lint` — **has ~45 pre-existing failures unrelated to this work; lint only your changed files.**

## Evaluation Context

Key findings that shaped this prompt (full evaluation: `prompts/gridctl/rich-type-editors/feature-evaluation.md`):

- **This is the signposted next increment.** `VariableTypeSelector.tsx` and `pkg/vault/types.go` both comment *"PR 1 records the type as metadata only; PR 2 will wire type-aware expansion."* The type infrastructure is deliberate groundwork; this feature completes the UI layer.
- **Market positioning**: type-specific editors are a differentiator (ahead of GitHub/GitLab/Vercel/Doppler; only Retool has the full widget-per-type model). The JSON editor mirrors where Vault and Infisical are heading.
- **Number widget decision (user-confirmed)**: do NOT use a native `<input type="number">` spinner (2025 anti-pattern: scroll-wheel mutation, a11y gaps, silent character rejection). Use `<input type="text" inputmode="numeric">` + optional +/− stepper buttons.
- **JSON editor decision (user-confirmed)**: use **CodeMirror 6**, not a hand-rolled textarea overlay. The overlay approach is a known trap (scroll-sync fragility, Tab-key hijacking that breaks a11y, per-browser wrapping bugs). This is a **deliberate exception** to the dependency-minimalism default in `CONSTITUTION.md` Article II — include a one-line dependency justification in the PR description.
- **Risk mitigations baked in**: gate rich editors behind reveal for secrets (can't highlight/chip a masked value); rework Enter-semantics per widget; extract one shared component to avoid the four call sites drifting further (and to fix the unvalidated bulk-import path).

## Feature Description

When creating or editing a variable, the value input adapts to the variable's type:

- **`string`** — unchanged: the existing masked/text input with eye-reveal and `SecretGenerator`.
- **`json`** — a CodeMirror 6 mini-editor with JSON syntax highlighting and inline validation.
- **`list`** — a tag-input: type a tag, press Enter/comma to commit it as a chip; remove chips individually; duplicates are rejected.
- **`bool`** — a `role="switch"` toggle (true/false).
- **`number`** — a text input with `inputmode="numeric"` plus optional +/− stepper buttons.

This removes recurring friction (hand-formatting JSON, comma-vs-JSON ambiguity for lists, memorizing bool tokens, submit-only error discovery) and surfaces the backend's existing type system in the UI.

## Requirements

### Functional Requirements

1. Introduce a single shared component `VariableValueInput` (in `web/src/components/vault/`) that renders the correct editor for a given `type` and emits a **normalized** value string matching the existing `validateVariableInput` contract.
2. `string` type renders the current behavior (masked/text input, eye toggle, `SecretGenerator` for plaintext). No regression.
3. `json` type renders a CodeMirror 6 editor with JSON highlighting; invalid JSON is surfaced inline (lint gutter / squiggle) and also blocks save.
4. `list` type renders a tag-input: Enter or comma commits the current buffer as a chip; Backspace on an empty input removes the last chip; duplicate tags are rejected; empty/whitespace tags are ignored; each chip has a labeled remove button. The component holds `string[]` internally and emits `JSON.stringify(tags)` (matching the `list` normalizer).
5. `bool` type renders a `role="switch"` toggle. It emits `"true"`/`"false"`.
6. `number` type renders `<input type="text" inputmode="numeric">` with +/− stepper buttons; non-numeric input is rejected on blur and blocks save. Disable scroll-wheel value mutation.
7. Wire `VariableValueInput` into all four call sites:
   - `VariableQuickAddForm.tsx` (add) — widget swaps as `VariableTypeSelector` changes.
   - `SecretItem.tsx` (inline edit) — widget renders from the fixed `secret.type` (no selector in edit mode).
   - `VariablesPopover.tsx` (wizard) — same as add, within the height-constrained popover.
   - `EnvImportModal.tsx` (bulk import) — at minimum route per-row values through `validateVariableInput` so import stops submitting unvalidated values; use `compact` rendering.
8. **Enter-semantics per widget**: in the JSON editor Enter inserts a newline (submit via Cmd/Ctrl+Enter or the explicit Add/Save button); in the tag input Enter commits a tag (not form submit). Update `SecretItem`'s hard-coded `Enter`→`onEditSave` so it does not fire mid-edit for json/list.
9. **Secret gating**: for secret variables, `json`/`list`/`number` rich editors render only when the value is revealed (extend the existing `showValue || !isSecret` pattern); the `bool` toggle always renders.
10. **Type-switch value preservation** (add/wizard): when the user switches type with text already entered, do not silently wipe it — re-interpret if representable in the new widget, otherwise preserve it in a fallback text field with a small "doesn't match {type}" hint.
11. Validation moves earlier for `json`/`number` (on-blur / debounced on-change) while keeping the existing on-submit check as the backstop. Reuse `validateVariableInput` for the canonical messages.
12. Add a `compact` prop so `EnvImportModal` cells and `SecretItem` rows can render a denser variant than the add form, and reserve a stable min-height so the add form doesn't jump between widget heights.

### Non-Functional Requirements

- **Accessibility**: toggle uses `role="switch"` + `aria-checked` + a stable label (don't relabel On/Off); tag input announces add/remove via an `aria-live="polite"` region and gives each chip a `<button aria-label="Remove {tag}">`; JSON and number fields expose `aria-invalid` + `aria-describedby` for errors; the JSON editor must not trap Tab focus permanently.
- **Bundle**: CodeMirror is the only new dependency; do not pull in Monaco. Lazy-load the JSON editor if it meaningfully affects initial bundle size.
- **No API/backend change**: the value submitted to `/api/var` must remain the normalized string the API already accepts.
- **Tests**: add Vitest + Testing Library tests for `VariableValueInput` covering each type's emit contract, the secret-reveal gate, Enter-semantics, and tag dedupe. (Note: `variableTypeHelpers.ts` currently has no direct tests — add them while you're here.)

### Out of Scope

- Backend per-type value validation (the API does no value validation today; that's a separate defense-in-depth task — see Potential Pitfalls).
- Pre-filling the existing value when editing a `list`/`json` variable is **optional** (see UX Specification) — the current edit flow blanks the value. If you do tackle it, parse the stored JSON-array string into chips; do not show raw `["a","b"]` in a tag field.
- Changing the set of supported types, or adding new types (e.g. yaml, datetime).
- A document-level / whole-secret JSON editor (Vault-style). This is per-value only.
- CodeMirror features beyond JSON highlighting + lint (no themes switcher, no multi-language).

## Architecture Guidance

### Recommended Approach

Build one `VariableValueInput` component that owns: (a) widget selection by `type`, (b) the secret-reveal gate, (c) emitting the normalized string via `validateVariableInput`. Implement each widget as a small sub-component in `web/src/components/vault/` (e.g. `JsonValueEditor.tsx`, `ListTagInput.tsx`, `BoolToggle.tsx`, `NumberValueInput.tsx`). Keep the `string` path delegating to the existing input markup so there is zero regression for the common case.

Proposed prop shape:

```ts
interface VariableValueInputProps {
  type: VariableType;
  value: string;            // current raw/normalized string
  onChange: (normalized: string) => void;
  isSecret: boolean;
  revealed: boolean;        // whether the value is currently visible
  onToggleReveal: () => void;
  onValidityChange?: (valid: boolean) => void;
  onRequestSubmit?: () => void; // Cmd/Ctrl+Enter from json, Enter from string/number
  compact?: boolean;
  enableZoom?: boolean;     // mirror existing `.log-text` zoom support
  placeholder?: string;
}
```

### Key Files to Understand

- `web/src/components/vault/variableTypeHelpers.ts` — the canonical per-type validation/normalization the editors MUST keep producing (`list` → `JSON.stringify(array)`; `json`/`number` passthrough; `bool` token whitelist). Read this first.
- `web/src/components/vault/VariableQuickAddForm.tsx` — add path; `<form onSubmit>` (Enter submits), submit-only validation, `SecretGenerator` for `string`, eye-reveal pattern (`type={showValue || !isSecret ? 'text' : 'password'}`).
- `web/src/components/vault/SecretItem.tsx` — inline edit (`isEditing` branch, ~lines 104-154); type is a fixed badge; hard-coded `Enter`→save / `Escape`→cancel; compact `p-2` row layout.
- `web/src/components/workspaces/VaultWorkspace.tsx` — owns `editType`/`editValue`; `handleEdit` (~lines 244-254) blanks `editValue` on edit; `handleEditSave` normalizes via `validateVariableInput`.
- `web/src/components/wizard/VariablesPopover.tsx` — third create surface; plain-button submit (no native Enter), ~260px height budget.
- `web/src/components/vault/EnvImportModal.tsx` — bulk import; per-row `VariableTypeSelector` but no value validation today.
- `web/src/components/vault/VariableTypeSelector.tsx` — drives which widget renders in the add path.
- `web/src/components/ui/tokenize.ts` + `CodeViewer.tsx` — existing read-only JSON highlighter (context; the editor uses CodeMirror instead).
- `web/src/lib/api.ts` (~lines 535-625) — `VariableType`, `Variable`, `Create/UpdateVariableInput`.
- `web/src/__tests__/VariableQuickAddForm.test.tsx` — testing conventions to follow.

### Integration Points

- Replace the value `<input>` in `VariableQuickAddForm` and `SecretItem` with `VariableValueInput`. Thread the existing `showValue`/`showEditValue` reveal state into `revealed`/`onToggleReveal`.
- In `VaultWorkspace`/`VaultPanel`, pass the variable's `type` down to the edit row (already available as `secret.type`) and keep using `validateVariableInput` on save.
- In `EnvImportModal`, run each row's value through `validateVariableInput(row.type, row.value)` before submit; surface row-level errors.

### Reusable Components

- `validateVariableInput` / `getValuePlaceholder` (`variableTypeHelpers.ts`) — reuse, do not reinvent.
- `SecretGenerator.tsx` — keep wired for `type === 'string'` only.
- `cn` helper (`web/src/lib/cn`), Tailwind semantic tokens, `lucide-react` icons (`X` for chip remove, `Plus`/`Minus` for steppers, `Eye`/`EyeOff` for reveal).
- For CodeMirror: `@uiw/react-codemirror`, `@codemirror/lang-json`, and `@codemirror/lint` (with a JSON lint source). Match the app's dark theme.

## UX Specification

- **Discovery/activation**: add & wizard — the type selector already exists; the value widget swaps when type changes (reserve a stable min-height so the form doesn't jump). Inline edit — widget is determined by the fixed `secret.type` badge.
- **Interaction**:
  - `json`: multi-line CodeMirror editor; Enter = newline; Cmd/Ctrl+Enter or the Add/Save button submits; invalid JSON shows an inline lint marker and disables save.
  - `list`: type → Enter/comma commits a chip; Backspace on empty input removes the last chip; duplicates rejected; flush any uncommitted buffer on submit.
  - `bool`: a labeled switch; Space/Enter toggles.
  - `number`: text input + +/− steppers; reject non-numeric on blur.
- **Feedback**: `json`/`number` validate on blur (and debounced on change) with inline messages reusing `validateVariableInput`'s text; on-submit remains the backstop. `list`/`bool` can't be invalid.
- **Error states**: keep the existing small red text placement for submit-time errors; add inline per-widget feedback for json/number.
- **Secrets**: `json`/`list`/`number` rich editors appear only when revealed; before reveal, show the masked input + reveal affordance. `bool` toggle always shows.
- **List on edit (optional polish)**: the edit flow currently blanks the value (full retype). Prefer fetching and pre-filling the current value into the widget (parse stored JSON-array → chips for `list`); if you keep the blank start, show the current value as read-only context above the input. Never render a raw `["a","b"]` JSON string inside a tag field.

## Implementation Notes

### Conventions to Follow

- One component per file in `web/src/components/vault/`; small focused components matching the existing style.
- Tailwind semantic tokens only; no inline hex except where the codebase already does (gradients in `SecretItem`).
- Sign commits with `-S`; conventional commit messages (`feat: …`, ≤50 char subject); no mention of AI tooling in commits/PR/branches (per repo conventions).
- gridctl uses a **fork workflow** (`/branch-fork`, `/pr-fork`) — branch from upstream, PR to upstream.
- Use `make build` + `./gridctl` to test locally, not a brew-installed binary.

### Potential Pitfalls

- **`SecretItem` Enter-to-save** is the highest-risk regression: it currently saves on any Enter. For json (newline) and list (commit tag) this must not fire.
- **Tag buffer loss**: flush the uncommitted tag-input buffer into a chip on blur/submit, or users lose the tag they typed but didn't "enter."
- **Secret + rich editor incoherence**: never highlight/chip a masked value — gate on reveal.
- **List normalization**: emit `JSON.stringify(tags)` directly; don't round-trip through comma text. Verify the emitted string round-trips through `validateVariableInput('list', ...)` unchanged.
- **Backend does NOT validate values on the API path** (`internal/api/vault.go` only checks the type *name*) — the frontend is the only gate via the web UI. The canonical Go logic `validateAndNormalize` (`cmd/gridctl/var.go`) is CLI-only and has no test. If you want server-side guarantees, lifting `validateAndNormalize` into `pkg/vault` and calling it from the API handlers is a reasonable follow-up (out of scope here, but note it in the PR).
- **CodeMirror React 19**: `@uiw/react-codemirror` installs clean on React 19 (`peer react >=17`) but has no explicit React-19 support statement — smoke-test mounting/unmounting and theme.
- **Lint baseline is dirty** (~45 pre-existing errors, plus eslint lints `web/coverage/*`): lint only your changed files.

### Suggested Build Order

1. Scaffold `VariableValueInput` with the prop shape; delegate `string` to existing markup (no behavior change). Wire it into `VariableQuickAddForm` to prove the seam.
2. `BoolToggle` and `NumberValueInput` (cheapest, highest-confidence). Add tests.
3. `ListTagInput` (chips, dedupe, Enter/comma/Backspace, aria-live, emit `JSON.stringify`). Add tests.
4. Add the CodeMirror dependency; build `JsonValueEditor` (highlight + lint + Cmd/Ctrl+Enter submit). Add tests. Lazy-load if needed.
5. Wire `VariableValueInput` into `SecretItem` (fix Enter-semantics), `VariablesPopover`, and `EnvImportModal` (close the unvalidated-import gap).
6. Secret-reveal gating + type-switch value preservation + stable min-height polish.
7. Add `variableTypeHelpers.test.ts`. Run `npm test`, `npm run build`, and lint your changed files.

## Acceptance Criteria

1. Selecting each type in the add form renders the correct widget; the `string` path is visually and behaviorally unchanged.
2. For each type, the value submitted to the API equals what `validateVariableInput(type, value)` would have produced before this change (no contract drift) — verified by tests.
3. The JSON editor highlights JSON, shows inline errors for invalid JSON, and blocks save while invalid; Enter inserts a newline and Cmd/Ctrl+Enter (or the button) submits.
4. The tag input commits on Enter/comma, removes the last chip on Backspace, rejects duplicates/empties, flushes the pending buffer on submit, and emits a JSON array string.
5. The bool toggle is a `role="switch"` with `aria-checked`, keyboard-operable, and emits `"true"`/`"false"`.
6. The number input uses `inputmode="numeric"` + steppers, rejects non-numeric on blur, blocks save on invalid, and does not change value on scroll wheel.
7. Inline edit (`SecretItem`) renders the widget from the variable's fixed type; Enter no longer force-saves for json/list.
8. For secret variables, `json`/`list`/`number` rich editors appear only after reveal; the bool toggle always shows.
9. `EnvImportModal` no longer submits values that fail `validateVariableInput`.
10. All four call sites use the shared `VariableValueInput`.
11. New Vitest tests pass (`npm test`), the web build succeeds (`npm run build`), and changed files lint clean.
12. The PR description includes a one-line CodeMirror dependency justification per `CONSTITUTION.md` Article II.

## References

- Full evaluation: `prompts/gridctl/rich-type-editors/feature-evaluation.md`
- CodeMirror lint: https://codemirror.net/examples/lint/
- @uiw/react-codemirror: https://github.com/uiwjs/react-codemirror
- W3C APG switch pattern: https://www.w3.org/WAI/ARIA/apg/patterns/switch/
- GOV.UK on input type=number: https://technology.blog.gov.uk/2020/02/24/why-the-gov-uk-design-system-team-changed-the-input-type-for-numbers/
- Inline validation UX: https://smart-interface-design-patterns.com/articles/inline-validation-ux/
- NN/g input steppers: https://www.nngroup.com/articles/input-steppers/
- Retool input components (reference for the widget-per-type model): https://retool.com/blog/new-input-ui-component-library
