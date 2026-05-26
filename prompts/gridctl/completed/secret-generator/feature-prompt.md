# Feature Implementation: Secret Generator

## Context

**gridctl** is a Go-based MCP (Model Context Protocol) gateway with a built-in skill
library, currently at v0.1.0-beta.9. This feature lives entirely in its **web UI**
(`web/`), a modern React stack:

- **React 19** + **TypeScript 6** (strict; `import type` required by `verbatimModuleSyntax`)
- **Vite 8** build, **Vitest 4** + **@testing-library/react** for tests (jsdom)
- **Tailwind CSS 4** with custom theme tokens (`text-text-primary`, `text-text-muted`,
  `surface`, `surface-elevated`, `border`, `status-error`, `primary`, etc.) composed via
  a `cn()` helper (`web/src/lib/cn.ts`)
- **Zustand 5** for state, **lucide-react** for icons
- No UI component library (no Radix/shadcn/headless-ui), **no popover/floating library**,
  **no crypto/random library** — and the team prefers to keep it that way.

The "Variables workspace" (the **VaultWorkspace**; the store/hooks retain the historic
`useVaultStore`/`useVaultManager` names) lets users create/edit **variables** — secrets,
API keys, tokens, and plaintext config values. Each variable has a `key`, a `value`, a
`type` (`'string' | 'json' | 'list' | 'number' | 'bool'`), and an `is_secret` flag.
Values are sent as opaque plaintext strings to the Go backend; encryption-at-rest is
server-side. **This feature requires no backend changes.**

## Evaluation Context

Key findings from the feature-scout evaluation that shaped this prompt:

- **Closest competitor validates the approach.** Doppler ships in-field secret
  generation done **client-side via the Web Crypto API**. Most peers (GCP, GitHub
  Actions, Vercel, Infisical) have no generator at all. Password managers (Bitwarden
  especially) are the UX reference. This is a "catch up to the leader, leap ahead of the
  rest" feature.
- **Build, don't add a dependency.** The on-brand npm packages are stale or don't run
  in-browser. The correct primitive is native: `crypto.getRandomValues` + rejection
  sampling (~30 lines). gridctl's `web/` has zero crypto deps; keep it that way.
- **There is no "Add/Edit modal."** Value entry happens in **three inline sites** (see
  Integration Points). This was the spec's main inaccuracy.
- **UI decision (confirmed with the user): inline disclosure panel + action-row trigger,
  NOT a floating popover.** The wizard's `VariablesPopover` is itself a portal popover
  whose outside-click handler checks only its own refs; a nested floating popover would
  close the wizard form mid-edit. An inline panel sidesteps this and makes covering all
  three sites cheap. (See ASCII mockup under UX Specification.)
- **Scope decision (confirmed with the user): all three sites, full features** — length
  slider, character-class toggles, live entropy display, regenerate, copy-to-clipboard.
- **Risk mitigation baked in:** modulo bias is the one place a subtle bug becomes a real
  security defect — rejection sampling is a hard requirement (CONSTITUTION Article XII,
  "Secure Defaults").

Full evaluation: `prompts/gridctl/secret-generator/feature-evaluation.md`

## Feature Description

Add a built-in **secret generator** to the Variables workspace. A wand/dice trigger
sits in the action row beside each variable value input. Activating it expands an inline
panel with generation controls (length, character classes, symbols). Clicking "Generate"
fills the value input with a cryptographically secure random string and reveals it.

This removes a context-switch: users currently leave gridctl to generate strong secrets
in a password manager or `openssl rand`, then paste them back. It benefits anyone
creating secret-type variables — the hot path of the app's most-used workspace.

## Requirements

### Functional Requirements

1. A **wand trigger** (lucide `Wand2`, or `Dices` if preferred) appears in the existing
   action row beneath the value input at all three integration sites (see Integration
   Points), styled to match the existing in-row Eye-toggle buttons (`size={12}`,
   `text-text-muted hover:text-primary`).
2. The trigger is shown **only when the variable `type === 'string'`** (a random string
   is meaningless for number/bool/json/list and would fail `validateVariableInput`).
   It shows for both secret and plaintext strings; do **not** gate on `is_secret`.
3. Activating the trigger toggles an **inline disclosure panel** (not a floating
   popover) rendered in normal document flow directly below the input.
4. The panel exposes:
   - **Length** control (slider or number input), range **8–64**, default **24**, with
     the numeric value visible.
   - **Character-class toggles**: `A-Z`, `a-z`, `0-9`, symbols (`!@#…`). All **on** by
     default. At least one class must remain enabled (disable the last active toggle so
     the alphabet can never be empty).
   - A **live entropy indicator**: `length × log₂(alphabetSize)`, displayed as e.g.
     `~143 bits`, recomputed as length/classes change.
   - A primary **Generate** button.
   - A **copy-to-clipboard** affordance for the generated value.
5. **Generate** computes a secure random string from the current settings and writes it
   to the value input via the site's existing setter, then **auto-reveals** the value
   (sets the site's show/reveal state to visible).
6. Clicking Generate again **regenerates** with the current settings (the same button
   serves as regenerate; optionally relabel to "Regenerate" once a value exists).
7. The panel **stays open** after generating (so the user can regenerate or tweak), is
   **collapsed by default**, and collapses on `Escape` or outside interaction.
8. Generation is **fully client-side** — the value never leaves the browser before the
   user submits the form through the existing create/update path.

### Non-Functional Requirements

1. **Cryptographic correctness (hard requirement):** use `crypto.getRandomValues`. Map
   bytes to the alphabet with **rejection sampling** — `max = 256 - (256 % alphabet.length)`,
   discard any byte `>= max`, index with `byte % alphabet.length`. **Never** use
   `Math.random`, and **never** use a raw `% alphabet.length` on an unfiltered byte
   (modulo bias). Aligns with CONSTITUTION Article XII.
2. **No new dependencies.** Native Web Crypto + lucide icons only.
3. **Accessibility:** the trigger is a real `<button type="button">` with `aria-label`,
   `aria-expanded`, and `aria-controls` referencing the panel. Class toggles use
   `role="group"` + `aria-pressed` (mirror `VariableSecretToggle`). An
   `aria-live="polite"` region announces **metadata only** — e.g. "Generated a 24-character
   value, ~143 bits of entropy" — **never** the secret characters. The slider exposes
   `aria-valuetext` like "24 characters".
4. **No secret leakage:** never log, toast, or otherwise emit the generated value's
   characters (the copy action writes to the clipboard only; its toast says "Copied", not
   the value). Don't persist generated values to `localStorage`/`sessionStorage` or
   long-lived state.
5. **Escape handling:** the panel's `Escape` handler must `stopPropagation` so it
   doesn't also cancel the wizard popover or the SecretItem inline edit (whose input
   already binds `Escape` → `onEditCancel`).
6. **Lint hygiene:** keep new/changed files lint-clean. In particular, avoid synchronous
   `setState` inside any `useEffect` (the repo's `react-hooks/set-state-in-effect` rule
   is active). Note `npm run lint` has pre-existing repo-wide failures unrelated to this
   work — lint only your changed files.
7. **Type safety:** strict TS, `import type` for type-only imports.

### Out of Scope

- Passphrase / diceware (word-based) generation mode.
- Encoding/format presets (hex/base64/base64url) and "preset modes" (password vs API key
  vs token). String + class toggles only for v1.
- "Require at least N of each class" minimum-count policy.
- Exclude-ambiguous-characters toggle, exclude-custom-characters, pattern templates,
  saved generator profiles.
- Have-I-Been-Pwned / breach checks.
- Any backend, API, or Go changes.
- Generation for non-`string` variable types.

## Architecture Guidance

### Recommended Approach

Build **two new units** and wire them into three existing components:

1. **`web/src/lib/generateSecret.ts`** — a pure, dependency-free util. Export something
   like:
   ```ts
   export interface SecretOptions {
     length: number;
     upper: boolean;
     lower: boolean;
     digits: boolean;
     symbols: boolean;
   }
   export function buildAlphabet(opts: SecretOptions): string;
   export function generateSecret(opts: SecretOptions): string; // crypto.getRandomValues + rejection sampling
   export function entropyBits(length: number, alphabetSize: number): number; // length * log2(size)
   ```
   This is the easiest unit to test exhaustively and the one place correctness matters
   most.

2. **`web/src/components/vault/SecretGenerator.tsx`** — a single shared component used by
   all three sites. Props roughly:
   ```ts
   interface SecretGeneratorProps {
     onGenerate: (value: string) => void; // writes to the site's value setter
     onReveal?: () => void;               // ask the site to reveal the value
     iconSize?: number;                   // sites differ: 12 vs 10
     className?: string;
   }
   ```
   It owns the trigger button, the open/closed disclosure state, the length/class state,
   the entropy display, Generate/regenerate, and copy. Render the panel inline (normal
   flow), not via `createPortal`. Each consuming site passes its own value setter and
   reveal callback.

Keep the component self-contained so the three wirings are near-identical (the only
per-site variance is `iconSize` and which existing row the trigger mounts into).

### Key Files to Understand

Read these first:

- `web/src/components/vault/VariableQuickAddForm.tsx` — primary Add form. Value in
  `newValue`/`setNewValue`, reveal in `showValue`/`setShowValue`; action row at the
  `flex flex-wrap items-center gap-2` block (type + secret toggle). Trigger mounts here.
- `web/src/components/vault/SecretItem.tsx` — inline **edit** form (the `isEditing`
  branch). Value via `editValue`/`onEditValueChange` props; reveal via
  `showEditValue`/`onEditToggleShow`; action row is the Cancel/Save `flex justify-end`
  block. Note its input already binds `Escape` → `onEditCancel`.
- `web/src/components/wizard/VariablesPopover.tsx` — wizard "Create New Variable"
  sub-form. Value in `newValue`/`setNewValue`, reveal in `showValue`. **This is itself a
  portal popover** with an outside-click handler (around lines 86–99) checking only
  `triggerRef`/`dropdownRef` — the reason the generator must be an inline panel, not a
  nested popover. Trigger mounts in the `flex flex-wrap gap-1` toggle rows.
- `web/src/components/vault/VariableSecretToggle.tsx` — segmented-toggle visual language
  to reuse for the class chips.
- `web/src/components/vault/variableTypeHelpers.ts` — `validateVariableInput`; confirms a
  generated `string` passes validation unchanged.
- `web/src/components/workspaces/VaultWorkspace.tsx` — owns the edit state
  (`editValue`/`showEditValue`) passed down to `SecretItem`; relevant if SecretItem needs
  a `setShowEditValue(true)` path for auto-reveal.

### Integration Points

| Site | File | Value setter | Reveal setter for auto-reveal |
|------|------|--------------|-------------------------------|
| Add (primary) | `VariableQuickAddForm.tsx` | `setNewValue` | `setShowValue(true)` |
| Add (wizard) | `wizard/VariablesPopover.tsx` | `setNewValue` | `setShowValue(true)` |
| Edit (inline) | `vault/SecretItem.tsx` | `onEditValueChange` | `onEditToggleShow` is a toggle — call it only when currently hidden, or thread a `setShowEditValue(true)` from `VaultWorkspace` |

At each site: render `<SecretGenerator>` in the existing action row, gated on
`type === 'string'`. Wire `onGenerate` to the value setter and `onReveal` to the reveal
setter. **Do not modify the value `<input>` markup or its `pr-*` padding** — the inline
panel sits below the input/row, so the input's right slot (Eye toggle) is untouched.

### Reusable Components

- `cn()` from `web/src/lib/cn.ts` for class composition.
- `Button` from `web/src/components/ui/Button.tsx` for the Generate action
  (`variant="primary" size="sm"`).
- The Eye-toggle button styling already in each site for the trigger's look.
- Clipboard + toast: `navigator.clipboard.writeText(value)` then `showToast('success',
  'Copied')` — pattern in `web/src/components/wizard/steps/ReviewStep.tsx` (~line 76).
- `VariableSecretToggle` as the visual template for class chips.
- Do **not** use `IconButton` for the trigger — it's `p-2`/`size 14–16`, too large for
  the dense in-row contexts.

## UX Specification

```
┌──────────────────────────────┐
│ KEY_NAME                     │
│ ┌──────────────────────────┐ │
│ │ ••••••••••••       👁  │ │   ← value input UNCHANGED (eye toggle stays)
│ └──────────────────────────┘ │
│ 🪄 [string ▾] [secret ▾]     │   ← wand trigger in the EXISTING action row
│ ┌── generate ────────────┐   │
│ │ Length  [——●——] 24     │   │   ← inline disclosure panel (normal flow)
│ │ ☑A-Z ☑a-z ☑0-9 ☑!@#    │   │
│ │ ~143 bits   [Generate] │   │
│ └────────────────────────┘   │
└──────────────────────────────┘
```

- **Discovery:** the wand sits in the action row that already exists below the value
  input; visible only for `type === 'string'`.
- **Activation:** click the wand → the inline panel expands below (the wand reflects
  `aria-expanded`). Click again or `Escape` → collapse.
- **Interaction:** adjust length/classes (entropy updates live) → click **Generate** →
  the value input fills and reveals; the panel stays open. Click Generate again to roll a
  new value. A copy button copies the value to the clipboard.
- **Feedback:** generated value appears (revealed) in the value input; entropy line shows
  bits; `aria-live` announces metadata only; copy shows a "Copied" toast.
- **Error states:** the alphabet can never be empty (≥1 class enforced), so Generate is
  always valid when shown. If `navigator.clipboard` is unavailable, fail quietly (no
  toast / a neutral message) — do not surface the value in an error.

## Implementation Notes

### Conventions to Follow

- Functional components, hooks, `import type` for types, `cn()` for classes, lucide for
  icons, theme tokens (no raw hex unless matching an existing inline pattern).
- Match the existing dense sizing in these components (`text-[10px]`/`text-xs`,
  `size={10–12}` icons, `rounded-lg`, `px-2/px-3 py-1/py-1.5`).
- Comments concise and meaningful; don't over-explain.

### Potential Pitfalls

- **Modulo bias** — the headline correctness risk. Use rejection sampling; add a unit
  test asserting roughly uniform distribution and that no out-of-alphabet chars appear.
- **Portal-in-portal** — do not render the panel with `createPortal`. Inline only.
- **SecretItem auto-reveal** — `onEditToggleShow` is a *toggle*, not a setter. Calling it
  when already revealed would hide the value. Call it only when `showEditValue` is false,
  or add a dedicated `setShowEditValue(true)` path from `VaultWorkspace`.
- **Escape propagation** — `stopPropagation` on the panel's Escape so it doesn't also
  cancel the wizard popover or the inline edit.
- **`set-state-in-effect` lint rule** — avoid synchronous `setState` in `useEffect`. The
  inline panel shouldn't need positioning effects (that's the point), so this is mostly
  about any open/close or focus effects you add.
- **Don't leak the value** — no logging/toasting of the characters; metadata only.

### Suggested Build Order

1. `web/src/lib/generateSecret.ts` + unit tests (`buildAlphabet`, `generateSecret`,
   `entropyBits`; assert no modulo bias, no empty alphabet, length honored).
2. `web/src/components/vault/SecretGenerator.tsx` + component tests (toggle open, adjust
   length/classes, entropy updates, Generate calls `onGenerate`/`onReveal`, ≥1 class
   enforced, copy calls clipboard, Escape collapses).
3. Wire into `VariableQuickAddForm.tsx` (simplest site) and add a test for that wiring
   (the form has no test file yet — add one).
4. Wire into `SecretItem.tsx` (handle auto-reveal toggle nuance) and update its test.
5. Wire into `wizard/VariablesPopover.tsx` (verify the wizard popover does NOT close when
   interacting with the inline panel) and update its test.
6. Run `npm run build` (tsc + vite) and the Vitest suites for changed files; ensure new
   files are lint-clean.
7. Add a `web/CHANGELOG.md` `[Unreleased]` entry following existing conventions.

## Acceptance Criteria

1. `generateSecret` uses `crypto.getRandomValues` with rejection sampling; a distribution
   test shows no modulo bias and never emits characters outside the selected alphabet.
2. The wand trigger appears in the action row of all three sites **only** when
   `type === 'string'`, styled consistently with existing in-row buttons.
3. Clicking the trigger expands an inline panel (no portal) with length (8–64, default
   24), four class toggles (all default on, ≥1 always enforced), a live `~N bits` entropy
   readout, and a Generate button.
4. Generate fills the value input with a secure string and auto-reveals it; the panel
   stays open; clicking Generate again produces a different value.
5. A copy control writes the value to the clipboard and shows a "Copied" toast (no value
   in the toast/logs).
6. In the wizard, interacting with the panel (toggles, slider, Generate, copy) does
   **not** close the `VariablesPopover` form.
7. Default add/edit/paste flows are unchanged: value inputs keep their markup and
   padding, and the panel is collapsed by default.
8. a11y: trigger has `aria-label`/`aria-expanded`/`aria-controls`; class toggles use
   `role="group"`/`aria-pressed`; an `aria-live` region announces metadata only; `Escape`
   collapses the panel without cancelling the surrounding edit/wizard.
9. No new dependencies added to `web/package.json`.
10. `npm run build` passes; new/changed files are lint-clean; Vitest suites for the new
    util, the new component, and the three wired components pass.
11. A `web/CHANGELOG.md` `[Unreleased]` entry is added.

## References

- Doppler secret generation (closest analog, client-side Web Crypto): https://docs.doppler.com/docs/secret-generation
- Bitwarden generator (option-vocabulary reference): https://bitwarden.com/help/generator/
- MDN — Crypto.getRandomValues(): https://developer.mozilla.org/en-US/docs/Web/API/Crypto/getRandomValues
- Hanno Böck — secure password in JS (rejection-sampling formula): https://blog.hboeck.de/archives/907-How-to-create-a-Secure,-Random-Password-with-JavaScript.html
- joepie91 — Secure random values in JavaScript/Node.js: https://gist.github.com/joepie91/7105003c3b26e65efcea63f3db82dfba
- OWASP — Insecure Randomness (why not Math.random): https://owasp.org/www-community/vulnerabilities/Insecure_Randomness
- NIST SP 800-63B (length/entropy guidance): https://pages.nist.gov/800-63-3/sp800-63b.html
- nanoid (reference implementation of getRandomValues + rejection sampling): https://github.com/ai/nanoid
- Mozilla — preventing secrets leaking through the clipboard: https://blog.mozilla.org/security/2021/12/15/preventing-secrets-from-leaking-through-clipboard/
