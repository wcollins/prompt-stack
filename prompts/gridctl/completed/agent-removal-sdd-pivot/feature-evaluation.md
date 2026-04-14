# Feature Evaluation: Agent Removal & Spec-Driven Development Pivot

**Date**: 2026-03-27
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Large

## Summary

Remove all agent orchestration code (~10,500 lines across 45+ files) and pivot gridctl's identity to MCP infrastructure management with spec-driven tool development via SKILL.md. The agent story was incoherent — headless runtime was unimplemented, A2A TaskHandlers were nil, and container agents added orchestration overhead without meaningful UX advantage over direct MCP connections. The SKILL.md registry already implements spec-driven development at the spec-as-source level; the only missing piece is making `acceptance_criteria` executable via a new `gridctl test` command.

## The Idea

**Remove**: All agent orchestration — container agents (Docker lifecycle), headless runtime (`runtime: claude-code`), A2A protocol (agent-to-agent communication), agent canvas nodes, agent wizard form, `uses` scoping in the gateway.

**Keep**: Everything MCP — gateway aggregation, MCP server management (container, remote HTTP, OpenAPI, SSH, local process), resource management, provisioner/link coverage, the canvas, the wizard for MCP servers and resources.

**Add**: Complete the spec-driven development loop. gridctl already has SKILL.md parsing, `ToMCPTool()` generation, a workflow executor, and a validator that warns when acceptance criteria are missing. The gap is `gridctl test` — a command that executes a skill's `acceptance_criteria` as live MCP tool calls and asserts expected behavior, turning SKILL.md from a documentation convention into an executable contract.

**Reframe**: gridctl becomes "the best way to build, deploy, and connect MCP tool infrastructure." Skills are spec-driven tools. MCP servers are the underlying providers. The gateway aggregates everything. AI clients connect and get tools.

## Project Context

### Current State

gridctl has three agent types in its config schema, of which two are dead ends:
- Container agents: Docker lifecycle works, but adds orchestration overhead with no UX advantage over running containers that connect to the gateway directly
- Headless runtime (`runtime: claude-code`): Schema only — never implemented. Deployed agents stay `pending` forever.
- A2A agents: `RegisterLocalAgent` called with `nil` TaskHandler — discovery only, not functional for task routing

The SKILL.md registry (`pkg/registry/`) is a mature, well-tested spec-driven development system that already implements spec-first, spec-anchored, and spec-as-source patterns. It has been quietly shipping alongside the agent complexity without being the product's primary story.

### Removal Scope

| Package / Area | Lines | Action |
|---|---|---|
| `pkg/runtime/agent/` | 2,977 | Remove entirely |
| `pkg/a2a/` | 2,081 | Remove entirely |
| `pkg/adapter/` | 1,135 | Remove entirely |
| `internal/api/api.go` agent handlers | ~600 | Remove |
| `pkg/controller/gateway_builder.go` agent registration | ~165 | Remove |
| `pkg/runtime/orchestrator.go` agent startup | ~200 | Remove |
| `pkg/mcp/gateway.go` agent scoping | ~60 | Remove |
| `pkg/config/types.go` Agent structs | ~50 | Remove |
| `web/src/components/graph/AgentNode.tsx` | 231 | Remove |
| `web/src/components/graph/AgentBuilderInspector.tsx` | 722 | Remove |
| `web/src/components/wizard/steps/AgentForm.tsx` | 730 | Remove |
| Frontend types, graph lib, stores (partial) | ~1,295 | Partial removal |
| **Total** | **~10,500+** | |

### What Stays Untouched

The `WorkloadRuntime` interface, Docker runtime implementation, orchestrator (MCP server + resource startup), MCP gateway core, provisioner coverage, config validation for MCP servers and resources, the canvas and wizard shells, and all of `pkg/registry/`.

### On `uses` Scoping

The `uses`/scoping mechanism in `pkg/mcp/gateway.go` filtered which MCP servers an agent could access by agent identity in the SSE query parameter. Without agents, there is no identity to scope against. Drop it entirely. Per-client access control, if needed later, belongs as a gateway authentication feature (OAuth scopes, API keys with tool restrictions) — not as a YAML-defined agent profile.

### Reusable Components for the SDD Addition

- `pkg/registry/executor.go` — `Executor` already runs workflow steps via `ToolCaller`; `gridctl test` can use the same executor to run acceptance criteria scenarios
- `pkg/registry/validator.go` — already warns `WarnNoAcceptanceCriteria = "executable skill has no acceptance criteria defined"`; the infrastructure for acceptance criteria enforcement is already wired
- `pkg/registry/types.go` — `AgentSkill.AcceptanceCriteria []string` already exists; the field just needs a parser and runner
- `pkg/registry/server.go` — registry HTTP server already exposes skills; test results can be surfaced via a new `/api/registry/skills/{name}/test` endpoint

## Market Analysis

### Competitive Landscape

**Spec-driven development** (per Martin Fowler, GitHub, Augment Code):
- The discipline is gaining adoption fast. GitHub spec-kit (open source), Kiro (AWS IDE), and Tessl (private beta) all implement variants. No tool has closed the complete loop for MCP-specific development.
- The spec artifact format is not standardized: ranges from Markdown with YAML frontmatter (SKILL.md, spec-kit, Kiro) to OpenAPI contracts (Stainless, cnoe-io codegen). gridctl's SKILL.md is aligned with the emerging agentskills.io community standard.

**MCP tool development**:
- OpenAPI-to-MCP generation (Stainless, cnoe-io/openapi-mcp-codegen, FastMCP) treats OpenAPI as the source-of-truth spec. Mature, but limited to API-backed tools.
- No tool provides: spec format → MCP server generation → executable acceptance criteria → live validation. gridctl is structurally closest to closing this gap.

**Agent orchestration (what's being removed)**:
- n8n, Temporal, CrewAI, AutoGen all do this better. gridctl was never going to win this fight.

### Market Positioning

The removal is a **competitive clarification**. gridctl stops competing in a crowded agent orchestration market and focuses on a space where it has real structural advantage: MCP infrastructure with spec-driven tool development. Nobody else has SKILL.md + workflow executor + OpenAPI server generation + provisioner coverage across 12 AI clients in a single tool.

### Ecosystem Support

- agentskills.io — gridctl already implements this spec format with extensions (`acceptance_criteria`, `state`, workflow execution)
- MCP spec 2025-11-25 added `outputSchema` to tool definitions — confirms the industry moving toward tool-level contracts, directly aligned with SKILL.md's approach
- GitHub spec-kit — compatible workflow (Specify/Plan/Tasks maps to SKILL.md draft → workflow → acceptance_criteria)

### Demand Signals

The three SDD articles provided (Fowler, GitHub, Augment Code) all published in 2025-2026, indicating active practitioner adoption. The `WarnNoAcceptanceCriteria` warning already in gridctl's validator suggests the intent to make criteria executable was always planned. No existing users to migrate (beta, no production usage).

## User Experience

### Interaction Model

**Before removal**: User encounters agent nodes on canvas, tries restart/stop (returns 404 or nothing), deploys headless agent (stays pending), wonders what A2A does.

**After removal**: Three clean node types on canvas — gateway, MCP servers, resources. Skills from the registry appear as a fourth node type (tool providers, not process managers). Every node does what it says.

**SDD workflow** (new primary development path):
1. `gridctl wizard` → "Add Skill" → fill name, description, inputs, workflow steps, acceptance criteria → generates SKILL.md in `draft` state
2. `gridctl deploy` → skill executor wires the skill to the gateway as an MCP tool
3. `gridctl test my-skill` → runs acceptance criteria as live MCP tool calls against the deployed stack → pass/fail output
4. Criteria pass → `gridctl activate my-skill` → skill transitions to `active`
5. Connected AI clients (Claude Desktop, Gemini CLI, Cursor, etc.) call the skill as a native MCP tool

### Workflow Impact

- Removes all friction from agent lifecycle management (no more pending states, 404 restart errors, A2A discovery confusion)
- Canvas becomes a clean infrastructure visualization with no misleading agent nodes
- SDD workflow is more discoverable: the wizard is the entry point for both MCP server deployment and skill authoring
- `gridctl test` closes the feedback loop that currently requires manual testing

### UX Recommendations

1. **Rename the registry section on canvas**: Skills appear as a distinct node type with a spec icon, clearly separated from MCP server nodes
2. **Wizard "Add Skill" flow**: Should prefill acceptance criteria with Given/When/Then template stubs to guide the spec-first habit
3. **Test output**: `gridctl test` output should show each acceptance criterion as pass/fail with the actual MCP tool call and response, not just a summary
4. **State-gated deployment**: Consider blocking `active` state unless acceptance criteria are present and passing — enforce the spec-driven habit at the CLI level

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Agent story is incoherent; product identity is unclear |
| User impact | Broad+Deep | All users get a sharper product; devs get complete SDD workflow |
| Strategic alignment | Core mission | MCP infrastructure + spec-driven tooling is coherent and defensible |
| Market positioning | Leap ahead | No competitor has spec-driven MCP development with executable acceptance criteria |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Significant | 45+ files touched, but it's deletion — shared infra (orchestrator, gateway, config) needs surgical partial removal |
| Effort estimate | Large | ~10,500 lines removed + `gridctl test` new command |
| Risk level | Medium | Regression risk in shared code paths; mitigated by beta status (no users) |
| Maintenance burden | Minimal | Net negative — you're removing ~10,500 lines of ongoing maintenance |

## Recommendation

**Build.** No caveats. The removal has no users to break (beta), the shared infrastructure cleanly survives, and the spec-driven pivot completes a story that the registry package has been quietly setting up for.

The work breaks cleanly into two independent streams:

**Stream A — Remove**: Mechanical deletion of the three fully-removable packages (`pkg/a2a/`, `pkg/runtime/agent/`, `pkg/adapter/`) plus surgical removal from shared files (orchestrator, gateway, config, API, frontend). No design decisions needed — just delete and fix compilation. Two specific risks to mitigate explicitly:
- **Frontend layout stability**: Removing `AgentNode`, `AgentBuilderInspector`, and `AgentForm` (~1,700 lines of React) is high-risk for UI regressions in the canvas and wizard shells. Verify layout stability after removal before declaring Stream A done.
- **Gateway memory cleanup**: The `agentAccess map[string][]string` field in `pkg/mcp/gateway.go` must be fully removed, not just its population logic. Leaving the map allocated with no write path creates a memory leak and will produce confusing log output.

**Stream B — Complete SDD**: Add `gridctl test` command using the existing executor infrastructure, add `acceptance_criteria` parsing/running in the executor, add a `/api/registry/skills/{name}/test` endpoint, update the wizard to include acceptance criteria authoring in the skill form. The test runner output must prioritize Given/When/Then format to reinforce the spec-driven habit. THEN clause assertions use simple "contains" and "regex" matching for v1 — deterministic exact equality is inappropriate for LLM tool outputs.

Both streams are independently shippable. Stream A first — get the codebase clean, then Stream B sharpens the new story.

## References

- [Spec-Driven Development: 3 Tools Compared — Martin Fowler](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
- [Spec-Driven Development with AI — GitHub Blog](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/)
- [What is Spec-Driven Development — Augment Code](https://www.augmentcode.com/guides/what-is-spec-driven-development)
- [agentskills.io specification](https://agentskills.io/specification)
- [MCP Specification 2025-11-25 — modelcontextprotocol.io](https://modelcontextprotocol.io/specification/2025-11-25)
- [openapi-mcp-codegen — cnoe-io](https://github.com/cnoe-io/openapi-mcp-codegen)
- [GitHub spec-kit](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/)
