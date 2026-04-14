# Feature Evaluation: gridctl Network Agent

**Date**: 2026-04-13
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Large (Phase 1 scoped to Medium)

## Summary

Build a new standalone repository (`gridctl/network-agent`) containing a compiled Go AI agent specialized in network engineering, consuming the gridctl MCP gateway as its unified tool backend. The market gap is validated (closest OSS competitor stalled), the platform is ready, and the IETF is actively standardizing the exact architecture being proposed — timing is ahead of the standard. Scope Phase 1 tightly to the agent core, SSH/gNMI access, and propose→review→execute UX; defer ITSM integration, NETCONF, and webhook surfaces to Phase 2+.

## The Idea

A standalone Go binary (`netagent`) that acts as a security-first AI agent for network engineering automation. It connects to the gridctl MCP gateway as its unified tool backend, maintains an agent loop with LLM integration (Claude), and enforces enterprise-grade safety controls: human-in-the-loop gating for write operations, immutable Git-based audit trails (GAIT), tool allow-lists, and policy enforcement before any external call. Input surfaces: CLI, TUI (plan review), webhook (Slack/WebEx). Domain focus: device automation (gNMI, SSH), reconciliation with source-of-truth (NetBox), observability, security auditing, and change management.

**Problem**: Network engineers lack a production-safe AI agent that can autonomously reason over network tasks while maintaining enterprise change-control requirements. Existing tools are either closed vendor SaaS (Cisco Catalyst Center AI, Juniper Marvis), Python/Node.js runtimes too fragile for production (NetClaw), or generic agents with no network domain knowledge.

**Who benefits**: Platform/NetOps/SRE teams managing network infrastructure who want LLM-assisted automation without the risks of unconstrained tool access.

## Project Context

### Current State

gridctl is a mature MCP orchestration platform (v0.1.0-beta.5, 16 months in active development) that aggregates tools from multiple downstream MCP servers into a single unified endpoint. Core tagline: "One endpoint. Dozens of AI tools. Zero configuration drift." It is a protocol bridge and tool aggregator — deliberately NOT an agent itself. Features: MCP gateway (stdio, SSE, HTTP transports), container orchestration (Docker + Podman), vault (XChaCha20-Poly1305 + Argon2id), skills registry (executable DAG workflows), schema pinning (TOFU rug-pull protection), OpenTelemetry distributed tracing on every tool call, gateway-level auth, web UI dashboard.

The gateway is explicitly designed for external agent consumption — any MCP client connects via `POST /mcp` using standard MCP JSON-RPC 2.0. No existing agent/LLM loop exists in gridctl itself; it is deliberately a platform.

### Integration Surface

The network-agent consumes gridctl, not the reverse. No modifications to gridctl required.

| Interface | How network-agent uses it |
|-----------|--------------------------|
| `POST http://localhost:8180/mcp` | Standard MCP HTTP — agent connects as a client |
| `POST /api/registry/skills/{name}/execute` | Invoke executable skills from agent loop |
| `GET /api/vault/{key}` | Credential access without duplication |
| `GET /api/traces` | Agent actions appear automatically as OTel spans |
| `gridctl apply network-stack.yaml` | Provisions network MCP servers the agent needs |
| `stack.yaml tools:` array | Per-server allow-lists inherited by the agent |
| Schema pinning | TOFU protection inherited automatically |

### Reusable Components

| Component | Location in gridctl | How network-agent uses it |
|-----------|--------------------|-----------------------------|
| AgentClient interface | `pkg/mcp/types.go` | HTTP client implementation connecting to gateway |
| ToolCallObserver | `pkg/mcp/types.go:52-61` | Audit logging hook — wrap with GAIT recorder |
| SchemaVerifier | `pkg/mcp/types.go:87-101` | Policy enforcement — validate before tool call |
| Skill executor pattern | `pkg/registry/executor.go` | DAG execution, retry, conditional logic patterns |
| Vault integration | `pkg/vault/` | Secrets access pattern: `${vault:SSH_KEY}` in stack.yaml |
| OTel tracing | `go.opentelemetry.io/otel` in go.mod | Already a dependency; agent calls traced automatically |

## Market Analysis

### Competitive Landscape

| Tool | Runtime | Architecture | Status | Gap |
|------|---------|-------------|--------|-----|
| NetClaw | Python/Node.js | OpenClaw gateway + 112 skills + 51 MCP integrations | Stalled Feb 2025 (412 ⭐) | Not compiled; fragile runtime |
| GoClaw | Go | OpenClaw rewritten in Go, multi-tenant, 5-layer security | Early-stage (2.7k ⭐) | Not network-specific |
| Cisco Catalyst Center AI | Closed SaaS | Proprietary, Cisco-hardware-locked | GA | Not composable |
| Juniper Marvis | Closed SaaS | Microservices cloud, driver-assist + self-driving modes | Production | Not composable |
| pyATS MCP server | Python | Containerized stdio MCP server for Cisco pyATS | Experimental (19 ⭐) | Agent layer missing |
| Juniper MCP server | Python | Official JunOS MCP server | Active | Agent layer missing |
| NetBox MCP server | Python | Official read-only NetBox MCP server | Production | Agent layer missing |

**Key gap**: No production Go-based AI agent wrapping MCP network tools with security-first policies, ITSM gating, and audit trails as a standalone compiled binary.

### Market Positioning

**Differentiator** — not table-stakes. Basic network automation (Ansible, NAPALM, Netmiko) is table-stakes. AI agents with production safety controls are actively differentiating in 2025-2026. Gartner projects GenAI will account for 25% of initial network configs by 2027 (up from <3% in 2024). The OSS gap is specifically at the compiled, production-safe, AI-agent layer — not at the protocol or data model layer.

### Ecosystem Support

**Go library stack is clear and production-ready:**

| Layer | Library | Stars | Maturity |
|-------|---------|-------|---------|
| MCP client | `mark3labs/mcp-go` | 8,585 | Production (weekly releases) |
| LLM calls | `anthropics/anthropic-sdk-go` | 974 | Production (daily releases, v1.35.1) |
| gNMI | `openconfig/gnmic` | 287 | Production (Nokia-backed, active) |
| CLI/SSH | `scrapli/scrapligo` | 298 | Production (same author as Python scrapli) |
| NETCONF | `Juniper/go-netconf` | 264 | Stable |
| NetBox | `netbox-community/go-netbox` | 226 | Stable (auto-generated from OpenAPI) |

IETF: 3 active Internet-Drafts formalizing MCP for network management (OPSAWG working group, NMRG). The architecture being proposed already satisfies the emerging standard.

### Demand Signals

- NANOG 93, 95, 96: AI network automation was a dominant theme with full workshops and sessions
- NetBox: 20.2k GitHub stars — integration expected by the community
- Network to Code Slack: 17,000 members; active NautobotGPT + AI content series
- 97M+ monthly MCP SDK downloads; adopted as universal standard by Anthropic, OpenAI, Google, Microsoft
- NetClaw's stall (412 stars, Feb 2025) proves the concept is real and leaves an open gap
- Job market: AI engineering salaries avg $206k in 2025; demand growing 135%+
- Timing: ~12-18 month window before commercial incumbents close the OSS gap

## User Experience

### Interaction Model

**Discovery**: Install via `go install` or binary release. Paired with `gridctl apply network-stack.yaml` which provisions the required network MCP servers.

**Activation modes**:
- `netagent run "check BGP health on all routers"` — single-shot NL command
- `netagent chat` — interactive multi-turn session
- `netagent skill health-check --device 10.1.1.1` — direct skill invocation
- Background daemon feeding Slack/WebEx (Phase 2)

**Agent loop (Propose → Review → Execute)**:
1. Input received (CLI, chat, or skill invocation)
2. Agent reasons, selects skills/tools, builds execution plan
3. Plan displayed as structured summary (device targets, tool calls, expected outcomes)
4. **Write operations require explicit `y/N` gate** — read operations run autonomously
5. On approval, agent executes tool calls via gridctl gateway
6. Results formatted; GAIT commit written with full audit trail

### Workflow Impact

Reduces friction by replacing ad-hoc multi-tool workflows with a single NL interface. Adds friction only if positioned as a second general-purpose agent alongside Claude Desktop — must be clearly positioned as a specialized network agent.

### UX Recommendations

Based on analysis of NetClaw, Juniper Marvis, Cisco Catalyst Center AI, and network automation abandonment patterns:

1. **Non-negotiable: dry-run preview before any write** — NAPALM pattern; table-stakes for network engineers
2. **Asymmetric gating**: read ops autonomous, write ops gated — prevents approval fatigue (top abandonment cause)
3. **Error messages must be network-contextual** — diagnostic messages with next-step actions, not stack traces
4. **TUI only for plan review** — all other output plain text (pipe-able, SSH-friendly, fast)
5. **Time-to-first-value < 10 minutes** — `gridctl apply network-stack.yaml && netagent run "show bgp summary"` must work immediately
6. **Confidence-based routing** — surface ambiguity before action, not after

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | 57% of network tasks remain manual despite existing automation |
| User impact | Narrow+Deep | Network/NetOps engineers specifically; pain is acute and well-documented |
| Strategic alignment | Core mission | network-agent IS the canonical proof-of-concept for the gridctl platform |
| Market positioning | Leap ahead | No production Go-based network AI agent; NetClaw stalled; IETF still writing standards |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | New repository; consumes gridctl gateway via standard MCP HTTP; no gridctl modifications needed |
| Effort estimate | Large (Phase 1: Medium) | Full vision is Very Large; Phase 1 (agent core + SSH + gNMI + GAIT + CLI/TUI) is Medium |
| Risk level | Medium | Clear library stack; multi-vendor device handling needs careful testing |
| Maintenance burden | High | Multi-vendor APIs change; LLM provider evolution; skill library expansion; security policy updates |

## Recommendation

**Build with caveats** — high strategic value with disciplined, phased scope.

**Phase 1 (Medium effort, ~6-8 weeks)**:
- Core agent loop: LLM client (Claude via `anthropics/anthropic-sdk-go`), tool-call orchestration via gridctl gateway
- Network access: SSH device interaction (`scrapli/scrapligo`), gNMI queries (`openconfig/gnmic`)
- Propose→Review→Execute UX with TUI plan review panel
- GAIT audit trail (Git commit per session with full trace — input, intent, tool calls, results)
- Security policies: tool allow-lists, dangerous command blocking, input sanitization
- CLI entrypoint: `netagent run`, `netagent chat`, `netagent skill`
- `network-stack.yaml` example for common network MCP server patterns
- SOUL.md (agent personality) and AGENTS.md (safety rules) loaded from workspace

**Phase 2+ (defer)**:
- NETCONF/YANG support
- Slack/WebEx webhook daemon mode
- ITSM integration (ServiceNow CR gating)
- NetBox/Nautobot reconciliation workflows
- Multi-vendor MCP server library (containerized gNMI, SSH, REST bridges)
- Advanced lab simulation (Containerlab integration)

**The key caveat**: Maintenance burden is high. Multi-vendor network device support requires ongoing effort as OS versions change. This is not a "build and ship" project — it requires an active maintainer invested in the network engineering domain.

**Why now**: gridctl platform is ready, OSS gap is open after NetClaw stalled, IETF is writing standards this architecture already satisfies, MCP has reached universal adoption. The ~12-18 month window is real.

## References

- [NetClaw GitHub](https://github.com/automateyournetwork/netclaw)
- [GoClaw GitHub](https://github.com/nextlevelbuilder/goclaw)
- [mark3labs/mcp-go](https://github.com/mark3labs/mcp-go)
- [modelcontextprotocol/go-sdk](https://github.com/modelcontextprotocol/go-sdk)
- [anthropics/anthropic-sdk-go](https://github.com/anthropics/anthropic-sdk-go)
- [openconfig/gnmic](https://github.com/openconfig/gnmic)
- [scrapli/scrapligo](https://github.com/scrapli/scrapligo)
- [Juniper/go-netconf](https://github.com/Juniper/go-netconf)
- [netbox-community/go-netbox](https://github.com/netbox-community/go-netbox)
- [IETF draft: MCP for network management](https://www.ietf.org/archive/id/draft-zw-opsawg-mcp-network-mgmt-00.html)
- [IETF draft: MCP troubleshooting automation](https://www.ietf.org/archive/id/draft-zeng-mcp-troubleshooting-00.html)
- [IETF draft: MCP + A2A applicability](https://www.ietf.org/archive/id/draft-zeng-opsawg-applicability-mcp-a2a-00.html)
- [Cisco: Beyond the Chatbot — Agentic Frameworks](https://blogs.cisco.com/learning/beyond-the-chatbot-how-agentic-frameworks-change-network-engineering)
- [Juniper Marvis AI Assistant](https://www.juniper.net/us/en/products/cloud-services/marvis-ai-assistant-datasheet.html)
- [Cisco Catalyst Center AI Assistant](https://www.cisco.com/c/en/us/td/docs/cloud-systems-management/network-automation-and-management/catalyst-center/articles/cisco-catalyst-center-ai-assistant.html)
- [NetBox Labs AI Open Source](https://netboxlabs.com/blog/new-ways-use-ai-netbox-open-sourced/)
- [State of Network Automation 2024 — NetBox Labs](https://netboxlabs.com/blog/the-state-of-network-automation-in-2024/)
- [Gartner GenAI in networking (via Selector AI)](https://www.selector.ai/blog/unlocking-the-power-of-llms-and-ai-agents-for-network-automation/)
- [HPE Mist Agentic AI Announcement](https://www.hpe.com/us/en/newsroom/press-release/2025/08/hpe-accelerates-self-driving-network-operations-with-new-mist-agentic-ai-native-innovations.html)
