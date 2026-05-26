# Feature Implementation: Drag-and-Drop Import (Variables workspace)

## Context

gridctl is an MCP gateway + skill library: a Go CLI/daemon backend with a React web UI under `web/`. Tech stack: **React 19 + TypeScript, Vite 8, Zustand 5, react-router-dom v7, Tailwind CSS v4** (custom design-token palette), **lucide-react** icons, **Vitest 4 + @testing-library/react + jsdom** for tests. There is **no UI-kit and no drag-drop library** — the house style is hand-rolled native HTML5 patterns. The web UI is "Stable" but internal with no API guarantee, so it can iterate freely.

The Variables (a.k.a. Vault) workspace is the most actively-developed surface in the app. Variables are imported client-side: a file/paste is parsed in the browser into structured input and sent to `POST /api/var/import`. No backend changes are needed for this feature.

## Evaluation Context

Key findings from the full evaluation (`feature-evaluation.md` in this folder) that shaped this prompt:

- **The feature substantially already exists in pieces.** The import modal, the `.env` parser, the save pipeline, and even basic in-modal drag-drop all exist. The genuine new work is: a **page-level dropzone overlay**, the **auto-open + pre-populate** wiring, and (in scope here) a **new client-side `.json` parser**.
- **Market:** Drag-and-drop file import is a modest differentiator (only Doppler/Infisical do it, both field-scoped — a full-page overlay exceeds documented peers). The category-leading asset is gridctl's review-before-save modal, which already exists, so this is polish on a strong core. `.json` support puts gridctl ahead of the `.env`-only crowd (Infisical, Netlify).
- **UX decision — hybrid, not pure full-page:** keep the modal's existing scoped dropzone + file picker as the discoverable/accessible entry; layer a **drag-activated-only** overlay (invisible at rest) on top. NN/g and MDN both require a click/file-picker fallback and warn that an always-on overlay blocks content.
- **Native, no library:** react-dropzone solves multi-file/upload problems this single-file parse flow doesn't have, and would violate house style for ~40–60 lines the repo already has working.
- **Risk is low** because the human reviews the parsed preview table before anything persists — any mis-parse is caught pre-save.

## Feature Description

On the Variables workspace, dragging a `.env` or `.json` file anywhere over the page reveals a full-page dropzone overlay. Dropping the file reads and parses it client-side, then opens the existing import modal (`EnvImportModal`) pre-populated with the parsed content, where the user reviews keys/values/types/sets and conflicts before saving. This reduces friction and improves discoverability of the existing import capability, and closes the CLI/UI parity gap by adding `.json` import to the web UI.

## Requirements

### Functional Requirements
1. While the user drags a file over the Variables workspace, show a full-page dropzone overlay; hide it otherwise. The overlay must **not** be visible at rest.
2. Only activate for drags carrying files — gate on `e.dataTransfer.types.includes('Files')` so internal pointer drags (panel resizers, react-flow nodes) never trigger it.
3. On drop, take the **first** file, read its text, and **validate before opening the modal**:
   - Wrong type (not `.env`/`.json`/plain-text) → `showToast('error', ...)`, do not open.
   - Empty file → `showToast('warning', ...)`, do not open.
   - Multiple files dropped → import the first, `showToast('warning', 'Dropped multiple files — importing the first only')`.
4. On a valid drop, open `EnvImportModal` pre-populated with the parsed content for review. The user must still explicitly confirm the import (no auto-save).
5. Add an optional `initialText?: string` (or `initialFile`) prop to `EnvImportModal` so it can open pre-seeded. It currently inits `text` to `''` and `handleFile` *appends* — pre-population must seed the initial value cleanly.
6. Parse `.env` via the existing `parseEnv()`. For `.json`, add a new client-side parser mirroring the CLI's `parseVariablesJSON` (`cmd/gridctl/var.go`): accept both the legacy map shape `{"KEY":"value"}` (everything string + secret) and the v2 shape `{"variables":[{key,value,type,isSecret,set?}]}`. Route by file extension/content via a small `parseFile(name, text)` dispatcher.
7. Suppress the page overlay while the modal is already open (`!importOpen`) — let the modal's own textarea dropzone handle mid-edit drops (which correctly append).
8. Suppress the page overlay when the vault is locked (`!locked`).
9. Add a low-noise discovery cue: one muted line in the empty-state caption slot (`VaultWorkspace.tsx` ~`:1035`), e.g. "…or drop a `.env` or `.json` file anywhere on this page." No persistent banner in the populated state.

### Non-Functional Requirements
- **Native HTML5 only** — no new dependency. `preventDefault` on `dragover` and `drop` (otherwise the browser navigates away to open the file).
- **No flicker:** use a drag-depth counter (increment on `dragenter`, decrement on `dragleave`, overlay visible only when counter > 0) or `relatedTarget`/`pointer-events-none` so crossing child element boundaries doesn't toggle the overlay.
- **Accessibility:** the overlay is decorative (`aria-hidden="true"`), mouse-only; the existing focusable `<input type="file">` in the modal remains the keyboard/screen-reader-equal path. Drag-drop must never be the only route. Auto-opening the modal must hand focus to the existing `useFocusTrap` (it already does this when opened via the button).
- **Design language:** mirror the modal's existing dropzone cue — `border-2 border-dashed border-primary/50`, `bg-primary/5 text-primary`, `Upload` icon, `bg-background/80 backdrop-blur-sm`, `animate-fade-in-scale`. Use the design tokens, not raw colors.
- **Secret-by-default preserved:** imported rows default to `isSecret: true` (Constitution Article XII). The existing `rowFromParsed` already does this; the `.json` v2 shape may specify `isSecret` explicitly — honor it, default to `true` when absent.
- **Tests:** add Vitest coverage. jsdom does not fire native drag events, so use synthetic `fireEvent.drop`/`fireEvent.dragOver` with a mocked `dataTransfer` (`{ files: [...], types: ['Files'] }`) and stub `File.prototype.text` (follow the `web/vitest.setup.ts` polyfill pattern).

### Out of Scope
- The detached `/var` page (`web/src/pages/DetachedVaultPage.tsx`) — it has **no import modal at all** (only a quick-add form), so drop-import there is separate, larger work. Extracting the drag logic into a reusable hook (`usePageFileDrop`) makes it a trivial future addition, but wiring the detached page is not required for this feature.
- Any backend / Go changes — import is fully client-side to `POST /api/var/import`.
- Multi-file batch import, YAML, directory drops, upload progress UI.
- An always-visible dropzone or persistent on-canvas banner in the populated state.

## Architecture Guidance

### Recommended Approach
Implement a small reusable hook, e.g. `web/src/hooks/usePageFileDrop.ts`, that owns the native window/element drag listeners, the drag-depth counter, the `types.includes('Files')` gate, and exposes `{ isDragging }` plus an `onFiles(files: FileList)` callback. Mount it in `VaultWorkspace`, gated on `!importOpen && !locked`. Read + validate the dropped file in the workspace (so validation happens before the modal opens), then set workspace state (`droppedText` + `importOpen`) and pass `initialText` to the modal at the existing mount point. This keeps `EnvImportModal` surface-area small (one new optional prop) and makes the detached page a future one-liner.

Put parsing behind a `parseFile(fileName, text)` dispatcher in `web/src/lib/` that calls `parseEnv` for `.env`/text and a new `parseVariablesJson` for `.json`, both returning the same `ParsedEnvEntry[]`-shaped result the modal already consumes.

### Key Files to Understand
- `web/src/components/workspaces/VaultWorkspace.tsx` — the page. `importOpen` state (`:142`), modal mount (`:596`), root `<div>` attach point (`:381`), header button (`:670`), empty-state caption (`:1035`), locked gating (`:416`, `:668`). Where the overlay + listeners + discovery cue go.
- `web/src/components/vault/EnvImportModal.tsx` — the modal to extend. Props (`:31`, add `initialText`), `text` state (`:98`), `handleFile` append behavior (`:152`), existing dropzone cue to mirror (`:290`), focus trap (`:93`), dialog a11y (`:226`).
- `web/src/lib/envParser.ts` — `parseEnv()`, `ParsedEnvEntry`, `detectType`. The shape the new JSON parser must produce.
- `cmd/gridctl/var.go` — `parseVariablesJSON` (~`:719`): the reference for the two JSON shapes (legacy map + v2 `{variables:[...]}`).
- `web/src/components/ui/Toast.tsx` — `showToast(type, message)` (`:27`); types `'success' | 'error' | 'warning'`.
- `web/src/hooks/useFocusTrap.ts` — focus convention the auto-opened modal already honors.
- `web/src/hooks/useVaultManager.ts` — `importVars` (the save path behind the modal); no change expected.
- `web/vitest.setup.ts` + `web/src/__tests__/VaultWorkspace.test.tsx` + `web/src/__tests__/envParser.test.ts` — test patterns to mirror (jsdom polyfills, api mocking, dialog assertions, parser rigor).

### Integration Points
- **`EnvImportModal`**: add `initialText?: string` to `EnvImportModalProps`; seed `useState(initialText ?? '')`. Keep the existing in-modal textarea dropzone (append-on-drop) for mid-edit drops.
- **`VaultWorkspace`**: add `droppedText` state alongside `importOpen`; mount `usePageFileDrop` gated on `!importOpen && !locked`; render the overlay (a `fixed`/`absolute inset-0` decorative layer) when `isDragging`; pass `initialText={droppedText}` to the modal; clear `droppedText` on modal close.
- **Parsing**: new `web/src/lib/parseFile.ts` (or extend `envParser.ts`) with `parseVariablesJson` + a `parseFile` dispatcher.

### Reusable Components
The entire parse → preview table → `POST /api/var/import` pipeline is reused unchanged (`EnvImportModal` body, `handleImport`, `useVaultManager.importVars`, `api.importVariables`). Reuse the modal's dropzone cue styling, the `showToast` hook, `useFocusTrap`, and the `animate-fade-in-scale` entrance.

## UX Specification

- **Discovery:** Header "Import .env" button and empty-state CTA remain primary. Add the one muted caption line about dropping a file. The overlay-on-drag is the just-in-time discovery moment in the populated state.
- **Activation:** Drag a file over the workspace → overlay fades in. Drop → validate → modal opens pre-populated (or a toast explains why it didn't).
- **Interaction:** Same review/edit/save flow as today (per-row type, set assignment, skip, reveal, overwrite badges, secret-by-default).
- **Feedback:** Overlay uses the dashed-border `border-primary/50` cue with `Upload` icon and copy like "Drop a .env or .json file to import." Errors/warnings via toast; never silent failure.
- **Error states:** wrong type → error toast; empty file → warning toast; multiple files → warning toast + import first; locked vault / modal already open → overlay simply doesn't appear.

## Implementation Notes

### Conventions to Follow
- Match surrounding code: design tokens (`bg-surface-elevated`, `text-text-muted`, `border-primary`, `bg-primary/5`, `status-error`), `cn()` helper, lucide icons, `useCallback`/`useMemo` density, concise rationale comments. Commit style: Conventional Commits, imperative subject ≤50 chars, `feat:` type. gridctl uses the **fork workflow** (`/branch-fork`, `/pr-fork`) — branch from upstream and PR to upstream; sign commits, no Claude mentions in VCS.
- Keep `EnvImportModal`'s "unmount resets state" model — pre-population works because the modal is freshly mounted on drop, not toggled while mounted.

### Potential Pitfalls
- **Flicker**: the existing in-modal dropzone avoids it only because its drop area has no child elements; a full-page overlay over the dense rail/table layout **will** flicker without a drag-depth counter or `pointer-events-none`.
- **Browser navigation**: forgetting `preventDefault` on `dragover`/`drop` makes the browser open the dropped file and navigate away.
- **`accept` is not validation**: it doesn't apply to drops at all — validate type after drop in JS.
- **Clobbering edits**: don't let the page overlay fire while the modal is open, or you'll re-seed/clobber in-progress edits.
- **`.json` typing**: legacy map shape has no types — default to string + secret like the CLI; v2 shape carries types/isSecret — honor them. The preview table lets the user correct either way.
- **Tests**: jsdom won't dispatch real drag events; synthesize them and stub `File.prototype.text`.

### Suggested Build Order
1. Add `initialText` to `EnvImportModal`; verify opening it from the existing button still works (regression).
2. Build `usePageFileDrop` (native listeners, drag-depth counter, files gate). Unit-test the gating logic.
3. Wire it into `VaultWorkspace` for `.env` only: overlay rendering, drop → read text → open modal pre-seeded; toast validation; gate on `!importOpen && !locked`.
4. Add the discovery caption line.
5. Add `parseVariablesJson` + `parseFile` dispatcher; extend accepted types and the file picker `accept` to include `.json`. Mirror the CLI's two shapes.
6. Tests: drop `.env`, drop `.json`, wrong type, empty file, multiple files, locked vault (no overlay), modal-open (no overlay).

## Acceptance Criteria

1. Dragging a file over the Variables workspace shows a full-page dropzone overlay styled consistently with the modal's dashed-border cue; the overlay is absent at rest and absent during non-file drags.
2. Dropping a valid `.env` file opens `EnvImportModal` pre-populated with the parsed keys/values/types; the user can review and must explicitly confirm to save.
3. Dropping a valid `.json` file (legacy map or v2 `{variables:[...]}`) opens the modal pre-populated with correctly parsed/typed rows; secret-by-default is preserved unless the v2 payload specifies otherwise.
4. Invalid type, empty file, and multiple-file drops each produce the specified toast and behave as described (no silent failure; first-file import for multiples).
5. No overlay appears while the modal is already open or while the vault is locked.
6. The overlay never causes flicker when dragging across the rail/table layout, and the browser never navigates away on drop.
7. The keyboard/screen-reader path (existing file picker + paste) is unchanged; the overlay is `aria-hidden`; auto-open hands focus to the focus trap.
8. A discovery cue line is present in the empty state; no persistent banner in the populated state.
9. No new npm dependency is added.
10. New Vitest tests cover the drop scenarios above and pass; existing tests (`VaultWorkspace.test.tsx`, `envParser.test.ts`) still pass; lint and `npm run build` succeed.

## References

- Full evaluation: `feature-evaluation.md` (this folder)
- MDN — File drag and drop: https://developer.mozilla.org/en-US/docs/Web/API/HTML_Drag_and_Drop_API/File_drag_and_drop
- NN/g — Drag-and-Drop: How to Design for Ease of Use: https://www.nngroup.com/articles/drag-drop/
- Smart Interface Design Patterns — Drag-and-Drop UX: https://smart-interface-design-patterns.com/articles/drag-and-drop-ux/
- React Aria — Accessible drag and drop: https://react-aria.adobe.com/blog/drag-and-drop
- Doppler — Drag and Drop to Import Secrets: https://www.doppler.com/changes/drag-and-drop-to-import-secrets
- CLI JSON reference: `cmd/gridctl/var.go` (`parseVariablesJSON`)
