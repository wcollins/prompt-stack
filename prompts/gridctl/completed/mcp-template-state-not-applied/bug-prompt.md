# Bug Fix: MCP Template Selection Not Applied to Form

## Context

gridctl is a CLI and web UI for managing MCP (Model Context Protocol) server stacks. The web frontend is a React + TypeScript app using Zustand for state management. The MCP server creation flow is a multi-step wizard: Type → Template → Configure → Review.

The wizard state lives in `web/src/stores/useWizardStore.ts`. The template step renders `web/src/components/wizard/TemplateGrid.tsx`. The Configure step renders `web/src/components/wizard/steps/MCPServerForm.tsx`.

## Investigation Context

- Root cause confirmed: `setSelectedTemplate` in the store saves the template ID string but never updates `formData['mcp-server'].serverType`. The form reads from `formData['mcp-server']`, not from `selectedTemplate`.
- Risk: Low — the fix is isolated to a single handler in `CreationWizard.tsx`.
- Reproduction: 100% deterministic across all environments.
- Full investigation: `/Users/william/code/prompt-stack/prompts/gridctl/mcp-template-state-not-applied/bug-evaluation.md`

## Bug Description

When a user selects any MCP Server template on the wizard's Template step (e.g., "External URL", "Local Process", "Build from Source"), clicking Next advances to the Configure screen — but the Configure screen ignores the template selection and displays the default "Container" server type.

**Expected**: Selecting "External URL" template → Configure screen shows "External URL" server type pre-selected.

**Actual**: Configure screen always shows "Container" server type regardless of which template was selected.

Only "Blank" and "Container (HTTP)" are unaffected because they happen to match the default `serverType: 'container'`.

## Root Cause

In `web/src/components/wizard/CreationWizard.tsx`, the template step renders:

```tsx
case 'template':
  if (!selectedType) return null;
  return (
    <TemplateGrid
      resourceType={selectedType}
      selected={selectedTemplate}
      onSelect={setSelectedTemplate}  // ← store action passed directly
    />
  );
```

`setSelectedTemplate` from the store (`web/src/stores/useWizardStore.ts:134-137`) only saves the string ID and advances the step — it never updates `formData['mcp-server']`.

The Configure form renders with `data={formData['mcp-server']}`, which has the persisted default `serverType: 'container'` until the user manually changes it.

## Fix Requirements

### Required Changes

1. In `web/src/components/wizard/CreationWizard.tsx`, create a `handleTemplateSelect` callback that intercepts template selection for `mcp-server` type, applies the appropriate form data, then calls `setSelectedTemplate`.

2. Implement a mapping from template ID to `MCPServerFormData` partial:

   | Template ID | serverType | transport |
   |---|---|---|
   | `blank` | `container` | (no change) |
   | `container-http` | `container` | `http` |
   | `container-stdio` | `container` | `stdio` |
   | `external-url` | `external` | `sse` |
   | `local-process` | `local` | `stdio` |
   | `from-source` | `source` | `http` |

3. Pass `handleTemplateSelect` instead of `setSelectedTemplate` in the template step's `renderStepContent` call.

### Constraints

- Do not modify the store's `setSelectedTemplate` — other resource types (stack, resource) use it too and don't need this mapping logic.
- Do not reset the full form on template change — only update `serverType` and `transport`. Preserve any name the user already entered.
- The handler must work for all resource types (pass through unchanged for non-mcp-server types).

### Out of Scope

- Removing the template step (separate UX evaluation)
- Pre-filling other form fields from templates (e.g., image, port) — just server type and transport
- Changing stack or resource template behavior

## Implementation Guidance

### Key Files to Read

1. `web/src/components/wizard/CreationWizard.tsx` — where the fix lives; `renderStepContent` at line 429 handles step rendering; template case at line 449
2. `web/src/stores/useWizardStore.ts` — `updateFormData` action (line 139) is what you need to call; `defaultFormData` (line 62) shows the shape
3. `web/src/components/wizard/TemplateGrid.tsx` — template IDs are defined here (lines 12-49)
4. `web/src/components/wizard/steps/MCPServerForm.tsx` — `ServerType` union type and `SERVER_TYPES` array (lines 35-85)

### Files to Modify

**`web/src/components/wizard/CreationWizard.tsx`**:

Add a `handleTemplateSelect` callback inside the `CreationWizard` component (near the other `useCallback` handlers around line 143). The callback needs access to `selectedType`, `updateFormData`, and `setSelectedTemplate` — all already destructured from `useWizardStore`.

Replace the `setSelectedTemplate` passthrough in `renderStepContent` with `handleTemplateSelect`.

Since `renderStepContent` is a standalone function outside the component, you'll need to either:
- Move the handler into the template case inline (pass it as an additional prop), or
- Thread `handleTemplateSelect` as a new parameter to `renderStepContent` alongside the existing `setSelectedTemplate` parameter

The cleaner approach: pass `handleTemplateSelect` in place of `setSelectedTemplate` in the function signature at line 433 (it has the same type `(id: string | null) => void`).

### Reusable Components

`updateFormData('mcp-server', partial)` from `useWizardStore` — already used throughout the component for form field updates. Use this to apply the template-derived serverType/transport.

### Conventions to Follow

- Use `useCallback` for the handler (other handlers in the component use it)
- TypeScript: the partial type is `Partial<MCPServerFormData>` — import `MCPServerFormData` from `'../../lib/yaml-builder'` (already imported at line 22)
- The `ServerType` type is defined in `'../../lib/yaml-builder'` — use it for the mapping values

## Regression Test

### Test Outline

Add to `web/src/__tests__/MCPServerForm.test.tsx` or a new `CreationWizard.test.tsx`:

```
Test: "template selection pre-populates mcp-server form serverType"

For each template:
  - Reset wizard store to default state
  - Set selectedType to 'mcp-server'
  - Simulate template selection (call the handler with the template ID)
  - Assert formData['mcp-server'].serverType equals expected value
  - Assert formData['mcp-server'].transport equals expected transport (where applicable)

Templates to cover:
  - 'external-url' → serverType: 'external', transport: 'sse'
  - 'local-process' → serverType: 'local', transport: 'stdio'
  - 'from-source'   → serverType: 'source', transport: 'http'
  - 'container-stdio' → serverType: 'container', transport: 'stdio'
  - 'container-http' → serverType: 'container', transport: 'http'
```

### Existing Test Patterns

Look at `web/src/__tests__/MCPServerForm.test.tsx` for the test style. Tests use React Testing Library with `@testing-library/react`. Store tests can use `useWizardStore.getState()` directly for assertions.

## Potential Pitfalls

1. **Don't reset the name field**: `updateFormData` merges (spreads existing data), so only pass `{ serverType, transport }` — the user's name input survives.
2. **`blank` template**: maps to `container` but don't set a transport — leave it as whatever the user previously had or the container default.
3. **`renderStepContent` is outside the component**: the handler must be threaded through as a parameter; don't access store state inside the standalone function.

## Acceptance Criteria

1. Selecting "External URL" template → Configure screen shows "External URL" pre-selected in the Server Type section
2. Selecting "Local Process" template → Configure screen shows "Local Process" pre-selected with stdio transport locked
3. Selecting "Build from Source" template → Configure screen shows "Source" pre-selected
4. Selecting "Container (stdio)" template → Configure screen shows Container with stdio transport selected
5. Non-mcp-server resource types (stack, resource) are unaffected
6. Previously entered name field is preserved across template changes
7. Regression test passes for all template → serverType mappings

## References

- Bug evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/mcp-template-state-not-applied/bug-evaluation.md`
