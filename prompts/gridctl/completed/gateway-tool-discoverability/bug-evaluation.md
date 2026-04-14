# Bug Investigation: Gateway Tool Discoverability and Disambiguation

**Date**: 2026-04-08
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small (P1) / Trivial (P2, P3)

## Summary

Three related bugs in gridctl's MCP gateway degrade the agent experience when connected to Claude Desktop and other LLM clients. Bug 1 (missing `instructions` field on `InitializeResult`) causes cold-start inertia where the model doesn't spontaneously use gridctl tools without manual prompting. Bugs 2 and 3 cause wrong-name selection where the model constructs tool calls with un-prefixed names that fail routing. All three are low-risk, high-confidence fixes confined to `pkg/mcp/types.go`, `pkg/mcp/gateway.go`, and `pkg/mcp/router.go`.

## The Bug

**Bug 1 — Cold start**: On a fresh chat, the model does not reach for gridctl's aggregated tools. The user must explicitly prompt "use gridctl" or name the server before the model attempts any tool calls. This occurs because `InitializeResult` has no `instructions` field; the model receives zero narrative context about the gateway at session start.

**Bug 2 — Wrong-name (Title leak)**: Once the model is trying to call a tool, it frequently uses the un-prefixed form (`list_devices`) instead of the canonical namespaced form (`gridctl-local__list_devices`). This is caused by `AggregatedTools()` setting `Title` to the original un-prefixed tool name, which the model sees in tool pickers and prefers.

**Bug 3 — Weak description**: The `Description` field uses a bracketed-label format (`[gridctl-local] List devices`) rather than an instruction-shaped format that names the server and required call form explicitly. This is a soft hint that models don't reliably treat as binding routing information.

**Expected behavior**: On session start, the model receives an `instructions` string that names all registered MCP servers, their tool counts, and directs the model to use the full prefixed tool name (or `search` first in code mode). All aggregated tools have a `Title` that is either absent or equal to the prefixed name, and a `Description` that explicitly states the server affiliation and required call form.

**Discovered via**: Developer observation during Claude Desktop integration testing; documented in `bug.md` spec.

## Root Cause

### Defect Location

- `pkg/mcp/types.go:169-173` — `InitializeResult` struct has no `Instructions` field
- `pkg/mcp/gateway.go:689-713` — `HandleInitialize` returns a hardcoded struct with no instructions
- `pkg/mcp/router.go:98-106` — `AggregatedTools()` sets `Title = tool.Name` (un-prefixed) and uses weak description format

### Code Path

**Bug 1**:
```
client sends initialize → HandleInitialize() → InitializeResult{ProtocolVersion, ServerInfo, Capabilities}
                                                 ↑ no Instructions field; model gets zero narrative
```

**Bug 2**:
```
client sends tools/list → HandleToolsList() → router.AggregatedTools()
                                               ↑ Title = tool.Name (un-prefixed, e.g. "list_devices")
                                               model reads Title, prefers it → tools/call "list_devices"
                                               ParsePrefixedTool fails: "invalid tool name format"
```

**Bug 3**:
```
client sends tools/list → AggregatedTools() → Description = "[gridctl-local] List devices"
                                               model reads label, applies prior → uses un-prefixed name
```

### Why It Happens

- **Bug 1**: `InitializeResult` was defined with the three core MCP required fields but the optional `instructions` field from the 2024-11-05 spec was never added. `HandleInitialize` has no code to build or populate it.

- **Bug 2**: The comment at `router.go:98` says "Use original tool name as title for UI display." This was a reasonable initial decision but is incorrect for a gateway: the `Title` is model-visible and the model treats it as an alias for `Name`. Setting it to the un-prefixed form creates a shortcut the model prefers.

- **Bug 3**: The `[server] description` format was chosen as a quick way to signal server affiliation, but bracketed tags read as UI annotations, not as action directives. The model doesn't derive "I must call this tool by its full prefixed name" from a bracketed prefix.

### Similar Instances

None — all three defects are isolated to the `AggregatedTools()` function and `HandleInitialize`. The routing layer (`PrefixTool`, `ParsePrefixedTool`, `RouteToolCall`) is correct and has no similar issues.

## Impact

### Severity Classification

**High** — Incorrect behavior that blocks gridctl's primary integration use case. Not a crash or data loss, but a complete failure of the advertised value proposition: "connect Claude Desktop to your grid through one endpoint" requires the model to autonomously discover and use gridctl tools. These bugs prevent that.

### User Reach

Every user who runs `gridctl link` and opens a new Claude Desktop session. The provisioner (`pkg/provisioner/`) auto-injects gridctl config into 13+ supported LLM clients, so this is the default onboarding path. Affects Claude Desktop, Claude Code, Cursor, Windsurf, and all other provisioner-supported clients.

### Workflow Impact

- **Core path blocked**: Model doesn't spontaneously use gridctl tools on cold start (Bug 1). User must manually prime every session.
- **Common path degraded**: ~frequent tool call failures due to wrong-name selection (Bugs 2 and 3 compounded). User must correct the model each time.
- **Code mode fully broken**: Users with `code_mode: on` receive no guidance to call `search` first before `execute`.

### Workarounds

1. Prepend every session: "You have access to gridctl tools — use them." (low quality, manual, defeats automation)
2. Correct the model after wrong-name failures: "Call it `gridctl-local__list_devices`." (requires knowing the prefixed form)
3. No workaround for code mode discoverability.

### Urgency Signals

- Affects every new session from first `gridctl link` onward — first-minute failure
- MCP 2024-11-05 spec explicitly defines `instructions` for this use case; gridctl is non-compliant
- Claude Desktop and Claude Code both surface `instructions` into system context at handshake — this is a designed affordance gridctl is not using
- Documented in a detailed spec (`bug.md`) indicating developer awareness and intent to fix

## Reproduction

### Minimum Reproduction Steps

**Bug 1**:
1. Register ≥1 MCP server with a gridctl gateway
2. Call `HandleInitialize(InitializeParams{...})` or send an MCP `initialize` request
3. Observe: `result.Instructions == ""` (field absent in JSON response)

**Bug 2**:
1. Register a server with at least one tool (e.g., `{Name: "list_devices"}`) in the gateway
2. Call `router.AggregatedTools()`
3. Observe: `tools[0].Title == "list_devices"` — the un-prefixed name, not the prefixed form

**Bug 3**:
1. Same setup as Bug 2
2. Observe: `tools[0].Description == "[gridctl-local] ..."` — bracketed label format

### Affected Environments

All environments — bugs are deterministic code paths, not environment-specific.

### Non-Affected Environments

N/A — both the missing field and the incorrect field values are always present.

### Failure Mode

- **Bug 1**: `InitializeResult.Instructions` is the empty string. JSON response omits the field (`omitempty` if it existed; currently the field simply doesn't exist). Model has no system context about the gateway.
- **Bug 2**: Model constructs `tools/call` with `name = "list_devices"`. `ParsePrefixedTool` returns error: `"invalid tool name format: list_devices (expected agent__tool)"`. The call fails.
- **Bug 3**: System leaves the model in a clean state (no corruption), but the description provides insufficient routing guidance, compounding Bug 2.

## Fix Assessment

### Fix Surface

- `pkg/mcp/types.go`: Add `Instructions string` field with `json:"instructions,omitempty"` to `InitializeResult`
- `pkg/mcp/gateway.go`: Add `buildInstructions() string` helper; call it from `HandleInitialize`
- `pkg/mcp/router.go`: In `AggregatedTools()`, change `Title` assignment and `Description` format string
- `pkg/mcp/router_test.go`: Update `TestRouter_AggregatedTools` and `TestRouter_AggregatedTools_NoTitle` assertions; add new tests
- `pkg/mcp/gateway_test.go`: Update `TestGateway_HandleInitialize`; add 4 new test cases

### Risk Factors

- **Bug 1**: `Instructions` is optional per MCP spec (`omitempty` drops it if empty). No client depends on its absence. Zero risk.
- **Bug 2**: `Title` is optional display metadata (`omitempty`). Changing it to prefixed name or omitting it cannot affect routing. Zero risk.
- **Bug 3**: Description format change only. No code depends on the specific format. Zero risk.
- **Tests**: Existing assertions on old `Title` and `Description` values will need updates — easy mechanical changes.

### Regression Test Outline

**Bug 1 — 4 test cases needed**:
1. `TestGateway_HandleInitialize_Instructions`: Given 2 fake MCP servers, `Instructions` names both, includes tool counts, includes prefixed name example
2. `TestGateway_HandleInitialize_CodeMode`: When code mode is active, `Instructions` mentions `search` and `execute` by name
3. `TestGateway_HandleInitialize_NoServers`: With zero servers, `Instructions` is `""` and marshals without the field
4. `TestGateway_HandleInitialize_FiltersA2A`: Given 1 MCP server and 1 A2A adapter, `Instructions` names only the MCP server

**Bug 2 — 2 test cases to update + 1 new**:
- Update `TestRouter_AggregatedTools`: assert `tool.Title == "myagent__mytool"` (prefixed) instead of `"My Tool"` (or assert empty if omit strategy chosen)
- Update `TestRouter_AggregatedTools_NoTitle`: assert `tools[0].Title == "agent__notitle"` (prefixed) or `""` (omitted)
- New `TestRouter_AggregatedTools_TitleNeverLeaks`: assert no tool's `Title` equals the original un-prefixed `tool.Name`

**Bug 3 — 1 test case to update + 1 new**:
- Update `TestRouter_AggregatedTools`: assert description contains server name and prefixed tool name (not `"[myagent] A test tool"`)
- New `TestRouter_AggregatedTools_DescriptionComplete`: for every returned tool, `strings.Contains(tool.Description, serverName)` and `strings.Contains(tool.Description, prefixedName)` both hold

## Recommendation

Fix all three priorities immediately in three separate commits (P1 → P2 → P3) so each is independently bisectable and revertable. The changes are trivial-to-small, isolated, low-risk, and directly unblock gridctl's primary integration story. The spec in `bug.md` provides exact text examples for the `instructions` string, making implementation straightforward. The total code change is approximately 50-80 lines across 5 files (mostly new `buildInstructions()` logic and test updates).

Do not defer any of the three. While P2 and P3 are lower-severity individually, they are cheap to fix alongside P1 and together eliminate both the cold-start and wrong-name failure modes completely.

## References

- MCP 2024-11-05 spec — `InitializeResult.instructions` field definition
- `/Users/william/code/gridctl/bug.md` — detailed spec with exact instructions text examples
- `pkg/mcp/types.go:169-173` — `InitializeResult` struct (missing field)
- `pkg/mcp/gateway.go:689-713` — `HandleInitialize` (no instructions population)
- `pkg/mcp/router.go:82-113` — `AggregatedTools()` (Title and Description bugs)
- `pkg/mcp/router_test.go:127-175` — existing tests asserting on old behavior
- `pkg/mcp/gateway_test.go:48-73` — existing `HandleInitialize` test (no instructions assertion)
