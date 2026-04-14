# Feature Evaluation: Visual Agent Builder & Test Flight Playground

**Date**: 2026-03-25
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Large

## Summary

The Visual Agent Builder + Test Flight Playground transforms gridctl from an MCP gateway/config tool into a full AI Development Environment. It adds a visual canvas for wiring agents to MCP servers, a chat playground for testing agents before deployment (with three-path authentication: direct API key, CLI proxy, and local Ollama inference), vault-aware prompt autocomplete, live token metrics from gridctl's existing metrics package, and A2A edge wiring for agent-to-agent configuration. The recommendation is **Build with caveats**: high strategic value and a genuine market gap, with scope adjustments to sequence the riskiest component (CLI proxy auth) after the core feature ships safely. No other tool in the MCP ecosystem combines topology-aware visual building, an integrated test playground, subscription-based CLI proxy authentication, and zero-auth local model support.

## The Idea

**Feature**: Two integrated components — Visual Agent Builder (extends the existing XYFlow canvas with "Agent Builder Mode," new Inspector Panel, and interactive edge-based wiring) and Test Flight Playground (chat interface for testing draft agents via SSE-streamed responses and a Reasoning Waterfall trace view).

**Problem it solves**: The "test before deploy" gap. Developers using gridctl cannot validate agent behavior — which tools get called, with what inputs, producing what outputs — before pushing to production. Additionally, developers on Claude Pro/Max or Gemini Advanced subscriptions cannot use API-key-based test tools because their subscription billing is separate from API credits.

**Who benefits**: Every gridctl user building MCP-powered agents — solo developers on $20/mo subscriptions (CLI Proxy path), enterprise teams managing shared API keys via vault (direct API key path), and developers on local networks or air-gapped environments (Ollama/local inference path).

**Prompted by**: The `idea.md` proposal, which frames this as the "missing link" that completes gridctl's arc from config tool to AI Development Environment — a recognized and emerging product category in 2026.

## Project Context

### Current State

gridctl is a production-grade MCP gateway and agent orchestration platform (Go backend + React 19 frontend). Its core capabilities: stack-as-code YAML definitions, multi-transport MCP server management (Docker, SSH, HTTP, OpenAPI), agent-level tool ACLs, distributed tracing via OpenTelemetry, vault-based secret management, and an XYFlow-based visual canvas showing the deployed topology.

The project is actively maintained, architecturally mature, and clearly directioned toward becoming an AI Development Environment. The `Agent` config type already has `Runtime` and `Prompt` fields reserved for headless agents running on `claude-code`, `gemini`, or other CLI runtimes — a deliberate forward-looking design decision.

Test coverage is solid in core packages (MCP gateway 77.6%, vault 85%, config 84.9%, metrics 93.6%) with the API layer at 65% and A2A module at 43.4%.

### Integration Surface

**Frontend (React 19, TypeScript):**
- `web/src/components/graph/Canvas.tsx` — add "Agent Builder Mode" toggle button + overlay rendering
- `web/src/components/layout/BottomPanel.tsx` — add `'playground'` as 5th tab to `TABS` array
- `web/src/stores/useUIStore.ts` — add `showAgentBuilderMode` boolean
- `web/src/types/index.ts` — add playground session types

**New frontend files:**
- `web/src/components/graph/AgentBuilderInspector.tsx` — right-aligned slide-out Inspector Panel
- `web/src/components/playground/PlaygroundTab.tsx` — chat + reasoning waterfall container
- `web/src/components/playground/PlaygroundInput.tsx` — message input + send button
- `web/src/components/playground/ReasoningWaterfall.tsx` — SSE-streamed tool call trace view
- `web/src/stores/usePlaygroundStore.ts` — messages, traces, running state, canvas highlights

**Backend (Go 1.24):**
- `pkg/runtime/agent/` — new package: `TestFlightSession` struct, `AuthMode` (`API_KEY | CLI_PROXY | LOCAL_LLM`), LLM client lifecycle, chat context management. The `handlePlaygroundChat` handler must use `config.ExpandString` from `pkg/config/loader.go` to resolve `${vault:KEY}` and `${VAR}` expressions in the system prompt before passing to any LLM client.
- `internal/api/playground.go` — new API endpoints: `POST /api/playground/chat`, `GET /api/playground/stream`, `POST /api/playground/auth`
- `go.mod` — add `anthropics/anthropic-sdk-go`, `openai/openai-go` (used for both OpenAI and Ollama/Path C via custom base URL), `googleapis/go-genai`

### Reusable Components

- **WiringModeOverlay.tsx** — direct precedent for Agent Builder Mode overlay pattern
- **TracesTab.tsx + TraceWaterfall.tsx** — baseline for Reasoning Waterfall visualization
- **Sidebar.tsx** (Agent section "Access" area) — baseline for tool filter checklist
- **`pkg/mcp/process.go`** (ProcessClient) — subprocess lifecycle management, direct template for CLI proxy
- **`pkg/tracing/buffer.go`** — existing trace storage, connects automatically to playground sessions
- **`react-resizable-panels`** (already in `package.json`) — Inspector Panel split layout

## Market Analysis

### Competitive Landscape

| Tool | Canvas | Playground | MCP-Native | CLI Proxy |
|------|--------|-----------|-----------|----------|
| Flowise | Best-in-class | Yes | Yes (2025) | No |
| Dify | Yes | Yes | Partial | No |
| LangGraph Studio | Execution viz | Chat+graph | No | No |
| ToolHive | No | Server-only | Yes | No |
| n8n | Yes | Node inspect | No | No |
| **gridctl (proposed)** | **Yes (XYFlow)** | **Yes** | **Core** | **Yes (novel)** |

Flowise is the closest analog — open-source, visual canvas, MCP support, embedded test playground. Key difference: Flowise is LLM-app-centric (chatbots, RAG pipelines), not MCP-infrastructure-centric. It has no concept of Docker topology, stack files, or gateway bridging. Flowise was acquired by Workday in August 2024 and is trending toward enterprise HR/finance automation.

LangGraph Studio is the gold standard for debugging UX — time-travel execution, step-through, state editing — but requires the LangGraph Python framework and cannot inspect arbitrary MCP server stacks.

### Market Positioning

**Differentiator** — not table-stakes. The combination of MCP-native topology canvas + integrated test playground + CLI proxy authentication does not exist in any current tool. Generic visual builders (Flowise, Langflow) lack MCP-native topology awareness. MCP-specific tools (ToolHive, MCP Inspector) test individual servers, not multi-server agent configurations.

Test-before-deploy as a concept is moving toward table-stakes — Microsoft Foundry, DigitalOcean, Salesforce, and Zendesk all ship agent testing environments as required pre-production steps. But the MCP-native, self-hosted variant of this tooling does not yet exist.

### Ecosystem Support

**Frontend**: `@xyflow/react` v12.10.0 is already in the project. XYFlow's official "AI Workflow Editor" template and Sim (27k stars, $7M raise, YC X25) both confirm React Flow is the canonical library for agent builder UIs.

**Backend LLM SDKs**: All three providers have GA-quality official Go SDKs:
- Anthropic: `anthropics/anthropic-sdk-go` v1.19.0 (official, GA)
- OpenAI: `openai/openai-go` v1.x (official, GA)
- Google: `googleapis/go-genai` (GA May 2025; `google/generative-ai-go` is deprecated, support ends Nov 2025)

**CLI Proxy pattern**: CLIProxyAPI (20k GitHub stars) validates massive community demand for "use my subscription as an API." Anthropic's own Claude Agent SDK spawns the `claude` CLI as a subprocess with JSON-lines over stdin/stdout — confirming the subprocess approach is a supported, first-class pattern.

### Demand Signals

- **CLIProxyAPI 20k stars**: The largest single demand signal — developers desperately want to use their $20/mo subscriptions for API-like access.
- **MCP Inspector issue #363**: The official MCP Inspector explicitly lacks an LLM-in-the-loop test interface; the community has filed a feature request for exactly what gridctl proposes.
- **MCP mainstream adoption**: 97M+ monthly SDK downloads, all three major labs committed, Linux Foundation governance. The TAM for MCP tooling is now large enough to support a niche product.
- **a16z 2026 analysis**: "Shift from 'how do I build it' to 'what do I build'" — test playgrounds shorten the feedback loop between agent idea and validated behavior.

## User Experience

### Interaction Model

**Discovery**: A new toggle button in Canvas.tsx's bottom-left control bar (same pattern as Wiring Mode, Spec Mode, Secret Heatmap). Tooltip: "Agent Builder Mode." Zero learning curve — fits existing discoverable-toggle pattern.

**Agent Builder Mode:**
1. User clicks toggle → canvas enters Agent Builder Mode
2. AgentNodes get a subtle Builder Mode indicator (edit icon or mode badge)
3. User double-clicks (or right-clicks) an AgentNode → Inspector Panel slides in from the right
4. Inspector Panel has three tabs: **Config** (prompt editor with vault variable syntax), **Tools** (checklist from connected ServerNodes), **Preview** (live YAML)
5. User drags edges from ServerNodes to AgentNodes to wire tool access — same interaction as WiringModeOverlay
6. YAML preview updates live as user changes prompt or tool selections

**Test Flight:**
1. With agent configured, user clicks "Test Flight" button (on AgentNode or Inspector Panel)
2. Bottom panel opens to Playground tab
3. Auth detection runs (`POST /api/playground/auth`) — detects `claude`/`gemini` CLI (Path B), API keys in vault per provider (Path A), and Ollama reachability at `localhost:11434` (Path C, zero-auth, offline)
4. Empty state shows available auth path(s) and 3 example prompts (contextual to agent's system prompt)
5. User sends first message
6. Canvas AgentNode shows `animate-ping` ring (thinking), edges to active MCP servers show `animated: true` (XYFlow built-in)
7. Reasoning Waterfall in Playground tab shows tool calls as they stream in (SSE)
8. Response appears in chat after tool calls complete
9. User can "End Flight" (reset session context) and try another test

### Workflow Impact

**Reduces friction**: Eliminates the need to deploy → test → re-configure → re-deploy cycle. The existing vault integration means API keys are already managed — test sessions can reuse vault secrets seamlessly.

**Adds minimal friction**: The new toggle and tab follow existing patterns. No new navigation concepts. The bottom panel Playground tab is discovered naturally alongside existing Logs/Traces tabs.

**Enables new users**: CLI proxy (Path B) removes the API credit barrier for subscription developers. Ollama (Path C) removes it entirely for local-model users — enabling air-gapped or cost-sensitive testing with no external dependencies.

### UX Recommendations

1. **Inspector tabs (Config | Tools | Preview)** over nested collapsible sections — live preview must be co-located in a tab, not a scroll-away section
2. **Vault-aware autocomplete in Config tab** — when user types `${vault:`, fetch available keys from `/api/vault` and render an inline dropdown. Prevents config drift and manual key lookup errors.
3. **Three-layer canvas animation**: `animate-ping` ring on AgentNode (thinking) + `animated: true` on XYFlow edges (active tool call) + "Processing" status badge on the target ServerNode — helps users identify which downstream server is the bottleneck during slow traces
4. **Reasoning Waterfall as timeline**, not card stack — expandable tool call detail on click (reuse `StepResultCard` pattern from `WorkflowRunner.tsx`)
5. **Turn-level token metrics** — display `tokens_in`, `tokens_out`, and `format_savings_pct` from the SSE `metrics` event after each turn. Reinforces the value of gridctl's output format compression.
6. **Persistent error banners** for auth/config failures — do NOT use the auto-dismissing `Toast.tsx` for Tier 3 errors
7. **Test Flight session boundaries** — visible "Session started" markers, "End Flight" button to reset context
8. **Empty state with auth detection** — auto-detect all three paths (vault API key, CLI, Ollama) before first run, surface the result with actionable options

### Accessibility Considerations

Two-layer animation (ring + edge) ensures tool call visibility for colorblind users. Edge `animated: true` provides motion-based feedback independent of color. Existing keyboard shortcuts pattern should extend to Inspector Panel (Tab navigation, keyboard submit).

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Test-before-deploy is moving to required practice. No MCP-native tool solves this. |
| User impact | Broad+Deep | Every gridctl agent-builder hits this friction. CLI proxy expands user base to $20/mo subscription devs. |
| Strategic alignment | Core mission | Directly completes gridctl's arc from config tool to AI Development Environment. Runtime+Prompt fields signal this was always planned. |
| Market positioning | Leap ahead | MCP-native topology canvas + test playground + CLI proxy is an unoccupied position. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | All patterns exist (overlay, tab, store). No architectural changes. Backend needs new package + 3 SDK deps. |
| Effort estimate | Large | 5 milestones. CLI Proxy (M3) and Trace Integration (M5) are the two heavy lifts. |
| Risk level | Medium | CLI proxy has policy risk (Anthropic may restrict subprocess piping). No data integrity/security risk — test-only sandbox. Path A must be robust fallback. |
| Maintenance burden | Moderate | 3 LLM SDK deps track fast-moving APIs. CLI proxy has process lifecycle complexity. Tracing integration is low-maintenance. |

## Recommendation

**Build with caveats.**

The feature is high-value, fills a real and confirmed market gap, and the codebase is exceptionally well-positioned to support it. All architectural patterns are in place. Official Go SDKs exist for all three LLM providers.

**Three caveats that shape the build approach:**

**Caveat 1 — Sequence the milestones to de-risk CLI proxy**:
Ship M1 (schema), M2 (playground UI), and M4 (visual wiring) as a cohesive Phase A before starting M3 (CLI proxy). Phase A delivers the Inspector Panel + Playground with direct API key auth — full UX value, zero policy risk. M3 (CLI proxy) is Phase B, explicitly opt-in, well-documented as using the CLI as designed (not as an API billing bypass). This means a degraded-but-functional feature ships faster, and the risky component is clearly isolated.

**Caveat 2 — Path A (direct API key) must be feature-complete as a standalone**:
Path A is the production-safe path. Path B (CLI proxy) is a convenience for developers without API credits. Users who rely on Path B and face a future Anthropic policy restriction must be able to switch to Path A without losing any other feature. Never let Path B be the only way to access a feature.

**Caveat 3 — HITL checkpoints should be on the roadmap**:
Human-in-the-loop approval steps are table-stakes in 2026 (Flowise V2, LangGraph, PromptFlow all ship them). The Test Flight Playground establishes the foundation. A future milestone should add the ability to pause agent execution at a tool call and require user approval before proceeding — this is a distinct feature but shares the Playground infrastructure.

## References

- [Flowise - Build AI Agents, Visually](https://flowiseai.com/)
- [LangGraph Studio: The first agent IDE](https://blog.langchain.com/langgraph-studio-the-first-agent-ide/)
- [GitHub - simstudioai/sim (27k stars)](https://github.com/simstudioai/sim)
- [GitHub - router-for-me/CLIProxyAPI (20k stars)](https://github.com/router-for-me/CLIProxyAPI)
- [MCP Inspector issue #363 — LLM-in-the-loop test interface request](https://github.com/modelcontextprotocol/inspector/issues/363)
- [GitHub - anthropics/anthropic-sdk-go](https://github.com/anthropics/anthropic-sdk-go)
- [GitHub - openai/openai-go](https://github.com/openai/openai-go)
- [GitHub - googleapis/go-genai](https://github.com/googleapis/go-genai)
- [The New Stack — 5 Key Trends Shaping Agentic Development in 2026](https://thenewstack.io/5-key-trends-shaping-agentic-development-in-2026/)
- [The New Stack — Why MCP Won](https://thenewstack.io/why-the-model-context-protocol-won/)
- [Claude Help Center — Subscription vs API Billing](https://support.claude.com/en/articles/9876003-i-have-a-paid-claude-subscription-pro-max-team-or-enterprise-plans-why-do-i-have-to-pay-separately-to-use-the-claude-api-and-console)
- [AI Workflow Editor - React Flow Template](https://reactflow.dev/ui/templates/ai-workflow-editor)
- [xyflow Spring Update 2025](https://xyflow.com/blog/spring-update-2025)
- [MCP Blog — 2026 Roadmap](http://blog.modelcontextprotocol.io/posts/2026-mcp-roadmap/)
- [Salesforce — 3 Essential Testing Steps for AI Agents](https://www.salesforce.com/blog/ai-agent-testing/)
- [VentureBeat — Three Disciplines Separating AI Agent Demos from Real-World Deployment](https://venturebeat.com/orchestration/the-three-disciplines-separating-ai-agent-demos-from-real-world-deployment)
