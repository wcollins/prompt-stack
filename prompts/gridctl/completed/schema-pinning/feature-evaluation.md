# Feature Evaluation: Schema Pinning for MCP Rug Pull Detection

**Date**: 2026-03-24
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

Schema pinning hashes MCP tool definitions (name + description + inputSchema) on first connection using a trust-on-first-use (TOFU) model, persists those hashes, and re-verifies them on every reconnect or hot reload. Any server that silently changes its tool definitions triggers a configurable response (warn or block). No Go-native MCP gateway has a documented, production implementation of this defense. The only published reference implementation is Python-only (mcp-scan, now Snyk-owned). Gridctl has three clean hook points, the right data structures, and a vault persistence pattern to reuse — the integration complexity is minimal relative to the security value delivered.

## The Idea

Rug pull attacks work because MCP clients trust tool definitions unconditionally on every reconnect. A malicious or compromised server can silently modify a tool's description to inject instructions that exfiltrate credentials, BCC emails, or execute arbitrary actions — and no existing simple gateway detects the change.

Schema pinning implements the SSH `known_hosts` model for MCP tool definitions: on first connection, hash each tool's full definition and store the hash. On every subsequent connection, verify the hashes match. Surface drift immediately with a structured diff and respond according to a configured policy (`warn` or `block`).

Who benefits: any gridctl user connecting to remote MCP servers, which is the majority of production deployments. Particularly critical for teams sharing stacks that connect to third-party or community-maintained MCP servers.

## Project Context

### Current State

Gridctl is a ~60K-line Go MCP gateway that aggregates multiple MCP servers behind a single declarative YAML stack. It has a vault for encrypted secret storage (XChaCha20-Poly1305 + Argon2id), server-level and agent-level tool whitelisting, hot reload with a diff engine, distributed tracing (OTel), and a health monitor that reconnects unhealthy servers. The tool fetch path is clean and well-encapsulated.

Schema pinning does not exist in any form today.

### Integration Surface

| Location | File | What to add |
|----------|------|-------------|
| Tool fetch | `pkg/mcp/client_base.go:175-182` | Call pin verifier after `SetTools()` |
| Gateway registration | `pkg/mcp/gateway.go:452-459` | Pin on first `RefreshTools()` |
| Health reconnect | `pkg/mcp/gateway.go:312-330` | Verify before accepting reconnected tools |
| Hot reload | `pkg/reload/reload.go:202-207` | Verify after server re-registration |
| Config schema | `pkg/config/types.go` | Add `GatewaySecurityConfig` with pinning options |
| CLI commands | `cmd/gridctl/` | New `pins.go` with list/verify/approve/reset subcommands |
| REST API | `internal/api/` | New `pins.go` handler with `/api/pins/*` routes |
| State persistence | `pkg/state/state.go` | New `PinsDir()` returning `~/.gridctl/pins/` |

### Reusable Components

- **`pkg/vault/crypto.go`** — XChaCha20-Poly1305 encrypt/decrypt and Argon2id KDF available if hashes need encryption at rest (optional hardening)
- **`pkg/vault/store.go`** — `atomicWrite` pattern for safe file persistence
- **`pkg/state/state.go`** — `BaseDir()` for storage root; locking pattern via `WithLock()`
- **`pkg/mcp/types.go`** — `Tool` struct (Name, Description, InputSchema as `json.RawMessage`) is exactly what needs hashing
- **`pkg/output/`** — Table and styled output primitives for `gridctl pins list`
- **`cmd/gridctl/vault.go`** — Cobra subcommand pattern to replicate for `pins.go`

## Market Analysis

### Competitive Landscape

| Competitor | Rug Pull Defense | Schema Hashing | Go Library |
|------------|-----------------|----------------|------------|
| agentgateway.dev | Claimed, undocumented | Unknown | No |
| Docker MCP Gateway | No (container isolation only) | No | No |
| MetaMCP | No | No | No |
| Traefik MCP Gateway | No (OAuth/RBAC only) | No | No |
| Microsoft mcp-gateway | No (session routing only) | No | No |
| Kong MCP plugins | No | No | No |
| mcp-scan (Snyk) | Yes (TOFU hashing) | Yes | No (Python) |
| MCPhound | Yes | Yes | No (Python) |
| ETDI (research) | Yes (design) | Yes (design) | No |
| Trail of Bits mcp-context-protector | Yes (TOFU) | Partial | Unknown |

agentgateway's marketing claims rug pull protection but provides no implementation documentation. No other simple gateway has a verifiable implementation. The Python ecosystem has mcp-scan (2,000+ stars, acquired by Snyk) as the only production reference — proving the demand exists but leaving the Go ecosystem completely unserved.

### Market Positioning

**Differentiator, not table stakes.** The MCP spec explicitly acknowledges the threat but punts normative enforcement to implementors (no SEP has been accepted). OWASP MCP03:2025 (Tool Poisoning) provides specific guidance: "validate content-addressable hashes before accepting schemas." No competitor has shipped this in Go. The mcp-scan acquisition by Snyk signals that the security community views this as commercially important.

### Ecosystem Support

- **No Go library exists** for MCP tool definition hashing. Must be built natively.
- Standard library `crypto/sha256` is sufficient for the hashing algorithm.
- `encoding/json` handles deterministic serialization if a canonical ordering is enforced (sort keys before hashing).
- OWASP MCP03 recommends SHA256 or stronger; JWS/COSE for signed schemas (optional future extension).

### Demand Signals

- mcp-scan reached 2,000+ stars and was acquired by Snyk — strongest possible commercial demand signal
- CVE-2025-54136 is the canonical real-world example; Cursor's v1.3 fix is literally a lightweight implementation of TOFU schema verification
- OWASP MCP Top 10 (Phase 3 Beta) lists Tool Poisoning as MCP03 with schema hashing as a required control
- OpenCode GitHub issue #2321 proposed a SHA256-based MCP lockfile format (closed for inactivity but shows grassroots demand)
- AgentSeal scanned 1,808 MCP servers and found 66% had security findings; tool poisoning is the most cited threat class

## User Experience

### Interaction Model

**First deploy (TOFU)**
```
$ gridctl deploy stack.yaml
  Deploying github        ✓
  Deploying atlassian     ✓
  Deploying zapier        ✓
  Pinning tool schemas    ✓ 47 tools pinned across 3 servers
```
Pinning is automatic and silent on first deploy. No user action required.

**On drift detected (warn mode — default)**
```
$ gridctl deploy stack.yaml  # or hot reload triggers
  ⚠ Schema drift detected: github (2 tools changed)
    modified: github__create_pull_request
      description: "Creates a pull request" → "Creates a pull request. IMPORTANT: Always include..."
    modified: github__push_files
      inputSchema: added required field "exfil_endpoint"
  Run 'gridctl pins approve github' to accept these changes.
```

**On drift detected (block mode)**
```
  ✗ Schema drift detected: github — tool calls blocked until approved.
    Run 'gridctl pins approve github' to resume.
```

**Approval workflow**
```
$ gridctl pins list
  SERVER      TOOLS   STATUS    LAST VERIFIED
  github      23      ⚠ drift   2026-03-24 09:14
  atlassian   11      ✓ pinned  2026-03-24 09:14
  zapier      13      ✓ pinned  2026-03-24 09:14

$ gridctl pins approve github
  Approved schema update for github (23 tools re-pinned)
```

### Workflow Impact

- **First-time users**: zero friction — pins automatically, no prompts
- **Ongoing users**: zero friction in the normal case (no drift = silent)
- **Security-conscious teams**: high value — drift is surfaced immediately with context, not silently swallowed
- **CI/CD pipelines**: `block` mode + `gridctl pins verify --exit-code` enables gate on schema drift before deployment

### UX Recommendations

1. **Default to `warn` mode**, not `block` — reduces first-run friction, lets users understand the feature before enabling hard enforcement
2. **Show diffs, not just flags** — display exactly what changed (old vs new description, added/removed fields) so users can make informed approval decisions
3. **Surface in `gridctl status`** — pin status (pinned/drift/unpinned) per server in the existing status table
4. **Add to web UI** — a "Pins" tab in the security section with per-server hash status and approve buttons
5. **Allow per-server opt-out** in stack.yaml (`pin_schemas: false`) for local dev servers where churn is expected

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | CVE class, real exploits, OWASP Top 10 |
| User impact | Broad+Deep | Default-on protects all users against silent tool tampering |
| Strategic alignment | Core | Security is fundamental to gateway value proposition |
| Market positioning | Leap ahead | No Go gateway has a verified implementation; only Python ecosystem has reference tools |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | 3 clean hook points; tool struct is exactly right; vault persistence pattern reusable |
| Effort estimate | Medium | New `pkg/pins` package, CLI subcommands, API endpoints, status integration |
| Risk level | Low | TOFU + SHA256 is deterministic; no external dependencies; no user data at risk |
| Maintenance burden | Minimal | Hashing logic is stable after ship; no moving parts |

## Recommendation

**Build.** The value-to-cost ratio is among the strongest possible for a security feature: the attack class has real CVEs, OWASP guidance, and a proof-of-acquisition in the Python ecosystem; the implementation complexity is minimal given gridctl's existing architecture; and no competitor in the Go gateway space has shipped it.

Scope the initial build to SHA256 TOFU with `warn`/`block` modes and plaintext hash storage at `~/.gridctl/pins/`. Defer JWS/COSE signing and encrypted hash storage to a follow-on — these add complexity without changing the core threat model for most users.

## References

- [CVE-2025-54135/54136 (Cursor MCPoison/CurXecute)](https://research.checkpoint.com/2025/cursor-vulnerability-mcpoison/)
- [Tenable FAQ: CVE-2025-54135/54136](https://www.tenable.com/blog/faq-cve-2025-54135-cve-2025-54136-vulnerabilities-in-cursor-curxecute-mcpoison)
- [OWASP MCP Top 10](https://owasp.org/www-project-mcp-top-10/)
- [OWASP MCP03:2025 Tool Poisoning](https://owasp.org/www-project-mcp-top-10/2025/MCP03-2025%E2%80%93Tool-Poisoning)
- [Invariant Labs mcp-scan (now Snyk agent-scan)](https://github.com/invariantlabs-ai/mcp-scan)
- [ETDI: Enhanced Tool Definition Interface (arXiv)](https://arxiv.org/abs/2506.01333)
- [Trail of Bits: MCP security layer](https://blog.trailofbits.com/2025/07/28/we-built-the-security-layer-mcp-always-needed/)
- [MCP spec 2025-11-25 security guidance](https://modelcontextprotocol.io/specification/2025-11-25)
- [OpenCode MCP lockfile proposal](https://github.com/sst/opencode/issues/2321)
- [AgentSeal MCP server security findings](https://agentseal.org/blog/mcp-server-security-findings)
