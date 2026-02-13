---
description: Sync with upstream and delete feature branch after PR merge
---

# Reset After Merge (Fork Workflow)

Clean up after a PR is merged and prepare for the next task.

Use this command after your pull request to upstream has been merged.

## Instructions

### 1. Check Current Branch

```bash
git branch --show-current
```

- If already on `main`: skip to step 3 (sync with upstream)
- If on feature branch: store the branch name and proceed

### 2. Switch to Main

```bash
git checkout main
```

### 3. Sync Main with Upstream

```bash
git fetch upstream
git merge upstream/main --ff-only
git push origin main
```

### 4. Delete Feature Branch (if applicable)

If you were on a feature branch:

**Delete local branch:**
```bash
git branch -D <branch-name>
```

**Delete remote branch on origin:**
```bash
git push origin --delete <branch-name>
```

### 5. Confirm Cleanup

Output to user:

> Reset complete. You're on `main`, synced with upstream.
>
> Deleted branch `<branch-name>` (local and remote).
>
> Ready for next task: `/branch-fork <task>`

If already on main (no branch to delete):

> Synced `main` with upstream.
>
> Ready for next task: `/branch-fork <task>`
