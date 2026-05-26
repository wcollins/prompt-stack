# Feature Evaluation: Secret Generator

**Date**: 2026-05-23
**Project**: gridctl
**Recommendation**: Build
**Value**: Medium (high strategic alignment, broad reach, shallow per-use benefit)
**Effort**: Small–Medium

## Summary

A client-side secret generator for the gridctl Variables workspace: a wand trigger
opens an inline panel (length, character-class toggles, live entropy) that populates
the value input with a cryptographically secure random string. It removes a
context-switch from the most actively developed surface in the app, requires zero
backend changes and zero new dependencies, and brings gridctl to parity with its
closest competitor (Doppler) while putting it ahead of most peers. **Build it.**

## The Idea

A built-in utility to generate cryptographically secure random strings for passwords,
API keys, and tokens directly within the variable creation/edit flow. A wand/dice
trigger sits beside the value input; activating it reveals controls for generation
criteria (length, alphanumeric classes, symbols); generating populates the value
field with a secure string.

**Problem it solves:** Today, a user creating a secret variable must leave gridctl,
generate a strong value in an external tool (password manager, `openssl rand`, an
online generator), then paste it back. This is a small but real context-switch in the
hot path of the app's most-used workspace.

**Who benefits:** Anyone creating secret-type variables — broadly, most gridctl users —
each time they need a fresh credential. Benefit is broad but shallow per use.

## Project Context

### Current State

gridctl is a Go-based MCP gateway with a built-in skill library, currently at
**v0.1.0-beta.9**. The web UI (`web/`) is a healthy, modern stack: **React 19 +
TypeScript 6 (strict) + Tailwind 4 + Vite 8**, tested with **Vitest 4 + Testing
Library** (strong coverage), state via **Zustand 5**, icons via **lucide-react**.

The "Variables workspace" referenced in the request is the **VaultWorkspace**
(recently renamed Vault → Variables in the UI vocabulary; the store/hooks keep the
historic `useVaultStore`/`useVaultManager` names). It is the single most actively
developed surface in the codebase — **4 of the last 5 commits touch it** (drag-and-drop
import, recently-edited indicator, usage surfacing).

### Integration Surface

**Critical reality vs. the spec:** there is **no "Add/Edit modal."** Variable value
entry happens in **three inline locations**, all sharing one pattern — a
`relative`-wrapped `<input type={show ? 'text' : 'password'}>` with an Eye/EyeOff
reveal button absolutely positioned inside it:

| Surface | File | Value state |
|---------|------|-------------|
| Add (primary) | `web/src/components/vault/VariableQuickAddForm.tsx` | `newValue` / `setNewValue` |
| Add (wizard) | `web/src/components/wizard/VariablesPopover.tsx` | `newValue` / `setNewValue` |
| Edit (inline) | `web/src/components/vault/SecretItem.tsx` | `editValue` / `onEditValueChange` (lifted to `VaultWorkspace`) |

Values are sent as **opaque plaintext strings** to the Go backend via
`createVariable`/`updateVariable` in `web/src/lib/api.ts` (`POST/PUT /api/var`).
Encryption-at-rest is server-side. A generated value flows through this unchanged path
as any typed value would — **no backend work is needed.** It is type `string` and
passes `validateVariableInput` (`variableTypeHelpers.ts`) trivially.

### Reusable Components

- **`web/src/components/wizard/VariablesPopover.tsx`** — the canonical hand-rolled
  portal popover (fixed positioning, flip logic, outside-click). Reference for any
  floating UI, and the source of the portal-in-portal hazard (see below).
- **`web/src/components/vault/VariableSecretToggle.tsx`** — segmented toggle visual
  language to reuse for the character-class chips (`role="group"`, `aria-pressed`).
- **`web/src/components/ui/Button.tsx`** — primary action button for "Generate".
- **`web/src/components/ui/IconButton.tsx`** — exists but is `p-2`/`size 14–16`, too
  large for the dense in-row contexts; mirror the existing Eye-toggle button styling
  instead (`size={10–12}`, `text-text-muted hover:text-primary`).
- **`web/src/hooks/useFocusTrap.ts`** — available (not needed for the chosen inline
  disclosure approach).
- **Clipboard + toast** pattern: `navigator.clipboard.writeText` + `showToast`, as in
  `web/src/components/wizard/steps/ReviewStep.tsx:76`.
- **`web/src/lib/cn.ts`** — Tailwind class-merge helper used throughout.

There is **no existing crypto/random utility** — `Math.random()` appears once (a
non-security wizard session ID). The generator's core must be built new with
`crypto.getRandomValues`.

### Health Signals

- **GREEN.** The Variables area is the best-tested, most-active part of the codebase
  (`VaultWorkspace.test.tsx`, `VariablesPopover.test.tsx`, `SecretItem.test.tsx`, etc.).
- **Lint caveat:** `npm run lint` has ~40 pre-existing errors (notably the new
  `react-hooks/set-state-in-effect` rule from a recent `eslint-plugin-react-hooks`
  bump) unrelated to this feature. Per project convention, lint only changed files and
  keep new code clean. Avoid synchronous `setState` inside any `useEffect`.

## Market Analysis

### Competitive Landscape

- **Doppler** ships almost exactly this: in-dashboard secret generation (Random Value
  in Base62/Hex/Base64/Base64URL, symmetric keys, key pairs), sized by entropy,
  generated **client-side via the Web Crypto `SubtleCrypto` API**. The closest analog
  to the proposed feature, and validation of both the UX and the "Web Crypto, no
  library" approach.
- **HashiCorp Vault**: generation via server-side password *policies* (length +
  per-class minimums), not an in-form affordance — but the same option vocabulary.
- **AWS Secrets Manager**: server-side `GetRandomPassword` (API/CLI only), with
  exclude-class semantics and `RequireEachIncludedType`.
- **GCP Secret Manager, GitHub Actions secrets, Vercel env vars, Infisical (static)**:
  **no built-in generator** — manual entry only.
- **Password managers** (Bitwarden, 1Password, Dashlane, KeePass, Chrome/Apple): inline
  generation is table-stakes. Bitwarden is the best **option-vocabulary** reference
  (length slider; class toggles; minimum numbers/special; avoid-ambiguous; passphrase
  mode). Chrome/Apple represent the "smart default, no knobs" end.

### Market Positioning

**Catch up / leap ahead.** Among direct peers, only Doppler ships in-field generation;
GCP/GitHub/Vercel/Infisical have nothing. Building this puts gridctl at parity with the
leader and ahead of the rest. Among password managers it is plainly table-stakes.

### Ecosystem Support

The correct primitive is **native**: `crypto.getRandomValues` + rejection sampling.
Library survey conclusion: **don't add a dependency.**
- `generate-password` (739K weekly DLs) does **not** work in-browser without a polyfill
  and is stale (2023).
- `secure-random-password` works in-browser but is unmaintained (2021) and ~40 KB.
- `crypto-random-string` v5 is Node-targeted ESM; poor browser fit.
- `nanoid` (zero-dep, browser-first, uses Web Crypto + rejection sampling internally)
  is the only one worth considering — but it saves ~10 lines and gridctl's `web/` has
  zero crypto deps the team wants to keep that way.
- `@scure/bip39` (audited) only matters if a future **passphrase/diceware** mode is added.

### Demand Signals

In-app secret generation is an expected feature in developer secrets tooling: Doppler
ships it, password managers treat inline generation as baseline, GitHub-style
"Generate" buttons for tokens are familiar, and standalone `.env` secret-key generator
tools/repos exist precisely because developers seek this micro-feature. Low risk, high
recognition.

## User Experience

### Interaction Model

- **Discovery/activation:** a wand (or dice) trigger in the **action row that already
  exists** below each value input (the type/secret-toggle row in QuickAddForm and
  VariablesPopover; the Cancel/Save row in SecretItem edit). **Not** crammed into the
  input's right slot next to the Eye toggle.
- **Surface:** clicking the wand expands an **inline disclosure panel** (length, class
  toggles, entropy, Generate) — **not a floating popover**.
- **Gating:** show the wand only when `type === 'string'`. Show for both secret and
  plaintext strings; do not gate on `is_secret`.
- **Flow:** Generate populates the value input directly, **auto-reveals** it, keeps the
  panel open for regenerate/tweak, and offers copy-to-clipboard. Collapsed by default,
  so the paste-your-own-value flow is untouched.

### Workflow Impact

Zero added friction to the common case (typing/pasting a known value): the value input
is unchanged, the panel is collapsed by default and opt-in, and the wand is hidden for
non-string types. Pure additive convenience.

### UX Recommendations

- **Inline panel, not popover** — the deciding factor. The wizard's `VariablesPopover`
  is itself a portal popover whose outside-click handler checks only `triggerRef`/
  `dropdownRef`; a nested floating popover would register clicks as "outside" and close
  the wizard form mid-edit. An inline disclosure (like SecretItem's own expand pattern)
  sidesteps this entirely and works identically in all three sites — which is what
  makes covering all three cheap.
- **Defaults:** length **24** (range 8–64), all four classes on (A-Z / a-z / 0-9 /
  symbols), symbols included by default for a secrets tool. Enforce ≥1 class on.
- **Strength = entropy bits** (`length × log₂(alphabetSize)`), shown live — honest for
  CSPRNG output, no dependency. Avoid a zxcvbn-style "weak/strong" meter.
- **a11y:** wand is a real `<button>` with `aria-label`, `aria-expanded`, `aria-controls`;
  `aria-live="polite"` announces **metadata only** ("Generated a 24-character value,
  ~143 bits") — never the secret characters; `Escape` collapses the panel and
  `stopPropagation`s so it doesn't also cancel the wizard/edit.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Minor–Significant | Removes a context-switch; convenience, not a blocking pain |
| User impact | Broad + Shallow | Most users create secrets; small per-use saving |
| Strategic alignment | Core–Adjacent | gridctl is a variables/secrets tool; this is its hottest surface |
| Market positioning | Catch up | Parity with Doppler; ahead of GCP/GitHub/Vercel/Infisical |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Zero backend; one shared component into 3 existing rows |
| Effort estimate | Small–Medium | ~30-line crypto util + small component + 3 wirings + tests |
| Risk level | Low | Client-side only, populates an input; no data-integrity risk. Sole caveat: modulo bias (mitigated by rejection sampling) |
| Maintenance burden | Minimal | Self-contained, no new deps |

## Recommendation

**Build.** This is a low-risk, modest-effort feature with strong strategic alignment —
gridctl is fundamentally a variables/secrets tool, and the Variables workspace is its
most actively developed surface. It requires **no backend changes and no new
dependencies**, is validated by the closest competitor (Doppler does precisely this,
client-side via Web Crypto), and is table-stakes among the best peers. The per-use
benefit is shallow but the reach is broad and the cost is small.

Two **approach refinements** (decided with the user, not value caveats) shape the build:

1. **Inline disclosure panel + action-row trigger**, not a floating popover in the
   input slot. This is the key decision: it avoids the portal-in-portal bug in the
   wizard, requires no value-input re-spacing, and makes covering all three sites cheap.
2. **All three integration sites in v1, full features** (length slider, class toggles,
   live entropy, regenerate, copy-to-clipboard).

The one place to be careful is **cryptographic correctness**: use
`crypto.getRandomValues` with **rejection sampling** (`max = 256 - (256 % alphabet.length)`,
discard bytes `>= max`) — never `Math.random` and never a raw `% alphabet.length`
(modulo bias). This aligns with CONSTITUTION Article XII ("Secure Defaults") and is the
only spot where a subtle bug would be a genuine security defect.

## References

- Doppler secret generation: https://docs.doppler.com/docs/secret-generation
- HashiCorp Vault password policies: https://developer.hashicorp.com/vault/docs/concepts/password-policies
- AWS GetRandomPassword API: https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetRandomPassword.html
- GCP Secret Manager: https://cloud.google.com/secret-manager/docs/creating-and-accessing-secrets
- GitHub Actions secrets: https://docs.github.com/en/actions/concepts/security/secrets
- Vercel sensitive env vars: https://vercel.com/docs/environment-variables/sensitive-environment-variables
- 1Password CLI item create (password recipe): https://developer.1password.com/docs/cli/item-create/
- Bitwarden generator (options): https://bitwarden.com/help/generator/
- Dashlane password generator: https://support.dashlane.com/hc/en-us/articles/202625022
- KeePass password generator: https://keepass.info/help/base/pwgenerator.html
- Chromium password generation design: https://www.chromium.org/developers/design-documents/password-generation/
- MDN — Crypto.getRandomValues(): https://developer.mozilla.org/en-US/docs/Web/API/Crypto/getRandomValues
- Hanno Böck — secure password in JS (rejection sampling): https://blog.hboeck.de/archives/907-How-to-create-a-Secure,-Random-Password-with-JavaScript.html
- joepie91 — Secure random values in JavaScript: https://gist.github.com/joepie91/7105003c3b26e65efcea63f3db82dfba
- OWASP — Insecure Randomness: https://owasp.org/www-community/vulnerabilities/Insecure_Randomness
- NIST SP 800-63B: https://pages.nist.gov/800-63-3/sp800-63b.html
- nanoid (reference implementation): https://github.com/ai/nanoid
- Mozilla — preventing secrets leaking through clipboard: https://blog.mozilla.org/security/2021/12/15/preventing-secrets-from-leaking-through-clipboard/
