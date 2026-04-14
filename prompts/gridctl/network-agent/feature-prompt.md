# Feature Implementation: gridctl Network Agent (Phase 1)

## Context

**gridctl** is a compiled Go MCP (Model Context Protocol) orchestration platform — "One endpoint. Dozens of AI tools. Zero configuration drift." It manages Docker/Podman containers running MCP servers and exposes them through a unified gateway at `localhost:8180`. MCP clients connect via `POST /mcp` (Streamable HTTP, JSON-RPC 2.0) or `GET /sse` (legacy SSE). The gateway handles tool routing, auth, vault secrets, schema pinning (TOFU), and OpenTelemetry distributed tracing.

**Tech stack**: Go 1.22+, Cobra CLI, structured logging (slog), OpenTelemetry, Docker/Podman SDK, XChaCha20-Poly1305 vault.

**Repository**: `https://github.com/gridctl/gridctl` (the platform this agent consumes — do not modify it)

**New repository**: `gridctl/network-agent` — a standalone Go binary that IS an agent, not a platform. It connects to the gridctl gateway as an MCP client.

**Key gridctl interfaces** (read from `pkg/mcp/types.go` for reference):
- `AgentClient` — the MCP client interface (6 methods: Name, Initialize, RefreshTools, Tools, CallTool, IsInitialized, ServerInfo)
- `ToolCallObserver` — hook for post-call notifications (used for audit logging)
- `ToolCallResult` — standardized tool response with content array

## Evaluation Context

- **Market insight**: NetClaw (Python/Node.js, 412 ⭐) is the closest comparable OSS tool and stalled in Feb 2025. No production Go-based network AI agent exists. GoClaw (2.7k ⭐) proved Go wins for compiled agent runtimes but is not network-specific.
- **UX decision**: Propose→Review→Execute is non-negotiable for network engineers (NAPALM "diff before commit" is table-stakes). Read ops autonomous, write ops gated. TUI only for plan review — all other output plain text.
- **Library choices**: `mark3labs/mcp-go` (not the official SDK) for MCP client — better ergonomics for client-side use; `anthropics/anthropic-sdk-go` for LLM (official, daily releases); `scrapli/scrapligo` for SSH/CLI; `openconfig/gnmic` for gNMI.
- **Scope discipline**: Phase 1 only. Full vision (112 skills, ITSM, NETCONF, webhooks) is out of scope.
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/network-agent/feature-evaluation.md`

## Feature Description

Build `gridctl/network-agent` — a new standalone Go repository containing a compiled binary (`netagent`) that acts as a security-first AI agent for network engineering. The agent:

1. Connects to a running gridctl MCP gateway as a client
2. Accepts natural language input via CLI or interactive chat
3. Reasons over the request using Claude (LLM), selects tools, and builds an execution plan
4. **Always presents a plan before executing write operations** (propose→review→execute)
5. Executes approved tool calls through the gridctl gateway
6. Records an immutable GAIT audit trail (Git commit per session)
7. Enforces security policies: tool allow-lists, dangerous command blocking

This is the canonical consumer of the gridctl platform — it validates gridctl's design by being exactly the kind of specialized domain agent gridctl was built to support.

## Requirements

### Functional Requirements

1. Connect to gridctl MCP gateway via HTTP (`POST /mcp`) using `mark3labs/mcp-go` as the MCP client
2. Authenticate with gateway using bearer token from config (or env var `GRIDCTL_TOKEN`)
3. Implement an agent loop: receive input → reason with Claude → build execution plan → present plan → execute on approval → record audit trail
4. Load SOUL.md (agent personality/system prompt) and AGENTS.md (safety rules) from workspace directory (`~/.netagent/` by default, overridable via `--workspace`)
5. Support three CLI commands:
   - `netagent run "<task>"` — single-shot NL command; exits after completion
   - `netagent chat` — interactive multi-turn conversational session
   - `netagent skill <name> [--device <addr>] [--args key=value]` — invoke a named skill directly
6. Present execution plan as structured output before any tool call that modifies state:
   - List of target devices
   - Tool calls to be made with arguments
   - Expected outcomes
   - Explicit `[y/N]` gate (skip with `--auto-approve` flag)
7. Enforce security policies before every tool call:
   - Dangerous command blocklist: `erase`, `reload`, `delete`, `shutdown` (configurable)
   - Tool allow-list: only tools explicitly in config are callable
   - Input sanitization: reject tool calls with injected shell metacharacters in string args
8. Write GAIT audit trail: after each session, commit to `~/.netagent/audit/` Git repository with:
   - Original natural language input
   - Interpreted intent (from agent reasoning)
   - Full list of tool calls made (with arguments)
   - Tool responses
   - Final output
   - Session timestamp and agent version
9. Support SSH device interaction via `scrapli/scrapligo` (as a local tool, not through gateway):
   - `netagent` connects directly to devices via SSH for read operations when no gNMI/MCP server is available
   - Uses vault credentials from gridctl: `GRIDCTL_VAULT_URL` env var points to gridctl vault API
10. Support gNMI queries via `openconfig/gnmic` (as a local tool):
    - Connect to devices using gNMI for structured data retrieval
    - Credentials sourced from gridctl vault
11. Ship a `network-stack.yaml` example in `stacks/` that declares common network MCP servers
12. Ship example SKILL.md files in `skills/` for: health-check, BGP summary, interface status

### Non-Functional Requirements

- Compiled as a single static binary (CGO_ENABLED=0 where possible)
- Config via `~/.netagent/config.yaml` with env var overrides (`NETAGENT_*` prefix)
- Standard Go error handling: wrap errors with `fmt.Errorf("...: %w", err)`; structured logging via `slog`
- All network device calls must have a configurable timeout (default 30s)
- No credentials in config files or logs — reference gridctl vault or env vars
- Unit tests for: agent loop logic, policy enforcement, GAIT audit writer, plan builder
- Integration test against a mock MCP gateway (test server using `mark3labs/mcp-go` in test mode)

### Out of Scope (Phase 1)

- NETCONF/YANG support
- Slack/WebEx/Teams webhook daemon mode
- ITSM integration (ServiceNow, Jira, PagerDuty)
- NetBox/Nautobot reconciliation workflows
- Multi-vendor containerized MCP server library
- Advanced lab simulation (Containerlab)
- Web UI or TUI beyond plan review panel
- A2A (Agent-to-Agent) communication
- Multi-agent orchestration

## Architecture Guidance

### Recommended Approach

Follow standard Go layout with clear separation between: agent loop, LLM client, policy enforcement, audit logging, and gateway client. No circular imports. Use interfaces for testability.

```
network-agent/
├── cmd/
│   └── netagent/
│       └── main.go           # Cobra root + run/chat/skill subcommands
├── internal/
│   ├── agent/
│   │   ├── agent.go          # Agent struct: holds LLMClient, GatewayClient, PolicyEnforcer, Auditor
│   │   ├── loop.go           # Core reasoning loop: input → plan → gate → execute → audit
│   │   └── plan.go           # Plan builder: structures tool calls into human-readable plan
│   ├── llm/
│   │   ├── client.go         # LLMClient interface
│   │   └── anthropic.go      # Anthropic SDK implementation
│   ├── gateway/
│   │   └── client.go         # MCP client using mark3labs/mcp-go, connects to gridctl gateway
│   ├── policy/
│   │   ├── enforcer.go       # PolicyEnforcer interface + default implementation
│   │   └── rules.go          # Blocklist, allow-list, sanitization rules
│   ├── audit/
│   │   ├── gait.go           # GAIT recorder: writes session to Git repo
│   │   └── session.go        # Session struct (input, intent, tool calls, results, metadata)
│   ├── skills/
│   │   ├── loader.go         # Scans workspace skills/ directory for SKILL.md files
│   │   └── executor.go       # Direct skill invocation (for netagent skill command)
│   └── config/
│       └── config.go         # Config struct + loader (file + env vars)
├── pkg/
│   └── types/
│       └── types.go          # Shared types: ToolCall, ToolResult, Plan, Session
├── skills/                   # Example SKILL.md files
│   ├── health-check/SKILL.md
│   ├── bgp-summary/SKILL.md
│   └── interface-status/SKILL.md
├── stacks/
│   └── network-stack.yaml    # Example stack for common network MCP servers
├── go.mod
└── README.md
```

### Key Interfaces to Define

```go
// LLMClient abstracts the LLM provider
type LLMClient interface {
    Complete(ctx context.Context, messages []Message, tools []Tool) (*LLMResponse, error)
}

// PolicyEnforcer validates tool calls before execution
type PolicyEnforcer interface {
    Enforce(ctx context.Context, call ToolCall) error
}

// Auditor records session history to tamper-evident storage
type Auditor interface {
    Record(ctx context.Context, session Session) error
}
```

### Key Files to Understand

Before implementing, read these gridctl files for patterns and interfaces:
- `pkg/mcp/types.go` — AgentClient interface, ToolCallResult, ToolCallObserver
- `pkg/mcp/gateway.go` — How gateway routes tool calls; the Router pattern
- `pkg/registry/executor.go` — DAG workflow execution; retry and error handling patterns
- `pkg/config/types.go` — Stack YAML schema; how MCPServer and GatewayConfig are structured
- `go.mod` — Which OTel packages are already in use

### Integration Points

1. **Gateway connection**: Use `mark3labs/mcp-go` client to connect to `http://localhost:8180/mcp`. Initialize with all available tools. Use `bearer` auth header if `GRIDCTL_TOKEN` is set.
2. **Vault credentials**: Call `GET http://localhost:8180/api/vault/{key}` with bearer token. Do not cache — fetch per-session.
3. **Traces**: Wrap all gateway tool calls in OTel spans. Use W3C TraceContext headers so spans appear in gridctl's trace view.
4. **Skills invocation**: For `netagent skill`, call `POST http://localhost:8180/api/registry/skills/{name}/execute` with input JSON.

### Reusable Components

- OTel tracing: use `go.opentelemetry.io/otel/trace` — same package as gridctl uses
- Structured logging: use `log/slog` — same as gridctl
- Error wrapping: `fmt.Errorf("operation: %w", err)` — same pattern as gridctl
- `mark3labs/mcp-go` has both server and client packages; use the client package only

## UX Specification

### Discovery

User installs `netagent` binary. Runs `netagent --help`. Sees three commands: `run`, `chat`, `skill`. README shows `gridctl apply stacks/network-stack.yaml` as the prerequisite step.

### Activation

**Single-shot**:
```
$ netagent run "check BGP health on all routers"
Connecting to gridctl gateway at localhost:8180...
Found 12 tools from 3 servers.

Planning:
  Target devices: 10.1.1.1 (spine-01), 10.1.1.2 (spine-02)
  Tool calls:
    1. network__gnmi_get {path: "network-instances/network-instance/protocols/bgp", device: "10.1.1.1"}
    2. network__gnmi_get {path: "network-instances/network-instance/protocols/bgp", device: "10.1.1.2"}
  Expected output: BGP neighbor state, session count, route counts

Execute? [y/N]: y

[spine-01] BGP: 4 neighbors, all ESTABLISHED. Routes: 1204 received, 892 installed.
[spine-02] BGP: 4 neighbors, 3 ESTABLISHED, 1 IDLE. Warning: peer 10.2.0.4 is down.

Audit trail written to ~/.netagent/audit/ (commit: a3f9c12)
```

**Interactive chat**:
```
$ netagent chat
netagent> check interface status on spine-01
...
netagent> now compare with spine-02
...
netagent> exit
```

### Feedback

- Read operations: direct output with minimal preamble
- Write operations: always show plan with explicit gate
- Errors: network-contextual messages ("SSH to 10.1.1.1 refused — verify management VRF and ACL permits this host")
- `--verbose` flag: shows full reasoning trace (tool calls, LLM messages)
- Audit trail reference printed at end of each session

### Error States

- Gateway not reachable: "Cannot connect to gridctl gateway at localhost:8180. Is gridctl running? Try: gridctl apply network-stack.yaml"
- Auth failure: "Gateway authentication failed. Set GRIDCTL_TOKEN or remove auth from stack.yaml gateway config."
- Tool blocked by policy: "Tool 'router__reload' is blocked by policy (destructive operation). Use --allow-dangerous to override."
- LLM timeout: "LLM request timed out after 30s. Reduce task complexity or check network connectivity."
- Device unreachable: "SSH to 10.1.1.1 failed: connection refused. Verify device is reachable and management ACL is configured."

## Implementation Notes

### Conventions to Follow

- All exported types, functions, and interfaces must have doc comments
- Use `context.Context` as first parameter for all I/O operations
- Config fields should have both YAML tags and env var bindings
- Tests must use table-driven patterns
- Use `slog.Default()` for logging; pass logger via context or dependency injection — no global logger mutation
- `go vet`, `golangci-lint run` must pass
- Commit format: `type: subject` (see gridctl AGENTS.md for conventions)

### Potential Pitfalls

1. **Tool call loops**: LLMs can get into tool call loops if the response isn't structured. Set a max tool call depth (default 10) and fail gracefully.
2. **Streaming vs. non-streaming**: Use non-streaming for plan generation (need full response to build plan); streaming is fine for chat output.
3. **Credential handling**: Never log credentials. When calling vault API, treat the response as sensitive. Clear from memory after use.
4. **MCP session management**: `mark3labs/mcp-go` manages SSE sessions internally; the client reconnects automatically. Don't implement your own reconnect logic.
5. **GAIT Git init**: First run must init the audit repo if it doesn't exist. Use `go-git` (`github.com/go-git/go-git/v5`) for programmatic Git operations — same approach as gridctl if it uses it.
6. **Plan review for automated mode**: `--auto-approve` must be explicit in config or CLI flag — never default to auto-approve.
7. **gNMI credentials**: `openconfig/gnmic` requires a target config including TLS settings. Default to TLS-enabled with system cert pool; support `--no-tls` for lab use only.
8. **SSH key vs. password**: Prefer SSH key auth via vault. Fall back to password only if explicitly configured.

### Suggested Build Order

1. **Config + types** (`internal/config/`, `pkg/types/`) — foundation for everything
2. **Gateway client** (`internal/gateway/`) — connect to gridctl, list tools, call a tool
3. **LLM client** (`internal/llm/`) — call Claude with tool definitions, parse tool call responses
4. **Policy enforcer** (`internal/policy/`) — allow-list and blocklist enforcement
5. **Plan builder** (`internal/agent/plan.go`) — structure tool calls into human-readable plan
6. **Agent loop** (`internal/agent/loop.go`) — wire together: input → reason → plan → gate → execute
7. **GAIT auditor** (`internal/audit/`) — Git-based session recording
8. **CLI commands** (`cmd/netagent/`) — `run`, `chat`, `skill` subcommands
9. **Skill loader** (`internal/skills/`) — scan workspace for SKILL.md files
10. **Example skills + network-stack.yaml** — ship working examples

## Acceptance Criteria

1. `netagent run "show bgp summary"` connects to a running gridctl gateway, calls at least one tool, and returns structured output — end to end without error
2. A tool on the blocklist (e.g., a tool with "reload" in its name) is rejected by the policy enforcer with a clear error message before any network call is made
3. `netagent run "restart interface eth0"` (a write operation) shows a plan and halts at `[y/N]` — does not execute without confirmation
4. After a successful session, `~/.netagent/audit/` contains a Git repository with at least one commit containing the session input, tool calls, and results
5. `netagent chat` maintains multi-turn context — a follow-up question ("now check spine-02") uses context from the previous turn
6. `go test ./...` passes with no race conditions (`go test -race ./...`)
7. `golangci-lint run` passes with no errors
8. `netagent run "show bgp summary"` with no gateway running returns a clear error message with remediation steps (not a panic or stack trace)
9. `netagent skill health-check --device 10.1.1.1` invokes the health-check skill via the gridctl registry API and returns formatted output
10. The `stacks/network-stack.yaml` example is valid per `gridctl validate stacks/network-stack.yaml` (exit 0)

## References

- [mark3labs/mcp-go](https://github.com/mark3labs/mcp-go) — MCP client library
- [anthropics/anthropic-sdk-go](https://github.com/anthropics/anthropic-sdk-go) — Claude SDK (tool use docs: SDK README)
- [openconfig/gnmic](https://github.com/openconfig/gnmic) — gNMI Go library (library mode docs in pkg/)
- [scrapli/scrapligo](https://github.com/scrapli/scrapligo) — Go SSH for network devices
- [go-git/go-git](https://github.com/go-git/go-git) — Programmatic Git for GAIT audit trail
- [IETF MCP for network management](https://www.ietf.org/archive/id/draft-zw-opsawg-mcp-network-mgmt-00.html) — Standards context
- [NetClaw skills reference](https://github.com/automateyournetwork/netclaw) — Reference for skill design patterns
- [gridctl AGENTS.md](https://github.com/gridctl/gridctl/blob/main/AGENTS.md) — Development conventions for the Go codebase this agent consumes
- [AgentSkills spec](https://agentskills.io) — SKILL.md frontmatter specification
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/network-agent/feature-evaluation.md`
