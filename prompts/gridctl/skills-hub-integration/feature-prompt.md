# Feature Implementation: Skills Hub Integration (gridctl.dev Registry)

## Context

**Project**: gridctl — a stack-as-code MCP (Model Context Protocol) gateway platform written in Go. gridctl defines, validates, and runs combinations of MCP servers from a single `stack.yaml` file. It also manages AI coding agent skills (SKILL.md files per the agentskills.io specification) via a skills registry system.

**Tech stack**:
- Go 1.23+, Cobra CLI framework, `go-pretty/v6` for table output
- `go-git/v5` for git operations
- Standard library `net/http` for HTTP clients (no third-party HTTP framework)
- YAML configuration files at `~/.gridctl/`
- `charmbracelet/log` via `pkg/output` for structured logging/printer

**Key architecture**:
- `cmd/gridctl/skill.go` — all skill CLI subcommands (`add`, `list`, `update`, `remove`, `pin`, `info`, `validate`, `try`)
- `pkg/skills/importer.go` — orchestrates git clone → discover → validate → security scan → import → lock
- `pkg/skills/remote.go` — git operations (shallow clone, ref resolution, SKILL.md discovery)
- `pkg/skills/lockfile.go` — `~/.gridctl/skills.lock.yaml` recording commit SHA, content hash, behavioral fingerprint
- `pkg/skills/config.go` — `~/.gridctl/skills.yaml` with skill sources (repo, ref, path, auto_update)
- `pkg/registry/types.go` — `AgentSkill` struct following agentskills.io spec
- `internal/api/skills.go` — REST API endpoints for web UI integration
- `pkg/output/` — `Printer` with amber theme, `table.StyleRounded` output

**Registry authority**: gridctl.dev is owned and is the canonical home for both the tool and its skills ecosystem. The registry lives at `gridctl.dev/api/v1/skills`. agentskills.io remains the spec reference only.

## Evaluation Context

- **Market insight**: Static JSON index in a git monorepo is the right MVP approach — validated by Homebrew, Raycast, and `tech-leads-club/agent-skills` (2K stars, same agentskills.io format). A Cloudflare Worker in front of GitHub Pages gives a real query API with zero server ops.
- **Aggregation**: `tech-leads-club/agent-skills` (77 skills, agentskills.io-compatible) is the day-one aggregation target — a nightly CI job normalizes their index into the `community` tier. This avoids launching with an empty catalog.
- **Publishing**: PR-based (Raycast model) — `gridctl skill publish` opens a PR to `gridctl/skills-hub`. No server auth needed; `GITHUB_TOKEN` already supported in the codebase.
- **UX decision**: Phase 1 ships `skill search` only. Phase 2 adds hub name resolution in `skill add`. Phase 3 adds `skill publish`. Each phase is independent.
- **Risk mitigation**: Hub URL configurable via `GRIDCTL_SKILLS_HUB_URL`. Direct `skill add <repo-url>` always works. Hub failure never breaks existing commands.
- **Full evaluation**: `prompt-stack/prompts/gridctl/skills-hub-integration/feature-evaluation.md`

## Feature Description

Three phased additions to the gridctl skills system, all pointing at the registry at `gridctl.dev`:

1. **`gridctl skill search <query>`** — query the registry, display results in a table
2. **Hub name resolution in `skill add`** — `gridctl skill add pr-review` resolves via registry, then imports
3. **`gridctl skill publish`** — validate a local skill and open a PR to `gridctl/skills-hub`

**Problem solved**: Skills can't be discovered without knowing repo URLs. No way to contribute back. gridctl.dev + these three commands close both gaps and create a contribution loop entirely within the CLI.

## Requirements

### Phase 1: `gridctl skill search`

**Functional:**
1. `gridctl skill search <query>` queries `GET https://gridctl.dev/api/v1/skills?query=<query>&limit=<n>` and displays results in a rounded table
2. Table columns: **Name**, **Category**, **Description**, **Tier** — matching style of `gridctl skill list`
3. `--format json` outputs raw JSON array to stdout
4. `--limit N` flag, default 20
5. Hub unreachable or non-200: clear user-facing error, exit non-zero, suggest `skill add <repo-url>` fallback
6. Zero results: `No skills found matching "<query>". Browse all at gridctl.dev/skills`
7. Hub base URL configurable via `GRIDCTL_SKILLS_HUB_URL` env var (default: `https://gridctl.dev`)
8. New file `pkg/skills/hub.go`: `HubClient` struct, `NewHubClient(baseURL string)`, `Search(ctx, query string, limit int) ([]HubSkill, error)`
9. `HubSkill` struct: `Name`, `Description`, `Category`, `Tags []string`, `Repo`, `Path`, `Version`, `Tier`, `Author`, `ContentHash`
10. REST endpoint `GET /api/skills/hub/search?query=<q>&limit=<n>` in `internal/api/skills.go` proxying to hub client

**Non-functional:**
- HTTP timeout: 10 seconds
- No new third-party dependencies — stdlib only
- `pkg/skills/hub_test.go` using `httptest.NewServer` for mock coverage

### Phase 2: Hub Name Resolution in `skill add`

**Functional:**
1. `gridctl skill add <name>` (no `://` in arg) → calls `HubClient.Resolve(ctx, name) (HubSkill, error)` to get repo + path
2. Resolved result feeds directly into existing `ImportOptions{Repo, Path}` — no other importer changes
3. `gridctl skill add <url>` (contains `://`) → existing behavior, no hub call
4. If hub unreachable during name resolution: error with suggestion to use full URL
5. Lock file gains optional `hub_name` and `tier` fields on the `LockedSkill` entry for traceability

**Non-functional:**
- Resolution adds at most one HTTP roundtrip before cloning; cached result (in-process only) for duration of command

### Phase 3: `gridctl skill publish`

**Functional:**
1. `gridctl skill publish [<name>]` — if name omitted, publishes the skill in the current directory (looks for SKILL.md)
2. Runs full `skill validate` before any network call — fails fast locally with actionable errors
3. Uses `GITHUB_TOKEN` (same env var already used in `pkg/skills/remote.go`) to create a fork of `gridctl/skills-hub` if needed and open a PR
4. PR template includes: skill name, description, category, SKILL.md content, and a checklist for reviewers
5. Prints the PR URL on success
6. `--category <cat>` flag to specify target category directory in the hub repo
7. `--dry-run` flag: validate + print what the PR would contain, no GitHub API calls

**Non-functional:**
- Requires `GITHUB_TOKEN` with `repo` scope — print clear instructions if missing
- Uses GitHub REST API (`api.github.com`) directly via stdlib HTTP — no octokit/go-github dependency

### Out of Scope (all phases)

- Paid/authenticated API tiers on the hub
- Semantic versioning constraints in `skill search` results
- Local caching of hub index to disk
- `skill unpublish` / skill deletion from hub via CLI
- Web UI for gridctl.dev (separate project)

## Architecture Guidance

### Recommended Approach

Follow exact patterns already in the codebase:
- HTTP client: `&http.Client{Timeout: 10 * time.Second}` with `http.NewRequestWithContext`
- CLI command: mirror `skillAddCmd` — `cobra.Command`, `RunE`, flags in the `var` block
- Output: `table.StyleRounded`, conditional columns, `--format json` with `json.MarshalIndent`

### Key Files to Understand First

| File | Why it matters |
|------|---------------|
| `cmd/gridctl/skill.go` | All existing skill commands — read in full; `runSkillList()` is the output pattern template; `init()` is where to register new subcommands |
| `cmd/gridctl/pins.go` | Lines ~217-280: best HTTP GET + error handling reference in the codebase |
| `pkg/skills/importer.go` | `ImportOptions` struct and `Import()` flow — Phase 2 feeds hub resolution into these |
| `pkg/skills/remote.go` | Lines ~145-147: `GITHUB_TOKEN` auth pattern for git — reuse in Phase 3 for GitHub API auth |
| `pkg/output/table.go` | Conditional column pattern (inspect data before deciding columns) |
| `pkg/output/styles.go` | Color constants — use `ColorAmber`, `ColorMuted`, `ColorGreen` |
| `pkg/skills/lockfile.go` | `LockedSkill` struct — Phase 2 adds optional `hub_name`, `tier` fields here |

### Integration Points

**Phase 1:**
1. `pkg/skills/hub.go` (new) — `HubClient`, `HubSkill`, `Search()`
2. `cmd/gridctl/skill.go` — `skillSearchCmd`, `runSkillSearch()`, flags `skillSearchLimit`/`skillSearchFormat`
3. `internal/api/skills.go` — `handleSkillsHubSearch` handler

**Phase 2:**
1. `pkg/skills/hub.go` — add `Resolve(ctx, name string) (HubSkill, error)` to `HubClient`
2. `cmd/gridctl/skill.go` — modify `runSkillAdd()` to detect non-URL arg and call `Resolve()` first
3. `pkg/skills/lockfile.go` — add `HubName string` and `Tier string` to `LockedSkill` (both `omitempty`)

**Phase 3:**
1. `pkg/skills/publisher.go` (new) — `Publisher` struct with `Publish(ctx, opts PublishOptions) (prURL string, error)`
2. `cmd/gridctl/skill.go` — `skillPublishCmd`, `runSkillPublish()`, flags `skillPublishCategory`/`skillPublishDryRun`

### Reusable Components

- `pkg/output.Printer` — `printer.Warn()` for errors, `printer.Info()` for status
- `url.QueryEscape()` for query parameters
- `context.WithTimeout` pattern from `cmd/gridctl/status.go`
- `GITHUB_TOKEN` env var pattern from `pkg/skills/remote.go` — reuse for GitHub API auth in Phase 3
- `skill validate` logic — Phase 3 calls this before any network ops

## UX Specification

### Phase 1: `skill search`

```
$ gridctl skill search github
┌──────────────────────────┬────────────┬───────────────────────────────────────────────┬───────────┐
│ Name                     │ Category   │ Description                                   │ Tier      │
├──────────────────────────┼────────────┼───────────────────────────────────────────────┼───────────┤
│ pr-review                │ git        │ Review pull requests with structured AI output │ curated   │
│ github-actions-debug     │ ci         │ Debug failing GitHub Actions workflows         │ community │
│ branch-strategy          │ git        │ Suggest branching and PR strategy              │ curated   │
└──────────────────────────┴────────────┴───────────────────────────────────────────────┴───────────┘

Use `gridctl skill add <repo-url>` to install a skill.
```

**Zero results:**
```
No skills found matching "xyz". Browse all at gridctl.dev/skills
```

**Network error:**
```
Error: could not reach skills hub (gridctl.dev): dial tcp: connection refused
Use `gridctl skill add <repo-url>` to install directly from a git repository.
```

### Phase 2: Hub Name Resolution

```
$ gridctl skill add pr-review
Resolving pr-review from gridctl.dev...
Importing from https://github.com/gridctl/skills-hub, path: git/pr-review
✓ Imported pr-review (active)
```

### Phase 3: `skill publish`

```
$ gridctl skill publish --category git
Validating branch-trunk... ✓
Opening PR to gridctl/skills-hub...
✓ PR opened: https://github.com/gridctl/skills-hub/pull/42

$ gridctl skill publish --dry-run
Validating branch-trunk... ✓
Would open PR to gridctl/skills-hub with:
  Category: git
  Path:     skills/git/branch-trunk/SKILL.md
  Title:    Add skill: branch-trunk
```

## Implementation Notes

### Conventions to Follow

- Exported types in new files get doc comments
- Errors wrapped: `fmt.Errorf("searching skills hub: %w", err)`, `fmt.Errorf("resolving skill name: %w", err)`, `fmt.Errorf("publishing skill: %w", err)`
- Flags named `skillSearch<Name>`, `skillPublish<Name>` — consistent with existing `skillAdd<Name>` pattern
- `cobra.ExactArgs(1)` for `skill search`; `cobra.MaximumNArgs(1)` for `skill publish` (name optional)
- JSON output always to stdout; error messages always to stderr via `printer.Warn()`

### Potential Pitfalls

- **URL encoding**: always `url.QueryEscape(query)` in `Search()` — never string concat
- **Hub URL trailing slash**: normalize in `NewHubClient()` with `strings.TrimRight(baseURL, "/")`
- **Phase 2 arg detection**: check for `://` in the arg to distinguish URL from hub name — do not use `url.Parse()` alone (it parses bare names without error)
- **Phase 3 fork vs direct push**: always fork-and-PR, never push to `gridctl/skills-hub` directly — the token may not have write access and PRs are the intended curation flow
- **GitHub API rate limits in Phase 3**: check for 403/429 and surface a clear message; the token avoids anonymous limits but still applies
- **Context propagation**: pass `cmd.Context()` into all hub client methods so ctrl-C cancels in-flight HTTP requests
- **`omitempty` on lock file additions**: `HubName` and `Tier` must be `omitempty` so existing lock files without these fields remain valid

### Hub Index Format (for coordinating with `gridctl/skills-hub` repo)

The hub API returns JSON matching this shape. The Cloudflare Worker fetches the full `index.json` from GitHub Pages and filters server-side by the `query` parameter (case-insensitive substring match across `name`, `description`, `tags`, `category`):

```json
{
  "version": "1",
  "updated_at": "2026-04-09T00:00:00Z",
  "skills": [
    {
      "name": "pr-review",
      "description": "Review pull requests with structured AI output",
      "category": "git",
      "tags": ["github", "pr", "review"],
      "author": "gridctl",
      "tier": "curated",
      "version": "1.0.0",
      "repo": "https://github.com/gridctl/skills-hub",
      "path": "git/pr-review",
      "content_hash": "sha256:abc123..."
    }
  ]
}
```

**Tier values**: `"curated"` (manually reviewed, in gridctl/skills-hub) | `"community"` (aggregated from upstream registries) | `"third-party"` (future: user-submitted, not yet reviewed)

**Aggregation**: a nightly GitHub Action in `gridctl/skills-hub` fetches `tech-leads-club/agent-skills` `skills-registry.json`, normalizes entries to the schema above (stamping `tier: community`), merges with curated entries (curated wins on name collision), and regenerates `index.json`. A `sources.yaml` in the repo controls which upstream registries are aggregated.

### Cloudflare Worker (for `gridctl.dev/api/v1/skills`)

~30 lines of JS. Fetches `index.json` from GitHub Pages, filters by `query` and `limit`, returns JSON. CORS headers for the web UI. Deploy via `wrangler`. Free tier: 100K req/day.

```js
export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const query = (url.searchParams.get("query") || "").toLowerCase();
    const limit = parseInt(url.searchParams.get("limit") || "20");

    const index = await fetch("https://gridctl.github.io/skills-hub/index.json")
      .then(r => r.json());

    const results = index.skills
      .filter(s => !query || [s.name, s.description, s.category, ...(s.tags || [])]
        .some(f => f.toLowerCase().includes(query)))
      .slice(0, limit);

    return Response.json(results, {
      headers: { "Access-Control-Allow-Origin": "*" }
    });
  }
};
```

### Suggested Build Order

**Phase 1:**
1. Finalize `HubSkill` JSON schema and Cloudflare Worker (needed before client ships)
2. Create `pkg/skills/hub.go` + `pkg/skills/hub_test.go`
3. Add `skillSearchCmd` to `cmd/gridctl/skill.go`
4. Add REST proxy in `internal/api/skills.go`

**Phase 2:**
1. Add `Resolve()` to `HubClient`
2. Modify `runSkillAdd()` to detect hub names
3. Extend `LockedSkill` with `hub_name`/`tier`

**Phase 3:**
1. Create `pkg/skills/publisher.go`
2. Add `skillPublishCmd` to `cmd/gridctl/skill.go`

Each phase is independently shippable and mergeable.

## Acceptance Criteria

### Phase 1
1. `gridctl skill search github` returns a rounded table with Name, Category, Description, Tier columns
2. `gridctl skill search github --format json` outputs a valid JSON array, no table
3. `gridctl skill search github --limit 5` returns at most 5 results
4. Hub unreachable → exits non-zero with clear error and `skill add <repo-url>` fallback suggestion
5. Zero results → prints zero-results message, exits 0
6. `GRIDCTL_SKILLS_HUB_URL=http://localhost:8080` overrides default hub URL
7. All existing skill subcommands unaffected
8. `hub_test.go` covers: successful search, empty results, HTTP 500, network timeout

### Phase 2
9. `gridctl skill add pr-review` (no URL) calls hub Resolve, then imports normally
10. `gridctl skill add https://github.com/user/repo` bypasses hub, existing behavior unchanged
11. Lock file for hub-installed skill contains `hub_name` and `tier` fields
12. Existing lock files without `hub_name`/`tier` load without error

### Phase 3
13. `gridctl skill publish` with no `GITHUB_TOKEN` prints instructions and exits non-zero
14. `gridctl skill publish` runs validation before any network call; validation failure exits before any GitHub API call
15. `gridctl skill publish --dry-run` prints PR preview, makes no API calls
16. `gridctl skill publish` prints the PR URL on success
17. `gridctl skill --help` lists `search` and `publish` in available subcommands

## References

- gridctl.dev — owned domain, canonical registry authority
- agentskills.io specification: `https://agentskills.io/specification`
- `tech-leads-club/agent-skills` (best prior art, 2K★): `https://github.com/tech-leads-club/agent-skills`
- Homebrew Formulae API (static JSON pattern): `https://formulae.brew.sh/api/formula.json`
- Cloudflare Workers docs: `https://developers.cloudflare.com/workers/`
- Raycast extensions (PR-as-publish model): `https://github.com/raycast/extensions`
- go-pretty table docs: `https://github.com/jedib0t/go-pretty`
- GitHub REST API (fork + PR): `https://docs.github.com/en/rest/pulls/pulls`
- Full feature evaluation: `prompt-stack/prompts/gridctl/skills-hub-integration/feature-evaluation.md`
