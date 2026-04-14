# Feature Implementation: Visual Agent Builder & Test Flight Playground

## Context

**gridctl** is a production-grade MCP (Model Context Protocol) gateway and agent orchestration platform. The tech stack is:
- **Backend**: Go 1.24, `net/http` standard library, custom JSON-RPC 2.0 (`pkg/jsonrpc`), OpenTelemetry tracing (`pkg/tracing`), Zustand state management pattern mirrored in Go packages
- **Frontend**: React 19.2.0, TypeScript ~5.9.3, XYFlow/React Flow 12.10.0, Zustand 5.0.9, Vite 7.2.4, Tailwind CSS 4.1.18, `react-resizable-panels` 4.5.8
- **Architecture**: Go API server (`internal/api/api.go`) serves both REST endpoints and the embedded React SPA. Canvas (`web/src/components/graph/Canvas.tsx`) is the primary UI surface. State is managed via Zustand stores (`useStackStore`, `useUIStore`, `useTracesStore`, etc.).

**Key existing patterns this feature builds on:**
- Canvas overlays: `WiringModeOverlay.tsx`, `SpecModeOverlay.tsx` — conditionally rendered overlays with boolean toggle flags in `useUIStore`
- Bottom panel tabs: `BottomPanel.tsx` with 4 tabs (Logs, Metrics, Spec, Traces) — each tab is a constant in `TABS` array, content is `invisible` when not active
- Sidebar/Inspector: `Sidebar.tsx` with context-aware content based on `selectedNodeId`
- Subprocess management: `pkg/mcp/process.go` (`ProcessClient`) — `exec.Cmd` with stdin/stdout piping for MCP server processes
- SSE streaming: `internal/api/api.go` registers SSE server at `/sse`; frontend has `useSSEShutdown` hook consuming `EventSource`
- Agent config: `pkg/config/types.go` `Agent` struct has `Runtime string` and `Prompt string` fields reserved for headless agents

## Evaluation Context

- **No existing tool combines** MCP-native topology canvas + integrated test playground + CLI proxy authentication — confirmed gap via market research
- **CLI proxy validated**: CLIProxyAPI (20k stars) confirms massive demand for "use my $20/mo subscription as API." Anthropic's own Agent SDK spawns `claude` CLI as subprocess — the pattern is officially supported
- **Official Go SDKs available** for all three LLM providers: `anthropics/anthropic-sdk-go` v1.19.0 (GA), `openai/openai-go` v1.x (GA), `googleapis/go-genai` (GA May 2025; `google/generative-ai-go` is deprecated)
- **UX benchmark**: LangGraph Studio's reasoning trace + canvas node animation is the gold standard. Two-layer animation (node ring for thinking, animated edges for active tool calls) is achievable with zero custom CSS via XYFlow's `animated: true` edge property
- **Risk mitigation**: CLI Proxy (Path B) should ship in a second phase, after Path A (direct API key) is feature-complete. Path A must work as a standalone
- Full evaluation: `prompts/gridctl/visual-agent-builder-playground/feature-evaluation.md`

## Feature Description

Add two integrated components to gridctl:

1. **Visual Agent Builder** — A canvas mode for configuring headless agents. Users toggle "Agent Builder Mode," then double-click an AgentNode to open an Inspector Panel (right-aligned slide-out). The Inspector has three tabs: **Config** (system prompt editor with `${vault:KEY}` variable support), **Tools** (checklist of available tools from connected MCP servers), and **Preview** (live YAML that updates as the user edits). Interactive edge-dragging (extending the existing WiringModeOverlay pattern) lets users wire MCP servers to agents visually.

2. **Test Flight Playground** — A 5th tab in the BottomPanel for testing draft agents via real-time chat. The backend spawns an LLM client (via direct API key or CLI subprocess) and routes tool calls through gridctl's existing MCP gateway. An SSE stream delivers both the LLM response and tool call trace data to the frontend. The Playground shows a chat message list, a Reasoning Waterfall (tool call timeline, expandable on click), and canvas nodes "light up" when their tools are being called.

**Three-path authentication:**
- **Path A** (direct API key): gridctl backend calls Anthropic/OpenAI/Gemini API directly using official Go SDKs. API keys pulled from vault.
- **Path B** (CLI proxy): gridctl spawns the local `claude` or `gemini` CLI as a subprocess, pipes user messages via stdin, captures responses from stdout. The CLI connects back to gridctl as its MCP server.
- **Path C** (local inference): gridctl calls any OpenAI-compatible local endpoint (Ollama default: `http://localhost:11434/v1`). Zero auth, zero cost, fully offline — aligns with gridctl's local-first philosophy.

## Requirements

### Functional Requirements

**Phase A — Inspector + Playground (API Key Auth)**

1. A new "Agent Builder Mode" toggle button appears in Canvas.tsx's bottom-left control panel, styled identically to existing mode toggles (ring indicator when active, icon with tooltip)
2. When Agent Builder Mode is active, double-clicking an AgentNode opens the Inspector Panel from the right side
3. Inspector Panel has three tabs: Config, Tools, Preview
4. Config tab: textarea for system prompt, with `${vault:KEY}` template variables highlighted in amber and standard `${VAR}` env variables highlighted in blue. Monospace font. Minimum 6 visible lines, resizable. When the user types `${vault:`, the editor calls `GET /api/vault` and renders an inline dropdown of available vault key names. Selecting a key completes the `${vault:KEY}` expression.
5. Tools tab: checklist of all tools available from MCP servers connected to this agent (via `uses` field). Checked = included in agent's tool access. Unchecked = excluded. Server name shown as subdued label beneath each tool.
6. Preview tab: read-only YAML block showing the serialized agent config as it stands. Updates immediately when Config or Tools are modified.
7. BottomPanel gains a 5th tab: "Playground" (icon: `MessageSquare` from lucide-react)
8. PlaygroundTab contains: model selector dropdown (Anthropic/OpenAI/Gemini/Ollama + specific model), auth status indicator, chat message list, message input + Send button, Reasoning Waterfall panel
9. On Playground tab open, `POST /api/playground/auth` fires automatically to detect: (a) API keys in vault for each provider, (b) `claude`/`gemini` CLI availability on PATH, (c) Ollama reachability at `http://localhost:11434` (also configurable via `OLLAMA_HOST` env var)
10. Auth status displayed as inline indicator (green = auth available, amber = partial, red = no auth) — not a toast
11. Empty state shows the detected auth path + 3 example prompts (static or contextual to agent's system prompt if set)
12. Sending a message calls `POST /api/playground/chat` with `{agentId, message, sessionId, authMode, model}`
13. Response streamed via `GET /api/playground/stream?sessionId=xxx` (SSE)
14. SSE events carry: `{type: "token", data: "..."}`, `{type: "tool_call_start", data: {toolName, serverName, input}}`, `{type: "tool_call_end", data: {toolName, output, durationMs}}`, `{type: "metrics", data: {tokens_in, tokens_out, format_savings_pct}}`, `{type: "done"}`. The `metrics` event fires immediately before `done` and reports total token usage for the turn plus the percentage savings from gridctl's `toon`/`csv` output format conversion (sourced from `pkg/metrics`).
15. Reasoning Waterfall renders tool call events as a timeline: operation name, server name (subdued), duration badge. Expandable on click to show input/output JSON.
16. While the agent is processing (between send and `done` event): AgentNode shows `animate-ping` ring (same pattern as existing running-agent ring in AgentNode.tsx). Edges to MCP servers whose tools are being called show `animated: true` (XYFlow built-in animated edge). The target ServerNode for each active tool call also shows a "Processing" status badge (e.g., a small pulsing dot or color-shift on the node header) to help users identify which downstream server is the bottleneck during slow traces. This badge clears on `tool_call_end`.
17. When `done` event fires: animations stop, response renders in chat
18. "End Flight" button resets session context (new `sessionId`, clears chat history in UI and backend session)
19. Backend `pkg/runtime/agent` package manages `TestFlightSession` lifecycle (create, message, stream, destroy)
20. `DELETE /api/playground/session/:id` destroys a session and cleans up backend resources

**Phase B — CLI Proxy (ship after Phase A is stable)**

21. When Path B (CLI proxy) is selected, backend spawns `claude --print` or `gemini` as a subprocess
22. The subprocess connects back to gridctl's MCP gateway (via the running gateway endpoint) to receive tool access
23. User messages are piped to CLI stdin; response is read from stdout
24. All other UX (waterfall, canvas animation, session management) behaves identically to Path A
25. `POST /api/playground/auth` response includes `cliPath` for each detected CLI (e.g., `/usr/local/bin/claude`)

**Additional Requirements (all phases)**

26. The Prompt Editor (Config tab) must provide live vault key autocomplete: when the user types `${vault:`, a dropdown appears with available vault key names fetched from `GET /api/vault`. Selecting a key closes the dropdown and completes the expression. This prevents configuration drift from manual key lookup.
27. Path C (local LLM) must be supported via any OpenAI-compatible endpoint. Default URL: `http://localhost:11434/v1` (Ollama). Configurable via a text field in the model selector UI. The model list for Path C is fetched from `GET <endpoint>/models`. This path requires no credentials and enables fully offline testing.
28. When a user drags an edge between two AgentNodes in Agent Builder Mode, the resulting connection must update the source agent's `equipped_skills` (or `uses`) field in the YAML preview to add the target agent as an A2A peer — enabling the Agent-to-Agent protocol. This is distinct from a ServerNode→AgentNode edge (which updates `uses` for MCP tool access).

### Non-Functional Requirements

- The Inspector Panel must not introduce layout jank on open/close — use CSS transition (existing `transition-all duration-300` pattern)
- SSE stream must use `http.Flusher` for immediate token delivery — no buffering
- Backend `TestFlightSession` must be goroutine-safe — protect shared state with appropriate synchronization
- CLI subprocess (Path B) must be terminated when session is destroyed or the HTTP connection drops — use `context.WithCancel` and defer `cmd.Process.Kill()`
- Model selector dropdown must include at minimum: claude-3-5-sonnet-latest, claude-3-7-sonnet-latest, gpt-4o, gpt-4o-mini, gemini-2.0-flash, gemini-2.5-pro, and a configurable Ollama endpoint (Path C)
- No API keys should appear in SSE event data or browser network inspector — keys are resolved on the backend only

### Out of Scope

- Human-in-the-loop (HITL) checkpoints mid-execution — planned for a future milestone
- Saving/exporting chat transcripts
- Multi-agent test sessions (testing multiple agents simultaneously)
- Fine-tuning or prompt optimization based on test results
- Persistent session history across gridctl restarts

## Architecture Guidance

### Recommended Approach

Follow the existing overlay + store pattern for the frontend:

1. Add `showAgentBuilderMode: boolean` + `toggleAgentBuilderMode()` to `useUIStore`
2. Add the new toggle button to Canvas.tsx's `<Panel position="bottom-left">` block — follow the exact pattern of `toggleWiringMode`
3. Create `AgentBuilderInspector.tsx` as a sibling to `WiringModeOverlay.tsx` in `web/src/components/graph/`
4. Create `usePlaygroundStore.ts` (not in `useUIStore` — state isolation is the project pattern)
5. Add `'playground'` to `BottomPanelTab` type in `useUIStore` and add to `TABS` array in `BottomPanel.tsx`
6. Create `web/src/components/playground/` directory with `PlaygroundTab.tsx`, `PlaygroundInput.tsx`, `ReasoningWaterfall.tsx`

For the backend:
1. Create `pkg/runtime/agent/` package — follow `pkg/runtime/docker/` as structural template
2. Define `TestFlightSession`, `AuthMode` (`API_KEY | CLI_PROXY | LOCAL_LLM`), and `LLMClient` interface in `pkg/runtime/agent/session.go`
3. Implement Path A using official SDKs in `pkg/runtime/agent/apikey.go`
4. Implement Path C (Ollama) using `openai/openai-go` with a custom base URL in `pkg/runtime/agent/localllm.go` (Phase A — same PR as Path A)
5. Implement Path B using `exec.Cmd` in `pkg/runtime/agent/cliproxy.go` (Phase B only)
5. Create `internal/api/playground.go` with the three endpoint handlers
6. Register endpoints in `internal/api/api.go` `registerRoutes()` method

### Key Files to Understand

Before writing any code, read these files in full:

1. `web/src/components/graph/Canvas.tsx` — understand the control panel structure and overlay rendering pattern (lines 225-356)
2. `web/src/components/graph/WiringModeOverlay.tsx` — direct template for Agent Builder Mode overlay
3. `web/src/components/layout/BottomPanel.tsx` — understand the TABS constant and tab panel rendering
4. `web/src/stores/useUIStore.ts` — understand which state is persisted vs ephemeral, and the `BottomPanelTab` type
5. `web/src/components/traces/TracesTab.tsx` — template for Reasoning Waterfall layout
6. `web/src/components/traces/TraceWaterfall.tsx` — template for timeline span rendering
7. `pkg/mcp/process.go` — template for subprocess lifecycle management (ProcessClient)
8. `internal/api/api.go` — understand how endpoints are registered and how SSE is wired
9. `pkg/config/types.go` — understand Agent struct, ToolSelector, A2AConfig (especially `equipped_skills` and its relationship to `uses` for A2A wiring)
10. `pkg/config/loader.go` — understand `ExpandString` (vault + env var resolution); this function **must** be used in the playground chat handler
11. `web/src/types/index.ts` — understand frontend type conventions (AgentStatus, ToolSelector)

### Integration Points

**`web/src/stores/useUIStore.ts`**:
```typescript
// Add to UIState interface:
showAgentBuilderMode: boolean;
toggleAgentBuilderMode: () => void;
// Add 'playground' to BottomPanelTab type union
```

**`web/src/components/graph/Canvas.tsx`** (after line 328, before closing `</Panel>`):
```tsx
<button
  onClick={toggleAgentBuilderMode}
  className={cn('control-button', showAgentBuilderMode && 'ring-1 ring-secondary/30')}
  title={showAgentBuilderMode ? 'Exit agent builder' : 'Enter agent builder'}
>
  <Bot className="w-4 h-4" />
</button>
```
And add the conditional overlay rendering after the `showSecretHeatmap` block.

**`web/src/components/layout/BottomPanel.tsx`** (in TABS array):
```typescript
import { MessageSquare } from 'lucide-react';
{ id: 'playground' as const, label: 'Playground', icon: MessageSquare },
```

**`internal/api/api.go`** — in `registerRoutes()`:
```go
r.POST("/api/playground/chat", s.handlePlaygroundChat)
r.GET("/api/playground/stream", s.handlePlaygroundStream)
r.POST("/api/playground/auth", s.handlePlaygroundAuth)
r.DELETE("/api/playground/session/:id", s.handlePlaygroundSessionDelete)
```

**Canvas node animation** — in `usePlaygroundStore.ts`:
```typescript
activeToolCallEdges: Set<string>; // edge IDs where tool calls are in-flight
agentIsThinking: boolean;
```
Then in `Canvas.tsx`, map `styledEdges` to set `animated: edge.id in activeToolCallEdges`.
For the AgentNode thinking ring, pass `isThinking` as a node data prop and reference it in `AgentNode.tsx`.

### Reusable Components

- `WiringModeOverlay.tsx` — copy the `className`, positioning, and banner pattern; adapt for Agent Builder Mode
- `TraceWaterfall.tsx` — the span timeline rendering (depth, duration bar, color-by-server) is directly applicable to the Reasoning Waterfall. Extract shared timeline primitives if overlap grows.
- `StepResultCard.tsx` (in `web/src/components/workflow/`) — the expand/collapse chevron pattern for tool call input/output display
- `pkg/mcp/process.go` `ProcessClient` — the `exec.Cmd` lifecycle: context cancellation, stderr capture, reconnect logic
- Existing input styling pattern from `LogsTab.tsx` / `TracesTab.tsx` for the chat message input

## UX Specification

### Discovery

User finds Agent Builder Mode via the bottom-left Canvas control bar toggle (Bot icon, tooltip "Enter agent builder"). The Playground tab appears in the BottomPanel header once the tab is added — no other discovery needed.

### Activation

**Agent Builder Mode**: Toggle button → canvas overlay activates → AgentNodes show a subtle mode indicator → double-click any AgentNode → Inspector Panel slides in from right

**Playground**: Click "Playground" tab in BottomPanel (or a "Test Flight ›" shortcut button in the Inspector Panel's Config tab) → auth detection runs → empty state renders → user sends first message

### Interaction

1. **Configuring an agent**: Edit system prompt in Config tab → see YAML update live in Preview tab → check/uncheck tools in Tools tab → click "Save to Stack" to persist changes to `stack.yaml`
2. **Running a test**: Select model, verify auth status, type a message, press Enter or click Send → canvas animates → waterfall populates → response renders → click any waterfall row to expand tool I/O
3. **Ending a session**: Click "End Flight" button (top-right of PlaygroundTab) → session resets, chat history clears, waterfall clears

### Feedback

- **Thinking state**: AgentNode `animate-ping` ring (cyan, 30% opacity) + edge `animated: true` on active tool call edges
- **Response streaming**: Tokens render incrementally in the assistant message bubble (streaming pattern)
- **Tool call lifecycle**: Waterfall row appears on `tool_call_start`, duration badge fills on `tool_call_end`
- **Session boundary**: Visible "── Session started ──" divider at the start of each session

### Error States

- **Tier 1 (actionable now)**: Auth errors — show inline below the auth status indicator, not as a toast. Example: "No API key found for Anthropic. Add one in Vault →" (button opens vault panel)
- **Tier 2 (partial failure)**: Tool call error — Reasoning Waterfall row shows red border + error message expanded by default. Chat response continues.
- **Tier 3 (terminal)**: Timeout, CLI not found, rate limit — show a persistent `PlaygroundErrorBanner` at the top of PlaygroundTab with specific error + one-click recovery. Do NOT use the auto-dismissing `Toast.tsx` for these.

## Implementation Notes

### Conventions to Follow

- **Zustand stores**: Each domain gets its own store file. `usePlaygroundStore.ts` should NOT be in `useUIStore.ts`. Follow `useTracesStore.ts` as a template (dynamic data, no persistence).
- **Component naming**: PascalCase, domain-prefixed for disambiguation (`PlaygroundTab`, `PlaygroundInput`, `ReasoningWaterfall`, `AgentBuilderInspector`)
- **API handler pattern**: Each handler file (`playground.go`) defines a `PlaygroundHandlers` struct with a constructor that takes dependencies. Register methods on the `APIServer` struct via a wrapper or embed.
- **Error responses**: Use the existing `writeError(w, status, message)` pattern from other handlers
- **SSE pattern**: Use `w.(http.Flusher)` after each write. Set `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `X-Accel-Buffering: no`. Write `data: {json}\n\n` format.
- **Go package conventions**: All exported types in `pkg/runtime/agent/` should have doc comments. Follow the patterns in `pkg/runtime/docker/`.

### Key Invariant: Vault and Env Var Resolution

The backend `handlePlaygroundChat` handler **must** resolve the agent's system prompt using the existing `config.ExpandString` function from `pkg/config/loader.go` before passing it to the LLM client. This function handles both `${vault:KEY}` (resolved from `vault.Store`) and standard `${VAR}` (resolved from the process environment). Using `ExpandString` guarantees that Test Flight behavior is identical to production deployment behavior — the same resolution logic is used in both cases. Do not implement a separate variable expansion path for the playground.

### Potential Pitfalls

1. **CLI subprocess and MCP server race condition (Path B)**: The `claude` CLI needs to connect back to gridctl's MCP gateway *after* gridctl has started the session. Use a ready-channel or a brief retry loop with timeout to confirm the CLI has connected before sending the first message.
2. **SSE connection cleanup**: The SSE stream goroutine must detect when the client disconnects (via `r.Context().Done()`) and clean up the `TestFlightSession`. Failure to do this leaks goroutines and subprocess handles.
3. **Tool call edge animation state**: `activeToolCallEdges` in `usePlaygroundStore` must be a `Set` that adds on `tool_call_start` and removes on `tool_call_end`. Ensure the `Set` is replaced (not mutated) on each update to trigger Zustand re-renders — use `new Set([...prev, edgeId])`.
4. **`google/generative-ai-go` deprecation**: Do NOT add `github.com/google/generative-ai-go` to `go.mod`. The correct import is `google.golang.org/genai` (GA since May 2025). Support for the old package ends November 2025.
5. **Session ID management**: Generate `sessionId` on the frontend (UUID v4) before the first `POST /api/playground/chat`. This allows the frontend to establish the SSE stream (`GET /api/playground/stream?sessionId=xxx`) before the chat response starts flowing, avoiding a race condition.
6. **Inspector Panel z-index**: The Inspector Panel must render above the Canvas but below the CommandPalette. Use `z-30` or check existing z-index layers before setting.

### Suggested Build Order

**Phase A:**

1. **Backend first**: Create `pkg/runtime/agent/` with `TestFlightSession`, `AuthMode`, and `LLMClient` interface. Implement Path A (Anthropic only, using `anthropics/anthropic-sdk-go`) and the three API endpoints in `internal/api/playground.go`. Write tests.
2. **Auth endpoint + detection**: Implement `POST /api/playground/auth` to detect vault API keys and CLI availability. Test manually with `curl`.
3. **Playground tab (minimal)**: Add `'playground'` to `BottomPanelTab`, create `PlaygroundTab.tsx` with auth status + basic message input. Wire to `POST /api/playground/chat`.
4. **SSE streaming**: Implement `GET /api/playground/stream` SSE endpoint. Connect frontend `usePlaygroundStore` to consume SSE events. Render streaming tokens in chat.
5. **Reasoning Waterfall**: Add `ReasoningWaterfall.tsx` consuming `tool_call_start` / `tool_call_end` SSE events. Expand/collapse on click.
6. **Canvas animation**: Add `animated` edge prop to `styledEdges` mapping in Canvas.tsx. Add thinking ring to AgentNode.
7. **Inspector Panel**: Add Agent Builder Mode toggle, create `AgentBuilderInspector.tsx` with Config/Tools/Preview tabs. Wire to `useStackStore` for live YAML preview. Add vault key autocomplete to prompt editor (call `GET /api/vault` on `${vault:` trigger).
8. **OpenAI + Gemini + Ollama SDK support**: Add `openai/openai-go`, `googleapis/go-genai`, and Ollama (via `openai/openai-go` with custom base URL) to Path A/C. Add model selector + Ollama endpoint field to frontend. Implement A2A edge wiring (AgentNode→AgentNode updates `equipped_skills`).

**Phase B (separate PR):**

9. **CLI proxy**: Implement `pkg/runtime/agent/cliproxy.go` with subprocess management. Update `POST /api/playground/auth` to include CLI detection. Add Path B option to frontend model selector.

## Acceptance Criteria

1. Toggling "Agent Builder Mode" in the Canvas control bar activates the mode without affecting existing canvas nodes or edges
2. Double-clicking an AgentNode in Agent Builder Mode opens the Inspector Panel with three tabs (Config, Tools, Preview)
3. Editing the system prompt in the Config tab causes the Preview tab to update within 200ms (no debounce lag that would confuse users)
4. The Tools tab lists only tools from MCP servers connected to the selected agent via the `uses` field
5. Unchecking a tool in the Tools tab immediately updates the agent's effective tool list in the Preview YAML
6. The Playground tab is visible in BottomPanel and navigable via click
7. `POST /api/playground/auth` returns correct auth availability for vault API keys and local CLI detection
8. Sending a message in the Playground and receiving an SSE response completes without error for at least one provider (Anthropic API key path)
9. The Reasoning Waterfall shows tool call events streamed in real-time (not batch-loaded after response completes)
10. The AgentNode shows `animate-ping` ring while the session is processing; the animation stops when `done` event fires
11. XYFlow edges to the active MCP server show `animated: true` during active tool calls; revert to non-animated after tool call completes
12. "End Flight" button clears chat history and resets the session on the backend
13. Auth errors appear inline in the PlaygroundTab, not as auto-dismissing toasts
14. No API keys appear in SSE event payloads or browser network requests
15. `DELETE /api/playground/session/:id` destroys the backend session and terminates any subprocess (Path B)
16. Typing `${vault:` in the Config tab prompt editor triggers an autocomplete dropdown populated with vault key names from `GET /api/vault`; selecting a key inserts the complete `${vault:KEY}` expression
17. The SSE stream emits a `type: "metrics"` event before `done` containing `tokens_in`, `tokens_out`, and `format_savings_pct`; these values are displayed in the Playground UI after each turn
18. When Path C (Ollama) is selected and `http://localhost:11434` is reachable, a test message completes successfully using a locally running model
19. Dragging an edge between two AgentNodes in Agent Builder Mode updates the source agent's `equipped_skills` field in the Preview YAML
20. The target ServerNode for an active tool call shows a visual "Processing" indicator that clears when the tool call completes
21. The backend system prompt passed to the LLM client has all `${vault:KEY}` and `${VAR}` expressions expanded via `config.ExpandString` — raw template strings must never reach the LLM API

## References

- [anthropics/anthropic-sdk-go](https://github.com/anthropics/anthropic-sdk-go) — official Anthropic Go SDK, v1.19.0
- [openai/openai-go](https://github.com/openai/openai-go) — official OpenAI Go SDK
- [googleapis/go-genai](https://github.com/googleapis/go-genai) — official Google Gemini Go SDK (GA May 2025); **do not use** `google/generative-ai-go`
- [XYFlow animated edges docs](https://reactflow.dev/api-reference/types/edge#animated) — `animated: true` on edge object
- [go-sse library](https://github.com/tmaxmax/go-sse) — spec-compliant SSE for Go, explicitly designed for LLM response streams
- [WiringModeOverlay.tsx](../../../gridctl/web/src/components/graph/WiringModeOverlay.tsx) — direct implementation template for Agent Builder Mode overlay
- [ProcessClient in pkg/mcp/process.go](../../../gridctl/pkg/mcp/process.go) — template for CLI subprocess lifecycle management
- [LangGraph Studio UX reference](https://blog.langchain.com/langgraph-studio-the-first-agent-ide/) — gold standard for reasoning trace + canvas animation UX
- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — community reference for CLI subprocess + JSON-lines communication pattern
- Full evaluation: `prompts/gridctl/visual-agent-builder-playground/feature-evaluation.md`
