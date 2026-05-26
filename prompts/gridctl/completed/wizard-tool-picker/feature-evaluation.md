# Feature Evaluation: Wizard Tool Picker with Fuzzy Search

**Date**: 2026-04-19
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

Replace the manual text-input `ToolsWhitelist` in the gridctl web UI wizard with a searchable, multi-select picker that lets users curate exactly which tools from each MCP server the gateway exposes. The backend filtering primitive already exists (`MCPServer.Tools []string` enforced via `filterTools()` at the gateway); this feature is the UX layer that makes it usable at scale. Ship in two phases — picker wired to already-loaded servers first, ephemeral probe for greenfield servers second.

## The Idea

**What**: An optional extension to the gridctl web UI wizard that replaces manual "type tool names by hand" entry with a searchable, checkable picker. Users can (a) select which tools from each MCP server to expose when creating a new stack, and (b) do the same when adding a new MCP server to an already-loaded stack via the topology "Add Server" button. Fuzzy search filters large tool lists.

**Problem**: MCP servers commonly emit 20+ tools each. Without curation, a stack with 5 servers can push 30–60k tokens of tool definitions into the LLM's context (25–30% of a 200k window). Tool confusion degrades agent reliability sharply past ~10 tools, and downstream clients enforce hard caps (Cursor ~40, GPT-5 API 128). The gateway-level allowlist (`tools: []` in stack YAML) solves this — but the wizard's manual text-input UX makes it unusable unless the user already knows the tool names.

**Who benefits**: Every user of the wizard. Acutely, users building access-control stacks (the `examples/access-control/tool-filtering.yaml` pattern).

## Project Context

### Current State

gridctl (v0.1.0-beta.6) is a mature MCP orchestrator — "Containerlab for MCP." Core architecture: a Go CLI orchestrates MCP server containers/processes, a Go gateway aggregates them behind a single SSE/HTTP endpoint, and a React web UI visualises the topology and offers a wizard for spec building.

The wizard is a 4-step flow (Type → Template → Form → Review). The Form step for MCP servers uses collapsible sections (Identity, Server Type, Configuration, Environment & Secrets, Advanced). Server-level tool filtering is documented, shipped, and demonstrated in the `examples/access-control/` directory.

### Integration Surface

| Layer | File | Role |
|---|---|---|
| Config schema | `pkg/config/types.go:143` | `MCPServer.Tools []string` — whitelist field |
| Enforcement | `pkg/mcp/client_base.go` | `SetToolWhitelist` + `filterTools` applied per client |
| Gateway init | `pkg/mcp/gateway.go:766-825` | Applies whitelist on server start |
| Wizard form | `web/src/components/wizard/steps/MCPServerForm.tsx:384-441` | Current manual `ToolsWhitelist` component |
| Wizard state | `web/src/stores/useWizardStore.ts` | Zustand store, `formData['mcp-server'].tools?: string[]` |
| YAML serialize | `web/src/lib/yaml-builder.ts:67,247-250` | `tools` field maps 1:1 to stack YAML |
| API aggregate | `internal/api/api.go` → `GET /api/tools` | Returns tools from all *currently loaded* servers |
| Topology entry | `web/src/components/canvas/Canvas.tsx:204-220` | "Add Server" button — reuses `CreationWizard` |
| Read-only display | `web/src/components/ui/ToolList.tsx` | Displays realized tools (distinct concern from picker) |

### Reusable Components

- **`cmdk` v1.1.1** already in `web/package.json` — headless command/combobox primitive; gives keyboard nav and a11y for free.
- **`fuse.js` v7.1.0** already in `web/package.json` — used by `hooks/useFuzzySearch.ts` for skills; pattern directly applicable to tools.
- **Existing async/error patterns**: `Loader2` spinner from lucide-react, `showToast('error', msg)`, inline `FieldError` component in `MCPServerForm.tsx`.
- **OpenAPI Operations Filter** (`MCPServerForm.tsx:1116-1189`) is the closest existing analogue — a tool-like picker in the same Advanced section.

## Market Analysis

### Competitive Landscape

| Tier | Projects | Notes |
|---|---|---|
| Config-file allowlist only | MCPO, Windsurf, mcp-filter | Baseline table-stakes |
| UI toggles (no search) | Cursor, Claude Desktop, Continue, Cline | Mass-market |
| UI + search + groupings | VS Code tools picker, MetaMCP Tools tab, ToolHive Optimizer | Frontier — and still rough (MetaMCP's search is on the roadmap) |
| No per-tool control | Claude Code | Multiple open issues: [#7328](https://github.com/anthropics/claude-code/issues/7328), [#18383](https://github.com/anthropics/claude-code/issues/18383), [#6759](https://github.com/anthropics/claude-code/issues/6759) |
| API filter param | Anthropic MCP connector (`allowed_tools`), OpenAI Agents `tool_filter` | Standardising in SDKs |

The MCP spec (2025-11-25) defines `tools/list` and `listChanged` but does **not** standardise client-side allowlisting — filtering is a gateway/client concern.

### Market Positioning

**Table-stakes in 2026, not a differentiator.** The UI layer with fuzzy search is where a thin slice remains — MetaMCP has the tab but search is "planned"; Cursor has toggles without search; ToolHive's semantic optimizer is runtime-only, not wizard-time. A wizard with probe-before-commit + fuzzy search lands in genuinely underserved territory.

### Ecosystem Support

- **Probe pattern is standard**: `mcptools` CLI and MCP Inspector both use ephemeral spawn + `initialize` + `tools/list`. No public MCP registry (official, Smithery, Glama, mcp.so) publishes tool manifests — they're package catalogs. Probe is the only complete answer.
- **Libraries in-tree** already cover the entire UI surface (cmdk + fuse.js).
- **No new Go deps required** — the gateway client lifecycle already has the ephemeral-spawn primitives needed.

### Demand Signals

- Claude Code [#7328](https://github.com/anthropics/claude-code/issues/7328): *"I only need 3 specific ones... I have to work with all 20+ tools, which clutters the interface."*
- Cursor forum: *"I just added github and jira and immediately hit 40 tools limit! my Cursor trial lasted for 10 minutes."* ([thread](https://forum.cursor.com/t/add-the-possibility-to-filter-mcp-tools/76776))
- MCP spec [discussion #1580](https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/1580) — request for `enabled` default-off flag.
- Practitioner discourse: [demiliani "too many tools"](https://demiliani.com/2025/09/04/model-context-protocol-and-the-too-many-tools-problem/), [jentic "MCP Tool Trap"](https://jentic.com/blog/the-mcp-tool-trap), [Writer "RAG-MCP"](https://writer.com/engineering/rag-mcp/).
- OWASP LLM 2025 / LLM06 (Excessive Agency) names per-tool allowlisting as the direct mitigation.
- Anthropic's "Effective context engineering" guidance ships `defer_loading` and Tool Search Tool as first-party mitigations for the same problem.

## User Experience

### Interaction Model

**Discovery**:
- When creating a new stack: user reaches the Advanced section of `MCPServerForm`, sees the `ToolsPicker` component (replaces current `ToolsWhitelist`).
- When adding to an existing stack: user clicks "Add Server" on Canvas (`Canvas.tsx:204-220`) — same `CreationWizard` path, same picker surface.

**Activation**:
- For servers already running in the topology: picker auto-populates from `useStackStore.tools` filtered to the current server's prefix. Fuzzy search on name + description.
- For greenfield servers: user fills image/command/URL fields. Picker shows a "Discover tools" button. On click, backend probes the server ephemerally, caches the result by config hash, populates the list.

**Interaction**:
- Multi-select checklist. Default state: no selection = "all tools exposed" (matches current semantics).
- Search input at top filters as you type. Fuzzy match over tool name + description.
- Select-all / clear-all quick actions.
- Visible tool count + token estimate (nudge users away from the downstream 40/128-tool cliff).

**Feedback**:
- Probe: `Loader2` spinner with `aria-busy`. Sub-second feedback if cached, 2–5s spinner if live probe.
- Error: inline `FieldError` pattern *plus* toast. Never blocks form advancement — manual tool-name entry stays available as fallback.

### Workflow Impact

- **Reduces friction** for every user who previously had to hand-type tool names from memory or docs.
- **Unchanged default path** — leaving the picker empty still exposes all tools (backward compatible with existing stacks).
- **New path unlocked**: users who previously gave up on the whitelist because they didn't know tool names can now curate.

### UX Recommendations

1. Keep the picker in the **Advanced section** — same collapsible where OpenAPI Operations Filter lives. This is optional refinement, not core config.
2. Build a **new `ToolsPicker.tsx`** — don't extend `ToolList.tsx`. The latter is read-only with param-detail expansion; the picker needs multi-select + search. Different concerns.
3. Use **cmdk** as the base (already a dep). Keyboard nav + a11y come free.
4. **Hybrid probe trigger**: explicit "Discover tools" button + silent auto-probe when user opens Advanced with image/command already filled. Debounce field changes by 500ms.
5. **Cache by config hash** (`sha256(command + args + env-allowlist)`). Re-opening the wizard must be instant.
6. Show a **token/tool-count indicator** in the picker header. This quietly teaches the "fewer tools = better agent" lesson without a wall of copy.
7. **Never block Next/Deploy** on probe failure. "No tools found" is a neutral state, not an error — some servers legitimately expose none.
8. **a11y**: `aria-label` on picker and search input, `aria-busy` on spinner container, `role="checkbox" aria-checked` on items.

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | OWASP-named mitigation for LLM06; 25–30% context bloat documented; reliability cliff past ~10 tools. Not "critical" only because enforcement already works via YAML. |
| User impact | Broad + Deep | Every wizard user hits this. Access-control story directly benefits. |
| Strategic alignment | Core mission | Gateway/orchestrator of MCP tools is gridctl's raison d'être; wizard is the marquee UX surface; access-control example already showcases the primitive. |
| Market positioning | Catch up + slight leap | Joins UI+search tier; probe-before-commit with caching is ahead of MetaMCP's "planned" search and ToolHive's runtime-only approach. |

### Cost Breakdown
| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Moderate | Picker is a drop-in replacement. The probe endpoint is the only new architectural surface — additive, not a refactor. |
| Effort estimate | Medium | Phase 1: picker + existing-topology wiring + fuzzy search + a11y + tests. Phase 2: probe API + ephemeral lifecycle + cache + error UX + tests. Persistence and enforcement already exist. |
| Risk level | Medium | Probe path risks: spawning processes with incomplete config, env/secret handling before user supplies them, probe hangs, resource leaks. Mitigations well-understood (timeouts, cleanup guarantees, cache). Phase-shipping isolates the risky half. |
| Maintenance burden | Moderate | Probe handler must track gateway client behaviour; picker tracks MCP spec evolution. Neither is high-churn. |

## Recommendation

**Build.** Two-phase shipping recommended to isolate risk:

- **Phase 1 (low risk)**: Replace `ToolsWhitelist` with `ToolsPicker` wired to the existing `/api/tools` for servers already loaded in the topology. Immediate win for scenario 2 ("Add Server" to an existing stack). Zero probe risk.
- **Phase 2 (higher risk)**: Add `POST /api/servers/probe` endpoint that performs ephemeral spawn + `initialize` + `tools/list`, with config-hash caching. Wire it into Phase 1's picker for greenfield servers. Covers scenario 1 (new stacks).

Each phase ships as its own branch, issue, and PR through `/feature-build` — independently reviewable, independently landable. Phase 1 alone is already a material UX improvement and could even be shipped standalone if Phase 2 hits unforeseen complexity.

**Scope discipline**: do not bundle identity-bound allowlists, policy-as-code, or audit logging into this feature. Those are the real durable differentiators but belong in follow-up features. The picker unblocks them — don't conflate.

## References

- [Anthropic MCP connector — allowed_tools](https://platform.claude.com/docs/en/agents-and-tools/mcp-connector)
- [Anthropic — Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Anthropic — Advanced tool use](https://www.anthropic.com/engineering/advanced-tool-use)
- [MCP spec 2025-11-25 — tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [MCP spec discussion #1580 — enabled default-off](https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/1580)
- [MetaMCP](https://github.com/metatool-ai/metamcp)
- [ToolHive (Stacklok)](https://github.com/stacklok/toolhive) / [MCP Optimizer docs](https://docs.stacklok.com/toolhive/tutorials/mcp-optimizer)
- [MCPO (OpenWebUI)](https://github.com/open-webui/mcpo)
- [mcp-filter](https://github.com/pro-vi/mcp-filter), [Portkey mcp-tool-filter](https://github.com/Portkey-AI/mcp-tool-filter)
- [Claude Code — per-tool filter issues #7328](https://github.com/anthropics/claude-code/issues/7328), [#18383](https://github.com/anthropics/claude-code/issues/18383), [#6759](https://github.com/anthropics/claude-code/issues/6759)
- [Cursor forum — filter MCP tools](https://forum.cursor.com/t/add-the-possibility-to-filter-mcp-tools/76776)
- [OWASP LLM Top 10 2025 (PDF)](https://owasp.org/www-project-top-10-for-large-language-model-applications/assets/PDF/OWASP-Top-10-for-LLMs-v2025.pdf)
- [f/mcptools](https://github.com/f/mcptools)
- [modelcontextprotocol/inspector](https://github.com/modelcontextprotocol/inspector)
- [cmdk](https://github.com/pacocoursey/cmdk)
- [Fuse.js](https://www.fusejs.io/)
- [demiliani — too many tools problem](https://demiliani.com/2025/09/04/model-context-protocol-and-the-too-many-tools-problem/)
- [jentic — MCP Tool Trap](https://jentic.com/blog/the-mcp-tool-trap)
- [Writer — RAG-MCP](https://writer.com/engineering/rag-mcp/)
