# Bug Investigation: Agent IDE null-nodes crash

**Date**: 2026-05-12
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial

## Summary

The Agent IDE (`http://localhost:8180/agent`) crashes on first load with
`Cannot read properties of null (reading 'length')` for any user whose
configured registry contains skills without a typed handler (a `skill.go`
or `skill.ts` file). PR #615 just made this trigger universal by
auto-wiring the dev server's project root to `~/.gridctl/registry/skills`,
which is the same directory many users already populate with Claude Code
markdown-only skills. The parser returns `Graph{Nodes: nil}` for those
skills, Go serializes `nil` to JSON `null`, and the React frontend
null-derefs on `graph.nodes.length`.

## The Bug

**Defect**: Opening the Agent IDE in a browser immediately shows
"IDE crashed — Cannot read properties of null (reading 'length')".

**Expected**: IDE renders the sidebar of registered skills and the
selected skill's parsed graph (or an empty-state for skills with no
typed handler).

**Actual**: ErrorBoundary catches a TypeError during render of the
auto-selected first skill; the entire IDE shell is replaced with a
crash screen and a Reload button (which loops back to the same crash).

**Discovery**: User reported while walking through
`proto/agent/HOWTO-audit-repo.md`, step 7 ("Validate in the visual
IDE"). All preceding backend steps succeeded — `gridctl agent validate`
returned `valid: true` for all three skills, `/api/tools` surfaced the
two leaf skills, `/api/playground/auth` showed the Anthropic key wired.
The crash is purely in the frontend rendering of the IDE.

## Root Cause

### Defect Location

Primary defect: `pkg/agent/dev/parser/parser.go:280`

```go
return Graph{Skill: skillName, ParseError: "no typed handler (skill.go / skill.ts) found"}, nil
```

Returns a `Graph` with `Nodes` left as the zero value (`nil`). When
encoded to JSON via `encoding/json`, a `nil` slice serializes as
`null`, not `[]`.

The frontend then crashes at `web/src/components/agent/ide/AgentIDE.tsx:241`:

```tsx
{graph.nodes.length} {graph.nodes.length === 1 ? 'node' : 'nodes'}
```

Same pattern repeats at:
- `web/src/components/agent/ide/Canvas.tsx:65,82,86,87,88,99,110,113,115`
- `web/src/components/agent/ide/NodeList.tsx:27,46,51`
- `web/src/components/agent/ide/AgentIDE.tsx:135,241`

### Code Path

1. User opens `http://localhost:8180/agent`
2. `AgentIDE` mounts; `refreshSkills()` calls `GET /api/agent/dev/skills`
3. Backend's `listSkillDirs()` walks every directory under the dev root
   that contains a `SKILL.md`, regardless of whether a typed handler
   sits next to it
4. Auto-select effect (`AgentIDE.tsx:96`) picks `skills[0]` (alphabetical)
   and sets `?skill=<first>` in the URL
5. Graph-fetch effect (`AgentIDE.tsx:69`) calls
   `GET /api/agent/dev/skills/<first>`
6. Backend's `handleGetSkill` → `parser.ParseSkill(name, dir)`
7. For an md-only skill, `ParseSkill` falls through the
   `skill.go`/`skill.ts` `os.Stat` checks and hits the trailing
   `return Graph{Skill: skillName, ParseError: "..."}, nil` (line 280)
8. JSON response: `{"skill":"blog","lang":"","file":"","nodes":null,"parse_error":"..."}`
9. `setGraph(g)` stores the null-nodes graph
10. Toolbar renders → `graph.nodes.length` → `TypeError`
11. `IDEErrorBoundary` catches → crash screen

### Why It Happens

Two architectural choices compound:

1. **`Graph.Nodes` is not initialized in the no-handler branch** (and
   even in the success branches, the slice is appended to from `nil`,
   which only initializes if at least one node is appended). For
   skills with no typed handler — or a typed handler containing zero
   recognized call sites — `Nodes` stays `nil` and serializes as
   `null`.

2. **`listSkillDirs` includes md-only skills** in the IDE skill list
   (with `lang: ""`, `node_count: 0`). The Agent IDE is specifically
   the typed-skill graph view, so these skills serve no purpose here;
   yet they appear in the sidebar and — crucially — get auto-selected
   on load.

This is the same class of bug as PR #613 (`bbf4947 fix: emit [] not
null for empty created/skipped arrays`) — the project has a recurring
Go-nil-slice → JSON-null → JS-crash pattern.

### Similar Instances

Several call sites in the frontend assume `graph.nodes` is always an
array. None of them defensively coerce `nodes ?? []`. Any future code
path that returns `Graph{}` from the parser would re-trigger the same
class of crash. A backend-side guarantee plus a single frontend
coercion in `fetchSkill` would close the door on the whole class.

## Impact

### Severity Classification

**Crash, on first load of a documented feature path**. Not a data-loss
or security bug; the system is recoverable (close tab, fix registry).
But the Agent IDE is unusable for any affected user until manually
worked around.

### User Reach

Anyone who runs `gridctl serve` while `~/.gridctl/registry/skills`
contains at least one directory with a `SKILL.md` and no typed handler.
That describes:

- Any user who installed gridctl-tracked Claude Code skills via
  `gridctl skill add` (the directory listing shows ~20 such entries
  for this user alone — `blog`, `branch-*`, `bug-build`, `docs`,
  `feature-*`, `gif-create`, `onboard-*`, `pr-*`, `release-gridctl`,
  `reset-*`, `skill-creator`, `sync-gridctl`, `frontend-design`)
- Any user mid-development on a new typed skill whose source file
  hasn't yet been written (scaffold-only state).

Single-skill projects with only typed handlers are safe — but that
configuration is uncommon now that PR #615 promotes the central
registry as the default IDE root.

### Workflow Impact

**Critical path blocker** for the Agent IDE feature that PR #615 (#9f6675d)
just shipped. `proto/agent/HOWTO-audit-repo.md` step 7 specifically
directs users to open the IDE; that step now fails for almost everyone.

### Workarounds

- **Move dev root**: `gridctl serve --port 8180 --agent-dev-root /tmp/typed-only` —
  works but is undocumented in HOWTO-audit-repo.md and forfeits the
  PR #615 auto-wire.
- **Empty registry**: Removing or renaming the md-only skills out of
  `~/.gridctl/registry/skills` works but breaks Claude Code skill access.
- **Browser URL hack**: Manually navigating to `/agent?skill=repo-audit`
  bypasses the first-alphabetical auto-select — works if the user knows
  this trick.

None of these are acceptable for a feature that just shipped.

### Urgency Signals

PR #615 (commit 9f6675d, merged most recently before this report)
explicitly added "Agent IDE wired root=…" to startup logs to advertise
the auto-wire. The HOWTO doc references commit "6947171 or newer (PR
#615)" as the prereq. The crash thus shows up immediately for every
user attempting the documented end-to-end exercise.

## Reproduction

### Minimum Reproduction Steps

1. Have at least one directory under `~/.gridctl/registry/skills/` that
   contains `SKILL.md` but neither `skill.go` nor `skill.ts` (any
   gridctl-installed Claude Code skill qualifies — `blog`, `docs`,
   etc.)
2. Run `make build` on a checkout at or after commit 9f6675d (PR #615).
3. Start the daemon: `./gridctl serve --port 8180`.
4. Confirm startup logs include
   `INFO agent IDE wired root=/Users/<you>/.gridctl/registry/skills`.
5. Open `http://localhost:8180/agent` in a browser.

**Result**: "IDE crashed — Cannot read properties of null (reading
'length')" within ~100ms of page load.

### Affected Environments

- All platforms (this is JavaScript + Go behavior, not OS-specific).
- All browsers (TypeError is thrown by the V8/JavaScriptCore null deref).
- Any gridctl build at or after `9f6675d` (PR #615) if the registry
  contains md-only skills. Older builds (before auto-wire) only
  affected users who explicitly pointed `--agent-dev-root` at a mixed
  registry.

### Non-Affected Environments

- Registries containing only typed skills (skill.go or skill.ts in
  every subdirectory).
- IDE launched with `--agent-dev-root` pointed at a typed-only path.
- Users who happen to land directly on a working skill URL (e.g.
  `/agent?skill=repo-audit`) — the crash only fires when the
  auto-selected first skill has null nodes.

### Failure Mode

Synchronous TypeError during the first paint of the `Toolbar`
component. React's error boundary intercepts and shows the crash
screen. The dev server continues serving other endpoints normally; the
runtime state of the daemon is untouched. Reloading the browser
re-runs the same fetch sequence and hits the same crash.

## Fix Assessment

### Fix Surface

Three small changes, two files in scope:

1. **`pkg/agent/dev/parser/parser.go`** — initialize `Graph.Nodes` to
   `[]Node{}` (non-nil empty slice) in every return path, so the JSON
   contract is always `"nodes": []`. The fastest spot is the no-handler
   branch at line 280, but for safety the empty-result branches of
   `parseGoFile` and `parseTSFile` should also be normalized.

2. **`pkg/agent/dev/devserver/devserver.go`** (`listSkillDirs`) —
   filter out entries with `lang == ""` before appending so the Agent
   IDE only sees typed skills (matches user's chosen scope: "crash fix
   + filter md-only skills"). md-only Claude Code skills don't belong
   in the typed-graph IDE.

3. **`web/src/lib/agent-api.ts`** (`fetchSkill`) — defensive
   `g.nodes ?? []` coercion before returning. Belt-and-suspenders so
   any future regression in the JSON contract doesn't re-trigger the
   same class of crash.

### Risk Factors

- **`listSkillDirs` filter change** could surprise a user who explicitly
  expects md-only skills to appear with zero nodes — but those entries
  cannot render anything useful in the typed-graph IDE, so the surprise
  is benign.
- **`Graph.Nodes` initialization** is purely additive and matches the
  pattern already established by PR #613. No risk.
- **Frontend `nodes ?? []` coercion** is purely defensive and changes
  no contract.

### Regression Test Outline

- Go: `pkg/agent/dev/parser/parser_test.go` — add a test that calls
  `ParseSkill("noop", t.TempDir())` (a tempdir with no skill.go/skill.ts)
  and asserts `g.Nodes != nil && len(g.Nodes) == 0`.
- Go: `pkg/agent/dev/devserver/devserver_test.go` — add a test that
  sets up a root with one md-only directory plus one typed directory,
  hits `/api/agent/dev/skills`, and asserts the response contains only
  the typed entry.
- Frontend: extend
  `web/src/components/agent/ide/__tests__/AgentIDE.test.tsx` (or create
  one) with a mocked `fetchSkill` that returns `{nodes: null}` and
  assert the IDE does not throw.

## Recommendation

**Fix immediately.** This is a crash on the first load of a feature
PR #615 just shipped, and the fix is a few lines following an existing
project pattern (PR #613). Three coordinated changes — server-side
guarantee, server-side filter, frontend defensive coercion — close the
door on the entire class.

A secondary issue surfaced during this investigation: the user
inadvertently wrote `SKILL.md` and `skill.ts` directly into the
registry root (`~/.gridctl/registry/skills/`), creating a spurious
"skills" entry. That's a user error, not a defect — but it's a sharp
edge worth noting in HOWTO-audit-repo.md (or rejecting in the registry
walker with a clear error message). Out of scope for this fix; flag for
a follow-up doc/UX issue if desired.

## References

- PR #615 (commit `9f6675d`) — auto-wires the Agent IDE dev server when
  `~/.gridctl/registry/skills` exists. The change that surfaced this
  latent bug for every user.
- PR #613 (commit `bbf4947`) — `fix: emit [] not null for empty
  created/skipped arrays`. Established the project pattern this fix
  should follow.
- `proto/agent/HOWTO-audit-repo.md` step 7 — the documented user
  journey that hits this crash.
- `pkg/agent/dev/parser/parser.go:280` — the line where the nil-slice
  return originates.
- `web/src/components/agent/ide/AgentIDE.tsx:241` — the line where
  the crash actually throws.
