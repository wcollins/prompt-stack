# Feature Implementation: Agent Runtime Removal (Skills Redesign)

## Context

**Project**: gridctl — an MCP gateway tool that proxies upstream MCP servers
(atlassian, github, gitlab, etc.) into a unified endpoint that Claude Code,
Claude Desktop, Cursor, Codex, and other MCP clients connect to. Pre-1.0
(v0.1.x alpha). Go backend + React/TypeScript frontend (web/), Vite + Tailwind.
Branch model: fork workflow (origin = your fork, upstream = main repo).

**Current architecture** (pre-removal):

- **`pkg/mcp/`** — the actual MCP gateway: Gateway, Router, SessionManager.
  Independent of agent runtime; preserved intact.
- **`pkg/registry/`** — skill store + MCP server exposing skills as MCP
  prompts. Implements `mcp.PromptProvider` (preserve) and `mcp.AgentClient`
  (rip out execution paths).
- **`pkg/agent/`** — 66 files, ~15K LOC. The execution layer being removed:
  orchestrator, runtime, sandbox, persist (run ledger), skill, compose,
  runner, gateway adapter, dev tooling, internal/eino LLM adapter, and the
  `pkg/agent/llm/` provider abstraction.
- **`pkg/controller/gateway_builder.go`** — ~1.7K LOC orchestration; assembles
  the agent runtime aggregate and wires it into the gateway + API server.
- **`internal/api/`** — REST API; routes for `/api/agent/{dev,runs}/*` and
  `/api/playground/*` come out.
- **`cmd/gridctl/`** — CLI; `agent`, `run`, `runs` subcommands come out.
- **`web/src/`** — React UI; four workspaces today (Topology / Stage /
  Library / Runs). Post-removal: Topology + Library only.

**Strategic frame**: gridctl pivots from "MCP gateway + agent runtime + skill
library" to "MCP gateway + skill library." The agent runtime category is
dominated by LangGraph / CrewAI / AutoGen / OpenAI Agents SDK; competing
there is structurally unwinnable for a small project. Post-removal, gridctl
owns a defensible niche: "MCP gateway with built-in skill-authoring UI"
that none of the 17+ competing MCP gateways address.

**Build commands** (from memory):
- `make build` produces `./gridctl` — use this, NOT the brew-installed binary.
- `go test -race ./...` for backend tests.
- `npm run build` inside `web/` for the frontend.
- `gridctl serve` daemonizes — use `--foreground` if a script needs to kill it.

## Evaluation Context

Key findings from the feature-scout evaluation that shape this prompt:

- **Architectural seams are pre-designed for this surgery**: `AgentRuntime`
  in `pkg/mcp/gateway.go:124-126` is an opaque marker interface; the
  registry's `SkillRegistry` and `TSDispatcher` are explicit interfaces;
  `AgentSkill.HandlerLanguage`/`HandlerPath` fields are tagged `yaml:"-"` so
  frontmatter parsing is handler-agnostic. This is not exploratory surgery.

- **`pkg/optimize/` and `pkg/pricing/` are already decoupled** — the comments
  in `pkg/optimize/optimize.go` mention `pkg/agent/persist` but there is **no
  actual import**. The decoupling is enforced by design. Deleting persist
  will not break optimize/pricing.

- **Two PRs, sequenced** (per user decision): PR1 = backend (Go) deletion +
  controller/api rewiring. PR2 = frontend (web) cleanup + docs +
  test pruning. This keeps each PR reviewable, limits in-flight risk, and
  lets PR1 ship a working backend before web catches up.

- **Playground deletion is explicit**: the original plan hedged on
  Playground. User confirmed it goes — including `pkg/agent/llm/`,
  `internal/api/playground.go`, `web/src/components/playground/`. No
  `pkg/llm/` extraction is needed.

- **Clean break, no migration window**: v0.1.x pre-1.0; CHANGELOG entry and
  redirect routes cover bookmark holdouts.

- Full evaluation: `prompts/gridctl/agent-runtime-removal/feature-evaluation.md`

## Feature Description

Delete the agent execution runtime and adjacent surfaces from gridctl, leaving
behind a focused MCP gateway with a workspace for authoring prompt-only
skills that the registry serves as MCP prompts to upstream clients.

**What this is**: a surgical removal of ~20K LOC, plus minimal rewiring of
the surfaces that touched the removed code (controller, api router, app
shell, route table, docs, CHANGELOG).

**What this solves**:
- Removes gridctl from the agent runtime category (LangGraph et al.) where it
  cannot win as a small project.
- Reduces sustained maintenance cost by ~15K LOC of runtime/sandbox/persist
  code.
- Simplifies the user mental model from 4 workspaces (Topology, Stage,
  Library, Runs) to 2 (Topology, Library).
- Aligns gridctl with the convergence point of two now-standardized specs:
  MCP (donated to CNCF) and Agent Skills (open spec adopted by 20+
  platforms).

**Who benefits**:
- gridctl maintainers: less code, tighter scope.
- gridctl UI users: simpler mental model.
- gridctl CLI users: smaller, more focused command tree.
- MCP client users (Claude Code, Claude Desktop, Cursor, etc.): no change —
  the registry-as-prompt-provider path is preserved unchanged.

## Requirements

### Functional Requirements

#### Backend (PR1)

1. **Delete `pkg/agent/` in its entirety**, including:
   - `pkg/agent/{orchestrator,runtime,skill,sandbox,persist,gateway,runner,compose,dev,internal/eino,llm}/`
   - All `*.go` and `*_test.go` files within.

2. **Delete CLI commands**:
   - `cmd/gridctl/agent.go` and `cmd/gridctl/agent_test.go`
   - `cmd/gridctl/runs.go` and `cmd/gridctl/runs_test.go`
   - `cmd/gridctl/run.go` and `cmd/gridctl/run_test.go` (the standalone `run`
     subcommand is part of the execution surface)
   - Remove `agent`, `run`, `runs` subcommand registrations from
     `cmd/gridctl/root.go` (whatever the registration shape is — look at
     existing subcommand wiring).

3. **Delete API handlers**:
   - `internal/api/agent_dev.go`, `agent_dev_test.go`
   - `internal/api/agent_runs.go`, `agent_runs_test.go`
   - `internal/api/playground.go` and any `playground_test.go`
   - `internal/api/run_persister.go`, `run_persister_test.go`
   - `internal/api/skills_test.go` if it exists and tests removed routes
     (read it first to confirm)
   - Remove `/api/agent/*` and `/api/playground/*` route registrations from
     `internal/api/router.go` (or whatever the router file is called).
   - Remove `AgentRuntime`-related fields, setter methods, and lazy
     initializers from `internal/api/api.go`. Specifically: the runtime
     reference, per-component setters for run store / approval registry /
     TS dispatcher / dev server, and the lazy `playgroundService` allocator.

4. **Rewire `pkg/controller/gateway_builder.go`**:
   - Delete all `pkg/agent/*` imports (8 of them per the explore-agent
     inventory).
   - Delete agent sandbox, runtime, dispatcher, tool caller initialization
     in `setupGateway()` (phase 1c — around lines 197-230).
   - Delete `SetAgentRuntime()` calls on gateway and `SetSkillRegistry()` /
     `SetTSDispatcher()` calls on registry server.
   - Delete `wireAgentDevServer()` and the dev-server attachment (~lines
     576-579).
   - Delete `loadGoSkillPlugins()` if present.
   - Delete `makeDispatcherBindings()` (~lines 905-982) and the `childRun...`
     wrapper helpers.

5. **Trim `pkg/mcp/gateway.go`**:
   - Remove the `AgentRuntime` marker interface (lines 118-126).
   - Remove the `agentRuntime` field on `Gateway` (line 141).
   - Remove `SetAgentRuntime()` (lines 237-245) and `AgentRuntime()`
     (lines 247-253) methods.
   - Remove the `RunPersister` field (line 148), `SetRunPersister()` (lines
     206-217), and any internal usage of the persister in the dispatch path.
     Verify there are no remaining callers; if there are non-runtime
     callers, leave the persister hook in place but cut the runtime
     callers only.

6. **Refactor `pkg/registry/server.go`**:
   - Delete the `github.com/gridctl/gridctl/pkg/agent/skill` import (line 11).
   - Delete the `SkillRegistry` interface (lines 23-26) and the
     `TSDispatcher` interface (lines 35-37) entirely. These have no
     remaining implementations once `pkg/agent/` is gone.
   - Delete the `skillRegistry` and `tsDispatcher` fields on `Server` (lines
     48-49).
   - Delete `SetSkillRegistry()` (lines 95-102) and `SetTSDispatcher()`
     (lines 104-111).
   - Update `Tools()` to return `nil` (or `[]mcp.Tool{}`) since there is no
     longer any typed-skill source. The `mcp.AgentClient` compile-time check
     (line 54) must still satisfy.
   - Update `CallTool()` to return `(nil, errors.New("registry: typed-skill
     execution removed; skills are served as MCP prompts only"))`. Or
     similar. The error path is required because `mcp.AgentClient` requires
     the method.
   - Confirm `ListPromptData()` / `GetPromptData()` (the `PromptProvider`
     surface) is untouched — these are the surviving public API.

7. **Refactor `pkg/registry/types.go`**:
   - Delete the `HandlerLanguage` and `HandlerPath` fields from `AgentSkill`
     (lines 47-48). These are no longer populated, no longer read.
   - Delete the comment block above them (lines 42-46) that describes
     handler discovery.

8. **Refactor `pkg/registry/store.go`**:
   - Delete `detectHandler()` and any walker code that probes for `skill.go`
     / `skill.ts` siblings.
   - Skills walked from disk now populate only the SKILL.md fields; no
     handler-detection branch.

9. **Trim `pkg/optimize/`**:
   - Remove heuristic files that reference the persist ledger (likely
     `unbounded_loop`, `oversized_prompt`, `untyped_handoff` per the plan).
     Use `rg -l "agent/persist|RunLedger|RunEvent" pkg/optimize/` to find
     the actual set.
   - Update doc comments that mention `pkg/agent/persist` to remove the
     reference.
   - `pkg/pricing/` is untouched — it's a generic utility.

10. **Delete integration tests that exercise the runtime**:
    - `tests/integration/hot_reload_test.go` (exercises the agent IDE hot
      reload)
    - `tests/integration/skills_private_git_test.go` (uses
      `pkg/agent/dev/parser`)
    - Keep `tests/integration/anthropic_skill_compat_test.go` and
      `tests/integration/runtime_test.go` (Docker orchestration, not agent
      runtime).

11. **`pkg/runtime/`** — confirm this is the Docker/Podman runtime
    orchestration package, NOT agent runtime. Should be untouched. (Name
    collision; easy to confuse.)

12. **Verify the backend builds and tests cleanly**:
    - `go build ./...`
    - `go test -race ./...`
    - `golangci-lint run`
    - `./gridctl --help` shows no `agent`, `run`, `runs` subcommands.

#### Frontend + Docs (PR2)

13. **Routing & workspace registry**:
    - `web/src/routes.tsx`:
      - Delete `SkillsWorkspace`, `RunsWorkspace`, `RunDetailWorkspace`
        lazy imports.
      - Delete `/skills`, `/runs`, `/runs/:runID` route blocks.
      - Update `<Route path="/agent">` → redirect to `/library` (not
        `/skills`).
      - Add explicit redirects so existing bookmarks don't 404:
        `<Route path="/skills" element={<Navigate to="/library" replace />} />`
        `<Route path="/runs" element={<Navigate to="/library" replace />} />`
        `<Route path="/runs/:runID" element={<Navigate to="/library" replace />} />`
        Keep these through v1.0 (mirroring the `/registry` → `/library-window`
        and `/vault` → `/var` pattern already used in the same file).
    - `web/src/types/workspace.ts`:
      - Update `Workspace` type to `'topology' | 'library'`.
      - Update `WORKSPACE_CONFIG` to only include topology and library;
        reorder so library is `shortcutKey: '2'`.
      - Verify `WORKSPACES`, `WORKSPACE_LABELS`, `isWorkspace` derive
        correctly.

14. **Delete web component trees**:
    - `web/src/components/agent/` (entire directory: IDE, Canvas, custom
      nodes, ApprovalBanner, etc.)
    - `web/src/components/runs/` (browser, hooks, stream wiring)
    - `web/src/components/skills/` (IDE-specific commands and hooks; not the
      Library — confirm by reading directory contents first)
    - `web/src/components/playground/` (PlaygroundTab and dependencies)
    - `web/src/components/workspaces/SkillsWorkspace.tsx`
    - `web/src/components/workspaces/RunsWorkspace.tsx`
    - `web/src/components/workspaces/RunDetailWorkspace.tsx`

15. **Delete web library files**:
    - `web/src/lib/agent-api.ts` (if present)
    - `web/src/lib/agent-runs.ts`
    - Anything in `web/src/api/` or `web/src/types/` named for agent / runs /
      playground.

16. **Trim `web/src/components/shell/AppShell.tsx`**:
    - Delete imports at lines 11, 19-20 (`ApprovalBanner`,
      `useGlobalRunsStream`, `useRunsCommands`).
    - Delete hook calls at lines 125-126.
    - Delete the `<ApprovalBanner />` JSX at line 147.
    - Update the comment at lines 102-104 that documents the ⌘1-4 shortcuts
      to reflect the new ⌘1-2 layout.
    - Update the comment at lines 180-182 that says "the three workspaces"
      to "the two workspaces."

17. **BottomPanel cleanup**:
    - Find the BottomPanel component (likely `web/src/components/layout/BottomPanel.tsx`).
    - Remove the "Runs" tab and any code that subscribed to the global runs
      stream.
    - If removing leaves only one or two surviving tabs, leave the panel as
      is — visual tightening is out of scope.

18. **LibraryGrid / SkillEditor sanity check**:
    - `web/src/components/registry/LibraryGrid.tsx` — confirm no "Run" or
      "Test" buttons survive that pointed to the deleted runtime.
    - `web/src/components/registry/SkillEditor.tsx` — preserve as-is. It
      edits SKILL.md frontmatter + body; handler-language/path fields were
      already optional and yaml:"-" tagged on the backend.
    - If either references `handlerLanguage` or `handlerPath` properties,
      remove them — they no longer come from the API.

19. **Documentation rewrite**:
    - `docs/skills.md` — rewrite. Drop sections on TS/Go handlers, sandbox,
      hybrid pattern, agent IDE. Keep agentskills.io spec coverage,
      Library workspace usage, MCP-prompt serving model. Reduce from 17 KB
      to whatever the surviving narrative warrants (likely 5-8 KB).
    - `docs/cli-reference.md` — delete `agent`, `agent dev`, `agent init`,
      `agent validate`, `agent build`, `run`, `runs`, `runs list`,
      `runs approve`, `runs resume` sections.
    - `docs/api-reference.md` — delete `/api/agent/*` and `/api/playground/*`
      sections.
    - `docs/troubleshooting.md` — remove agent IDE / handler compilation /
      skill execution sections.
    - `docs/project-status.md` — reclassify agent-runtime features as
      "Removed v0.1.x." Mark Library as "Stable" if appropriate.
    - `README.md` — delete "Skills (Early Access)" and "Visual Agent IDE
      (Early Access)" feature blocks. Update the one-liner from "MCP servers
      and Agent Skills" to "MCP gateway with built-in skill library."
    - `AGENTS.md` — archive (move to `docs/archive/AGENTS-pre-removal.md`)
      or delete. User's call; recommendation is **delete** since pre-1.0.
    - Run `/sync-gridctl` after docs edits to validate AGENTS.md is in sync
      (if it's kept).

20. **Examples cleanup**:
    - `examples/` — audit for any skill examples that include `skill.go` or
      `skill.ts` handler files. Delete the handler files; if the example
      becomes empty, delete the directory.

21. **CHANGELOG entry**:
    - Add a `## [Unreleased]` (or next version) section noting:
      - **Removed**: `gridctl agent`, `gridctl run`, `gridctl runs` CLI
        subcommands.
      - **Removed**: `/api/agent/*` and `/api/playground/*` REST routes.
      - **Removed**: Stage / Runs / Playground UI workspaces.
      - **Removed**: Typed-skill execution (TS and Go handlers); skills are
        now served exclusively as MCP prompts.
      - **Changed**: UI reduced from 4 workspaces to 2 (Topology, Library);
        ⌘ shortcuts renumbered.
      - **Migration**: bookmarks for `/skills`, `/runs`, `/agent` now
        redirect to `/library`.

22. **Verify the full system builds and runs**:
    - `make build` succeeds.
    - `./gridctl serve --foreground` starts cleanly with no agent-related
      log lines.
    - `cd web && npm run build` succeeds.
    - `cd web && npm run typecheck` (or equivalent) has zero errors.
    - UI loads in browser; ⌘1 / ⌘2 navigate between Topology and Library;
      Library can list/create/edit/delete a SKILL.md.
    - Connect a real MCP client (Claude Desktop with gridctl as an MCP
      server). Confirm `prompts/list` returns the active skills, and
      `prompts/get` returns their bodies.

### Non-Functional Requirements

- **No regressions** in the surviving surface: MCP gateway behavior, tool
  routing, registry CRUD, prompt serving, topology view, variable management.
- **Build performance**: the deletion should reduce both `go build` and
  `npm run build` time; verify with a before/after timing if convenient.
- **No new dependencies**.
- **Commit signing**: all commits use `-S` flag.
- **No Co-authored-by trailers**, no mention of Claude in commits/PRs/branches
  (per global CLAUDE.md).

### Out of Scope

- **Extracting `pkg/llm/` from `pkg/agent/llm/`**: ruled out. Playground is
  deleted, so the LLM provider package has no remaining consumer in the
  surviving surface.
- **Reskinning the Library workspace**: it just landed in commit `2411deb`;
  keep it as-is. Only remove any handler-language UI affordances if they
  exist.
- **Compacting BottomPanel** if it ends up with only one tab: visual
  tightening is a follow-up, not part of this removal.
- **CHANGELOG cleanup or versioning bump**: separate concern; this PR series
  only adds an Unreleased entry. Use `/release-gridctl` when ready to cut a
  release.

## Architecture Guidance

### Recommended Approach

**Two PRs, sequenced. Backend first, frontend + docs second.**

This is what the user confirmed in the Phase 1 / Phase 5 questions. Rationale:

- Backend PR lands a working, smaller backend. The web UI keeps pointing at
  routes that now 404 (Stage, Runs) but the rest of the system is
  consistent. Backend reviewers don't have to context-switch to TypeScript.
- Frontend PR cleans up the dangling references, updates routes, deletes
  components. Web reviewers don't have to read Go.
- Docs go in PR2 because they reference both surfaces.

**Strict deletion order within PR1** (to keep the compile graph happy):

1. CLI subcommands (`cmd/gridctl/{agent,run,runs}.go`) — leaf consumers.
2. API handlers (`internal/api/agent_*.go`, `playground.go`, `run_persister.go`).
3. Controller wiring (`pkg/controller/gateway_builder.go`).
4. Gateway methods (`pkg/mcp/gateway.go` — runtime + persister surface).
5. Registry interfaces and fields (`pkg/registry/server.go`, `types.go`, `store.go`).
6. `pkg/optimize/` heuristic files.
7. `pkg/agent/` (the entire package — last, because everything else has
   stopped importing it by this point).
8. Tests inside the deleted packages disappear with their packages; tests
   outside (e.g. `internal/api/skills_test.go`) get edited in step 2.

This order means at every intermediate commit `go build ./...` succeeds, even
if you commit incrementally during the PR.

### Key Files to Understand

Read these before starting (in priority order):

1. **`pkg/mcp/gateway.go`** (lines 118-260) — the `AgentRuntime` marker
   interface and the `Gateway` methods that read/write the runtime. This is
   the seam.
2. **`pkg/registry/server.go`** (lines 1-130) — the `SkillRegistry` /
   `TSDispatcher` interfaces and the registry server's setters. Understand
   why both `mcp.AgentClient` and `mcp.PromptProvider` are implemented and
   why only AgentClient gets gutted.
3. **`pkg/registry/types.go`** — `AgentSkill` struct. Note that handler
   fields are `yaml:"-"` so frontmatter parsing is unaffected by their
   deletion.
4. **`pkg/controller/gateway_builder.go`** (lines 197-230, 575-700, 905-982)
   — the orchestration nerve center. ~200 LOC come out; understand the
   structure first.
5. **`internal/api/api.go`** (lines 80-260) — `SetAgentRuntime`, per-component
   setters, lazy playground init.
6. **`web/src/components/shell/AppShell.tsx`** — the four lines to delete
   (imports, hook calls, JSX).
7. **`web/src/routes.tsx`** — the route table, the AgentRedirect, the
   pattern for redirect routes.
8. **`web/src/types/workspace.ts`** — `Workspace` type, `WORKSPACE_CONFIG`.
9. **`docs/skills.md`** — the doc that needs the most rewriting.
10. **`CHANGELOG.md`** — to follow the existing entry style.

### Integration Points

- **Surviving public API surface**:
  - REST: `/api/registry/*`, `/api/gateway/*`, `/api/topology/*`,
    `/api/var/*`, `/api/runtime/*` (Docker), and whatever the auth /
    session / health endpoints are.
  - MCP: `tools/list`, `tools/call`, `prompts/list`, `prompts/get`,
    `resources/list`, `resources/read`. Tools come from upstream MCP
    servers; prompts come from registry skills.
  - CLI: `gridctl serve`, `gridctl gateway`, `gridctl registry`,
    `gridctl topology`, `gridctl var`, `gridctl runtime`. Confirm by running
    `./gridctl --help` after the deletion.
- **Surviving frontend integration**: Topology workspace uses
  `useStackStore`, `usePolling`, the canvas + sidebar. Library uses
  `useLibraryCommands`, the SkillEditor, the registry API client.

### Reusable Components

Existing patterns to preserve:

- **Route redirect pattern**: `web/src/routes.tsx:94, 99` already uses
  `<Navigate to="..." replace />` for `/registry` → `/library-window` and
  `/vault` → `/var`. Use the same idiom for `/skills`, `/runs`, `/runs/:id`
  → `/library`.
- **Workspace addition pattern**: `web/src/types/workspace.ts` documents
  "adding a workspace = append here." Removal is the inverse: edit the
  array, every consumer (switcher, shortcuts, labels) follows.
- **Compile-time interface checks**: `pkg/registry/server.go:54` uses
  `var _ mcp.AgentClient = (*Server)(nil)`. Preserve this — it's what
  catches drift if `mcp.AgentClient` evolves.

## UX Specification

**Discovery**:
- First-time users land on the root (`/`) which redirects to the last-used
  workspace or `/topology` as the default. The remaining two workspaces in
  the top nav (Topology, Library) describe the value prop without an
  execution surface implying gridctl runs agents.

**Activation**:
- Users open Library, click "+ New Skill" (existing affordance from commit
  `2411deb`), fill in frontmatter, save. The skill becomes an MCP prompt
  served to upstream clients.

**Interaction**:
- Editing happens in SkillEditor (markdown body + frontmatter form).
- Activation state (draft/active/disabled) is changed via the Library UI;
  only `active` skills are served as MCP prompts.
- No "Run" or "Test" affordance in Library; the skill is exercised by an
  upstream MCP client.

**Feedback**:
- Toasts on save / state change / delete (existing pattern).
- Status bar (StatusBar component) shows gateway connection state.
- No approval banner; no in-flight run badge; no runs SSE stream.

**Error states**:
- Frontmatter validation errors render inline in SkillEditor (existing
  behavior).
- Bookmark hits for `/skills` / `/runs` / `/agent` redirect silently to
  `/library`. No error toast — these are graceful redirects, not failures.

## Implementation Notes

### Conventions to Follow

- **Commit format**: `<type>: <subject>` (max 50 chars, imperative, no
  period). Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`.
  For this work: `refactor: remove pkg/agent` is wrong (it's not a refactor,
  it's a removal); `chore: remove agent runtime` is the right shape, or
  break into `chore: remove agent CLI subcommands`, `chore: remove agent
  API handlers`, etc., across multiple commits in the PR.
- **No -i flags** on git commands.
- **All commits signed** with `-S`.
- **No mention of Claude** anywhere in version control (commits, PR titles,
  PR bodies, branch names).
- **Branch naming**: `chore/remove-agent-runtime-backend` for PR1,
  `chore/remove-agent-runtime-frontend` for PR2.

### Potential Pitfalls

1. **`pkg/registry/server.go:11` import of `pkg/agent/skill`** is a
   compile-time foot-gun. If you delete `pkg/agent/` first and run
   `go build ./...`, the entire registry package fails to compile, which
   cascades. Follow the strict deletion order above.

2. **`AgentRuntime` interface is opaque on purpose** (per the comment in
   `pkg/mcp/gateway.go:118-126`) to avoid an import cycle. Once removed,
   `pkg/mcp/` has no incoming agent dependencies, but verify by running
   `rg "pkg/agent" pkg/mcp/` — should return zero results post-removal.

3. **`internal/api/playground.go` couples to `pkg/agent` for ChatModel /
   ChatRequest / Usage types**. Don't try to "salvage" these into
   `pkg/llm/` — Playground is going. If you delete `pkg/agent/llm/` first
   and `playground.go` is still there, it won't compile. Delete
   `playground.go` first.

4. **`pkg/agent/skill` interface declaration in `pkg/registry/server.go`**
   is the only reason `pkg/registry` imports `pkg/agent`. When you delete
   the `SkillRegistry` interface, also delete the import — and double-check
   nothing else in `pkg/registry/` imports any `pkg/agent/*` package.

5. **`web/src/components/skills/` vs `web/src/components/registry/`**: the
   `skills/` directory is the agent-IDE skill commands (delete); the
   `registry/` directory has the Library workspace (preserve). Don't confuse
   them.

6. **`pkg/runtime/` is the Docker/Podman package**, not the agent runtime.
   Untouched.

7. **`tests/integration/runtime_test.go`** tests the Docker stack
   lifecycle, NOT the agent runtime. Keep it.

8. **`AgentRedirect`** in `web/src/components/shell/AgentRedirect.tsx`
   currently redirects `/agent` → `/skills`. Update to redirect `/agent` →
   `/library` (or replace with an inline `<Navigate to="/library" replace
   />` in `routes.tsx` and delete `AgentRedirect.tsx`).

9. **Commit `2411deb` is recent** (May 20, the day before this evaluation).
   The Library workspace structure it introduced is exactly what survives —
   keep its UI intact. The "Stage" rename it did is what's being undone:
   the Stage workspace (route id still `'skills'`) gets deleted, not
   renamed back.

10. **`go.mod` cleanup**: after deleting `pkg/agent/`, run `go mod tidy`.
    There will likely be dependency removals (eino, anthropic-sdk-go,
    openai-go, google genai, etc.) — verify these aren't used elsewhere
    before allowing the tidy to remove them.

### Suggested Build Order (PR1 — Backend)

1. Read the 10 essential files listed above.
2. Branch: `chore/remove-agent-runtime-backend`.
3. Commit 1: Delete CLI subcommands and update `root.go`. Verify
   `./gridctl --help` no longer shows agent/run/runs.
4. Commit 2: Delete API handlers and update router/api.go. Verify
   `go build ./...`.
5. Commit 3: Rewire `pkg/controller/gateway_builder.go`. Verify
   `go build ./...`.
6. Commit 4: Trim `pkg/mcp/gateway.go` (AgentRuntime interface + methods).
7. Commit 5: Refactor `pkg/registry/{server,types,store}.go`.
8. Commit 6: Trim `pkg/optimize/`.
9. Commit 7: Delete `pkg/agent/` entirely.
10. Commit 8: Delete integration tests that exercise the runtime.
11. Commit 9: `go mod tidy`, verify clean build, run `go test -race ./...`
    and `golangci-lint run`.
12. Open PR from origin to upstream. Use `/pr-fork`.

### Suggested Build Order (PR2 — Frontend + Docs)

13. Wait for PR1 to merge.
14. `/reset-fork` to sync, then `/branch-fork remove agent runtime frontend`.
15. Commit 1: Update `web/src/routes.tsx` (add redirects, remove lazy
    imports) and `web/src/types/workspace.ts` (shrink WORKSPACE_CONFIG).
16. Commit 2: Delete `web/src/components/{agent,runs,skills,playground}/`
    and `web/src/components/workspaces/{Skills,Runs,RunDetail}Workspace.tsx`.
17. Commit 3: Trim `AppShell.tsx` (imports, hook calls, ApprovalBanner JSX,
    shortcut comments).
18. Commit 4: BottomPanel cleanup; delete agent-related lib files
    (`web/src/lib/agent-api.ts`, `agent-runs.ts`).
19. Commit 5: Rewrite `docs/skills.md`, trim `docs/cli-reference.md`,
    `docs/api-reference.md`, `docs/troubleshooting.md`, update
    `docs/project-status.md`, update `README.md`. Delete or archive
    `AGENTS.md`.
20. Commit 6: Add CHANGELOG entry.
21. Verify: `make build`, `cd web && npm run build && npm run typecheck`,
    `./gridctl serve --foreground` clean startup, manual browser walkthrough
    of Topology + Library + bookmark redirects, MCP client connection test.
22. Open PR from origin to upstream. Use `/pr-fork`.

## Acceptance Criteria

PR1 (Backend):
1. `find . -path ./node_modules -prune -o -type d -name agent -print | grep -E "(pkg|cmd|internal)" | grep -v node_modules` returns zero matches under `pkg/`, `cmd/`, `internal/`.
2. `rg "pkg/agent" --type go` returns zero results.
3. `rg "/api/agent|/api/playground" --type go` returns zero results.
4. `./gridctl --help` does not list `agent`, `run`, or `runs` subcommands.
5. `go build ./...` succeeds with no warnings.
6. `go test -race ./...` passes with zero failures.
7. `golangci-lint run` passes.
8. `pkg/registry/server.go` has the `var _ mcp.AgentClient = (*Server)(nil)`
   compile-time check satisfied (`Tools()` returns empty slice, `CallTool()`
   returns error).
9. `pkg/registry/server.go` has the `var _ mcp.PromptProvider = (*Server)(nil)`
   compile-time check satisfied; `ListPromptData()` and `GetPromptData()`
   work unchanged.
10. `go mod tidy` produces a clean diff (no orphaned dependencies remain).
11. A live MCP client (Claude Desktop or `mcp inspector`) connected to
    `gridctl serve --foreground` successfully calls `prompts/list` and
    receives the active skills.

PR2 (Frontend + Docs):
12. `cd web && npm run build` succeeds.
13. `cd web && npm run typecheck` (or whatever the script is) passes with
    zero errors.
14. `rg "useGlobalRunsStream|useRunsCommands|ApprovalBanner|playground|SkillsWorkspace|RunsWorkspace" web/src/` returns zero results.
15. UI displays exactly two top-nav workspaces (Topology, Library) with
    ⌘1 and ⌘2 shortcuts.
16. Visiting `/skills`, `/runs`, `/runs/abc123`, `/agent` in a browser
    redirects to `/library` without an error toast.
17. Library can list, create, edit (frontmatter + body), activate, disable,
    and delete a SKILL.md round-trip.
18. BottomPanel does not show a "Runs" tab.
19. No browser console errors on any page load.
20. `docs/skills.md` no longer references TS/Go handlers, sandbox, or the
    Stage IDE. It references the Library workspace and the MCP-prompt
    serving model.
21. `README.md` one-liner and feature blocks reflect the gateway + library
    framing.
22. `CHANGELOG.md` has an `[Unreleased]` (or next version) entry that
    enumerates the removals.

## References

- [agentskills.io specification](https://agentskills.io/specification)
- [anthropic/skills GitHub](https://github.com/anthropics/skills)
- [FastMCP — Skills Provider](https://gofastmcp.com/servers/providers/skills)
- [MCP spec](https://modelcontextprotocol.io/) (now CNCF-hosted)
- [Anthropic — Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [Claude — Skills explained](https://claude.com/blog/skills-explained)
- Existing gridctl files cited inline above (paths + line numbers).
- The companion evaluation:
  `prompts/gridctl/agent-runtime-removal/feature-evaluation.md`
