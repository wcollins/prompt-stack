# Feature Implementation: Proto Testing Directory

## Context

**Project**: gridctl — a Go + React MCP (Model Context Protocol) orchestration gateway. It aggregates tools from multiple MCP servers into a single unified endpoint. Users manage "stacks" (declarative YAML configs) that describe which MCP servers to run, how to link them to LLM clients, and what resources to provision.

**Tech stack**: Go 1.25 CLI (Cobra), React 19 + TypeScript frontend (Vite, Tailwind, Zustand), Docker/Podman for container orchestration. The web UI is served at `http://localhost:8180` by the embedded SPA server.

**How to run locally**:
```bash
make build        # builds web + Go binary → ./gridctl
./gridctl apply <stack.yaml>   # deploy a stack
open http://localhost:8180     # open the web UI
./gridctl destroy <stack.yaml> # tear down
```

**Mock servers** (needed by many test scripts):
```bash
make mock-servers        # build and start mock MCP servers
make clean-mock-servers  # stop them when done
# OR source plan/ensure-mock-servers.sh inside a script
```

## Evaluation Context

- **Existing pattern**: `plan/` (gitignored) has 9 PR-specific smoke test scripts that prove the hybrid CLI+UI test doc pattern works well. `proto/` should follow the same ergonomics but be feature-organized instead of PR-organized.
- **Scope decision**: Target ~12 feature domains, not all 79 individual features. This keeps the directory maintainable long-term.
- **Mock infrastructure reuse**: Source `plan/ensure-mock-servers.sh` in any script that needs mock MCP servers.
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/proto-testing-directory/feature-evaluation.md`

## Feature Description

Create a `proto/` directory at the project root containing organized smoke tests for gridctl's full feature surface. CLI-testable features get shell scripts that deploy, exercise, assert, and clean up. UI features get `TEST.md` files with step-by-step manual test instructions. A top-level `run.sh` dispatches all or individual domain tests. The directory is gitignored and not referenced in AGENTS.md.

**Problem solved**: No single place today to smoke-test the full feature surface before or after a release. The existing `plan/` directory is PR-organized and incomplete.

**Beneficiary**: The developer (personal testing), especially before releases.

## Requirements

### Functional Requirements

1. Add `proto/` to `.gitignore`
2. Create `proto/run.sh` — top-level dispatcher that:
   - With no args: runs all `test.sh` scripts sequentially, prints a pass/fail summary
   - With a domain arg (`./proto/run.sh vault`): runs only that domain's `test.sh`
   - Prints a clear header for each domain and overall result at the end
3. Create one folder per feature domain listed in the Architecture section below
4. Each domain with CLI-testable features gets a `test.sh` that:
   - Sources `plan/ensure-mock-servers.sh` if mock servers are needed
   - Uses `./gridctl` (locally built binary) — never the installed binary
   - Deploys any needed fixtures, exercises the commands, prints results, cleans up
   - Exits 0 on success, non-zero on failure
   - Prints a clear `[PASS]` or `[FAIL]` line at the end
5. Each domain with UI features gets a `TEST.md` with:
   - Prerequisites section (what must be running)
   - Numbered steps with explicit "Click X" and "→ verify Y" callouts
   - A cleanup section
6. Domain folders that need YAML fixtures contain them inline (not referencing `plan/` fixtures directly)

### Non-Functional Requirements

- Scripts must be idempotent: re-running after a partial failure should not leave dirty state
- Each script should destroy any stacks it deploys, even on failure (use `trap` for cleanup)
- `TEST.md` files should be concise — 1–2 sentences per step, not paragraphs
- Scripts should not require any environment variables beyond what `./gridctl` already auto-detects (Docker socket, etc.)

### Out of Scope

- Adding proto/ to CI
- Modifying AGENTS.md or any source file
- Testing every one of the 79 individual features — focus on the 12 domain workflows
- Automated UI testing (Playwright/Cypress) — manual instructions only

## Architecture Guidance

### Directory Structure

```
proto/
├── run.sh                    # top-level dispatcher
├── stack/
│   ├── test.sh               # apply, destroy, status, plan, validate, reload, export
│   ├── stack-basic.yaml      # 2-server fixture (stdio + HTTP mock servers)
│   ├── stack-modified.yaml   # modified version for plan/reload testing
│   └── TEST.md               # UI: Spec tab, drift overlay, wizard
├── vault/
│   ├── test.sh               # set, get, list, delete, import, export, lock/unlock, sets, change-passphrase
│   └── TEST.md               # UI: Vault panel in web UI
├── skills/
│   ├── test.sh               # list, add (dry-run), info, validate, try, pin, update, remove
│   └── TEST.md               # UI: Registry sidebar, skill editor
├── link/
│   └── test.sh               # link --dry-run for each supported client, unlink --dry-run --all
├── traces/
│   ├── test.sh               # deploy stack, invoke tools via MCP, run gridctl traces
│   ├── traces-stack.yaml     # stack fixture
│   └── TEST.md               # UI: Traces tab, waterfall, span details
├── pins/
│   ├── test.sh               # pins list, pins verify, pins approve, pins reset
│   ├── pins-stack.yaml       # stack fixture with a server that has schema pins
│   └── TEST.md               # UI: Pins panel, drift badge
├── metrics/
│   ├── test.sh               # deploy stack, check /api/metrics endpoint
│   ├── metrics-stack.yaml    # fixture
│   └── TEST.md               # UI: Metrics tab, KPI cards, sparklines, token counter
├── wizard/
│   └── TEST.md               # UI: Creation wizard — all 6 form types, draft persistence, YAML preview
├── graph/
│   └── TEST.md               # UI: Canvas — node selection, drag, zoom, fit-to-view, wiring mode
├── playground/
│   ├── playground-stack.yaml # stack fixture with tools to invoke
│   └── TEST.md               # UI: Playground tab — invoke tool, reasoning waterfall
├── serve/
│   └── test.sh               # gridctl serve, verify UI is accessible, check /api/health
└── info/
    └── test.sh               # gridctl info, gridctl version
```

### Key Files to Understand First

1. `plan/ensure-mock-servers.sh` — the mock server start/build script; source this in any test that needs servers
2. `plan/run-wizard-test.sh` — canonical example of the hybrid CLI+UI test script pattern to follow
3. `plan/TESTING.md` — example of the TEST.md format and step style
4. `plan/01-basic-stack.yaml` — reuse or adapt for stack/traces/metrics fixtures
5. `cmd/gridctl/vault.go` — understand vault subcommands and flags
6. `cmd/gridctl/skill.go` — understand skill subcommands and flags
7. `cmd/gridctl/link.go` — understand supported clients and dry-run flag
8. `cmd/gridctl/pins.go` — understand pins subcommands
9. `examples/getting-started/` — example stacks to adapt for fixtures

### Integration Points

- `.gitignore` — add `proto/` entry
- No source code changes required

### Reusable Components

- `plan/ensure-mock-servers.sh` — source at top of any script needing mock MCP servers
- `plan/01-basic-stack.yaml` through `plan/12-full-stack.yaml` — adapt as proto fixtures rather than creating from scratch
- `examples/_mock-servers/` — the actual mock server binaries

## UX Specification

### run.sh dispatcher

```
Usage: ./proto/run.sh [domain]

Domains: stack vault skills link traces pins metrics serve info
         (omit to run all CLI domains)

Output:
  [stack] Running stack tests...
  [stack] PASS
  [vault] Running vault tests...
  [vault] PASS
  ...
  ─────────────────────────
  Results: 8/9 passed
  Failed:  traces
```

### test.sh scripts

Each script should follow this pattern:
```bash
#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRIDCTL="$SCRIPT_DIR/../../gridctl"
DOMAIN="<domain-name>"

# Cleanup trap
cleanup() { ... }
trap cleanup EXIT

echo "=== $DOMAIN tests ==="

# Source mock servers if needed
# source "$SCRIPT_DIR/../../plan/ensure-mock-servers.sh"

# Test cases...
echo "[ ] test: apply basic stack"
$GRIDCTL apply "$SCRIPT_DIR/stack-basic.yaml"
echo "[✓] test: apply basic stack"

# Final result
echo ""
echo "[PASS] $DOMAIN"
```

### TEST.md format

```markdown
# <Feature> — Manual Test Instructions

## Prerequisites
- `./gridctl apply proto/<domain>/<fixture>.yaml` is running
- Web UI open at http://localhost:8180

## Steps

### <Section Name>
1. Click **[button/element]** → verify [expected result]
2. ...

## Cleanup
Run: `./gridctl destroy proto/<domain>/<fixture>.yaml`
```

## Implementation Notes

### Conventions to Follow

- Always use `./gridctl` (relative to repo root), never `gridctl` — the user builds locally with `make build`
- Scripts use `set -e` but must also trap EXIT for cleanup so stacks don't get left running
- `--dry-run` flag is available on `link`, `unlink`, `skill update`, `skill add` — use it where possible to avoid side effects
- Vault tests need to handle the passphrase prompt; use `echo "testpass" | ./gridctl vault unlock` or `--value` flag for non-interactive operation
- `gridctl skill add` requires a real git URL; use `--dry-run` or a known-good public repo (e.g. one from the examples) for the test
- `gridctl traces` requires a running stack with actual MCP traffic; the metrics-stack fixture can serve double duty

### Potential Pitfalls

- **Vault encryption**: The vault is encrypted with Argon2id; tests that lock/unlock need a consistent passphrase. Use a hardcoded test passphrase and always unlock before subsequent vault operations.
- **Mock server timing**: After `gridctl apply`, sleep 3–5 seconds before testing status/tools to allow server registration. See plan/ scripts for the pattern.
- **Port conflicts**: If a previous test left a stack running, apply will fail. The cleanup trap handles this for normal exits; document "run `./gridctl destroy` manually if a test was aborted" in run.sh.
- **skill add side effects**: Installing a real skill modifies `~/.claude/`. Use `--no-activate` and remove with `gridctl skill remove` in the cleanup trap.
- **Wizard YAML preview**: The YAML preview panel only renders after a field is filled in — note this in the wizard TEST.md to avoid confusion.

### Suggested Build Order

1. `.gitignore` entry for `proto/`
2. `proto/info/test.sh` — simplest, no fixtures needed; validates binary path
3. `proto/serve/test.sh` — validates web UI startup
4. `proto/stack/test.sh` + fixtures — core workflow, most other tests depend on this pattern
5. `proto/vault/test.sh` + `vault/TEST.md`
6. `proto/link/test.sh`
7. `proto/skills/test.sh` + `skills/TEST.md`
8. `proto/traces/test.sh` + `traces/TEST.md`
9. `proto/pins/test.sh` + `pins/TEST.md`
10. `proto/metrics/test.sh` + `metrics/TEST.md`
11. `proto/wizard/TEST.md`, `proto/graph/TEST.md`, `proto/playground/TEST.md`
12. `proto/run.sh` — wire everything together last

## Acceptance Criteria

1. `proto/` does not appear in `git status` (properly gitignored)
2. `./proto/run.sh` runs without error and prints a summary with pass/fail per domain
3. `./proto/run.sh stack` runs only the stack domain tests
4. Each `test.sh` exits 0 when the feature works correctly
5. Each `test.sh` cleans up any deployed stacks (verify with `./gridctl status` returning empty after the script exits)
6. Vault `test.sh` exercises: set, get, list, delete, lock, unlock, import (from a temp .env file), export, change-passphrase, vault sets create/list/delete
7. Skills `test.sh` exercises: list, info, validate — and uses `--dry-run` / `--no-activate` for add/remove to avoid modifying `~/.claude/`
8. Link `test.sh` exercises `--dry-run` for at least 3 different clients (claude, cursor, vscode)
9. All `TEST.md` files follow the format spec above: prerequisites, numbered steps with "→ verify" callouts, cleanup section
10. `run.sh` accepts an optional domain argument; invalid domain prints usage and exits 1

## References

- Existing plan/ scripts (canonical examples): `/Users/william/code/gridctl/plan/`
- plan/TESTING.md (TEST.md format example): `/Users/william/code/gridctl/plan/TESTING.md`
- plan/run-wizard-test.sh (hybrid CLI+UI script example): `/Users/william/code/gridctl/plan/run-wizard-test.sh`
- gridctl CLI reference: `./gridctl --help` and `./gridctl <command> --help`
- Feature evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/proto-testing-directory/feature-evaluation.md`
