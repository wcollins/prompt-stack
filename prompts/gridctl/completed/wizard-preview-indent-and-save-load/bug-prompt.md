# Bug Fix: Wizard YAML Preview Indentation & Save & Load Dead-End

## Context

**Project:** gridctl — a CLI + daemon for managing MCP stacks, shipped with an embedded React + Vite + Tailwind web UI served at `:8180` when the daemon runs as `./gridctl serve`. The wizard is the primary visual flow for composing a stack spec without writing YAML by hand.

**Tech stack:**
- Backend: Go, `net/http`, package `internal/api`, stack state in `pkg/state`, config in `pkg/config`
- Frontend: React 18 + TypeScript + Vite, Tailwind CSS with custom design tokens, Zustand stores, react-resizable-panels
- Custom YAML serializer: `web/src/lib/yaml-builder.ts`
- Custom YAML syntax-highlighter: regex-based inside `YAMLPreview.tsx`

**Relevant architecture:**
- Wizard is a portal-based modal (`web/src/components/wizard/CreationWizard.tsx`)
- Steps: Type → Template → Configure → Review
- Configure step has a split panel: form on the left, live `<YAMLPreview />` on the right
- Review step has a `<ReviewStep />` with Download / Copy / Save & Load (for stacks) or Deploy (for other resource types)
- `onDeploy` is the callback the parent uses to close the modal and refresh the canvas

## Investigation Context

Two defects on the stackless `./gridctl serve` → first-stack walkthrough path:

- **Bug A (visual only, underlying data correct):** The YAML Preview panel strips leading whitespace when rendering highlighted YAML, making list items and nested keys appear flush-left. Root cause confirmed: the `<span>` that injects the highlighted HTML via `dangerouslySetInnerHTML` lacks `whitespace-pre`, and the browser's default `white-space: normal` collapses the leading spaces preserved by the tokenizer.
- **Bug B (UX dead-end masking a backend failure):** Clicking "Save & Load" writes `~/.gridctl/stacks/<name>.yaml` successfully, then `POST /api/stack/initialize` fails with a non-2xx / non-409 status (verified via DevTools Network: request row flagged red). The frontend's catch branch shows an error toast but does **not** call `onDeploy?.()`, so the modal stays open and the user reads it as "nothing happened".

Risk mitigations baked into the fix requirements:
- Don't touch the tokenizer (it's correct).
- Keep the non-409 fallback toast; extend it so the user has a persistent, readable signal that the save worked and why load didn't complete.
- Close the modal once the file has been persisted — that's the confirmed success signal.

Reproduction confirmed (user report + screenshots):
- `~/.gridctl/stacks/daily.yaml` written after clicking Save & Load
- `POST /api/stack/initialize` request visibly red in the Network panel
- Wizard modal stays open, no visible state change

Full investigation: `<prompts-dir>/wizard-preview-indent-and-save-load/bug-evaluation.md`

## Bug Description

### Bug A: YAML Preview renders without indentation
- **What is wrong:** The live YAML Preview on the Configure step renders list items (`- foo`) and nested keys (`command:` under `mcp-servers[x]`) at the wrong visual indent — they appear flush-left relative to their parent key, although the copy / download output is correct.
- **Expected:** The rendered preview matches the output of `Copy` and `Download` — indentation preserved.
- **Manifestation:** Lines like `- dev` under `secrets.sets:` or `- npx` under `command:` appear at column 0 instead of indented.
- **Affected users:** Everyone using the wizard in `./gridctl serve`.

### Bug B: Save & Load leaves the modal open when initialize fails
- **What is wrong:** When `POST /api/stack/initialize` fails with anything other than `409 StackAlreadyActiveError`, the error toast fires but the wizard modal does not close. The stack file was already successfully written in the prior `POST /api/stacks` step, so the user is stuck in the modal and believes the action did nothing.
- **Expected:** The modal should close on any confirmed-persisted save, and the user should have clear, persistent feedback about whether the stack loaded or needs a manual follow-up (`gridctl apply ~/.gridctl/stacks/<name>.yaml`).
- **Manifestation:** Click Save & Load → modal stays open, toast may flash briefly, user perceives no change.
- **Affected users:** Every user who hits an init-time failure on first-stack creation (Docker not running, missing secrets in vault, spec shape the reload handler can't load, etc.).

## Root Cause

### Bug A
File: `web/src/components/wizard/YAMLPreview.tsx`

Lines 121–124:
```tsx
<span
  className="flex-1 px-2"
  dangerouslySetInnerHTML={{ __html: html || '&nbsp;' }}
/>
```

The `highlightYAML()` tokenizer at lines 13–32 correctly preserves `$1` (leading whitespace) in every regex replacement, and `yaml-builder.ts` produces well-formed, indented YAML strings. The defect is in the render path: the span has no `whitespace-pre`, so the browser's default `white-space: normal` collapses runs of whitespace (including leading spaces before inline `<span>` token children) to a single character. The fix is one Tailwind class.

### Bug B
File: `web/src/components/wizard/steps/ReviewStep.tsx`

Lines 106–131 — the `handleSaveAndLoad` function:
```tsx
const handleSaveAndLoad = async () => {
  setDeploying(true);
  const name = extractStackName();
  try {
    await saveStack(yaml, name);
  } catch (err) {
    showToast('error', err instanceof Error ? err.message : 'Save failed');
    setDeploying(false);
    return;
  }

  try {
    await initializeStack(name);
    showToast('success', `Stack loaded — ${name} is now active`);
    onDeploy?.();
  } catch (err) {
    if (err instanceof StackAlreadyActiveError) {
      showToast('success', 'Stack saved to library');
      onDeploy?.();
    } else {
      showToast('error', `Saved but could not load — restart with \`gridctl apply ~/.gridctl/stacks/${name}.yaml\``);
      // ← missing onDeploy?.() — modal stays open
    }
  } finally {
    setDeploying(false);
  }
};
```

The final `else` branch omits `onDeploy?.()`. Since the file has already been persisted, the wizard no longer has a purpose — it should close, and the error toast (or a follow-up banner on the canvas) should carry the fallback instruction.

## Fix Requirements

### Required Changes

1. **Bug A — add `whitespace-pre` to the preview span in `web/src/components/wizard/YAMLPreview.tsx` line 122.**
   - Change `className="flex-1 px-2"` → `className="flex-1 px-2 whitespace-pre"`.
   - Verify visually: list items and nested keys keep their leading whitespace; long lines don't wreck the flex layout (the preview container has horizontal overflow handling via `scrollbar-dark` on the outer scroller).

2. **Bug B — close the wizard on confirmed save in `web/src/components/wizard/steps/ReviewStep.tsx` line 126.**
   - In the non-`StackAlreadyActiveError` branch, add `onDeploy?.()` immediately after the `showToast('error', ...)` call so the modal closes.
   - Keep the existing toast message — it tells the user the file is persisted and how to recover.

3. **Bug B, polish — make the error toast long-lived enough to be read.**
   - If `showToast` currently defaults to a short timeout, call it with an explicit longer duration (e.g., 8–10 seconds) for this specific fallback case. If `showToast` does not support a duration argument, do not refactor the toast system in this fix; just ensure the closed-modal + existing toast is clearly visible. Inspect `web/src/components/ui/Toast.tsx` to determine the right API shape.

### Constraints

- Do **not** modify the regex tokenizer in `highlightYAML()` — it is correct.
- Do **not** modify `yaml-builder.ts` — it is correct.
- Do **not** modify `CreationWizard.tsx`'s modal/onDeploy wiring — it is correct.
- Do **not** change the server-side `handleStackInitialize` behavior — its 409 / non-2xx semantics are part of a documented contract.
- Do **not** suppress or swallow the initialize error — the user should still be told initialization didn't complete.

### Out of Scope

- Diagnosing **why** `POST /api/stack/initialize` is failing in the user's environment. That is a separate investigation that needs the response body and `gridctl serve` stderr. Leave a follow-up note; do not attempt to infer and patch the backend in this fix.
- Refactoring the toast system.
- Adding a persistent in-canvas banner for "Stack saved but not loaded." That is a worthwhile follow-up; keep this fix minimal.
- Adding tests beyond what's listed in the Regression Test section.

## Implementation Guidance

### Key Files to Read

- `web/src/components/wizard/YAMLPreview.tsx` — the preview component; the only file that needs a code change for Bug A.
- `web/src/components/wizard/steps/ReviewStep.tsx` — the Review step; the only file that needs a code change for Bug B.
- `web/src/components/wizard/CreationWizard.tsx` — read `handleDeploy` at lines 240–243 and the wiring at line 504 to confirm `onDeploy` propagation (don't modify).
- `web/src/lib/api.ts` — read `saveStack` (lines 559–574) and `initializeStack` (lines 588–604) and the `StackAlreadyActiveError` class (lines 581–586) to understand the current error contract.
- `web/src/components/ui/Toast.tsx` — read to determine the `showToast` signature before touching toast duration.
- `proto/walkthrough.md` §3.9–3.10 — the documented expected user-visible behavior.

### Files to Modify

- `web/src/components/wizard/YAMLPreview.tsx` — line 122 only.
- `web/src/components/wizard/steps/ReviewStep.tsx` — inside the `else` branch at lines 125–127 only (add `onDeploy?.()` and optional toast-duration tweak).

### Reusable Components

- `onDeploy?.()` callback pattern is already established in `handleSaveAndLoad` — reuse it in the fallback branch.
- `showToast(severity, message)` is already imported at `ReviewStep.tsx:15`.

### Conventions to Follow

- TypeScript strict, 2-space indent.
- Tailwind classnames, `cn()` helper when composing.
- No new deps.
- Commit style (per repo CLAUDE.md): signed commits, `fix:` prefix, no Claude trailers.

## Regression Test

### Test Outline

Add tests in `web/src/components/wizard/__tests__/` (convention observed from existing `StackForm.test.tsx`, etc.).

1. **`YAMLPreview.test.tsx`** (new)
   - Render `<YAMLPreview yaml={...} />` with a multi-line YAML containing nested keys and list items.
   - Assert that the rendered DOM preserves leading whitespace for each line — either by reading `textContent` and comparing against the source string, or by asserting the computed style `white-space` on the preview span is `pre` (or `pre-wrap`).
   - Bonus: snapshot test on a known-good YAML fixture.

2. **`ReviewStep.test.tsx`** (new)
   - Mock `saveStack` to resolve, `initializeStack` to reject with a generic `Error` (not `StackAlreadyActiveError`).
   - Render `<ReviewStep yaml={...} resourceType="stack" resourceName="daily" onDeploy={jest.fn()} />`.
   - Simulate click on the Save & Load button.
   - Assert: `showToast` called with error severity and the fallback message; `onDeploy` was called exactly once.
   - Second test: `initializeStack` rejects with `StackAlreadyActiveError` — assert success toast + `onDeploy` called.
   - Third test: both calls resolve — assert success toast "Stack loaded — daily is now active" + `onDeploy` called.

### Existing Test Patterns

- Tests use Vitest + React Testing Library (check `package.json` scripts / imports in `StackForm.test.tsx`).
- Mocks for `lib/api.ts` are typically set up via `vi.mock('../../../lib/api', () => ({...}))`.
- `showToast` should be mocked too, since the component imports it directly.

## Potential Pitfalls

- **Long YAML lines + `whitespace-pre`**: if a single YAML line is very long (e.g., a fully-qualified image URL plus a bearer token), `whitespace-pre` will extend the line horizontally and trigger horizontal scroll. Verify scroll works on the preview panel (the outer `overflow-y-auto scrollbar-dark` container at line 113 handles vertical; horizontal overflow must either be allowed or the span must use `whitespace-pre-wrap` — test both against the walkthrough YAML and prefer `whitespace-pre` if the layout holds).
- **Don't call `onDeploy?.()` in the outer `saveStack` catch**: if the save itself failed, the file is not persisted and closing the modal would lose the user's work. The current behavior (toast + return + keep modal) is correct for that branch.
- **Don't swallow the underlying backend error**: the non-409 branch message already points users to `gridctl apply …`. Keep that hint intact.
- **Cache busting during dev**: if testing in a browser, ensure Vite HMR picks up the class change — hard-reload if the preview panel doesn't update.

## Acceptance Criteria

1. The YAML Preview panel in the Configure step renders with the same indentation as the output of the Copy and Download buttons, for the full `proto/walkthrough.md` Phase 3 stack.
2. Clicking Save & Load closes the wizard modal whenever `POST /api/stacks` succeeds — regardless of whether `POST /api/stack/initialize` succeeds, 409s, or errors.
3. On `initialize` error (non-409), the user sees a readable toast containing the `gridctl apply ~/.gridctl/stacks/<name>.yaml` hint long enough to act on.
4. On `initialize` success, the user sees the `Stack loaded — <name> is now active` toast and the canvas populates with the stack.
5. On `StackAlreadyActiveError`, the user sees `Stack saved to library` and the modal closes (no regression — this branch already calls `onDeploy?.()`).
6. New unit tests cover all three branches of `handleSaveAndLoad` and the indentation-preserving render of `YAMLPreview`.
7. No unrelated changes. No regressions in existing Vitest suites or `npm run build`.

## References

- `proto/walkthrough.md` §3.9–3.10 — expected user-visible Save & Load behavior
- Commit `53aed6d` — original Save & Load feature introducing the dead-end
- Commit `a2b48dd fix: reorder YAML highlight regexes to prevent HTML class name corruption` — prior precedent for surgical single-line fixes in `YAMLPreview.tsx`
- `web/AGENTS.md` §Stack Save & Load Flow — internal doc for the save/load flow
