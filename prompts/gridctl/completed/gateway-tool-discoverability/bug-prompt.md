# Bug Fix: Gateway Tool Discoverability and Disambiguation

## Context

gridctl is a Go-based MCP (Model Context Protocol) gateway that aggregates tools from multiple downstream MCP servers into a single endpoint. It is the primary way users connect Claude Desktop, Claude Code, and other LLM clients to their infrastructure. The gateway is in `pkg/mcp/` and exposes tools via two transports: HTTP SSE (`handler.go`) and Streamable HTTP (`streamable.go`).

Tech stack: Go 1.25+, stdlib testing with `gomock` for mocks, `pkg/mcp/` package with `gateway.go`, `router.go`, `types.go` as the core files.

## Investigation Context

- Root cause confirmed: three isolated defects in `pkg/mcp/types.go`, `pkg/mcp/gateway.go`, and `pkg/mcp/router.go`
- All three are low-risk, high-confidence changes — no architectural changes required
- Routing layer (`PrefixTool`, `ParsePrefixedTool`, `RouteToolCall`, `HandleToolsCall`) is correct; do not touch it
- Tests in `router_test.go` (lines 127-175) assert on the old buggy behavior — they must be updated
- Full investigation: `prompts/gridctl/gateway-tool-discoverability/bug-evaluation.md`

## Bug Description

Two failure modes degrade the agent experience when gridctl connects to Claude Desktop:

1. **Cold start** — on a fresh chat, the model does not spontaneously use gridctl's aggregated tools. The user must explicitly prompt "use gridctl" before the model attempts any tool calls. Cause: `InitializeResult` has no `instructions` field, so the model gets zero narrative about the gateway at session start.

2. **Wrong-name selection** — the model frequently constructs tool calls using the un-prefixed form (`list_devices`) instead of the canonical namespaced form (`gridctl-local__list_devices`). Cause: `AggregatedTools()` sets `Title = tool.Name` (un-prefixed), which the model sees in tool pickers and prefers; and the `Description` format `[server] desc` is a soft label, not a routing directive.

## Root Cause

### Bug 1 (Cold start)

**`pkg/mcp/types.go:169-173`** — `InitializeResult` is missing the `instructions` field:
```go
// Current (wrong):
type InitializeResult struct {
    ProtocolVersion string       `json:"protocolVersion"`
    ServerInfo      ServerInfo   `json:"serverInfo"`
    Capabilities    Capabilities `json:"capabilities"`
}
```

**`pkg/mcp/gateway.go:689-713`** — `HandleInitialize` returns a hardcoded struct with no instructions:
```go
return &InitializeResult{
    ProtocolVersion: MCPProtocolVersion,
    ServerInfo:      g.ServerInfo(),
    Capabilities:    caps,
}, session, nil
```

### Bug 2 (Title leak)

**`pkg/mcp/router.go:98-108`** — `AggregatedTools()` sets `Title` to the un-prefixed name:
```go
title := tool.Name     // e.g., "list_devices"
if tool.Title != "" {
    title = tool.Title
}
prefixedTool := Tool{
    Name:        PrefixTool(name, tool.Name),  // "gridctl-local__list_devices"
    Title:       title,                         // "list_devices" <-- WRONG
    Description: fmt.Sprintf("[%s] %s", name, tool.Description),  // weak label
    InputSchema: tool.InputSchema,
}
```

## Fix Requirements

### Required Changes

**Change 1: Add `Instructions` field to `InitializeResult`** (`pkg/mcp/types.go`)

```go
type InitializeResult struct {
    ProtocolVersion string       `json:"protocolVersion"`
    ServerInfo      ServerInfo   `json:"serverInfo"`
    Capabilities    Capabilities `json:"capabilities"`
    Instructions    string       `json:"instructions,omitempty"`
}
```

**Change 2: Add `buildInstructions()` helper to Gateway** (`pkg/mcp/gateway.go`)

Implement a method `func (g *Gateway) buildInstructions() string` that:
- Acquires `g.mu.RLock()` to read `g.serverMeta` and `g.codeModeStr`
- Iterates over `g.serverMeta` keys (sorted deterministically) to find MCP servers
- For each MCP server, reads tool count from `g.router.Clients()` or by looking up the client by name
- Returns `""` if no MCP servers are registered (the `omitempty` tag handles the JSON)
- Returns one of two variants based on `g.codeModeStr == "on"`:

  **Code mode OFF** (normal aggregation):
  > "gridctl is an MCP gateway aggregating tools from N downstream MCP servers: `server-a` (M tools), `server-b` (K tools). Use these tools as the primary way to interact with the underlying systems in this session. Tool names are namespaced as `<server>__<tool>` — always invoke them by their full prefixed name (e.g. `server-a__example_tool`). Call `tools/list` to see the full inventory."

  **Code mode ON**:
  > "gridctl is an MCP gateway running in code mode, aggregating tools from N downstream MCP servers: `server-a`, `server-b` (T tools total, hidden behind meta-tools to save context). Two meta-tools are exposed: `search` to discover tools by keyword and `execute` to run JavaScript that calls them via `mcp.callTool(serverName, toolName, args)`. ALWAYS call `search` first (with an empty query to list everything, or a keyword to filter) before attempting any other operation."

  Keep the string under ~600 characters. Sort the server list deterministically.

  **Important**: use `g.router` to get tool counts — call `g.router.Clients()` and find the matching client by name, then call `.Tools()` to count. Do not read `serverMeta` for tool counts; `serverMeta` holds config, not live tool data.

**Change 3: Call `buildInstructions()` from `HandleInitialize`** (`pkg/mcp/gateway.go`)

```go
return &InitializeResult{
    ProtocolVersion: MCPProtocolVersion,
    ServerInfo:      g.ServerInfo(),
    Capabilities:    caps,
    Instructions:    g.buildInstructions(),
}, session, nil
```

**Change 4: Fix `Title` in `AggregatedTools()`** (`pkg/mcp/router.go`)

Replace the current title logic. Two acceptable options — choose one and justify:

- **Option A (omit)**: Do not set `Title` at all. The `omitempty` tag on the `Tool.Title` field means it is dropped from JSON. Simplest fix; clients that render `Title` will fall back to `Name`.
- **Option B (prefix)**: Set `Title = prefixedName`. The picker shows the same string as the required `tools/call` name, eliminating ambiguity.

**Recommendation: Option B (prefix).** It keeps tool pickers readable while eliminating the shortcut alias. Implement as:

```go
prefixedName := PrefixTool(name, tool.Name)
prefixedTool := Tool{
    Name:        prefixedName,
    Title:       prefixedName,   // same as Name — no shortcut alias
    Description: ...,            // see Change 5
    InputSchema: tool.InputSchema,
}
```

**Change 5: Strengthen `Description` format in `AggregatedTools()`** (`pkg/mcp/router.go`)

```go
Description: fmt.Sprintf(
    "MCP server: %s. Call using the exact tool name %q. %s",
    name, prefixedName, tool.Description,
),
```

Example output: `MCP server: gridctl-local. Call using the exact tool name "gridctl-local__list_devices". List all connected devices and their status.`

### Constraints

- Do NOT change `PrefixTool`, `ParsePrefixedTool`, `RouteToolCall`, `HandleToolsCall`, or `HandleCall` — these are correct
- Do NOT change any provisioner code (`pkg/provisioner/`)
- Do NOT change transport code (`handler.go`, `streamable.go`, `sse.go`, `stdio.go`) — they already serialize `InitializeResult` and will pick up the new field automatically
- `buildInstructions()` must use the `serverMeta` filter (same as `Status()`) to exclude non-MCP clients (A2A adapters)
- `buildInstructions()` must sort server names for deterministic output
- `buildInstructions()` must NOT hold the router lock while holding the gateway lock (acquire gateway lock for `serverMeta`/`codeModeStr`, then call `g.router.Clients()` after releasing it, or structure accordingly to avoid deadlock)

### Out of Scope

- Structured server metadata on `Tool._meta`
- A third code-mode meta-tool (`list_servers` / `catalog`)
- Reviewing provisioner output for un-prefixed name leaks
- Reconciling the default Claude Desktop config key (`gridctl`) with downstream server prefixes (`gridctl-local`)
- Any changes to the `__` delimiter or prefix scheme

## Implementation Guidance

### Key Files to Read

1. **`pkg/mcp/types.go`** — `InitializeResult` (lines 168-173), `Tool` struct (lines 175-181). These are the types being modified.
2. **`pkg/mcp/gateway.go`** — `HandleInitialize` (lines 689-713), `Gateway` struct fields (`serverMeta`, `codeModeStr`, `codeMode` at lines 78-108), `Status()` (lines 1183-1244) for the `serverMeta` filter pattern to replicate in `buildInstructions()`, `CodeModeStatus()` (lines 290-298) for how `codeModeStr` is read.
3. **`pkg/mcp/router.go`** — `AggregatedTools()` (lines 82-113), `PrefixTool()`, `ParsePrefixedTool()`, `Clients()` method.
4. **`pkg/mcp/router_test.go`** — `TestRouter_AggregatedTools` (lines 127-154) and `TestRouter_AggregatedTools_NoTitle` (lines 156-175). These assert on old behavior and must be updated.
5. **`pkg/mcp/gateway_test.go`** — `TestGateway_HandleInitialize` (lines 48-73). Verify it still passes after adding `Instructions`. Add new test functions.
6. **`pkg/mcp/mock_helpers_test.go`** — `setupMockAgentClient()`. This is how fake MCP clients are created in tests.

### Files to Modify

| File | Change |
|------|--------|
| `pkg/mcp/types.go` | Add `Instructions string` field to `InitializeResult` |
| `pkg/mcp/gateway.go` | Add `buildInstructions()` helper; populate `Instructions` in `HandleInitialize` |
| `pkg/mcp/router.go` | Fix `Title` and `Description` in `AggregatedTools()` |
| `pkg/mcp/router_test.go` | Update assertions in `TestRouter_AggregatedTools` and `TestRouter_AggregatedTools_NoTitle`; add new tests |
| `pkg/mcp/gateway_test.go` | Add new test functions for `buildInstructions` behavior |

### Reusable Components

- `g.SetServerMeta(cfg MCPServerConfig)` (gateway.go:587) — use this in tests to register a fake MCP server in `serverMeta` without going through full `RegisterMCPServer`. Pass `MCPServerConfig{Name: "server-name"}`.
- `setupMockAgentClient(ctrl, name, tools)` (mock_helpers_test.go:10) — creates a `MockAgentClient` with defaults. Add it to gateway with `g.Router().AddClient(client); g.Router().RefreshTools()`.
- `sort.Strings()` — already imported in `gateway.go` and `router.go`. Use for deterministic server ordering.
- `strings.Builder` — idiomatic for building the instructions string.

### Conventions to Follow

- Lock ordering: gateway lock (`g.mu`) first, router lock second. `buildInstructions` should acquire `g.mu.RLock()` to read `serverMeta` and `codeModeStr`, then release it before calling `g.router.Clients()` (which acquires the router lock internally). Alternatively, read the client list separately and cross-reference.
- Test functions: `func TestGateway_Foo(t *testing.T)` naming, no subtests needed, standard `t.Fatalf` / `t.Errorf` assertions.
- No `t.Parallel()` in new tests (not used in this package).
- Existing mock setup pattern: `ctrl := gomock.NewController(t)`, `setupMockAgentClient(ctrl, name, tools)`.

## Regression Tests

### Tests to Update

**`pkg/mcp/router_test.go:TestRouter_AggregatedTools` (lines 127-154)**:
- Update `tool.Title` assertion: `"My Tool"` → `"myagent__mytool"` (if Option B chosen)
- Update `tool.Description` assertion: `"[myagent] A test tool"` → `"MCP server: myagent. Call using the exact tool name \"myagent__mytool\". A test tool"`

**`pkg/mcp/router_test.go:TestRouter_AggregatedTools_NoTitle` (lines 156-175)**:
- Update `tools[0].Title` assertion: `"notitle"` → `"agent__notitle"` (if Option B) or `""` (if Option A)
- Add assertion that `Title != "notitle"` (the original un-prefixed name must NOT appear)

### New Tests to Add

**`pkg/mcp/gateway_test.go`** — add the following test functions:

```
TestGateway_HandleInitialize_Instructions
  - Register two fake MCP servers via SetServerMeta + AddClient + RefreshTools
  - Call HandleInitialize
  - Assert: Instructions != ""
  - Assert: strings.Contains(Instructions, "server-a") && strings.Contains(Instructions, "server-b")
  - Assert: !strings.Contains(Instructions, "code mode") (code mode off variant)
  - Assert: strings.Contains(Instructions, "__") (prefixed name example present)

TestGateway_HandleInitialize_InstructionsCodeMode
  - Register one fake MCP server
  - Enable code mode (g.codeMode is not nil; check how SetCodeMode works or directly set g.codeModeStr = "on")
  - Call HandleInitialize
  - Assert: strings.Contains(Instructions, "search")
  - Assert: strings.Contains(Instructions, "execute")

TestGateway_HandleInitialize_InstructionsNoServers
  - No servers registered (empty gateway from NewGateway())
  - Call HandleInitialize
  - Assert: Instructions == ""
  - Assert: JSON marshal of result does NOT contain "instructions" key

TestGateway_HandleInitialize_InstructionsFiltersNonMCP
  - Register one MCP server via SetServerMeta + AddClient
  - Register one A2A adapter via AddClient only (no SetServerMeta call)
  - Call HandleInitialize
  - Assert: Instructions contains the MCP server name
  - Assert: Instructions does NOT contain the A2A adapter name
```

**`pkg/mcp/router_test.go`** — add:

```
TestRouter_AggregatedTools_TitleNeverLeaks
  - Register two servers each with two tools (no pre-existing Title)
  - Call AggregatedTools()
  - For each returned tool, assert tool.Title != original un-prefixed tool name

TestRouter_AggregatedTools_DescriptionComplete
  - Register a server with one tool
  - Call AggregatedTools()
  - Assert strings.Contains(tool.Description, serverName)
  - Assert strings.Contains(tool.Description, tool.Name) (the prefixed form)
```

### Existing Test Patterns

Test files use stdlib `testing` package. No test framework beyond `gomock`. Assertions are manual `t.Errorf`/`t.Fatalf` comparisons. Tests are not parallel. JSON marshal checks use `json.Marshal` + `strings.Contains` on the output string.

## Potential Pitfalls

1. **Lock ordering deadlock**: If `buildInstructions` holds `g.mu.RLock()` and then calls any router method that acquires the router lock, verify there is no reverse-lock path elsewhere. The safest approach: read `serverMeta` and `codeModeStr` under `g.mu.RLock()`, release it, then call `g.router.Clients()` to get live client data.

2. **`g.codeMode` vs `g.codeModeStr`**: The struct has both. `codeModeStr` is the string `"on"` or `""` — branch on `g.codeModeStr == "on"` as stated in the spec. Do not branch on `g.codeMode != nil` (they should be equivalent but `codeModeStr` is the authoritative status string already used by `CodeModeStatus()`).

3. **Tool count source**: Tool counts come from the live router clients (`.Tools()` on the `AgentClient`), not from `serverMeta` (which holds only config). Cross-reference: for each server name in `serverMeta`, find the matching client in `g.router.Clients()` by name, then count its tools.

4. **`omitempty` behavior**: With `Instructions string \`json:"instructions,omitempty"\``, Go omits the field from JSON only when the string is `""` (zero value). Make sure `buildInstructions()` returns `""` (not `" "` or `"gridctl is..."` when no servers are registered) so zero-server marshaling works correctly.

5. **Instructions string length**: Keep under ~600 characters. The spec provides exact template text — follow it rather than inventing new wording. For code mode on, the total server list is just names without tool counts (to stay under budget).

6. **Existing test assertions on Description format**: After the fix, `TestRouter_AggregatedTools` will fail because `tool.Description != "[myagent] A test tool"`. Update these assertions before running tests, or the test suite will fail.

## Acceptance Criteria

1. `InitializeResult.Instructions` is populated (non-empty) whenever at least one MCP server is registered with the gateway.
2. The instructions string correctly lists all registered MCP servers (but not non-MCP router clients like A2A adapters) in sorted order with their tool counts (code mode off) or just names (code mode on).
3. The instructions string differs between code mode on and code mode off: off-variant instructs use of full prefixed names; on-variant instructs calling `search` and `execute`.
4. With zero MCP servers, `Instructions` is `""` and the `instructions` key is absent from the JSON response.
5. `AggregatedTools()` never emits a `Title` whose value equals the original un-prefixed `tool.Name` (e.g., `Title == "list_devices"` when `Name == "gridctl-local__list_devices"` is prohibited).
6. Every aggregated tool's `Description` contains both the server name and the fully prefixed tool name.
7. All existing tests in `pkg/mcp/` pass (after updating assertions that encoded old behavior).
8. New tests pass: `TestGateway_HandleInitialize_Instructions`, `TestGateway_HandleInitialize_InstructionsCodeMode`, `TestGateway_HandleInitialize_InstructionsNoServers`, `TestGateway_HandleInitialize_InstructionsFiltersNonMCP`, `TestRouter_AggregatedTools_TitleNeverLeaks`, `TestRouter_AggregatedTools_DescriptionComplete`.

## References

- `bug.md` in the gridctl repo root — detailed spec with exact instructions text, acceptance criteria, and explicit out-of-scope items
- `prompts/gridctl/gateway-tool-discoverability/bug-evaluation.md` — full investigation report
- MCP 2024-11-05 spec — `InitializeResult.instructions` field definition
- `pkg/mcp/gateway.go:1183-1244` — `Status()` method as reference for the `serverMeta` filter pattern
