# Feature Evaluation: Enhanced Sidebar Metadata (Variable Set Recency)

**Date**: 2026-05-23
**Project**: gridctl
**Recommendation**: **Defer** the backend-timestamp version · **Build with caveats** the zero-backend "recently edited" dot
**Value**: Low (timestamp) / Medium (recency dot)
**Effort**: Medium (timestamp) / Small (recency dot)

## Summary

The originally-requested feature had two parts. The first — **show a variable count per set** — already ships today in every surface that renders sets, so it is out of scope. The second — a **per-set "Last Updated" / recently-modified indicator** — does not exist and would require adding timestamps to the encrypted vault schema (a v2→v3 migration). Research across the market and the codebase converged on the same conclusion: a real per-set timestamp is **low-value, medium-cost, and without market precedent**, but a much smaller win hides inside the request — a **session-scoped "recently edited" dot** that needs zero backend work and captures the one genuinely actionable slice of recency ("where did the edit I just made land?"). Recommendation: defer the timestamp, ship the dot.

## The Idea

> Improve visibility of variable-group details in the sidebar navigation: show the count of variables per set (e.g. `dev (5)`), and optionally surface a "Last Updated" hint or visual indicator for sets containing recently-modified variables.

**Who benefits**: users of the Variables sidebar panel and the Variables workspace who manage multiple named sets of secrets/config and want at-a-glance context without expanding each set.

## Project Context

### Current State

gridctl is a local MCP gateway control plane (Go backend + React/TS web UI). The "Variables" feature (formerly "vault") is a unified store of secrets + plaintext config, organized into named **Sets**. Variables are rendered in three surfaces, all sharing components and a single data hook:

- **Sidebar panel** — `VaultPanel.tsx` → `SetGroup.tsx`
- **Variables workspace** — `VaultWorkspace.tsx` → `SetPill`
- **Detached `/var` page** — `DetachedVaultPage.tsx` → `SetGroup.tsx`

The most recent vault work (PR #703, merged 2026-05-23) added a "used-by" badge surfacing which stack resources reference each variable — establishing both the metadata-on-rows direction this request fits, and a clean badge pattern to mirror.

### Existence check: the count already ships

Part one of the request is **already implemented**. Every set row renders its member count:

- `web/src/components/vault/SetGroup.tsx:75-77` — count pill next to the set name (sidebar + detached page)
- `web/src/components/workspaces/VaultWorkspace.tsx:761` — `SetPill count={set.count}`
- Backend: `pkg/vault/types.go:37` `SetSummary{ Count int }` → TS `VariableSet.count` (`web/src/lib/api.ts:551`)

The only difference from the spec is cosmetic: it's a styled pill (`dev` ⟦5⟧), not the literal `dev (5)` parenthetical. No work is needed here beyond an optional restyle.

### Integration Surface (recency, the part that doesn't exist)

- **Data model gap**: `Variable` (`pkg/vault/types.go:19`) and `Set`/`SetSummary` (`types.go:28-38`) carry **no timestamp**. The only time signal is `s.mtime` (`pkg/vault/store.go`), the whole-*file* modification time used for stale-cache detection — identical for every set, so useless as a per-set discriminator.
- **Frontend mutation chokepoint**: `web/src/hooks/useVaultManager.ts` is the single source of truth feeding all three surfaces. Every mutation (`createVar`, `updateVar`, `deleteVar`, `assignToSet`, `importVars`) routes through it and calls `refresh()`. This is the natural place to record "just edited" keys.
- **Shared store**: `web/src/stores/useVaultStore.ts` (Zustand) is consumed by both component trees — the right home for session-scoped "recently edited" state so the dot is consistent across sidebar and workspace.

### Reusable Components

- **"used-by" badge** (`web/src/components/vault/SecretItem.tsx:181-204`) — the design precedent. Key principle baked into its comments: *absence is the signal* (renders only when there's something to show). Tokens: `text-[10px] font-mono px-1.5 py-0.5 rounded`, `bg-secondary/10 text-secondary`, tiny icons `size={9-10}`.
- **`formatRelativeTime`** (`web/src/lib/time.ts:5`) — exists, but **caps at hours** (no day/week bucket); a 3-day-old set would render `"72h ago"`. Would need extending before any real timestamp use.

## Market Analysis

### Competitive Landscape

Per-item "last modified" recency, where tools surface it:

- **Show it in-list**: GitHub Actions (an "Updated" column), AWS Secrets Manager ("Last retrieved" column + `LastChangedDate` API), Vercel (sort by last-updated).
- **Detail page only**: HashiCorp Vault (KV metadata tab), 1Password ("last edited" + sort), Google Secret Manager, Azure Key Vault, Infisical (version history).
- **Don't show it at all**: GitLab CI/CD variables (open feature request #460761), CircleCI (unaddressed request), Netlify (audit log only).
- **Deliberately hidden**: Doppler ships per-secret age but **defaults it off behind a toggle** to manage list clutter.

### Market Positioning

**Nice-to-have, not table-stakes.** Multiple mature tools (GitLab, CircleCI, Netlify) ship without any variable recency at all. The decisive finding: **recency is almost universally per-item** — across 10+ surveyed tools, *none* surface an aggregate "last updated" at the folder/group level. The proposed per-*Set* timestamp is essentially without precedent: a mild differentiator at best, but unvalidated by prior art, and the tool closest to the idea (Doppler) deliberately defaults recency off.

### Ecosystem Support

No library is relevant — this is a domain-specific data-model + UI concern. The reference signal is GitHub Actions' per-item "Updated" column (the clearest "recency in list" precedent), which is *item-level*, not the group-level aggregate proposed here.

### Demand Signals

Demand for *item-level* recency exists (open requests against GitLab and CircleCI). There is **no observed demand for group-level recency aggregation** — no tool ships it, no request found for it.

## User Experience

### Interaction Model

A set-level "Last Updated" timestamp would appear on each (collapsed) set row, alongside the existing name + count pill + hover-revealed delete affordance.

### Workflow Impact

Three problems make the always-on timestamp a net negative:

1. **The aggregate is misleading.** "Updated 2h ago" on a folder reads as "the set was reconfigured," but it would actually mean one unnamed member's value changed. Count works as a whole-set aggregate because count *is* a set property; recency is a per-member property being collapsed onto the container.
2. **Recency isn't actionable for secrets.** Unlike server health ("is it alive?") or pin verification ("has upstream drifted?"), an old variable is *normal and good* — stable config and long-lived tokens are supposed to sit untouched. The one genuinely useful recency moment is transient: *"I just edited something — where did it land?"*
3. **It fights the codebase's conventions.** Relative time appears in exactly two places today — server "Last Check" (`Sidebar.tsx:257`) and pins "Last Verified" (`PinsPanel.tsx:78`) — both in *expanded panels or table columns*, never on a dense list row. And `formatRelativeTime` would emit absurd hour counts for old config.

### UX Recommendations

Skip the per-row timestamp. Ship a **session-scoped "recently edited" dot** next to the count pill on both `SetGroup` (sidebar) and `SetPill` (workspace):

- A small `bg-secondary/70` dot (`size-1.5 rounded-full`) appears on a set when any of its member variables were created/edited/imported/reassigned in the current session.
- Uses the set-identity color (`secondary`), so it reads as "activity here," not error/status.
- Carries `title="Recently edited"` + `aria-label` (never color-only).
- Clears on vault lock and page reload — it's a "since you last looked" hint, not persisted state.
- Honors the codebase's "absence is the signal" rule: nothing renders for sets with no recent edits.

This delivers the *only* actionable slice of recency, sidesteps the misleading-aggregate problem, and needs **zero backend work** because `useVaultManager` already knows which keys were just mutated.

## Feasibility

### Value Breakdown (per-set timestamp, as originally requested)

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Minor | Recency isn't actionable for stable secrets |
| User impact | Narrow + Shallow | Passive hint; unlocks no decision |
| Strategic alignment | Adjacent | Fits #703 "surface metadata" direction, but not core |
| Market positioning | Maintain | No competitor does group-level recency; nothing to catch up to |

### Cost Breakdown (per-set timestamp, as originally requested)

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Significant | Touches the encrypted vault schema (v2→v3 + migration) |
| Effort estimate | Medium | ~500–700 LoC; 8 write sites; ~40 tests; 3–4 days |
| Risk level | Medium | Backfill of pre-upgrade files loses real history; mutating a security-sensitive store |
| Maintenance burden | Moderate | New schema version + timestamp invariants to keep correct |

### Cost Breakdown (the recommended "recently edited" dot)

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Frontend-only; one Zustand field + two render sites |
| Effort estimate | Small | ~half a day incl. tests |
| Risk level | Low | No backend, no schema, no persisted state |
| Maintenance burden | Minimal | Self-contained session state |

## Recommendation

**Defer** the backend-timestamp version. It is low-value (recency isn't actionable for secrets; no competitor surfaces group-level recency; the aggregate is semantically misleading) and medium-cost (a migration of an encrypted, security-sensitive store). Per the cost/value weighting, medium effort does not justify low value.

Revisit the full timestamp only if a concrete need emerges — e.g. an audit/compliance requirement for per-variable change history, or sortable "last updated" in the workspace at item level (matching GitHub Actions' precedent). At that point, do it *properly*: per-variable `updated_at` in the schema, extend `formatRelativeTime` with day/week buckets, and surface the value in an expanded/detail surface rather than the collapsed row.

**Build with caveats** the session-scoped "recently edited" dot instead. It captures the single actionable moment of recency for near-zero cost and risk, fits the existing badge conventions, and improves the sidebar exactly where the original request aimed — without the schema migration. The implementation prompt for this is in `feature-prompt.md` alongside this evaluation.

## References

- GitHub Actions secrets/variables ("Updated" column): https://docs.github.com/en/rest/actions/secrets
- AWS Secrets Manager list view / API: https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_ListSecrets.html
- Doppler secrets (age toggle, default off): https://docs.doppler.com/docs/secrets
- HashiCorp Vault KV metadata: https://developer.hashicorp.com/vault/docs/commands/kv/metadata
- 1Password sort-by-date request: https://1password.community/discussion/136470/sorting-passwords-by-date-modified
- GitLab "last updated for CI/CD variables" request (#460761): https://gitlab.com/gitlab-org/gitlab/-/issues/460761
- CircleCI env-var change-log request: https://discuss.circleci.com/t/history-or-change-log-for-environment-variables/36100
- Vercel env var management: https://vercel.com/docs/environment-variables/managing-environment-variables
- Netlify env vars (audit-log only): https://docs.netlify.com/build/environment-variables/overview/
