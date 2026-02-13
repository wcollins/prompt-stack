---
description: Sync with upstream, create feature branch, and make changes
argument-hint: <task description>
---

# Create Feature Branch (Fork Workflow)

Start a new feature branch synced with upstream for: $ARGUMENTS

Use this command when working on a forked repository where you contribute changes back to an upstream repository via pull requests.

## Instructions

### 1. Ensure Upstream Remote Exists

Check if upstream remote is configured. If missing, ask user for the upstream URL:

```bash
git remote get-url upstream 2>/dev/null
```

If not configured, use `AskUserQuestion` to get the upstream repository URL, then add it:

```bash
git remote add upstream <upstream-url>
```

### 2. Sync Main with Upstream

```bash
git fetch upstream
git checkout main
git merge upstream/main --ff-only
git push origin main
```

### 3. Read Project Context

Read these files if they exist to understand naming conventions:
- `CLAUDE.md` - project rules
- `CONTRIBUTING.md` - branch prefixes and commit format
- `README.md` - project context

### 4. Generate Branch Name

Based on the task description in `$ARGUMENTS`:

**Determine prefix from keywords:**
- `fix/` - task contains "fix", "bug", "broken", "issue", "error"
- `refactor/` - task contains "refactor", "restructure", "reorganize", "clean up"
- `docs/` - task contains "doc", "readme", "guide", "contributing"
- `chore/` - task contains "chore", "ci", "deps", "bump", "update version"
- `feature/` - default for everything else

**Create slug:**
- Extract key words from task
- Convert to lowercase kebab-case
- Keep concise (3-5 words after prefix)

**Examples:**
| Task | Branch |
|------|--------|
| "add gateway5 health check" | `feature/add-gateway5-health-check` |
| "fix MongoDB connection timeout" | `fix/mongodb-connection-timeout` |
| "update README with Podman instructions" | `docs/readme-podman-instructions` |
| "bump Redis version to 7.4" | `chore/bump-redis-version` |

### 5. Confirm Branch Name

Use `AskUserQuestion` to present the generated branch name and let user confirm or provide alternative.

### 6. Create and Switch to Branch

```bash
git checkout -b <confirmed-branch-name>
```

### 7. Make Requested Changes

Implement the task described in `$ARGUMENTS`. Make all necessary file changes.

### 8. Return Control to User

After completing changes, inform the user:

> Changes complete on branch `<branch-name>`.
>
> Next steps:
> 1. Review changes: `git diff`
> 2. Test locally
> 3. When ready, run `/pr-fork` to commit and create pull request

## Important Rules

- **Do NOT create any commits**
- **Do NOT push to remote**
- Control returns to user for testing and validation
