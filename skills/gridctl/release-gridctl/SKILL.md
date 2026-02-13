---
description: Create a release for gridctl with version guidance and pre-release checks
argument-hint: "[VERSION | --tag | --redo VERSION] (e.g., v0.1.0-alpha.3, --tag, --redo v0.1.0-alpha.7)"
---

# Release Gridctl

Create a tagged release for the gridctl project. This is a two-phase process that respects branch protection rules.

**Workflow Model:** Fork-and-Pull
- `origin` = your fork (e.g., `wcollins/gridctl`)
- `upstream` = main repository (`gridctl/gridctl`)

**Process:**
1. **Phase A (Release PR)**: Create a release branch, update CHANGELOG.md, push to origin, create PR to upstream
2. **Phase B (Tag & Release)**: After PR merge, push the tag to **upstream** to trigger the release workflow
3. **Redo (--redo)**: Tear down existing release (GitHub release + tags + branch), then run Phase A

**Usage:**
- `/release-gridctl` - Create release PR with changelog update
- `/release-gridctl v0.1.0-beta.1` - Create release PR for specific version
- `/release-gridctl --tag` - After PR merge, create and push the release tag
- `/release-gridctl --redo v0.1.0-alpha.7` - Delete existing release and redo it

---

## Detect Mode

### Check Arguments

```bash
echo "$ARGUMENTS"
```

**Routing rules (check in order):**

1. **If `$ARGUMENTS` contains `--tag`:**
   - Jump to **Phase B: Tag & Release** (Section 7)

2. **If `$ARGUMENTS` contains `--redo`:**
   - Extract the version from `$ARGUMENTS` (the non-flag argument)
   - If no version provided: Error — `--redo` requires a version argument
   - Proceed to **Phase 0: Teardown** (Section 0), then flow into **Phase A** (Section 1)

3. **Otherwise:**
   - Proceed with **Phase A: Release PR** (Section 1)

---

# Phase 0: Teardown (--redo)

## 0. Teardown Existing Release

**Goal**: Remove existing GitHub release, tags, and branch so the version can be re-released

### 0.1 Verify Working Directory

Same checks as Section 1.1.

### 0.2 Verify Remotes

Same checks as Section 1.2.

### 0.3 Validate Version Format

Version must match `v{MAJOR}.{MINOR}.{PATCH}[-{prerelease}]`. Error if invalid.

### 0.4 Verify Release Exists

```bash
gh release view <version> --json tagName,name 2>/dev/null
```

If not found:
> **Error:** No GitHub release found for `<version>`. Use `/release-gridctl <version>` to create a new release.

### 0.5 Confirm Teardown

Use `AskUserQuestion`:
> **Redo release `<version>`?**
> This will delete the GitHub release, remote/local tags, and release branch, then recreate the release.

Options: **Yes, tear down and redo** / **No, cancel**

### 0.6 Delete GitHub Release

```bash
gh release delete <version> --yes
```

### 0.7 Delete Tags

```bash
git push upstream :refs/tags/<version> 2>/dev/null || true
git tag -d <version> 2>/dev/null || true
```

### 0.8 Clean Up Release Branch

```bash
git push origin --delete release/<version> 2>/dev/null || true
git branch -D release/<version> 2>/dev/null || true
```

### 0.9 Sync State

```bash
git checkout main
git fetch --tags --prune upstream
git pull upstream main
```

> **Teardown complete.** Proceeding with release creation for `<version>`.

Continue to **Phase A** (Section 1). The version is already determined — skip the version prompt in Section 2.5.

---

# Phase A: Release PR

## 1. Verify Environment

**Goal**: Ensure we're in the right place and state for a release

### 1.1 Verify Working Directory

```bash
pwd
basename $(pwd)
```

If not in `gridctl` directory:
> **Error:** Must be in the gridctl directory to create a release.
>
> Run: `cd /path/to/gridctl`

### 1.2 Verify Remotes

```bash
git remote -v
```

Verify both remotes are configured:
- `origin` should point to your fork (e.g., `wcollins/gridctl`)
- `upstream` should point to main repo (`gridctl/gridctl`)

If upstream is not configured:
> **Error:** Upstream remote not configured.
>
> Add the upstream remote:
> ```bash
> git remote add upstream git@github.com:gridctl/gridctl.git
> ```

### 1.3 Verify Clean Working Tree

```bash
git status --porcelain
```

If there are uncommitted changes:
> **Error:** Working tree is not clean.
>
> Commit or stash your changes before releasing:
> ```bash
> git stash
> # or
> git add . && git commit -m "..."
> ```

### 1.4 Verify on Main Branch

```bash
git branch --show-current
```

If not on `main`:
> **Error:** Must be on main branch to start a release.
>
> Run: `git checkout main && git pull upstream main`

### 1.5 Sync with Upstream

```bash
git fetch --tags upstream
git pull upstream main
```

---

## 2. Analyze Version History

**Goal**: Determine current version and suggest next logical version

### 2.1 Get Current Tags

```bash
git tag -l "v*" --sort=-version:refname | head -20
```

Parse the latest tag to understand current version state.

### 2.2 Parse Version Components

Extract from latest tag (e.g., `v0.1.0-alpha.2`):
- **Major**: 0
- **Minor**: 1
- **Patch**: 0
- **Pre-release type**: alpha, beta, rc, or stable (no suffix)
- **Pre-release number**: 2

### 2.3 Calculate Next Version Options

Based on current version, present logical next versions:

| Current | Next Options |
|---------|--------------|
| `v0.1.0-alpha.2` | `v0.1.0-alpha.3` (next alpha), `v0.1.0-beta.1` (promote to beta), `v0.1.0-rc.1` (promote to rc), `v0.1.0` (stable) |
| `v0.1.0-beta.3` | `v0.1.0-beta.4` (next beta), `v0.1.0-rc.1` (promote to rc), `v0.1.0` (stable) |
| `v0.1.0-rc.2` | `v0.1.0-rc.3` (next rc), `v0.1.0` (stable) |
| `v0.1.0` | `v0.1.1` (patch), `v0.2.0` (minor), `v1.0.0` (major) |
| `v1.2.3` | `v1.2.4` (patch), `v1.3.0` (minor), `v2.0.0` (major) |

### 2.4 Check for Breaking Changes

```bash
git log $(git describe --tags --abbrev=0)..HEAD --oneline | grep -E "^[a-f0-9]+ .*!:" || echo "No breaking changes"
```

If breaking changes detected, recommend incrementing major version (or noting for pre-release).

### 2.5 Determine Version

**If `$ARGUMENTS` contains a version (not `--tag`):**
- Validate format matches `v{MAJOR}.{MINOR}.{PATCH}[-{prerelease}]`
- Use provided version

**If no version provided:**
- Use `AskUserQuestion` to present options:

> **Current version:** `v0.1.0-alpha.2`
>
> Select next version:

Options:
- `v0.1.0-alpha.3` - Next alpha (Recommended for continued development)
- `v0.1.0-beta.1` - Promote to beta (Feature complete, needs testing)
- `v0.1.0-rc.1` - Release candidate (Ready for final testing)
- `v0.1.0` - Stable release (Production ready)

---

## 3. Pre-Release Checks

**Goal**: Ensure code quality before creating release PR

### 3.1 Run Linter

```bash
golangci-lint run --timeout 3m
```

If lint fails:
> **Error:** Lint check failed.
>
> Fix lint issues before releasing. See errors above.

### 3.2 Run Tests

```bash
go test -race ./...
```

If tests fail:
> **Error:** Tests failed.
>
> Fix failing tests before releasing. See errors above.

### 3.3 Verify Build

```bash
go build ./cmd/gridctl/
```

If build fails:
> **Error:** Build failed.
>
> Fix build errors before releasing. See errors above.

### 3.4 Check Web Build

```bash
if [ -d "web" ]; then
  npm ci --prefix web
  npm run build --prefix web
fi
```

If web build fails:
> **Warning:** Web build failed. The release workflow will fail.
>
> Fix web build issues or proceed if intentional.

---

## 4. Create Release Branch

**Goal**: Create a branch for the release PR

### 4.1 Create Branch

```bash
git checkout -b release/<version>
```

Example:
```bash
git checkout -b release/v0.1.0-alpha.3
```

---

## 5. Update Changelog

**Goal**: Generate changelog for this release

### 5.1 Generate Changelog with git-cliff

```bash
git-cliff --config cliff.toml -o CHANGELOG.md
```

If git-cliff is not installed:
```bash
# Install git-cliff
cargo install git-cliff
# Or on macOS
brew install git-cliff
```

### 5.2 Verify Changelog

```bash
head -50 CHANGELOG.md
```

Review that the changelog looks correct and includes the expected changes.

### 5.3 Commit Changelog

```bash
git add CHANGELOG.md
git commit -S -m "docs: update changelog for <version>"
```

Example:
```bash
git add CHANGELOG.md
git commit -S -m "docs: update changelog for v0.1.0-alpha.3"
```

---

## 6. Create Release PR

**Goal**: Push branch and create PR for review

### 6.1 Push Branch

```bash
git push -u origin release/<version>
```

### 6.2 Create Pull Request

```bash
gh pr create \
  --base main \
  --title "Release <version>" \
  --body "$(cat <<'EOF'
## Release <version>

Updates CHANGELOG.md for release.

## Checklist

- [x] All checks passed (lint, test, build)
- [x] Changelog generated with git-cliff
- [ ] PR reviewed and approved
- [ ] After merge, run `/release-gridctl --tag` to create the release tag
EOF
)"
```

### 6.3 Add Label

```bash
gh pr edit --add-label "release"
```

### 6.4 Store Release Version

Create a temporary file to remember the version for the tag phase:

```bash
echo "<version>" > .release-version
```

### 6.5 Return to User

> **Release PR Created**
>
> Branch: `release/<version>`
> PR: <PR_URL>
>
> **Next steps:**
> 1. Review and approve the PR
> 2. Merge the PR to main
> 3. Run `/release-gridctl --tag` to create and push the release tag

**Stop here.** Wait for PR to be merged.

---

# Phase B: Tag & Release

## 7. Verify Ready for Tagging

**Goal**: Ensure PR is merged and we're ready to tag

### 7.1 Verify Working Directory

```bash
pwd
basename $(pwd)
```

If not in `gridctl` directory:
> **Error:** Must be in the gridctl directory.

### 7.2 Verify Upstream Remote

```bash
git remote get-url upstream
```

If upstream is not configured:
> **Error:** Upstream remote not configured.
>
> Add the upstream remote:
> ```bash
> git remote add upstream git@github.com:gridctl/gridctl.git
> ```

### 7.3 Check for Release Version File

```bash
cat .release-version 2>/dev/null || echo ""
```

If file exists, use that version. Otherwise, determine from recent PRs or ask user.

### 7.4 Sync Main from Upstream

```bash
git checkout main
git pull upstream main
git fetch --tags upstream
```

### 7.5 Verify Release PR is Merged

```bash
# Check if release branch was merged
gh pr list --state merged --search "release/<version>" --limit 1
```

If PR not found or not merged:
> **Error:** Release PR not found or not merged.
>
> Ensure the release PR is merged before tagging.

### 7.6 Verify Tag Doesn't Exist

```bash
git tag -l "<version>"
```

If tag already exists:
> **Error:** Tag `<version>` already exists.
>
> Choose a different version or delete the existing tag:
> ```bash
> git tag -d <version>
> git push upstream :refs/tags/<version>
> ```

---

## 8. Create and Push Tag

**Goal**: Create the release tag to trigger the workflow

### 8.1 Confirm Release

Use `AskUserQuestion`:
> Create and push tag `<version>`?
>
> This will trigger the GitHub Actions release workflow.

Options:
- **Yes, create release** - Proceed with tag creation
- **No, cancel** - Abort without changes

### 8.2 Create Annotated Tag

```bash
git tag -a <version> -m "Release <version>"
```

Example:
```bash
git tag -a v0.1.0-alpha.3 -m "Release v0.1.0-alpha.3"
```

### 8.3 Push Tag to Upstream

**IMPORTANT:** Push to `upstream`, not `origin`. The release workflow runs on the upstream repository.

```bash
git push upstream <version>
```

### 8.4 Cleanup

```bash
# Remove the release version file
rm -f .release-version

# Delete local release branch (remote was deleted by PR merge)
git branch -d release/<version> 2>/dev/null || true
```

---

## 9. Report

**Goal**: Confirm release and provide links

> **Release Created Successfully**
>
> Tag `<version>` has been pushed to upstream.
>
> **GitHub Actions:**
> The release workflow is now running. Monitor progress at:
> https://github.com/gridctl/gridctl/actions
>
> **Release URL (when complete):**
> https://github.com/gridctl/gridctl/releases/tag/<version>
>
> **What happens automatically:**
> - Binaries are built for Linux and macOS (amd64/arm64)
> - GitHub Release is created with release notes
> - Homebrew tap is updated

---

## Error Recovery

### Tag Already Exists

If the tag already exists:
> **Error:** Tag `<version>` already exists.
>
> Choose a different version or delete the existing tag:
> ```bash
> git tag -d <version>
> git push upstream :refs/tags/<version>
> ```

### Push Failed

If push fails:
> **Error:** Failed to push tag.
>
> Check your permissions and try:
> ```bash
> git push upstream <version>
> ```

### Rollback

If you need to undo a release:
```bash
# Delete local tag
git tag -d <version>

# Delete remote tag (if pushed)
git push upstream :refs/tags/<version>
```

---

## Version Naming Reference

### Semantic Versioning

Format: `v{MAJOR}.{MINOR}.{PATCH}[-{prerelease}]`

| Component | When to Increment |
|-----------|-------------------|
| MAJOR | Breaking changes (incompatible API changes) |
| MINOR | New features (backward compatible) |
| PATCH | Bug fixes (backward compatible) |

### Pre-release Labels

| Label | Meaning | When to Use |
|-------|---------|-------------|
| `alpha.N` | Active development | Features incomplete, unstable |
| `beta.N` | Feature complete | Testing needed, may have bugs |
| `rc.N` | Release candidate | Final testing, production-ready candidate |
| (none) | Stable | Production ready |

### Version Progression Example

```
v0.1.0-alpha.1  →  Initial alpha
v0.1.0-alpha.2  →  Continue development
v0.1.0-alpha.3  →  More features
v0.1.0-beta.1   →  Feature complete
v0.1.0-beta.2   →  Bug fixes
v0.1.0-rc.1     →  Release candidate
v0.1.0-rc.2     →  Final fixes
v0.1.0          →  Stable release
v0.1.1          →  Patch release
v0.2.0          →  Minor release
v1.0.0          →  Major release
```

---

## Important Rules

- **Two-phase process**: PR first, then tag after merge
- **Must be on main branch** to start release
- **All checks must pass** before creating release PR
- **Use annotated tags** (`git tag -a`) not lightweight tags
- **Never force push tags** - if a tag exists, choose a different version
- **Sign commits** with `-S` flag
- **`--redo` requires a version** - always specify which release to redo
