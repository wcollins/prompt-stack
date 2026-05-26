# Bug Investigation: Wizard YAML Preview Indentation & Save & Load Dead-End

**Date**: 2026-04-17
**Project**: gridctl
**Recommendation**: Fix immediately (both bugs)
**Severity**: High (both)
**Fix Complexity**: Trivial (Bug A) / Small (Bug B)

## Summary

Two defects in the `./gridctl serve` stack-creation wizard hit the walkthrough's golden path. Bug A: the YAML Preview panel loses all leading whitespace when rendering, so list items and nested keys appear flush-left even though the underlying string is well-formed. Bug B: clicking "Save & Load" on the Review step writes the stack file to `~/.gridctl/stacks/` but when the subsequent `POST /api/stack/initialize` fails with a non-409 error, the wizard shows a toast and then traps the user in the modal — creating a "nothing happened" impression.

## The Bug

### Bug A — YAML preview indentation is stripped on render
- **Where**: Configure step of the New Stack wizard; the right-side "YAML PREVIEW" panel.
- **Expected**: The preview matches the copyable / downloadable YAML — list items indented, nested keys indented, `command:` array entries appearing under `zapier`.
- **Actual**: The rendered preview shows every line flush-left below its parent key. Copying the YAML out as text is correct. Verified visually via user screenshot against the `proto/walkthrough.md` expected YAML.
- **Discovery**: User followed `proto/walkthrough.md` Phase 3 and noticed the rendered preview in Image 1 disagreed with the copied text.

### Bug B — Save & Load leaves the modal open with no clear outcome
- **Where**: Review step of the New Stack wizard; the primary "Save & Load" button.
- **Expected** (per `proto/walkthrough.md` §3.10): stack file saved, `Stack loaded — daily is now active` toast, wizard closes, canvas populates.
- **Actual**: Stack file IS saved (confirmed: `daily.yaml` written into `~/.gridctl/stacks/`). `POST /api/stack/initialize` fires but fails (verified via DevTools Network — row is flagged with the red failure icon). The catch branch at `ReviewStep.tsx:125–127` shows a toast but does **not** call `onDeploy?.()`, so the wizard remains open. From the user's POV, nothing happened.
- **Discovery**: User clicking Save & Load per walkthrough and seeing no state change.

## Root Cause

### Defect Location

**Bug A**: `web/src/components/wizard/YAMLPreview.tsx:121–124`
```tsx
<span
  className="flex-1 px-2"                     // ← missing whitespace-pre
  dangerouslySetInnerHTML={{ __html: html || '&nbsp;' }}
/>
```
The tokenizer at `YAMLPreview.tsx:13–32` correctly preserves `$1` (leading whitespace) in every regex replacement, and `web/src/lib/yaml-builder.ts` serializes with correct `' '.repeat(indentLevel)` spacing. Both produce a well-formed string. The render path loses the indentation because the span has no `whitespace-pre` / `whitespace-pre-wrap` — browser default `white-space: normal` collapses all leading whitespace inside the inline HTML fragment before any of the `<span>` color children.

**Bug B**: `web/src/components/wizard/steps/ReviewStep.tsx:106–131`
```tsx
const handleSaveAndLoad = async () => {
  setDeploying(true);
  const name = extractStackName();
  try {
    await saveStack(yaml, name);              // ✅ succeeds — file written
  } catch (err) {
    showToast('error', err instanceof Error ? err.message : 'Save failed');
    setDeploying(false);
    return;
  }

  try {
    await initializeStack(name);              // ❌ fails in current repro
    showToast('success', `Stack loaded — ${name} is now active`);
    onDeploy?.();
  } catch (err) {
    if (err instanceof StackAlreadyActiveError) {
      showToast('success', 'Stack saved to library');
      onDeploy?.();                           // ← closes modal
    } else {
      showToast('error', `Saved but could not load — restart with \`gridctl apply ~/.gridctl/stacks/${name}.yaml\``);
      // ← NO onDeploy?.() — modal stays open, UX dead-end
    }
  } finally {
    setDeploying(false);
  }
};
```

### Code Path

**Bug A**: user fills form → `CreationWizard.tsx:176–198` debounces `buildYAML(...)` → `generatedYaml` state updates → `YAMLPreview.tsx:391` re-renders → `highlightYAML()` builds lines → `<span className="flex-1 px-2" dangerouslySetInnerHTML=...>` → browser CSS collapses whitespace.

**Bug B**: user clicks Save & Load on Review → `handleSaveAndLoad` → `POST /api/stacks` (200, file written) → `POST /api/stack/initialize` (non-2xx, non-409) → `catch` branch non-`StackAlreadyActiveError` → `showToast('error', ...)` → no modal close → user sees unchanged wizard.

### Why It Happens

**Bug A**: inline HTML text defaults to `white-space: normal` in the browser, which collapses runs of whitespace (including leading spaces before inline `<span>` children). Each rendered line is a `<span>` child of a `<div class="flex …">`, not a `<pre>`, so the default applies.

**Bug B**: the fallback branch assumes users can recover via the CLI hint in the toast, but:
1. Toasts auto-dismiss and are easy to miss.
2. The stack was genuinely saved — the modal has no further purpose.
3. Leaving the primary action unresolved after a clicked submit is a UX dead-end that reads as "broken".

Separately, the initialize call is failing. Likely causes (requires inspection of the `initialize` response body):
- `reloadHandler.Initialize` returns error (container pull, Docker daemon reachability, network driver creation).
- `result.Success == false` from `reloadHandler.Initialize` (spec-level issue parsing `command:` list or vault interpolation).
- Missing `ZAPIER_MCP_TOKEN` in vault at load time causing Zapier container bootstrap to fail.

### Similar Instances
No other `whitespace-pre`-missing usages in wizard code surfaced. No other `showToast('error', …)` patterns that swallow `onDeploy?.()` after a confirmed persisted save — this is the only save-then-load action in the wizard today.

## Impact

### Severity Classification
- **Bug A**: Cosmetic defect on a feature-demo UI. Classification: **High-visibility cosmetic**. Non-blocking but damages first-impression and the walkthrough's credibility.
- **Bug B**: UX dead-end masking a backend failure. Classification: **Regression-equivalent** — the primary action of the wizard appears non-functional.

### User Reach
- Every user following `proto/walkthrough.md` Phase 3 (stackless onboarding → first stack).
- Every user using the wizard in `./gridctl serve` mode who hits any init-time failure (Docker issue, missing secret, etc.).

### Workflow Impact
- Bug A: core path for anyone learning gridctl via the wizard. The rendered preview is the dominant visual artifact of the Configure step.
- Bug B: core path for first-stack creation in stackless mode. Users will believe the save flow is broken, not realize the file was persisted, and not recover on their own.

### Workarounds
- Bug A: copy the YAML out to read it correctly. Functional but undermines the whole point of a live preview.
- Bug B: the CLI hint in the toast works if the user sees it and acts on it. In practice, the modal staying up strongly implies failure.

### Urgency Signals
- Both bugs are on the walkthrough's golden path.
- Bug A was introduced/carried alongside commit `a9f56e9 feat: add live YAML preview with validation annotations`.
- Bug B was introduced in commit `53aed6d feat: add Save & Load action to wizard ReviewStep for stacks (#460)`.
- No issues filed yet — user-reported here first.

## Reproduction

### Minimum Reproduction Steps
**Bug A**:
1. `make build && ./gridctl serve`
2. Open `http://localhost:8180` → click "+" to open wizard
3. Stack → Blank → Next
4. Set Name: `daily`, add any MCP server, reach Configure step
5. Observe the right-side YAML Preview — list items and nested keys render flush-left
6. Copy the YAML out with the Copy button on the Review step — indentation is correct

**Bug B**:
1. Same setup through the wizard into the Review step with a valid stack
2. Click "Save & Load"
3. Observe `~/.gridctl/stacks/<name>.yaml` is written
4. Observe `POST /api/stack/initialize` fails in DevTools Network (non-2xx, non-409)
5. Observe the wizard modal stays open — user interprets as "nothing happened"

### Affected Environments
- Confirmed: macOS (Darwin 24.6.0), Brave/Chromium 147, `gridctl` built at current `main` (commit `12977cd`).
- Framework: React 18 + Vite + Tailwind.

### Non-Affected Environments
- Bug A: would also affect every browser; not environment-specific.
- Bug B: any environment where `reloadHandler.Initialize` succeeds (stack loads cleanly) doesn't trip the dead-end branch.

### Failure Mode
- Bug A: visual only. Underlying data correct; preview misleading.
- Bug B: data-persistence OK; follow-up action failed; UI stuck.

## Fix Assessment

### Fix Surface
- `web/src/components/wizard/YAMLPreview.tsx` — one className change on line 122.
- `web/src/components/wizard/steps/ReviewStep.tsx` — extend the non-409 catch branch so the modal closes and the user has a persistent signal that the save succeeded (toast + wizard close + potentially canvas/header empty-state copy indicating why init didn't complete).

### Risk Factors
- `whitespace-pre` on a flex child inside a horizontal row: verify long lines don't wreck the layout. The container already has horizontal scroll via `scrollbar-dark`. `whitespace-pre-wrap` is the safer alternative if wrapping is wanted.
- Closing the modal on init failure: lose in-modal context on the error. Mitigation: keep/extend the toast with explicit next-step CLI command, ensure the toast is long-lived (or make it a persistent inline alert on the canvas until dismissed).

### Regression Test Outline
- Unit/DOM test for `YAMLPreview` that asserts rendered `textContent` includes expected leading whitespace for a known YAML string (or asserts computed `white-space` style).
- Unit test for `handleSaveAndLoad` paths: happy / 409 / non-409 — assert `onDeploy` is called in all three saved-successfully branches.

## Recommendation

**Fix immediately — both bugs.** They are on the documented onboarding path in `proto/walkthrough.md` and make the product feel broken on first contact.

- Bug A — single-class CSS change. No tradeoffs.
- Bug B — close the modal on any successful save (saveStack returned 2xx), regardless of whether initialize succeeded. Ensure the toast for the non-409 fallback is persistent enough to be read (or swap to an inline banner shown on the canvas empty-state). Separately open a follow-up to inspect the `initialize` Response body and fix the underlying failure — that diagnostic is orthogonal to the UX fix.

## References

- `proto/walkthrough.md` §3.9–3.10 — documented expected Save & Load behavior
- `web/src/components/wizard/YAMLPreview.tsx` — preview panel and tokenizer
- `web/src/components/wizard/steps/ReviewStep.tsx` — Save & Load handler
- `web/src/components/wizard/CreationWizard.tsx` — modal / onDeploy wiring
- `web/src/lib/api.ts` — `saveStack`, `initializeStack`, `StackAlreadyActiveError`
- `internal/api/stack.go` — `handleStacksSave`, `handleStackInitialize`
- Commit `53aed6d` — original Save & Load feature that introduced the dead-end branch
