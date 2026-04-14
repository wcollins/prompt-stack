# Bug Fix: Tools Hidden When Code Mode Active

## Context

gridctl is a Go + React/TypeScript gateway for MCP (Model Context Protocol) servers. The backend is in Go (`pkg/mcp/`, `internal/api/`). The frontend is in React with Zustand state management (`web/src/`). The UI displays a canvas of MCP server nodes; clicking a server opens a sidebar detail panel.

**Key architecture**:
- `GET /api/status` → returns each server's `toolCount` (from cached `client.Tools()`)
- `GET /api/tools` → returns all aggregated tool definitions (prefixed as `serverName__toolName`)
- `useStackStore` (Zustand) holds both `mcpServers[]` (with toolCount) and `tools[]` (full definitions)
- `ToolList` component reads from `useStackStore.tools` and filters by server name prefix

## Investigation Context

- Root cause confirmed at `web/src/components/ui/ToolList.tsx:43-60` and `pkg/mcp/gateway.go:717-724`
- Reproduces deterministically whenever `code_mode: on` is set in gateway config
- The gateway itself drives users toward code mode via a log hint at 50+ total tools (`logToolCountHint` at `pkg/mcp/gateway.go:652`)
- UI already has code mode visual indicators in StatusBar and GatewayNode — just ToolList is unaware
- Full investigation: `prompt-stack/prompts/gridctl/tools-hidden-code-mode/bug-evaluation.md`

## Bug Description

**What is wrong**: When code mode is enabled, the MCP server detail panel shows "No tools available" under the Tools section, even though the count badge correctly shows the server's tool count (e.g., "40 tools").

**Expected**: Either display actual tool information, or show a clear, contextual message explaining that code mode is active and tools are accessed via meta-tools.

**How it manifests**: Count badge and list contradict each other — count shows 40, list shows empty.

**Who is affected**: All users with `code_mode: on` in their gateway config.

## Root Cause

When code mode is active, `HandleToolsList()` in `pkg/mcp/gateway.go:717` returns only two unprefixed meta-tools (`search` and `execute`) instead of the usual `serverName__toolName` prefixed tools.

`ToolList.tsx:43-44` filters the global tools store by prefix:
```tsx
let serverTools = (tools ?? []).filter((t) =>
  t.name.startsWith(`${serverName}${TOOL_NAME_DELIMITER}`)
);
```

Meta-tool names (`"search"`, `"execute"`) do not start with any server prefix. The filter returns empty. `ToolList.tsx:55-60` then shows "No tools available" — misleading because the server genuinely has 40 tools.

The tool COUNT is correct because it comes from a different source (`/api/status` → `client.Tools()`) which is unaffected by code mode.

## Fix Requirements

### Required Changes

1. **`web/src/components/ui/ToolList.tsx`**: Read `codeMode` from `useStackStore`. When `codeMode` is active (`codeMode && codeMode !== 'off'`), render a contextual message instead of the server-prefix-filtered list.

   The message should explain WHY tools aren't listed and what to do instead. For example:
   > Code mode active — tools are accessible via the **search** and **execute** meta-tools.

2. Do NOT modify any backend code — this is purely a frontend display fix.

### Constraints

- The fix must NOT change any data fetching or store state
- Do NOT remove the "No tools available" fallback — keep it for when code mode is off and a server genuinely has no tools
- The message for code mode must be clearly different from the empty-state message to avoid confusion
- Keep the component style consistent with the existing "No tools available" styling (`text-sm text-text-muted italic px-4 py-2`)

### Out of Scope

- Do not modify how code mode tools are fetched or stored
- Do not change the backend `HandleToolsList()` behavior
- Do not add tool execution or interaction to the sidebar

## Implementation Guidance

### Key Files to Read

1. `web/src/components/ui/ToolList.tsx` — the component to fix; understand the full render logic before making changes
2. `web/src/stores/useStackStore.ts` — to understand the `codeMode: string | null` field and its values
3. `web/src/components/layout/StatusBar.tsx:90-96` — example of how code mode is checked elsewhere in the UI (pattern to follow)

### Files to Modify

**`web/src/components/ui/ToolList.tsx`** — Add a single `codeMode` selector at the top of the `ToolList` function (alongside the existing `tools` selector). Add an early return before the filter logic for when code mode is active.

Approximate structure:
```tsx
export function ToolList({ serverName, whitelist }: ToolListProps) {
  const tools = useStackStore((s) => s.tools);
  const codeMode = useStackStore((s) => s.codeMode);  // add this

  // Add early return for code mode
  if (codeMode && codeMode !== 'off') {
    return (
      <p className="text-sm text-text-muted italic px-4 py-2">
        {/* message explaining code mode */}
      </p>
    );
  }

  // existing filter logic unchanged below
  let serverTools = (tools ?? []).filter(...);
  // ...
}
```

### Reusable Components

- The existing `<p className="text-sm text-text-muted italic px-4 py-2">` pattern is already used for the "No tools available" empty state — reuse the same classes for visual consistency

### Conventions to Follow

- Keep it simple: this is a 5–10 line change
- No new imports needed (codeMode is already in the store; no new icons or components required)
- TypeScript: `codeMode` is typed as `string | null` in the store
- Do NOT add comments explaining what code mode is — the component already has good inline comments

## Regression Test

### Test Outline

Create `web/src/__tests__/ToolList.test.tsx`:

```
Test 1: "shows code mode message when code mode is active"
  - Mock useStackStore to return:
      tools: [{ name: "search", ... }, { name: "execute", ... }]
      codeMode: "on"
  - Render: <ToolList serverName="github" />
  - Assert: screen contains text about code mode
  - Assert: screen does NOT contain "No tools available"
  - Assert: screen does NOT contain tool items (no github__ prefixed tools)

Test 2: "shows tools normally when code mode is off"
  - Mock useStackStore to return:
      tools: [{ name: "github__create_issue", inputSchema: {}, ... }]
      codeMode: null
  - Render: <ToolList serverName="github" />
  - Assert: screen contains "create_issue"
  - Assert: screen does NOT contain "No tools available"

Test 3: "shows empty state when server has no tools and code mode is off"
  - Mock useStackStore to return:
      tools: []
      codeMode: null
  - Render: <ToolList serverName="github" />
  - Assert: screen contains "No tools available"
```

### Existing Test Patterns

Look at `web/src/__tests__/CustomNode.test.tsx` for the testing pattern — it uses `vi.mock` to mock `useStackStore` and `@testing-library/react` for rendering. Follow the same pattern.

The store is mocked with:
```tsx
vi.mock('../stores/useStackStore', () => ({
  useStackStore: vi.fn(),
}));
```

Then in each test:
```tsx
(useStackStore as Mock).mockImplementation((selector) =>
  selector({ tools: [...], codeMode: 'on', ... })
);
```

## Potential Pitfalls

- `codeMode` in the store can be `null` (when off) or `"on"` (string). Check both — use `codeMode && codeMode !== 'off'` to guard against unexpected values (same pattern as `StatusBar.tsx:91`)
- The `useStackStore` selector syntax is `useStackStore((s) => s.field)` — call it as a separate hook, not merged with the existing `tools` selector

## Acceptance Criteria

1. When `codeMode` is `"on"` in the store, `ToolList` renders a message about code mode — not "No tools available"
2. The message is distinct from the empty-state message so users understand WHY the list is different
3. When `codeMode` is `null` (off), `ToolList` behavior is identical to before this fix
4. Regression tests cover all three cases: code mode on, code mode off with tools, code mode off with no tools
5. No existing tests break

## References

- Full bug investigation: `prompt-stack/prompts/gridctl/tools-hidden-code-mode/bug-evaluation.md`
- Code mode meta-tools: `pkg/mcp/codemode_tools.go` (defines `search` and `execute`)
- Code mode in gateway: `pkg/mcp/gateway.go:717-724` (the HandleToolsList short-circuit)
- Store definition: `web/src/stores/useStackStore.ts:28` (`codeMode: string | null`)
- StatusBar code mode check: `web/src/components/layout/StatusBar.tsx:91` (pattern reference)
