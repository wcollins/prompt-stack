---
description: Sync with origin, create feature branch, and make changes
argument-hint: <task description>
---

# Create Feature Branch (Trunk Workflow)

Start a new branch synced with origin for: $ARGUMENTS

Use this command for repositories where you have direct push access and work with a single main branch (trunk-based development).

## Instructions

### 1. Sync Main with Origin

```bash
git checkout main
git pull origin main
```

### 2. Read Project Context

Read these files if they exist to understand naming conventions:
- `CLAUDE.md` - project rules
- `CONTRIBUTING.md` - branch prefixes and commit format
- `README.md` - project context

### 3. Generate Branch Name

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
| "add tmux configuration" | `feature/add-tmux-configuration` |
| "fix shell profile sourcing order" | `fix/shell-profile-sourcing-order` |
| "refactor shell configuration loading" | `refactor/shell-configuration-loading` |
| "update README with new install steps" | `docs/readme-install-steps` |
| "bump neovim plugin versions" | `chore/bump-neovim-plugins` |

### 4. Create and Switch to Branch

```bash
git checkout -b <branch-name>
```

### 5. Return Control

> Branch `<branch-name>` created and checked out.
>
> Next steps:
> 1. Make changes
> 2. When ready, run `/pr-trunk` to commit and create pull request

## Important Rules

- **Do NOT create any commits**
- **Do NOT push to remote**
- **Do NOT implement changes** — branching only creates the branch
- Generate the branch name automatically — do not ask for confirmation
