---
description: Validate project state and synchronize AGENTS.md documentation with codebase reality
argument-hint: Optional scope (e.g., "web" to sync only web/AGENTS.md)
---

# Sync Gridctl Documentation

Ensure AGENTS.md files accurately reflect the current codebase state. This command validates, not generates—it fixes documentation that has become **incorrect**, not documentation that is merely incomplete.

## Philosophy

Documentation is a **living document**. The goal is accuracy, not comprehensiveness. Only fix what is actually wrong.

**This command will:**
- Find documentation that contradicts the code
- Fix incorrect examples, signatures, and references
- Update outdated architectural descriptions

**This command will NOT:**
- Add changelog-style entries
- Document every new function or file
- Create PRs when nothing is broken
- Add documentation for "completeness"

---

## Phase 1: Project Discovery

**Goal**: Map the project structure and locate all agent documentation

**Actions**:

1. Identify project root and verify it's a valid project:
   ```bash
   # Check for AGENTS.md or CLAUDE.md at root
   ls -la AGENTS.md CLAUDE.md 2>/dev/null
   
   # Check if CLAUDE.md is symlinked to AGENTS.md
   readlink CLAUDE.md 2>/dev/null
   ```

2. Find all AGENTS.md files in the project:
   ```bash
   fd -t f "AGENTS.md" --hidden --no-ignore
   ```

3. Build a documentation map:
   | File | Scope | Last Modified |
   |------|-------|---------------|
   | AGENTS.md | Project root | timestamp |
   | web/AGENTS.md | Web frontend | timestamp |
   | ... | ... | ... |

4. If `$ARGUMENTS` specifies a scope, filter to only that scope's AGENTS.md

---

## Phase 2: Change Detection

**Goal**: Identify what has changed since documentation was last accurate

**Actions**:

1. Get recent changes to understand what might have drifted:
   ```bash
   # Files changed in last 30 commits (adjust as needed)
   git log --oneline -30 --name-only --pretty=format: | sort | uniq -c | sort -rn | head -50
   
   # Or changes since a tag/date
   git diff --name-only $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~30) HEAD
   ```

2. Categorize changed files by relevance to each AGENTS.md scope:
   - **Root AGENTS.md**: Overall architecture, build commands, CLI usage, directory structure
   - **Scoped AGENTS.md**: Files within that directory tree

3. Create a focused change list:
   ```
   Changes relevant to AGENTS.md (root):
   - pkg/mcp/gateway.go (protocol bridge logic)
   - cmd/gridctl/deploy.go (CLI commands)
   - pkg/config/types.go (topology schema)
   
   Changes relevant to web/AGENTS.md:
   - web/src/components/graph/AgentNode.tsx
   - web/src/lib/api.ts
   ```

---

## Phase 3: Documentation Audit

**Goal**: For each AGENTS.md, verify claims against actual code

**CRITICAL**: Read the documentation carefully, then verify each factual claim.

**Actions for each AGENTS.md file**:

1. **Read the documentation** completely to understand what it claims

2. **Verify structural claims**:
   - Directory structure diagrams match reality
   - File paths mentioned actually exist
   - Package/module organization is accurate
   
   ```bash
   # Verify directory structure claims
   tree -L 2 -d --noreport
   
   # Check Go package structure
   ls -la pkg/ cmd/ internal/
   ```

3. **Verify code examples**:
   - Command examples still work
   - API signatures match actual function definitions
   - Configuration schemas match actual parsers
   
   ```bash
   # Check if documented Cobra commands exist
   rg "func.*Command" cmd/gridctl/ --type go
   
   # Verify struct fields match documentation
   rg "type.*struct" pkg/config/types.go -A 20
   
   # Check topology YAML schema matches docs
   rg "yaml:" pkg/config/types.go
   ```

4. **Verify behavioral claims**:
   - Documented defaults match code defaults
   - Documented flags/options actually exist
   - Documented environment variables are read
   
   ```bash
   # Check for documented env vars
   rg "os.Getenv|viper.Get" --type go
   
   # Verify CLI flags
   rg "\.Flags\(\)|\.PersistentFlags\(\)" cmd/gridctl/ --type go -A 5
   ```

5. **Verify references**:
   - Internal links point to existing files
   - Test file references are accurate
   - Example file paths exist

   ```bash
   # Check example files exist
   ls -la examples/getting-started/
   ls -la examples/transports/
   ```

---

## Phase 4: Problem Classification

**Goal**: Distinguish actual problems from non-issues

For each discrepancy found, classify it:

### Actual Problems (FIX THESE)

| Type | Example | Action |
|------|---------|--------|
| **Wrong** | Doc says `--verbose` but flag is `--debug` | Fix the documentation |
| **Broken** | Code example uses deleted function | Update the example |
| **Misleading** | Doc says "default port 8080" but code uses 8180 | Fix the default |
| **Stale** | Directory structure shows deleted package | Remove from diagram |
| **Incorrect signature** | Doc shows `func New(ctx)` but actual is `func New(ctx, opts)` | Update signature |

### Non-Problems (IGNORE THESE)

| Type | Example | Why Ignore |
|------|---------|------------|
| **Missing** | New helper function has no docs | Completeness isn't the goal |
| **Sparse** | Feature works but has minimal docs | Working > documented |
| **Style** | Could be explained better | Not incorrect |
| **Enhancement** | Could add more examples | Not a fix |

---

## Phase 5: Targeted Fixes

**Goal**: Fix only what is actually broken

**DO NOT PROCEED** if no actual problems were found. Report this and exit.

**Actions**:

1. For each actual problem identified:
   - Quote the incorrect documentation
   - Show the correct code/behavior
   - Propose the minimal fix

2. Group fixes by file (minimize number of edits)

3. Present fixes to user for approval:
   ```
   Found 3 issues in AGENTS.md:
   
   1. [WRONG DEFAULT] Line 45: "default port 8080" → should be "8180"
   2. [STALE PATH] Line 112: "pkg/server/handler.go" → file was moved to "internal/api/handler.go"
   3. [BROKEN EXAMPLE] Line 203: `make run-dev` → command is now `make dev`
   
   No issues found in web/AGENTS.md ✓
   
   Apply fixes? (y/n)
   ```

4. Apply approved fixes with atomic edits

---

## Phase 6: Validation

**Goal**: Confirm fixes are correct

**Actions**:

1. Re-read modified AGENTS.md files
2. Verify each fix addresses the identified problem
3. Ensure no new errors were introduced
4. Run any documented commands to verify they work:
   ```bash
   # Test documented build commands
   make build --dry-run 2>/dev/null || echo "Verify manually"
   
   # Verify Go builds
   go build ./cmd/gridctl/
   ```

---

## Phase 7: Report

**Goal**: Summarize what was done (or not done)

### If fixes were made:
```
## Sync Complete

### Files Updated
- AGENTS.md: 3 fixes applied
  - Corrected default port value
  - Updated moved file path
  - Fixed build command example

### Files Unchanged
- web/AGENTS.md: No issues found

### Verification
All documented commands tested successfully.
```

### If no fixes needed:
```
## Sync Complete

All AGENTS.md files are accurate. No changes needed.

### Verified
- AGENTS.md: 47 claims verified ✓
- web/AGENTS.md: 23 claims verified ✓
```

---

## Edge Cases

### Symlink Handling
If CLAUDE.md is symlinked to AGENTS.md:
- Only edit AGENTS.md (the source)
- Verify symlink is intact after edits
- Do not create duplicate content

### Scope Argument
If user provides `$ARGUMENTS`:
- `sync-gridctl web` → Only audit web/AGENTS.md
- `sync-gridctl pkg/mcp` → Find AGENTS.md in that path or nearest parent

### Large Projects
For projects with many AGENTS.md files:
- Process in dependency order (leaf nodes first)
- Report progress after each file
- Allow user to interrupt between files

---

## Anti-Patterns to Avoid

| Don't | Why |
|-------|-----|
| Add "Last updated: DATE" | Adds noise, quickly becomes stale |
| Document every new file | Not the goal of sync |
| Rewrite for "clarity" | Only fix incorrect, not unclear |
| Add TODO comments | Fix it or leave it |
| Create PR when nothing changed | Wastes review cycles |
| Add changelog entries | Use git history for that |
| Over-document simple things | Code is the source of truth |

---

## Success Criteria

The sync is successful when:

1. **Every factual claim** in AGENTS.md can be verified against code
2. **Every code example** runs without modification  
3. **Every file path** points to an existing file
4. **Every default value** matches the actual default in code
5. **Nothing was added** that wasn't fixing an error
