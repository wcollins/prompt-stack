---
description: Stage and commit an uncommitted codebase in logical chunks via PRs to upstream
argument-hint: "[continue]"
---

# Onboard Codebase (Fork Workflow)

Stage and commit an uncommitted codebase in logical chunks via PRs to upstream.

Use this command to version control an existing project that has code but no meaningful commit history. It breaks the codebase into reviewable chunks and creates separate PRs for each, targeting an upstream repository.

**Usage:**
- `/onboard-fork` - Initial run: analyze codebase, create chunk plan, stage first chunk
- `/onboard-fork continue` - After PR merge: stage next chunk

## Instructions

### 1. Check Arguments

If `$ARGUMENTS` contains "continue":
- Jump to **Continue Flow** section (step 13)

Otherwise:
- Proceed with **Initial Flow** (step 2)

---

## Initial Flow

### 2. Verify Starting State

```bash
git branch --show-current
git status --porcelain
```

**Checks:**
- Must be on `main` branch
- Should have untracked files (files not yet added to git)

If not on main:
> **Error:** Not on main branch.
>
> Switch to main first: `git checkout main`

If no untracked files found:
> **Error:** No untracked files found.
>
> This command is for versioning uncommitted codebases. Your files may already be tracked.

### 3. Check for Existing State

```bash
test -f .claude/onboard-state.json && cat .claude/onboard-state.json
```

If state file exists and phase is NOT "completed":
> **Existing session detected.**
>
> An onboarding operation is already in progress.
> - To continue: `/onboard-fork continue`
> - To start fresh: Delete `.claude/onboard-state.json` and run again

If state file exists and phase IS "completed":
> **Previous session completed.**
>
> Delete `.claude/onboard-state.json` to start a new onboarding session.

### 4. Gather Untracked Files

```bash
git ls-files --others --exclude-standard
```

Store the complete file list for analysis.

### 5. Analyze and Chunk Files

Categorize all untracked files into tiers, then group into chunks.

**Tier 1 - Foundation (always first chunk):**
- `.gitignore`, `.gitattributes`
- `LICENSE`, `LICENSE.md`, `LICENSE.txt`
- `README.md`, `README`
- Package manifests: `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.toml`, `Cargo.lock`, `pyproject.toml`, `poetry.lock`, `requirements.txt`, `go.mod`, `go.sum`, `Gemfile`, `Gemfile.lock`
- Build configs: `tsconfig.json`, `tsconfig.*.json`, `jsconfig.json`, `*.config.js`, `*.config.ts`, `*.config.mjs`, `vite.config.*`, `webpack.config.*`, `rollup.config.*`, `esbuild.*`, `Makefile`, `CMakeLists.txt`
- Container: `Dockerfile`, `docker-compose.yml`, `docker-compose.yaml`, `.dockerignore`
- CI/CD: `.github/*`, `.gitlab-ci.yml`, `.travis.yml`, `azure-pipelines.yml`, `Jenkinsfile`
- Linting/formatting: `.eslintrc*`, `.prettierrc*`, `.stylelintrc*`, `.editorconfig`, `biome.json`, `deno.json`
- Environment: `.env.example`, `.env.template`

**Tier 2 - Types/Interfaces (if >3 files, separate chunk):**
- `*.d.ts` files
- `types/*`, `src/types/*`
- `interfaces/*`, `src/interfaces/*`
- `typings/*`

**Tier 3 - Core Implementation:**
- `src/lib/*`, `lib/*`
- `src/core/*`, `core/*`
- `src/utils/*`, `utils/*`, `src/helpers/*`, `helpers/*`
- `src/services/*`, `services/*`
- `internal/*`

**Tier 4 - Features/Components:**
- `src/components/*`, `components/*`
- `src/features/*`, `features/*`
- `src/pages/*`, `pages/*`, `src/views/*`, `views/*`
- `src/routes/*`, `routes/*`
- `src/api/*`, `api/*`, `src/handlers/*`, `handlers/*`
- `src/controllers/*`, `controllers/*`
- `src/models/*`, `models/*`

**Tier 5 - Tests (if present, separate chunk):**
- `*.test.*`, `*.spec.*`, `*_test.*`
- `tests/*`, `test/*`, `__tests__/*`, `spec/*`

**Tier 6 - Documentation (if >2 files, separate chunk):**
- `docs/*`, `documentation/*`
- `examples/*`, `samples/*`
- `*.md` files not in root (excluding README/LICENSE)
- `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`

**Grouping Rules:**
- Target 5-20 files per chunk (split large tiers by subdirectory)
- Keep files in same directory together
- Minimum 2 chunks, maximum 7 chunks
- If total files < 10, use just 2 chunks (foundation + everything else)

**Assign commit types:**
- Foundation → `chore`
- Types/Interfaces → `feat`
- Core/Features → `feat`
- Tests → `test`
- Documentation → `docs`

### 6. Present Plan for Confirmation

Display the chunking plan:

> **Onboarding Plan**
>
> Project: `<directory-name>`
> Total files: `<count>`
> Proposed chunks: `<count>`
>
> | # | Name | Files | Type | Description |
> |---|------|-------|------|-------------|
> | 1 | project-setup | 8 | chore | Configuration, build tools, CI/CD |
> | 2 | core-implementation | 12 | feat | Core utilities and services |
> | 3 | features | 15 | feat | Components and API handlers |
> | 4 | tests | 6 | test | Test suite |
> | 5 | documentation | 4 | docs | Guides and examples |

Use `AskUserQuestion` to confirm:
> Does this plan look good?

Options:
- **Yes, proceed** - Continue with staging
- **Adjust chunks** - Describe what to change
- **Cancel** - Stop without making changes

If user wants adjustments, modify the plan and re-confirm.

### 7. Create State File

```bash
mkdir -p .claude
```

Write state to `.claude/onboard-state.json`:
```json
{
  "version": "1.0",
  "workflow": "fork",
  "created_at": "<ISO-8601 timestamp>",
  "updated_at": "<ISO-8601 timestamp>",
  "project_name": "<directory-name>",
  "total_files": <count>,
  "chunks": [
    {
      "index": 0,
      "name": "<chunk-name>",
      "description": "<description>",
      "branch_name": "<prefix>/<chunk-name>",
      "commit_type": "<type>",
      "files": ["<file1>", "<file2>", ...],
      "status": "pending",
      "pr_url": null,
      "completed_at": null
    }
  ],
  "current_chunk_index": 0,
  "phase": "staging"
}
```

### 8. Ensure Upstream Remote

```bash
git remote get-url upstream 2>/dev/null
```

If upstream is not configured, use `AskUserQuestion`:
> **Upstream remote not configured.**
>
> What is the upstream repository URL?
>
> Example: `https://github.com/owner/repo.git`

Then add the remote:
```bash
git remote add upstream <url>
```

### 9. Sync Main with Upstream

```bash
git fetch upstream
git checkout main
git merge upstream/main --ff-only
git push origin main
```

### 10. Create Branch for Chunk 1

Determine branch name from chunk:
- `chore/` prefix for foundation chunks
- `feat/` prefix for implementation chunks
- `test/` prefix for test chunks
- `docs/` prefix for documentation chunks

Use the chunk name as the branch suffix (kebab-case).

```bash
git checkout -b <branch-name>
```

### 11. Stage Chunk 1 Files

Stage only the files belonging to this chunk:

```bash
git add <file1> <file2> <file3> ...
```

Update state file:
- Set chunk 0 status to `in_progress`
- Set phase to `awaiting_pr`
- Update `updated_at` timestamp

### 12. Return Control to User

Display summary and next steps:

> **Chunk 1 of N staged: `<chunk-name>`**
>
> Branch: `<branch-name>`
>
> Files staged (`<count>`):
> - `<file1>`
> - `<file2>`
> - `<file3>`
> - ... (showing first 10)
>
> **Note:** `/pr-fork` will create individual commits for each file.
> Commit type for this chunk: `<type>`
>
> **Next steps:**
> 1. Review staged files: `git diff --staged`
> 2. Create PR: `/pr-fork` (creates one commit per file)
> 3. Merge PR in GitHub
> 4. Clean up: `/reset-fork`
> 5. Continue: `/onboard-fork continue`

**Stop here.** Wait for user to complete PR workflow.

---

## Continue Flow

### 13. Load State File

```bash
cat .claude/onboard-state.json
```

If no state file exists:
> **Error:** No onboarding session in progress.
>
> Run `/onboard-fork` to start a new session.

Parse the state file and validate:
- workflow should be "fork"
- phase should be "awaiting_pr"
- current_chunk_index should be valid

### 14. Verify Previous Chunk Complete

```bash
git branch --show-current
```

If NOT on `main` branch:
> **Error:** Still on feature branch `<branch>`.
>
> Complete the PR workflow first:
> 1. Run `/pr-fork` if you haven't created the PR
> 2. Merge the PR in GitHub
> 3. Run `/reset-fork` to clean up
> 4. Then run `/onboard-fork continue`

### 15. Mark Previous Chunk Complete

Update state file:
- Set previous chunk status to `completed`
- Set previous chunk `completed_at` to current timestamp
- Increment `current_chunk_index`
- Update `updated_at` timestamp

### 16. Check if All Chunks Complete

If `current_chunk_index` >= total chunks:

> **Onboarding Complete!**
>
> All chunks have been committed as separate PRs:
>
> | # | Name | Files | Status |
> |---|------|-------|--------|
> | 1 | project-setup | 8 | Merged |
> | 2 | core-implementation | 12 | Merged |
> | ... | ... | ... | ... |
>
> Total: `<total-files>` files across `<chunk-count>` pull requests.
>
> Your codebase is now version controlled!

Update state: phase = "completed"

**Stop here.** Onboarding is complete.

### 17. Sync Main with Upstream

```bash
git fetch upstream
git checkout main
git merge upstream/main --ff-only
git push origin main
```

### 18. Create Branch for Next Chunk

Get next chunk from state file.

```bash
git checkout -b <next-branch-name>
```

### 19. Stage Next Chunk Files

```bash
git add <file1> <file2> ...
```

Update state file:
- Set current chunk status to `in_progress`
- Update `updated_at` timestamp

### 20. Return Control to User

Display progress and next steps:

> **Onboarding Progress: `<completed>`/`<total>` chunks complete**
>
> Completed:
> - [x] 1. project-setup
> - [x] 2. core-implementation
>
> **Chunk `<N>` of `<total>` staged: `<chunk-name>`**
>
> Branch: `<branch-name>`
>
> Files staged (`<count>`):
> - `<file1>`
> - `<file2>`
> - ...
>
> **Note:** `/pr-fork` will create individual commits for each file.
> Commit type for this chunk: `<type>`
>
> **Next steps:**
> 1. Review staged files: `git diff --staged`
> 2. Create PR: `/pr-fork` (creates one commit per file)
> 3. Merge PR in GitHub
> 4. Clean up: `/reset-fork`
> 5. Continue: `/onboard-fork continue`

**Stop here.** Wait for user to complete PR workflow.

---

## Important Rules

- **Do NOT create commits** - user runs `/pr-fork` for that
- **Do NOT push to remote** - user runs `/pr-fork` for that
- **Do NOT modify the pr-fork or reset-fork commands** - they work as-is
- **One file = one commit** - `/pr-fork` creates individual commits per file
- **Persist state** after every significant action
- **Fail gracefully** with clear recovery instructions
- Follow all commit conventions when suggesting commit messages
- Keep chunk descriptions concise (5-10 words)
- If files are deleted between runs, skip them and warn the user
