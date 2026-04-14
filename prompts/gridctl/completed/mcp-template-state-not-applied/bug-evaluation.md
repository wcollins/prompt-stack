# Bug Investigation: MCP Template Selection Not Applied to Form

**Date**: 2026-03-30
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Medium
**Fix Complexity**: Trivial

## Summary

When a user selects a non-container template (e.g., "External URL") on the MCP Server creation wizard's template screen, the Configure screen ignores the selection and defaults to Container. The template-to-form-data mapping is missing from the wizard's template selection handler. This is a clear defect, not a design question — the template screen was built to pre-populate server type, but the wiring was never implemented.

## The Bug

**Wrong behavior**: User selects "External URL" template (orange checkmark appears, Next button activates), clicks Next, and arrives at the Configure screen with Container still selected as server type.

**Expected behavior**: Selecting "External URL" template should pre-populate `serverType: 'external'` and `transport: 'sse'` on the Configure screen.

**Discovery**: User noticed via the UI that template selection has no visible effect on the subsequent form.

## Root Cause

### Defect Location

`web/src/components/wizard/CreationWizard.tsx:450-456` — the template step renders `TemplateGrid` with `onSelect={setSelectedTemplate}`, passing the store action directly.

`web/src/stores/useWizardStore.ts:134-137` — `setSelectedTemplate` only saves the template ID string and advances the step. It never updates `formData['mcp-server'].serverType`.

### Code Path

1. User selects template → `TemplateGrid.onSelect(templateId)` fires
2. `setSelectedTemplate(templateId)` in store: sets `selectedTemplate = templateId`, sets `currentStep = 'form'`
3. Form step renders `MCPServerForm` with `data={formData['mcp-server']}`
4. `formData['mcp-server']` was never updated — still has default `serverType: 'container'`

### Why It Happens

`setSelectedTemplate` stores a string ID that is never consulted by the form. The form reads from `formData['mcp-server'].serverType`, which only changes when the user interacts with the server type picker inside the form. There is no code that translates `selectedTemplate → formData.serverType`.

### Template-to-ServerType Mapping (missing)

| Template ID | Should set serverType | Transport |
|---|---|---|
| `blank` | `container` | (unchanged) |
| `container-http` | `container` | `http` |
| `container-stdio` | `container` | `stdio` |
| `external-url` | **`external`** | `sse` |
| `local-process` | `local` | `stdio` |
| `from-source` | `source` | `http` |

### Similar Instances

The same pattern exists for `stack` and `resource` templates in `TemplateGrid.tsx`, but those forms are less impacted since their templates don't have type divergence the way `mcp-server` does.

## Impact

### Severity Classification

Incorrect behavior. The template step's entire purpose is to pre-configure the form — it shows a YAML preview of what the server will look like, implying that selecting it will configure the form accordingly. That implicit contract is broken.

### User Reach

Every user creating a non-container MCP server via the creation wizard is affected:
- External URL
- Local Process
- Build from Source
- Container (stdio transport — gets wrong transport default)

Only "Blank" and "Container (HTTP)" templates happen to match the default form state.

### Workflow Impact

Not a blocker — user can still select the correct server type manually on the Configure screen. But the misleading UX (checkmark + Next without visible effect) erodes trust in the wizard.

### Workarounds

Adequate: select the correct server type on the Configure screen. Annoying: requires the user to understand that the template step did nothing and re-make their choice.

### Urgency Signals

No active user escalations identified. Medium urgency — the template screen is surfaced prominently in the primary MCP server creation workflow.

## Reproduction

### Minimum Reproduction Steps

1. Open the Creation Wizard (any trigger)
2. Select "MCP Server" → click Next
3. Select any non-container template (e.g., "External URL") — orange checkmark appears
4. Click Next
5. Observe: Configure screen shows "Container" selected, not "External URL"

### Affected Environments

All environments — this is a pure state management bug with no environment-specific factors.

### Non-Affected Environments

Selecting "Blank" or "Container (HTTP)" templates: these match the default `serverType: 'container'`, so the bug is invisible.

### Failure Mode

Silent state mismatch — the form renders with stale default data instead of template-derived data.

## Fix Assessment

### Fix Surface

Single file: `web/src/components/wizard/CreationWizard.tsx`

Replace direct `setSelectedTemplate` passthrough with a handler that:
1. Maps `templateId → { serverType, transport? }`
2. Calls `updateFormData('mcp-server', mappedData)`
3. Then calls `setSelectedTemplate(templateId)` to advance the step

### Risk Factors

Low. Change is isolated to the template selection handler in a single component. The mapping is mechanical (IDs → known enum values). No database, API, or shared state at risk.

### Regression Test Outline

In `web/src/__tests__/MCPServerForm.test.tsx` or a new wizard integration test:

- Set up wizard store with `selectedType: 'mcp-server'`
- Call `setSelectedTemplate('external-url')`
- Assert `formData['mcp-server'].serverType === 'external'`
- Assert `formData['mcp-server'].transport === 'sse'`
- Repeat for `local-process`, `from-source`, `container-stdio`

## Recommendation

**Fix immediately.** Trivial fix, isolated to one file, high confidence. The template screen is a first-class UI element that forms the second step of the primary creation workflow. Its current behavior (selecting a template has no effect on the form) actively misleads users.

Note on the "is the template screen redundant?" question: that's a valid UX concern worth evaluating separately with `/feature-scout`. The template step could be removed in favor of starting directly on the Configure screen. But fixing the current broken behavior is the right first step regardless of whether the template screen survives a future design review.

## References

- Affected component: `web/src/components/wizard/CreationWizard.tsx:450-456`
- Store action: `web/src/stores/useWizardStore.ts:134-137`
- Template definitions: `web/src/components/wizard/TemplateGrid.tsx:12-49`
- Form component: `web/src/components/wizard/steps/MCPServerForm.tsx:35-85`
