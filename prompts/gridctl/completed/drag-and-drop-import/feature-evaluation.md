# Feature Evaluation: Drag-and-Drop Import

**Date**: 2026-05-23
**Project**: gridctl
**Recommendation**: Build (with a scoped approach)
**Value**: Medium
**Effort**: Small (`.env`) / Small–Medium (`+ .json`)

## Summary

Add a drag-activated, full-page dropzone overlay to the Variables workspace so dragging a `.env`/`.json` file anywhere over the page surfaces an overlay, and dropping it opens the existing import modal pre-populated with the parsed file for review before saving. The import flow, the `.env` parser, and even basic in-modal drag-drop already exist — the genuine new work is the page-level overlay, the auto-open + pre-populate wiring, and (if kept in scope) a new client-side `.json` parser. It's low-risk friction-reduction/polish that lands squarely in the most actively-developed area of the product, so it clears the bar comfortably despite being a convenience rather than a must-have.

## The Idea

Make the existing import functionality more discoverable and frictionless via native drag-and-drop. Dragging a valid file over the Variables page triggers a visual dropzone overlay; dropping it opens the import wizard pre-populated with parsed keys/values for review before saving. Beneficiaries: anyone onboarding variables into gridctl from an existing `.env`/`.json` file — primarily during initial setup or when migrating from another tool.

**Two corrections to the original premise, established during analysis:**
1. **`.json` import does not exist in the web UI today.** It exists only in the CLI (`cmd/gridctl/var.go` → `parseVariablesJSON`). The web modal parses `.env` only (`web/src/lib/envParser.ts`), and the file picker's `accept` is `.env,text/plain`. UI `.json` support is net-new parser work, not plumbing.
2. **Discoverability is already fairly high.** Import is a primary "Import .env" header button *and* the headline empty-state CTA, and the modal subtitle already reads "paste · drop · pick a .env file." So this is friction-reduction and a distinctive UX touch, not unlocking a buried capability.

## Project Context

### Current State
gridctl is an MCP gateway + skill library: a Go CLI/daemon backend with a React 19 + TypeScript + Vite 8 web UI (Zustand state, Tailwind v4 design tokens, react-router-dom v7, lucide icons; no UI-kit, hand-rolled native patterns). The web UI is officially "Stable" but internal with "no API guarantee" (`docs/project-status.md`), so it can iterate freely. The Variables (Vault) workspace is the single hottest area of the codebase — the last ~15 PRs are variable-focused (unified store, usage indexing, recently-edited indicators), with commits through the evaluation date. The feature lands directly in the active development path.

### Integration Surface
- `web/src/components/workspaces/VaultWorkspace.tsx` (1,079 lines) — the Variables page; owns `importOpen` state (`:142`), mounts `EnvImportModal` conditionally (`:596`), the workspace root `<div>` (`:381`) is the natural attach point, header import button (`:670`), empty-state CTA + caption slot (`:1022`, `:1035`), locked gating (`:416`, `:668`).
- `web/src/components/vault/EnvImportModal.tsx` (533 lines) — the import modal; `EnvImportModalProps` (`:31`) has **no** `initialText`/`initialFile`; `text` state inits to `''` (`:98`); `handleFile` **appends** to existing text (`:152`); existing in-modal dropzone cue (`:290`); focus trap (`:93`); dialog a11y (`:226`).
- `web/src/lib/envParser.ts` — `parseEnv()` (`:45`); `.env`-only, no JSON path. A `.json` parser would live alongside it.
- `web/src/components/ui/Toast.tsx` — `showToast(type, message)` (`:27`), already used throughout VaultWorkspace; `ToastContainer` mounted in AppShell (`:159`).
- `web/src/hooks/useFocusTrap.ts` — initial-focus + restore convention the auto-opened modal already follows.
- `cmd/gridctl/var.go` — `parseVariablesJSON` (`~:719`) — reference for any UI `.json` parser (legacy `{"KEY":"value"}` map + v2 `{"variables":[...]}` shapes).

### Reusable Components
The build is mostly reuse. The full parse → preview table → `POST /api/var/import` pipeline (`EnvImportModal` → `useVaultManager.importVars` → `api.importVariables`) is untouched. `handleFile` is already a `useCallback`. The modal's existing dashed-border dropzone cue is the visual template for the overlay. The toast hook, focus trap, and `animate-fade-in-scale` entrance animation all already exist.

### Health Signals
Modern/maintained deps (React 19.2, Vite 8, Vitest 4.1, Tailwind 4.1, Zustand 5); zero TODO/FIXME/`any`/`@ts-ignore` in the vault code; strong a11y conventions (`role="dialog"`, `aria-modal`, focus trap, Escape/backdrop close). Two friction points: `VaultWorkspace.tsx` is a large, state-dense file, and there is **no `EnvImportModal.test.tsx`** — jsdom won't fire native drag events, so new tests need synthetic `fireEvent.drop` with a mocked `dataTransfer` and a stubbed `File.prototype.text` (the `vitest.setup.ts` polyfill pattern shows how).

## Market Analysis

### Competitive Landscape
| Tool | `.env` | `.json` | Mechanism | Review step | Conflict handling |
|---|---|---|---|---|---|
| Doppler | Yes | Yes (+YAML) | Paste **or** drag file into modal field | — | — |
| Infisical | Yes | — | Drag-drop into a pane | — | — |
| 1Password Env | Yes | — | File-picker button | Yes — verify before save | — |
| Netlify | Yes | — | Paste into form | — | Yes — skip/update merge |
| Railway | Yes | Yes | Paste into RAW editor | — | per-editor |
| Render / Fly / Vault / Heroku | partial / CLI | — | varies | — | — |

### Market Positioning
Bulk `.env` import is **table-stakes** in this category — a vault tool without it is the outlier. Drag-and-drop *specifically* is a **modest differentiator**: only Doppler and Infisical do real file drag-drop, and both are scoped to a field/pane, not a full-page overlay. A full-page dropzone would be more aggressive than anything documented. Crucially, the category's most under-served capability is the **review/preview-before-save modal with conflict handling and secret-by-default** — only 1Password and Netlify do anything close, and gridctl's `EnvImportModal` already exceeds both. The drag gesture is polish on top of an already category-leading core. `.json` support puts gridctl with Doppler/Railway, ahead of the `.env`-only crowd.

### Ecosystem Support
Native HTML5 (DataTransfer, `File.text()`, dragover/drop) is sufficient — the repo already has working native drop code. `react-dropzone` (v15, ~10.9M weekly downloads, ~10–12 KB gz) is the de-facto library but solves multi-file/upload-progress problems this single-file parse flow doesn't have, and adding it would violate the codebase's deliberate no-dependency house style. Reference implementations: MDN "File drag and drop" (canonical window-level handling), the enter/leave counter pattern (Dragster) for flicker.

### Demand Signals
No explicit user-demand artifact was found; this is a polish/discoverability improvement on a feature that already works. The signal is indirect: the Variables workspace is under heavy active development, and competitors increasingly ship file-based import, so it fits both internal momentum and category direction.

## User Experience

### Interaction Model
1. `dragenter`/`dragover` detects a drag carrying files — gated on `e.dataTransfer.types.includes('Files')` so react-resizable-panels separators and react-flow node drags (no files) never trigger it.
2. A drag-activated, full-page overlay appears (invisible at rest), scaling up the modal's existing cue: `border-2 border-dashed border-primary/50`, `bg-primary/5 text-primary`, `Upload` icon, `bg-background/80 backdrop-blur-sm`, `animate-fade-in-scale`.
3. On drop: `preventDefault`, take the first file, read its text, **validate before opening**.
4. Open `EnvImportModal` pre-seeded via a new optional `initialText?` prop (reading the file in the workspace keeps the modal surface small and lets validation happen pre-modal).
5. Review → save reuses the existing pipeline unchanged.

### Workflow Impact
Net friction reduction. The header button and empty-state CTA remain the primary, discoverable entry; the overlay is a drag-activated accelerator for users who already understand "drop a file here." No existing workflow is removed or changed.

### UX Recommendations
- **Hybrid, not pure full-page.** Keep the modal's scoped dropzone + "Pick a file" input as the discoverable/accessible entry; the overlay is the accelerator layer.
- **Scope to the Variables workspace, not AppShell.** Workspaces are lazy-loaded, so VaultWorkspace-scoped listeners are inert elsewhere for free; an app-wide overlay would be a dead affordance over Topology/Library where no import target exists.
- **Discovery cue:** add one muted line to the empty-state caption (`text-[10px] text-text-muted`) — e.g. "…or drop a `.env` file anywhere on this page." No persistent banner in the populated state (consistent with the codebase's quiet, neutral surfaces — see the topology-edges-neutral precedent).
- **Errors via `showToast`, validated before opening:** multiple files → warn + import first; empty file → warn, don't open; wrong type → error, don't open.
- **A11y:** overlay is `aria-hidden`/decorative; the existing focusable file picker is the keyboard/SR path; auto-open hands focus to the existing `useFocusTrap` exactly as the button does.
- **Guardrails:** gate listeners on `!importOpen` (don't clobber in-progress edits — the modal's own dropzone handles mid-edit drops by appending) and `!locked` (locked vault hides import); use a drag-depth counter to kill `dragleave` flicker over the dense rail/table layout.

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Minor–Moderate | Import is already discoverable; this polishes/reduces friction rather than unlocking a buried capability. |
| User impact | Broad + Shallow | Anyone importing benefits, but the per-use gain is a small convenience over the existing button. |
| Strategic alignment | High | Variables is the single hottest area of the codebase; lands in the active path. |
| Market positioning | Differentiator (modest) | Full-page dropzone exceeds documented peers; the review-modal core already leads the category. |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal–Moderate | Reuses the entire parse→preview→save pipeline. New: overlay, `initialText` prop, drag-depth counter, gating. `.json` adds an isolated parser. |
| Effort estimate | Small / Small–Medium | Core ~40–60 lines of native code from existing patterns; `+ .json` adds a parser mirroring the CLI + tests. |
| Risk level | Low | No backend changes; human reviews every import before save; native APIs the repo already uses. Known risks (flicker, accidental capture, locked/detached states) all mitigable. |
| Maintenance burden | Minimal | Native code, no new dependency, isolated parser. |

## Recommendation

**Build it, with a scoped approach.** Value is Medium and cost/risk are Low — and most of the work is *reuse* of an already category-leading import core that sits in the most actively-developed area of the product. The honest framing: this is friction-reduction plus a distinctive UX touch, not a must-have, but the marginal effort is small enough and the strategic fit high enough that it clears the bar.

The "caveats" are scope guardrails, not reasons to hesitate:
- **Hybrid overlay** (drag-activated, invisible at rest) layered over the existing scoped dropzone + picker; **scoped to the Variables workspace**.
- **`.json` as a bounded second deliverable** — an isolated `parseVariablesJson()` mirroring the CLI's two shapes, behind a `parseFile()` dispatcher, with its own tests. De-scopable to `.env`-only for the smallest PR.
- **Bake in the guardrails:** gate on `!importOpen` + `!locked`, drag-depth counter for flicker, validate file type/emptiness before opening, toast-based feedback.
- **Detached `/var` page is out of scope for v1** — `DetachedVaultPage` has no import modal at all (only a quick-add form), so wiring drop-import there is separate, larger work. Extracting the drag logic into a reusable hook (`usePageFileDrop`) makes it a trivial future addition; recommended but not required.

This is squarely a `/feature-dev` or `/feature-build` candidate. The implementation prompt is in `feature-prompt.md` alongside this file.

## References

- Doppler — Drag and Drop to Import Secrets: https://www.doppler.com/changes/drag-and-drop-to-import-secrets
- Doppler — Importing Secrets: https://docs.doppler.com/docs/importing-secrets
- Infisical — Project / secrets management: https://infisical.com/docs/documentation/platform/secrets-mgmt/project
- 1Password Environments (.env public beta): https://1password.com/blog/1password-environments-env-files-public-beta
- Netlify — Environment variables (import + merge strategy): https://docs.netlify.com/build/environment-variables/get-started/
- Railway — Variables (RAW editor): https://docs.railway.com/variables
- Render — Environment variables / secret files: https://render.com/docs/configure-environment-variables
- HashiCorp Vault — Import: https://developer.hashicorp.com/vault/docs/import
- NN/g — Drag-and-Drop: How to Design for Ease of Use: https://www.nngroup.com/articles/drag-drop/
- MDN — File drag and drop: https://developer.mozilla.org/en-US/docs/Web/API/HTML_Drag_and_Drop_API/File_drag_and_drop
- Smart Interface Design Patterns — Drag-and-Drop UX: https://smart-interface-design-patterns.com/articles/drag-and-drop-ux/
- React Aria — Taming the dragon: Accessible drag and drop: https://react-aria.adobe.com/blog/drag-and-drop
- react-dropzone: https://react-dropzone.js.org/ · https://github.com/react-dropzone/react-dropzone
