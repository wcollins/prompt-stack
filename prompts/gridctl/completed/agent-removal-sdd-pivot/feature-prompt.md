# Feature Implementation: Agent Removal & Spec-Driven Development Pivot

## Context

gridctl is a Go CLI and web application for managing multi-agent MCP stacks. It supports three agent types: container agents (Docker), A2A agents (agent-to-agent protocol), and headless agents (`runtime: claude-code`). This change removes all agent orchestration and pivots the product identity to: MCP infrastructure management + spec-driven tool development via SKILL.md.

**Tech stack**: Go 1.23+, React/TypeScript frontend, Docker runtime via `github.com/docker/docker`, structured logging via `github.com/charmbracelet/log`, YAML config, MCP over HTTP (Streamable HTTP transport). Registry uses SKILL.md (YAML frontmatter + Markdown body).

**Beta product, no existing users.** This is a clean break with no migration concerns.

## Evaluation Context

- **No existing users**: Beta product. No backward compatibility required for agent config or A2A endpoints.
- **Agent story was broken**: Headless runtime never implemented (schema only), A2A TaskHandlers were `nil` (discovery only, not functional), container agent orchestration added overhead without UX advantage.
- **SDD is already 90% built**: `pkg/registry/` has SKILL.md parsing, `ToMCPTool()` generation, a DAG-based workflow executor, and a validator that already warns when acceptance criteria are missing. The only gap is executing those criteria as live MCP calls.
- **Two independent streams**: Stream A (remove agents) and Stream B (complete SDD) are independently shippable. Do A first.
- **Full evaluation**: `./feature-evaluation.md`

## Feature Description

**Stream A — Remove agent orchestration**: Delete three fully-removable packages, surgically remove agent code from shared files, clean up frontend. Net result: ~10,500 lines removed, product identity sharpened.

**Stream B — Complete spec-driven development**: Add `gridctl test <skill>` command that executes a skill's `acceptance_criteria` as live MCP tool calls. The validator already warns when criteria are missing; this makes them executable. Add wizard support for authoring acceptance criteria. Surface test results via API and canvas.

## Requirements

### Stream A: Agent Removal

#### Functional Requirements

1. Remove `pkg/runtime/agent/` package entirely (10 files, 2,977 lines)
2. Remove `pkg/a2a/` package entirely (7 files, 2,081 lines)
3. Remove `pkg/adapter/` package entirely (2 files, 1,135 lines)
4. Remove `Agent`, `A2AConfig`, `A2ASkill`, `A2AAgent`, `A2AAuth` structs from `pkg/config/types.go`
5. Remove `IsHeadless()` and `IsA2AEnabled()` methods from `pkg/config/types.go`
6. Remove `Agents []Agent` and `A2AAgents []A2AAgent` fields from the `Stack` struct
7. Remove `startAgent()`, `sortAgentsByDependency()`, `agentLabels()`, and the agent startup loop from `pkg/runtime/orchestrator.go`
8. Remove `AgentResult` struct and `Agents` field from `UpResult` in `pkg/runtime/orchestrator.go`
9. Remove agent scoping from `pkg/mcp/gateway.go`: `agentAccess` field, `RegisterAgent()`, `UnregisterAgent()`, `HasAgent()`, `GetAgentAllowedServers()`, `getAgentServerAccess()`, `HandleToolsListForAgent()`, `HandleToolsCallForAgent()`, `getAgentFilteredTools()`
10. Remove agent handlers from `internal/api/api.go`: `handleAgentAction()`, `handleAgentLogs()`, `handleAgentRestart()`, `handleAgentStop()`, `getContainerAgents()`, `getAgentStatuses()`, `handleA2AAgentCards()`
11. Remove `/api/agents/` and A2A route registrations from `internal/api/api.go`
12. Remove `registerAgents()`, `registerA2AAgents()`, `registerAgentAdapters()` from `pkg/controller/gateway_builder.go`
13. Remove A2A gateway fields and initialization from `pkg/controller/gateway_builder.go`
14. Remove `web/src/components/graph/AgentNode.tsx` entirely
15. Remove `web/src/components/graph/AgentBuilderInspector.tsx` entirely
16. Remove `web/src/components/wizard/steps/AgentForm.tsx` entirely
17. Remove `AgentStatus`, `AgentNodeData`, `AgentVariant` from `web/src/types/index.ts`
18. Remove agent node creation, agent edges, and agent edge types from `web/src/lib/graph/`
19. Remove agent form data from wizard store and stack store
20. Remove `agents:` and `a2a-agents:` from stack YAML schema validation
21. `go build ./...` passes with zero errors after removal
22. `npm run build` passes with zero errors after removal
23. All existing non-agent tests pass

#### Non-Functional Requirements

- No new dependencies introduced during removal
- Do not touch `pkg/registry/`, `pkg/provisioner/`, or any MCP server / resource management code
- Remove agent-related test files alongside the packages being removed; do not leave orphaned test helpers

#### Out of Scope (Stream A)

- Adding any new functionality
- Changing how MCP servers or resources are managed
- Adding `gridctl test` (that is Stream B)
- Any frontend skill/registry UI changes

---

### Stream B: Complete Spec-Driven Development

#### Functional Requirements

1. Add `gridctl test <skill-name>` CLI command that runs a skill's `acceptance_criteria` against the live gateway
2. Parse each acceptance criterion string using Given/When/Then structure:
   - `GIVEN <context> WHEN <tool-call-description> THEN <assertion>`
   - Tool call: resolve the tool name and construct input from the WHEN clause
   - Assertion: check the tool result against the THEN clause
3. The executor for test runs through the existing `pkg/registry/executor.go` `ToolCaller` interface — tests call actual MCP tools against the running gateway, not mocks
4. `gridctl test` output per criterion: `✓ GIVEN ... WHEN ... THEN ...` or `✗ GIVEN ... WHEN ... THEN ... (got: <actual>)`
5. Exit code 0 if all criteria pass, non-zero if any fail
6. Add `POST /api/registry/skills/{name}/test` API endpoint that runs criteria and returns structured results:
   ```json
   {
     "skill": "my-skill",
     "passed": 2,
     "failed": 1,
     "results": [
       {"criterion": "GIVEN ... WHEN ... THEN ...", "passed": true},
       {"criterion": "GIVEN ... WHEN ... THEN ...", "passed": false, "actual": "..."}
     ]
   }
   ```
7. The wizard "Add Skill" form must include an acceptance criteria section with Given/When/Then stub templates
8. The canvas skill node shows a test status badge: `✓ tested` (green), `✗ failing` (red), or `— untested` (gray) based on last test run result stored in the registry
9. `gridctl validate <skill-name>` already warns on missing criteria; after this change it should exit non-zero (error, not warning) when an executable skill has no acceptance criteria
10. Skills can only transition from `draft` → `active` if acceptance criteria are present (enforced by `gridctl activate`)

#### Non-Functional Requirements

- Test runs must timeout per criterion (default: 30s per criterion, configurable via `--timeout`)
- Test output must show which MCP tool was called and with what arguments for each criterion, for debuggability
- The `acceptance_criteria` field format does not change — existing SKILL.md files with prose criteria still parse correctly; the executor attempts to parse them as Given/When/Then and skips (with a warning) any that don't match the pattern

#### Out of Scope (Stream B)

- Formal BDD framework integration (Gherkin parser, etc.)
- Test result persistence across gateway restarts (in-memory is fine for now)
- CI/CD integration hooks
- Parallel test execution across multiple skills

---

## Architecture Guidance

### Stream A: Key Files and Removal Order

Work in this order to minimize broken intermediate states:

**1. Remove the three standalone packages first** (no shared code dependencies):
```
pkg/runtime/agent/    → rm -rf
pkg/a2a/              → rm -rf
pkg/adapter/          → rm -rf
```
Run `go build ./...` after each — these will break imports elsewhere, which is your TODO list.

**2. Fix `pkg/controller/gateway_builder.go`**:
- Remove imports for `pkg/a2a`, `pkg/adapter`
- Remove A2A gateway fields from the `Instance` struct and builder
- Remove `registerAgents()`, `registerA2AAgents()`, `registerAgentAdapters()` methods
- Remove calls to those methods in the main build flow

**3. Fix `pkg/mcp/gateway.go`**:
- Remove `agentAccess map[string][]string` field **and its initialization** — the map itself must be gone, not just the code that writes to it. A nil or empty allocated map with no write path is a memory leak and will produce confusing entries in gateway log output.
- Remove the 8 agent-scoping methods (lines 654-853)
- Remove associated tests in `gateway_test.go`

**4. Fix `pkg/runtime/orchestrator.go`**:
- Remove `AgentResult` struct and `Agents []AgentResult` from `UpResult`
- Remove agent startup loop from `Up()` (the `for _, agent := range stack.Agents` block)
- Remove `startAgent()` method entirely
- Remove `sortAgentsByDependency()` and `agentLabels()` functions
- Remove associated test cases

**5. Fix `pkg/config/types.go`**:
- Remove `Agent`, `A2AConfig`, `A2ASkill`, `A2AAgent`, `A2AAuth` structs
- Remove `Agents []Agent` and `A2AAgents []A2AAgent` from `Stack`
- Remove `IsHeadless()` and `IsA2AEnabled()` methods
- Fix `NeedsContainerRuntime()` and `ContainerWorkloads()` which reference agents
- Update config validation in `pkg/config/validate.go` — remove agent validation blocks

**6. Fix `internal/api/api.go`**:
- Remove imports for `pkg/a2a`, `pkg/runtime/agent`
- Remove `a2aGateway` field from `Server`
- Remove `SetA2AGateway()`, `A2AGateway()` methods
- Remove route registrations for `/api/agents/` and A2A agent cards
- Remove all agent handlers and helpers (lines 568-876 approximately)
- Update `GET /api/status` response — remove `agents` field

**7. Frontend cleanup**:
- `rm web/src/components/graph/AgentNode.tsx`
- `rm web/src/components/graph/AgentBuilderInspector.tsx`
- `rm web/src/components/wizard/steps/AgentForm.tsx`
- Update `web/src/types/index.ts` — remove agent types
- Update `web/src/lib/graph/nodes.ts`, `edges.ts`, `transform.ts`, `types.ts` — remove agent node/edge creation
- Update `web/src/stores/useWizardStore.ts`, `useStackStore.ts` — remove agent state
- Update canvas `nodeTypes` registration — remove `agentNode` type
- Run `npm run build` to find remaining references
- **After deletion, manually verify canvas layout and wizard shell**: removing ~1,700 lines of React (AgentNode + AgentBuilderInspector + AgentForm) is the highest-risk UI regression surface. Confirm the canvas renders correctly with only gateway/MCP server/resource nodes, and the wizard opens and closes without errors before declaring Stream A done.

### Stream B: Key Files to Understand First

| File | Why it matters |
|------|---------------|
| `pkg/registry/types.go` | `AgentSkill.AcceptanceCriteria []string` — field exists, just unevaluated |
| `pkg/registry/executor.go` | `Executor.Execute()` — use this to run test scenarios through the same ToolCaller path as real skill execution |
| `pkg/registry/validator.go:21-22` | `WarnNoAcceptanceCriteria` — change from warning to error in `gridctl activate` path |
| `pkg/registry/server.go` | Add `/api/registry/skills/{name}/test` endpoint here |
| `pkg/registry/store.go` | How skills are loaded; where to persist last test result |
| `cmd/gridctl/` | Where to add the `test` subcommand |

### Stream B: Recommended Approach

The acceptance criteria format is intentionally simple — prose Given/When/Then strings. The executor should parse them with a best-effort regex, not a full Gherkin parser:

```go
// Pattern: GIVEN <context> WHEN <tool> is called with <args> THEN <assertion>
// Simple form: GIVEN <anything> WHEN <tool-name> THEN <assertion>
var criterionPattern = regexp.MustCompile(
    `(?i)GIVEN\s+(.+?)\s+WHEN\s+(.+?)\s+THEN\s+(.+)`)
```

For the initial implementation, focus on making criteria that reference skill inputs + tool names parseable. The WHEN clause resolves to a tool call; the THEN clause is evaluated against the string representation of the result.

**v1 assertion types for THEN clauses** (exact equality is inappropriate for LLM tool outputs — results are non-deterministic):
- `contains <substring>` — result string contains the expected value (default if no qualifier)
- `matches <regex>` — result matches a regular expression
- `is empty` — result is empty or blank
- `is not empty` — result has content

Examples in a SKILL.md:
```yaml
acceptance_criteria:
  - GIVEN a valid PR number WHEN the skill is called THEN contains changed_files
  - GIVEN an invalid PR WHEN the skill is called THEN contains error
  - GIVEN max_files is 5 WHEN the skill is called THEN matches "files":\s*\[([^]]*,){0,4}[^]]*\]
```

The output format must always render as Given/When/Then, one line per criterion, to reinforce the spec-driven habit. Do not collapse or reformat criteria into a summary table.

The test command connects to the running gateway at `http://localhost:<port>` (same as `gridctl status` does). It creates an `Executor` with the gateway as the `ToolCaller` and runs each criterion as a single-step workflow.

### Reusable Components

- `pkg/registry/executor.go:Executor` — use directly for test runs, same as skill execution
- `pkg/registry/dag.go` — already handles step dependency resolution; criteria run sequentially (no DAG needed for tests)
- `pkg/registry/template.go` — template rendering for injecting test inputs into tool args
- `cmd/gridctl/` existing subcommand pattern — follow the same structure as `gridctl validate`

## UX Specification

### Stream A — Canvas After Removal

**Node types**: gateway, mcp-server, resource, skill (from registry). No agent nodes.

**Wizard flows**: Add MCP Server, Add Resource. Agent creation removed entirely.

**Status endpoint** (`GET /api/status`): Remove `agents` array from response. All clients connected to the gateway appear in the `clients` section (already implemented).

### Stream B — `gridctl test` CLI

```
$ gridctl test summarize-pr-diff

Running acceptance criteria for skill: summarize-pr-diff
Gateway: http://localhost:8180

  GIVEN a valid PR number
  WHEN  summarize-pr-diff is called
  THEN  contains changed_files
  ✓ passed
  → github__get_pull_request({"repo":"test/repo","pull_number":1}) → ok
  → github__get_diff({"repo":"test/repo","pull_number":1}) → ok

  GIVEN an invalid PR number
  WHEN  summarize-pr-diff is called
  THEN  contains error
  ✗ failed
  → github__get_pull_request({"repo":"test/repo","pull_number":99999}) → ok
  → Result: {"changed_files":0,"line_delta":0,"description":"PR not found"}
  → Expected result to contain "error"

2 criteria, 1 passed, 1 failed

Skill status: FAILING
Run 'gridctl test summarize-pr-diff --verbose' for full tool response bodies.
```

### Stream B — Wizard Skill Form Acceptance Criteria Section

Add a repeatable field group in the wizard skill form:

```
Acceptance Criteria
[+ Add criterion]

  ┌─────────────────────────────────────────────────────┐
  │ GIVEN  [a valid input is provided              ]    │
  │ WHEN   [the skill is called                    ]    │
  │ THEN   [a result is returned without errors    ]    │
  └─────────────────────────────────────────────────────┘
```

Pre-populate with one stub criterion on form open to establish the habit.

### Stream B — Canvas Skill Node Test Badge

Skill nodes on the canvas display a small badge below the skill name:
- `✓ tested` (green) — all criteria passed on last run
- `✗ failing` (red) — one or more criteria failed
- `— untested` (gray, default) — no test has been run

Clicking the badge opens a panel showing per-criterion pass/fail results.

## Implementation Notes

### Conventions to Follow

- Error wrapping: `fmt.Errorf("running acceptance criteria for %s: %w", skillName, err)`
- Structured logging: pass the logger from the command context, use `slog.Info/Warn/Error`
- Test command exit codes: 0 = all pass, 1 = criteria failures, 2 = infrastructure error (gateway unreachable, skill not found)
- Follow the existing `gridctl validate` command pattern for the `gridctl test` command structure

### Potential Pitfalls (Stream A)

1. **`NeedsContainerRuntime()` references agents**: `pkg/config/types.go` checks both MCP servers and agents for container runtime need. After removal, only MCP servers and resources remain in this check.
2. **`ContainerWorkloads()` references agents**: Same file — remove agents from the workload list.
3. **`pkg/config/plan.go` agent diffing**: The stack plan/diff logic includes agent comparison. Remove entirely.
4. **`pkg/config/health.go` agent health checks**: Remove agent health check sections.
5. **Frontend `transform.ts`**: This file builds the graph from API status response. It currently handles agent nodes from `status.agents`. After removal, the `agents` array is gone from the API — remove all references.
6. **Frontend `AgentBuilderInspector.tsx`**: This is 722 lines and likely has shared imports (types, hooks). Check for any non-agent components that may have been co-located in this file before deleting.

### Potential Pitfalls (Stream B)

1. **Criterion parsing ambiguity**: Some prose criteria won't parse cleanly. Skip unparseable criteria with a warning rather than failing the test run.
2. **Gateway must be running**: `gridctl test` requires the gateway to be up. Fail fast with a clear "gateway not reachable" message if it isn't.
3. **Tool name resolution**: Criteria reference skills and tools by logical name. The executor needs the full `server__tool` format. Check that the skill's `allowed-tools` field maps correctly to registered gateway tools.
4. **Timeout per criterion**: Default 30s. Without this, a hanging tool call blocks the entire test run.

### Suggested Build Order

**Stream A**:
1. Delete three packages, fix compilation errors bottom-up (packages → controller → orchestrator → config → API → frontend)
2. Run full test suite, fix any broken tests in remaining packages
3. `npm run build` and fix frontend compilation
4. Manual smoke test: `gridctl up` with an MCP-server-only stack, verify canvas shows correctly

**Stream B**:
1. Add `acceptance_criteria` runner to `pkg/registry/executor.go` (new method on `Executor`)
2. Add `gridctl test` CLI command in `cmd/gridctl/`
3. Add `/api/registry/skills/{name}/test` endpoint to `pkg/registry/server.go`
4. Update wizard skill form to include acceptance criteria fields
5. Update canvas skill node to show test status badge
6. Update `gridctl activate` to require acceptance criteria
7. Integration test: full cycle from SKILL.md with criteria → `gridctl test` → pass → activate

## Acceptance Criteria

### Stream A

1. `go build ./...` succeeds with zero errors
2. `npm run build` succeeds with zero errors
3. All non-agent tests pass (`go test ./...`)
4. `GET /api/status` response contains no `agents` field
5. Stack YAML with `agents:` block fails validation with a clear error
6. Stack YAML with `a2a-agents:` block fails validation with a clear error
7. Canvas renders with no agent node type registered — `nodeTypes` has no `agentNode` key
8. The wizard has no "Add Agent" option
9. `go mod tidy` produces no changes (no orphaned dependencies from removed packages)

### Stream B

1. `gridctl test <skill>` with all-passing criteria exits 0
2. `gridctl test <skill>` with one failing criterion exits 1 and prints `✗` for the failing criterion with actual output
3. `gridctl test <skill>` when gateway is not running exits 2 with "gateway not reachable" message
4. `gridctl test <skill>` when skill has no acceptance criteria exits 1 with "no acceptance criteria defined" message
5. `POST /api/registry/skills/{name}/test` returns structured JSON with per-criterion results
6. `gridctl activate <skill>` fails when skill has no acceptance criteria, prints actionable error
7. Wizard skill form renders acceptance criteria section with one pre-populated stub
8. Canvas skill node shows `— untested` badge by default, `✓ tested` after passing test run
9. A criterion that doesn't match Given/When/Then pattern is skipped with a warning, not a failure
10. Each test criterion has a 30s timeout enforced; a hanging tool call is reported as a failure

## References

- [agentskills.io specification](https://agentskills.io/specification)
- [Spec-Driven Development: 3 Tools Compared — Martin Fowler](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
- [Spec-Driven Development with AI — GitHub Blog](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/)
- [What is Spec-Driven Development — Augment Code](https://www.augmentcode.com/guides/what-is-spec-driven-development)
- [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)
- [Feature evaluation](./feature-evaluation.md)
