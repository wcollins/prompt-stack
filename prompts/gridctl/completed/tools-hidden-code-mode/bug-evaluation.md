# Bug Investigation: Tools Hidden When Code Mode Active

**Date**: 2026-04-08
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Medium
**Fix Complexity**: Trivial

## Summary

When code mode is active, the MCP server detail panel shows "No tools available" under the Tools section despite the count badge correctly displaying the server's tool count (e.g., "40"). This is caused by `ToolList.tsx` filtering the global tools store by server name prefix — but code mode replaces the tool list with two unprefixed meta-tools (`search`, `execute`), which match nothing. The gateway actively suggests code mode to users when total tool count exceeds 50, reliably driving users into this broken state.

## The Bug

**Wrong behavior**: MCP server detail panel shows "No tools available" in the Tools section with a count badge of "40".
**Expected behavior**: Either show the actual tools (if accessible) or a contextual message explaining code mode is active and tools are accessed via `search`/`execute` meta-tools.
**Discovery**: Visual inspection — user reported regression after the gateway logged a suggestion to enable `code_mode`.

## Root Cause

### Defect Location

- **Primary**: `web/src/components/ui/ToolList.tsx:43-60` — filter assumes all tools in store are prefixed with server names; fails silently when code mode meta-tools are present
- **Contributing**: `pkg/mcp/gateway.go:717-724` — `HandleToolsList()` returns only meta-tools when code mode is active, with no signal to the frontend about this substitution
- **Trigger path**: `pkg/mcp/gateway.go:652-660` — `logToolCountHint()` actively suggests enabling code mode at 50+ total tools

### Code Path

```
User enables code_mode: on in config
    → gateway.SetCodeMode() sets g.codeMode (gateway.go:154)

Frontend polling (usePolling.ts:29-32):
    Promise.all([fetchStatus(), fetchTools()])

fetchStatus() → /api/status → gateway.Status() → client.Tools() → 40 tools cached
    → MCPServerNodeData.toolCount = 40  ✓ correct

fetchTools() → /api/tools → HandleToolsList() (gateway.go:717):
    if g.codeMode != nil:            ← code mode IS active
        return cm.ToolsList()        ← returns [search, execute], no server prefix

setTools([search, execute])          ← store.tools = [search, execute]

ToolList.tsx:43:
    filter t.name.startsWith("github__")
        "search".startsWith("github__") → false
        "execute".startsWith("github__") → false
    serverTools = []

Line 55-60: "No tools available"    ← displayed to user ✗
```

### Why It Happens

`HandleToolsList()` intentionally replaces all server tools with 2 gateway-level meta-tools when code mode is active. This is correct behavior for LLM clients (reduces context by ~78 tools to 2). However, `ToolList.tsx` was never updated to handle this substitution — it assumes the global tools store always contains prefixed server tools. When code mode meta-tools arrive, the prefix filter silently discards them, showing a misleading empty state.

### Similar Instances

The same `useStackStore.tools` source is used by the Workflow Visual Designer's toolbox palette. It would also show an empty or wrong tool list when code mode is active (separate code path, same data source).

## Impact

### Severity Classification

**Incorrect behavior** — informational display shows misleading data. Not a crash or data loss, but actively confusing because the count badge and the list contradict each other.

### User Reach

All users who have enabled `code_mode: on`. This is a non-trivial population because:
- The gateway explicitly logs a suggestion to enable code mode at 50+ total tools (`logToolCountHint`)
- Three MCP servers averaging 10–20 tools each exceeds this threshold easily
- Users following the log hint reliably land in this broken state

### Workflow Impact

Sidebar tool browsing is broken for all code mode users. Tool execution at the gateway level is unaffected — the gateway routes calls correctly regardless. The broken display is informational only.

### Workarounds

None in the sidebar. Users must:
1. Recognize the count/list contradiction
2. Know code mode affects the tool display
3. Find tool details elsewhere (e.g., by checking the YAML config or CLI)

The gateway logs a "Code Mode" indicator in the status bar (`StatusBar.tsx:91-96`) and on the gateway node card (`GatewayNode.tsx:146-151`), so code mode IS visible in the UI — but the Tools section gives no indication that code mode is why the list is empty.

### Urgency Signals

The gateway's own `logToolCountHint()` function is an active recruitment funnel into this broken state. Any moderately large stack (3 servers × 20 tools = 60 > threshold of 50) will trigger the log suggestion.

## Reproduction

### Minimum Reproduction Steps

1. Configure gridctl with `code_mode: on` in the gateway section of `stack.yaml`
2. Run `gridctl apply stack.yaml` with at least one MCP server configured
3. Open the gridctl UI
4. Select any MCP server node on the canvas
5. Click to expand the "Tools" section in the detail panel
6. Observe "No tools available" despite the count badge showing a non-zero number

### Affected Environments

All environments with `code_mode: on` or `--code-mode` flag set.

### Non-Affected Environments

`code_mode: off` (default) — tools display normally.

### Failure Mode

The system is recoverable — code mode can be disabled by removing the config option. Data is not corrupted.

## Fix Assessment

### Fix Surface

Single file: `web/src/components/ui/ToolList.tsx` (~10 lines)

The fix: read `codeMode` from `useStackStore`, and when code mode is active, show a contextual message instead of the misleading empty state.

### Risk Factors

Low. The change is isolated to one presentational component with no side effects on state or data flow.

### Regression Test Outline

Test file: `web/src/__tests__/ToolList.test.tsx` (new file)

```
describe("ToolList with code mode active")
  test("shows code mode message when codeMode is on and tools are meta-tools only")
    - Render ToolList with serverName="github"
    - Store state: tools = [{name: "search", ...}, {name: "execute", ...}], codeMode = "on"
    - Assert: renders code mode explanation message
    - Assert: does NOT render "No tools available"
    - Assert: does NOT render any github__ tool items

describe("ToolList with code mode off")
  test("filters and shows server-prefixed tools when codeMode is null")
    - Render ToolList with serverName="github"
    - Store state: tools = [{name: "github__create_issue", ...}], codeMode = null
    - Assert: renders "create_issue" tool item
```

## Recommendation

**Fix immediately.** The gateway's tool count hint at 50+ tools actively drives users toward code mode. Any user following the gateway's own suggestion encounters this broken display. The fix is trivial (10 lines, zero risk) and the impact on code mode users is significant (100% of their sidebar tool browsing is broken). There's no reason to defer.

The fix should display a clear code mode message in the Tools section panel:
> "Code mode active — tools are wrapped by search/execute meta-tools. Individual tool schemas are still available in the gateway config."

## References

- Root cause: `web/src/components/ui/ToolList.tsx:43-60`
- Code mode tool substitution: `pkg/mcp/gateway.go:717-724`
- Code mode meta-tools: `pkg/mcp/codemode.go:37-43`, `pkg/mcp/codemode_tools.go`
- Gateway hint trigger: `pkg/mcp/gateway.go:652-660`
- Status bar code mode badge: `web/src/components/layout/StatusBar.tsx:90-96`
- Gateway node code mode badge: `web/src/components/graph/GatewayNode.tsx:145-151`
