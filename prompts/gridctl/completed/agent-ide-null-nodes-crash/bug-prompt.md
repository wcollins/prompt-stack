# Bug Fix: Agent IDE null-nodes crash

## Context

**Project**: gridctl — a Go CLI + embedded React/TypeScript web UI for
managing AI agent stacks, MCP servers, and typed agent skills.

**Relevant architecture**:
- The "Agent IDE" is a React frontend served by the Go daemon at
  `http://localhost:<port>/agent`. It visualizes typed-skill graphs
  (recognized `tool()` / `llm()` / `parallel()` / `handoff()` /
  `approval()` call sites) parsed from `skill.go` or `skill.ts`
  source files.
- Backend dev surface lives at `pkg/agent/dev/devserver/devserver.go`,
  registers routes under `/api/agent/dev/*`, and is mounted into the
  daemon by `gridctl serve` (PR #615 auto-wires it when
  `~/.gridctl/registry/skills` exists).
- The Go parser lives at `pkg/agent/dev/parser/parser.go` with the
  TypeScript-flavor extractor in `parser/ts.go`.
- Frontend lives in `web/src/components/agent/ide/` with the API
  client in `web/src/lib/agent-api.ts`.
- The IDE is a read-only canvas — "code is canon", the IDE never
  writes source back.

**Tech stack**: Go 1.22+ (`net/http` with `mux.HandleFunc` 1.22-style
patterns), React 18 + TypeScript + Vite + React Router, Tailwind for
styling, `react-flow` for the canvas surface.

## Investigation Context

- **Root cause confirmed**: `pkg/agent/dev/parser/parser.go:280`
  returns `Graph{Skill: skillName, ParseError: "..."}` with `Nodes`
  uninitialized (Go zero-value `nil` slice). Go's `encoding/json`
  serializes `nil` slices as `null`. The frontend reads
  `graph.nodes.length` at `web/src/components/agent/ide/AgentIDE.tsx:241`
  (and ~10 other sites) and throws `TypeError: Cannot read properties
  of null (reading 'length')` on the auto-selected first skill.
- **Live verification**: `curl -s http://localhost:8180/api/agent/dev/skills/blog`
  on the reporter's machine returns
  `{"skill":"blog","lang":"","file":"","nodes":null,"parse_error":"no typed handler (skill.go / skill.ts) found"}`.
- **Why it triggers now**: PR #615 (commit `9f6675d`) auto-wired the
  Agent IDE backend to `~/.gridctl/registry/skills`. Many users have
  markdown-only Claude Code skills in that directory (no `skill.go` /
  `skill.ts`). Those entries flow through the IDE's auto-select and
  trigger the null-nodes crash.
- **Risk mitigation baked into the fix**: align with the project
  pattern established by PR #613 (`bbf4947 fix: emit [] not null`) —
  guarantee `[]` on the wire — and harden the frontend with one
  defensive coercion so the same class of bug can't re-emerge.
- **Reproduction**: Deterministic. Start `gridctl serve` against a
  registry that contains at least one directory with `SKILL.md` and
  no typed handler; open `/agent` in any browser; crash fires on
  first paint.
- **Full investigation**:
  `/Users/william/code/prompt-stack/prompts/gridctl/agent-ide-null-nodes-crash/bug-evaluation.md`

## Bug Description

Opening the Agent IDE at `http://localhost:<port>/agent` immediately
crashes with `Cannot read properties of null (reading 'length')` for
any user whose Agent IDE root contains a directory with `SKILL.md`
but no `skill.go` or `skill.ts`.

Expected: the IDE renders the sidebar of recognized skills and the
selected skill's parsed graph (or a clean empty-state if the skill
has no recognized call sites).

Actual: a React ErrorBoundary catches a TypeError thrown during the
first render of the Toolbar (which reads `graph.nodes.length`). The
crash screen offers only a Reload button that re-triggers the same
crash.

Affected users: everyone who runs `gridctl serve` at or after PR #615
while `~/.gridctl/registry/skills` contains any markdown-only Claude
Code skill (e.g. `blog`, `docs`, `bug-build`, `feature-build`, etc.).

## Root Cause

`pkg/agent/dev/parser/parser.go:280` (`ParseSkill`):

```go
return Graph{Skill: skillName, ParseError: "no typed handler (skill.go / skill.ts) found"}, nil
```

`Graph.Nodes` is declared as `[]Node` but never initialized in this
branch. Go's `encoding/json` emits `nil` slices as JSON `null`. The
frontend's `SkillGraph.nodes: AgentNode[]` typing is therefore wrong
at runtime, and every call site that reads `.length` or `.map` blows
up.

Additionally, `pkg/agent/dev/devserver/devserver.go:listSkillDirs`
emits md-only skills (entries with `lang: ""`) in the IDE skill list.
Those entries cannot render anything useful in the typed-skill graph
view, yet they appear in the sidebar and get auto-selected on first
load (alphabetical order — `blog` wins on the reporter's machine).

## Fix Requirements

### Required Changes

1. **Backend: guarantee non-nil `Nodes` slice in every `ParseSkill` /
   `parseGoFile` / `parseTSFile` return path.** The fix is one
   initialization per branch — change `Graph{...}` literals to set
   `Nodes: []Node{}`, and ensure the success branches start with
   `g := Graph{..., Nodes: []Node{}}` so even zero-recognized-node
   skills serialize as `"nodes": []`.

2. **Backend: filter md-only skills from `listSkillDirs`.** Skip
   entries whose `lang == ""` (no `skill.go` or `skill.ts` alongside
   `SKILL.md`). The IDE is the typed-skill graph view; markdown-only
   Claude Code skills don't belong here. Confirm there are no other
   IDE features that depend on those entries showing up.

3. **Frontend: defensive coercion in `fetchSkill`.** Coerce
   `nodes ?? []` (and `nodes` on `WatcherEvent` graphs if applicable)
   in `web/src/lib/agent-api.ts` before returning. Belt-and-suspenders
   so a future regression in the JSON contract can't re-trigger the
   class of crash.

### Constraints

- **Do not** change the JSON field names or types — the parser shape
  is documented in `parser.go` and consumed by the frontend's typings.
- **Do not** change behavior for skills that have a typed handler with
  zero recognized call sites — they should still appear in the
  sidebar (the canvas just renders an empty graph).
- **Do not** silently drop md-only skills elsewhere in the codebase —
  the filter is scoped to `listSkillDirs` for the Agent IDE only.
- **Do not** add `--agent-dev-root` flag changes; the auto-wire
  behavior from PR #615 should keep working unchanged.

### Out of Scope

- Refactoring `ParseSkill` to support a third source language.
- Adding a UI affordance to filter, search, or group skills in the
  sidebar.
- Rejecting `SKILL.md` files at the registry root (the user error
  that produced a spurious "skills" entry on the reporter's machine).
  That's a separate UX issue; flag for a follow-up.
- Any change to the `gridctl agent validate` WARN behavior.
- Frontend visual changes beyond the defensive `nodes ?? []` coercion.

## Implementation Guidance

### Key Files to Read

- `pkg/agent/dev/parser/parser.go` — the `Graph` struct definition,
  `ParseFile`, `ParseSkill`, and the Go AST walker. The defect is on
  line 280; the success branches build `Nodes` via `append` from a
  nil slice, which works at runtime but leaves an uninitialized slice
  if no nodes are appended.
- `pkg/agent/dev/parser/ts.go` — same shape, TypeScript flavor;
  check whether the empty-result path here has the same defect and
  fix it the same way.
- `pkg/agent/dev/devserver/devserver.go` — `listSkillDirs` is the
  filter site for change #2; `handleGetSkill` is where the JSON
  response is built.
- `web/src/lib/agent-api.ts` — `fetchSkill` returns `SkillGraph`;
  the coercion goes here.
- `web/src/components/agent/ide/AgentIDE.tsx` — see lines 135 and 241
  for the canonical crash sites.
- `web/src/components/agent/ide/Canvas.tsx` — heaviest user of
  `graph.nodes`; cross-check it after the coercion lands.

### Files to Modify

- `pkg/agent/dev/parser/parser.go`
  - In `ParseSkill` (line 280), change the return to
    `return Graph{Skill: skillName, Nodes: []Node{}, ParseError: "no typed handler (skill.go / skill.ts) found"}, nil`.
  - In `parseGoFile` (line 142), change `g := Graph{Skill: skillName, Lang: LangGo, File: path}`
    to also initialize `Nodes: []Node{}`.
- `pkg/agent/dev/parser/ts.go`
  - Same treatment for the TS parser's `Graph` construction.
- `pkg/agent/dev/devserver/devserver.go`
  - In `listSkillDirs`, after the `lang` detection block, skip
    appending the entry when `lang == ""`. (Insert a `continue`-style
    `return nil` from the walker callback before
    `entries = append(...)`.)
- `web/src/lib/agent-api.ts`
  - In `fetchSkill`, after the JSON parse, normalize:
    `const g = (await res.json()) as SkillGraph; return { ...g, nodes: g.nodes ?? [] };`

### Reusable Components

- The `writeJSON` / `writeJSONError` helpers in
  `pkg/agent/dev/devserver/devserver.go` already handle the response
  envelope — no new helpers needed.
- The frontend's `AgentNode` and `SkillGraph` types in
  `web/src/lib/agent-api.ts` are the authoritative shape — keep them
  unchanged; the runtime coercion brings reality back in line with
  the types.

### Conventions to Follow

- Tests live next to source as `*_test.go` (Go) or
  `__tests__/<name>.test.tsx` (frontend). Both flavors exist in
  this codebase — follow the established style.
- Go tests use the standard `testing` package; no testify. Asserts
  via `if got != want { t.Fatalf(...) }`.
- Frontend tests use Vitest + Testing Library (see existing tests
  under `web/src/__tests__/`).
- Commit message style: `fix: <short>` (see git log on this repo —
  conventional commits, no body required for small fixes).
- Sign commits with `-S`. Don't mention Claude in commits, PRs, or
  branches.
- PRs go to `main` via fork workflow on this repo (see CLAUDE.md
  global instructions).

## Regression Test

### Test Outline

1. **`pkg/agent/dev/parser/parser_test.go`** — new test
   `TestParseSkill_NoHandler_ReturnsEmptyNodes`:
   - Create a temp directory containing only a `SKILL.md`.
   - Call `parser.ParseSkill("noop", tempDir)`.
   - Assert `err == nil`.
   - Assert `g.Nodes != nil` AND `len(g.Nodes) == 0`.
   - Marshal `g` to JSON and assert the output contains `"nodes":[]`
     (NOT `"nodes":null`).

2. **`pkg/agent/dev/devserver/devserver_test.go`** — new test
   `TestListSkills_FiltersMdOnlySkills`:
   - Build a tempdir root with two subdirectories:
     - `md-only/SKILL.md`
     - `typed/SKILL.md` + `typed/skill.ts` (minimal stub)
   - Construct a server with `NewServer(root, nil)`.
   - Hit `GET /api/agent/dev/skills`.
   - Assert the response's `skills` array contains exactly one entry,
     and that entry is `typed`.

3. **Frontend** — extend the existing IDE tests (or create
   `web/src/components/agent/ide/__tests__/AgentIDE.test.tsx`):
   - Mock `fetchSkill` to return `{skill: "x", lang: "", file: "", nodes: null, parse_error: "..."}`.
   - Render `<AgentIDE />`.
   - Assert it does not throw and renders a graceful empty state.
   - (Optional) Also test `fetchSkill` directly: pass a `null`-nodes
     JSON response and assert the returned object has `nodes: []`.

### Existing Test Patterns

- Look at `pkg/agent/dev/parser/parser_test.go` for the existing Go
  parser test style (uses `t.TempDir()`, writes files directly,
  compares result fields).
- Look at `pkg/agent/dev/devserver/devserver_test.go` for the existing
  HTTP test style (uses `httptest.NewServer` or `http.NewRequest`
  against `Handler()`).
- For the frontend, check `web/src/__tests__/` for established
  Vitest + Testing Library conventions used by this codebase.

## Potential Pitfalls

- **`parseGoFile` and `parseTSFile` build `Nodes` via `append` from
  the zero value.** That works if at least one node is appended (Go
  allocates the backing array on first append) — but the JSON
  contract breaks for skills with a valid typed handler that contains
  zero recognized call sites. Initialize to `[]Node{}` up front in
  both Go and TS parsers, not just in the no-handler return path.

- **Don't filter md-only skills globally — only in the Agent IDE
  listing.** Other surfaces (e.g. registry CLI) likely depend on
  full registry visibility. Confirm by searching for callers of
  `listSkillDirs` and any reuse of the same SKILL.md walker
  elsewhere.

- **The reporter's machine has a spurious "skills" entry** because
  they accidentally wrote `SKILL.md` and `skill.ts` directly to the
  registry root (`~/.gridctl/registry/skills/SKILL.md`). The
  `listSkillDirs` code at line 103 promotes that into a phantom
  "skills" entry (`name = filepath.Base(s.root)`). The filter
  change in this fix doesn't remove that entry (it has a typed
  handler, so `lang == "ts"`), but it's worth being aware of when
  reproducing — clean it up with
  `rm ~/.gridctl/registry/skills/SKILL.md ~/.gridctl/registry/skills/skill.ts`
  before testing.

- **Tests must verify the JSON wire shape, not just the Go value.**
  A test that only checks `g.Nodes != nil` doesn't prove the JSON
  serializes correctly. Marshal and assert on the resulting bytes.

## Acceptance Criteria

1. `parser.ParseSkill("noop", <tempdir-with-only-SKILL.md>)` returns
   a `Graph` whose `Nodes` is a non-nil empty slice. JSON encoding
   of the result contains `"nodes":[]`, not `"nodes":null`.

2. All success paths of `parseGoFile` and `parseTSFile` likewise
   guarantee `Nodes` is non-nil, including when zero recognized
   call sites are found.

3. `GET /api/agent/dev/skills` on a root with one md-only and one
   typed skill returns exactly one entry (the typed skill).

4. `fetchSkill` in `web/src/lib/agent-api.ts` coerces `nodes ?? []`
   before returning, so a stray `null` in any future JSON response
   does not propagate into a render crash.

5. Opening `http://localhost:8180/agent` after `gridctl serve` (with
   a mixed registry) loads the IDE without throwing. The auto-selected
   skill renders its graph or an empty-state — never the
   ErrorBoundary crash screen.

6. Existing tests in `pkg/agent/dev/parser/`,
   `pkg/agent/dev/devserver/`, and the frontend test suite all still
   pass. New regression tests added for the three changes above pass.

7. `make build` succeeds, `golangci-lint` is clean for changed files,
   `npm run build` (or the project's equivalent frontend build)
   succeeds.

8. Manual smoke: walk through `proto/agent/HOWTO-audit-repo.md` step
   7 — the Agent IDE loads, the three `repo-*` skills appear in the
   sidebar, and clicking each renders its graph in both LIST and
   CANVAS views.

## References

- `/Users/william/code/prompt-stack/prompts/gridctl/agent-ide-null-nodes-crash/bug-evaluation.md`
  — full bug investigation with reproduction details.
- PR #615 (commit `9f6675d`, `fix: wire agent IDE dev server in serve flag`)
  — the change that surfaced this latent bug for every user with a
  mixed registry.
- PR #613 (commit `bbf4947`, `fix: emit [] not null for empty
  created/skipped arrays`) — the project's existing pattern for the
  same class of Go-nil-slice → JSON-null bug.
- `proto/agent/HOWTO-audit-repo.md` step 7 — the documented user
  journey this fix unblocks.
