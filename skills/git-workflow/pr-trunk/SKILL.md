---
description: Commit changes, push to origin, and create PR to main
---

# Create Pull Request (Trunk Workflow)

Commit changes and create a pull request to main.

Use this command for repositories where you have direct push access and work with a single main branch.

## Instructions

### 1. Verify State

Check current branch and changes:

```bash
git branch --show-current
git status
```

- If on `main`: Stop and inform user to switch to feature branch
- If no changes: Stop and inform user there's nothing to commit

### 2. Analyze Changes

Review all changes to understand scope:

```bash
git status
git diff
```

Determine:
- What files changed
- Nature of changes (feature, fix, docs, etc.)
- Logical groupings for commits

### 3. Create Atomic Commits

**Commit format:**
```
<type>: <subject>
```

- **type**: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`
- **subject**: imperative mood, max 50 chars, no period

**Signing**: All commits must be signed with `-S` flag

**Grouping strategy**:
- **One file = one commit** (always commit files individually)
- Each file gets its own atomic commit with appropriate type
- Order commits logically (config before implementation, implementation before tests)

**Commit order**:
1. Infrastructure/config changes first
2. Core implementation second
3. Documentation last

**Critical rules**:
- **No Co-authored-by trailers**
- **No mention of Claude**

Stage and commit each file individually:
```bash
# Repeat for each changed file:
git add <file>
git commit -S -m "<type>: <subject describing this file's change>"
```

Example with multiple files:
```bash
git add src/config.ts
git commit -S -m "chore: add configuration module"

git add src/utils.ts
git commit -S -m "feat: add utility functions"

git add src/utils.test.ts
git commit -S -m "test: add utility function tests"
```

### 4. Push to Origin

```bash
git push -u origin $(git branch --show-current)
```

### 5. Create Pull Request

Use `gh` CLI to create PR targeting main:

```bash
gh pr create \
  --base main \
  --title "<type>: <subject>" \
  --body "$(cat <<'EOF'
## Description

<1-2 sentences: what this PR does and why>

## Type of Change

- [x] <mark appropriate type>

## Changes Made

- <bullet point of key change>
- <bullet point of key change>

## Testing

<how to test>

## Checklist

- [x] Code follows the project's style guidelines
- [x] Self-review of code has been performed
- [x] Commits follow conventional format
- [x] No secrets or credentials committed
EOF
)"
```

**PR guidelines**:
- Title matches primary commit message
- Description is concise and practical
- Mark only applicable checklist items
- Do NOT be overly wordy

### 6. Add Label

Apply a label based on the commit type from the PR title:

| Commit Type | Label |
|-------------|-------|
| `feat` | `enhancement` |
| `fix` | `bug` |
| `docs` | `documentation` |
| `refactor` | `refactor` |
| `chore` | `chore` |

```bash
gh pr edit --add-label "<label>"
```

### 7. Return PR URL

Output the PR URL to user:

> Pull request created: <PR_URL>
>
> Next steps:
> - Review the PR in GitHub
> - Merge when ready
> - Run `/reset-trunk` to clean up after merge

## Important Rules

- Sign all commits (`-S` flag)
- No Co-authored-by trailers
- No mention of Claude anywhere
- Keep PR description practical and concise
