# Feature Evaluation: Native MCP Security Scanning for gridctl

**Date**: 2026-05-05
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: Medium–High (strategic positioning)
**Effort**: Medium (4–8 weeks scoped to v1)

## Summary

Add MCP-traffic security scanning natively to gridctl's gateway: tool description scanning at `tools/list` (tool poisoning), pre-execution tool policy with regex + shell normalization, response prompt injection scanning on tool results, and a semantic-drift extension to the existing `pkg/pins/` schema-pinning surface (**MCP rug-pull detection** in industry terminology). Tool-call chain detection is deliberately deferred from v1.

The case is strategic, not demand-driven. Gridctl has 16 stars and zero external requests for this feature. But the threat surface is real (OWASP MCP Top 10, MITRE ATLAS AML.T0110, 30+ CVEs in early 2026), the OSS-gateway category is consolidating around shipping security baked-in, and there is no first-class OSS MCP gateway today that ships native scanning at this scope — peer offerings are either pure transport (Docker MCP Gateway, Toolhive, mcp-proxy) or commercial-tier (Lasso, Lunar.dev, Operant). Shipping native scanning would put gridctl alone in the OSS niche.

## The Idea

When MCP traffic flows through gridctl's gateway — `tools/list` aggregations, `tools/call` requests, and tool-call responses — scan it for the four highest-impact MCP threat classes:

1. **Tool poisoning** — instruction-injection payloads embedded in tool descriptions, parameter names, schema defaults, enum examples (Invariant Labs disclosed this attack class in April 2025; demonstrated on real public MCP servers).
2. **Pre-execution tool policy** — regex matches on tool name + argument values, with shell obfuscation normalization, to block or redirect dangerous operations (`rm -rf /`, `curl … | sh`, reverse-shell payloads, credential exfiltration patterns).
3. **Response prompt injection** — text patterns in tool results designed to override the agent's instructions (jailbreak templates, role override, credential solicitation, memory persistence).
4. **MCP rug-pull / semantic drift** — extend `pkg/pins/`'s existing TOFU hash-based drift detection so changes that introduce injection-style content in descriptions are flagged distinctly from benign edits. ("MCP rug-pull" is the term Invariant Labs and the broader research community use for this attack class.)

Who benefits: gridctl operators running multi-server stacks who currently have zero gateway-level defense against tool poisoning, malicious tool descriptions, or rug-pull attacks. Today the only options are deploying a separate firewall (mcp-context-protector, Snyk agent-scan, Cisco mcp-scanner) or running unprotected.

## Project Context

### Current State
Gridctl is an MCP gateway/aggregator at v0.1.0-beta.8. Active development: ~18 commits in the past week, recent feature work on telemetry persistence, autoscaling, replicas. Gateway is in `pkg/mcp/`; clean architecture with explicit extension interfaces.

Existing security surface (already shipped):
- **Schema pinning** (`pkg/pins/`): TOFU hash-based drift detection on tool definitions per server. Status states: pinned, verified, drift, new_tools, removed_tools. Wired into the gateway via `mcp.SchemaVerifier` interface (see `pkg/pins/adapter.go:GatewayAdapter`).
- **Skill scanning** (`pkg/skills/scanner.go`): regex-based pattern detection for dangerous shell patterns in skill workflows (curl|sh, eval $VAR, rm -rf /, reverse shells, etc.). Eight built-in patterns. Returns `[]SecurityFinding` with stepID, pattern, description, severity.
- **Tool allowlist** (`MCPServerConfig.Tools []string` in `pkg/mcp/gateway.go`): per-server whitelist of tool names; empty = all tools.
- **Vault** (`gridctl vault`): encrypted local secret storage with `${vault:KEY}` references in stack.yaml.
- **Logging redaction** (`pkg/logging/redact.go`): regex patterns for Authorization headers, bearer tokens, API keys.
- **Auth middleware** (`internal/api/auth.go`): bearer / API key with `ConstantTimeCompare`.

### Integration Surface
The MCP request flow is: HTTP handler → Router (namespace lookup) → ReplicaSet (health-based dispatch) → Downstream AgentClient (stdio / HTTP / SSH / OpenAPI / external) → Response → Format conversion → Metrics observer → Client.

The two natural integration points are inside `pkg/mcp/gateway.go`:
- **`HandleToolsList()`** (around line 1222) — point to scan tool descriptions/schemas for poisoning before returning the aggregated list.
- **`HandleToolsCall()`** (around line 1238) — point to apply pre-execution tool policy *before* `replica.Client().CallTool()`, and to scan response content *before* `applyFormatConversion()`.

### Reusable Components
- **`pkg/pins/`** — exact template for `pkg/security/`: store + types + adapter pattern. Status states (`pinned`, `drift`, etc.) generalize cleanly to security verdicts (`clean`, `warn`, `block`).
- **`pkg/skills/scanner.go`** — pattern-engine template for tool-name + arg matching (8 patterns ready to extend).
- **`mcp.SchemaVerifier` + `mcp.PinResetter` interfaces** — proves the extension pattern works; security scanner adopts the same contract.
- **`mcp.ToolCallObserver` interface** — post-execution hook already wired; security findings can ride alongside existing metrics.
- **`pkg/tracing/`** — security verdicts attach as span attributes; no new audit log infra needed.
- **Web UI `web/src/components/pins/`** — diff component reusable for description drift.
- **Web UI `web/src/components/graph/Canvas.tsx`** — existing canvas component; the per-server shield glyph attaches here, no new top-level component needed.
- **CLI `cmd/gridctl/pins.go`** — CLI shape template for `cmd/gridctl/scan.go`.
- **REST `internal/api/pins.go`** — REST shape template for `internal/api/security.go`.

## Market Analysis

### Competitive Landscape

**OSS gateways shipping no MCP-content scanning:** Docker MCP Gateway, Toolhive (Stacklok), Obot, mcp-proxy (sparfenyuk), mcpm. These compete on routing, RBAC, catalogs.

**OSS gateways shipping security:** Lasso Security MCP Gateway (prompt-injection plugin, tool description scanning, PII), MCP Manager (AI-powered tool change scanning), Lunar.dev MCPX (risk scoring + tool hardening), Operant AI (runtime threat detection — proprietary). Most are either partly commercial or behind a license tier.

**Dedicated MCP / agent firewalls (deployed separately, not bundled in a gateway):** Snyk agent-scan (acquired Invariant Labs' `mcp-scan` June 2025), Cisco mcp-scanner (YARA + LLM judge), Trail of Bits `mcp-context-protector` (response scanning + tool description scanning + TOFU drift; OSS reference implementation), Promptfoo MCP scanner, Lakera Guard, Knostic Kirin, Palo Alto Prisma AIRS (acquired Portkey).

### Market Positioning

In May 2026, MCP security scanning is **transitioning from differentiator to table-stakes for production-positioning gateways**. Commercial / enterprise tier ships it; OSS tier is split. Trail of Bits' open-source `mcp-context-protector` is the public reference implementation and forces the comparison.

Gridctl shipping native scanning would:
- Move it from "OSS gateways with nothing" tier to "OSS gateways with real security baked in" tier (Lasso, Lunar are the only current peers there, both partly commercial).
- Be benchmarked against `mcp-context-protector`; an honest "we cover poisoning + tool policy + injection scanning + drift" positions gridctl on par with or above it for the OSS gateway use case.
- Establish a defensible single-binary positioning: *the* OSS MCP gateway with security baked in, no second tool to deploy.

### Ecosystem Support
Available references for design:
- Trail of Bits `mcp-context-protector` (OSS, forces a comparison)
- Snyk `agent-scan` / Invariant `mcp-scan` (OSS rule sets and patterns to learn from)
- Cisco `mcp-scanner` (YARA-style rule format)
- OWASP MCP Top 10 official mitigations
- IETF `draft-sharif-mcps-secure-mcp-00` (tool-definition integrity, not yet a standard)

### Demand Signals

**Direct demand at gridctl scale: zero.** 16 stars, 1 human contributor, 0 external security feature requests. Schema pinning has no external usage signal either.

**Peer-gateway demand: thin.** Most "add scanning" issues on peer repos (Toolhive, Lasso) come from security-vendor business development, not end users.

**Real attacks: many.** OWASP MCP Top 10 published. MITRE ATLAS AML.T0110 added Jan 2026. CVE-2025-54136 (Cursor MCPoison), CVE-2025-6514 (mcp-remote RCE), Anthropic MCP design flaw (Apr 2026, ~200K servers). Invariant Labs tool-poisoning + WhatsApp rug-pull demos. The MCPTox academic benchmark found 5.5% of public servers exhibit tool-poisoning behavior.

The honest read: this is a strategic/positioning build, not a demand-driven one. Frame it that way — don't dress it up as filling a documented user gap, because the gap is undocumented.

## User Experience

### Interaction Model

Default user experience: zero new lines in `stack.yaml`, scanning runs automatically with `mode: warn`. After `gridctl apply stack.yaml`:
- **Clean stack:** one new line at the bottom — `security: 4 servers scanned, 142 tools pinned, 0 findings`. Canvas shows a green shield glyph per server node.
- **Finding-but-warn (default):** one yellow line — `security: 1 finding (warn) — github.search_code: tool description contains injection-style instruction. Run 'gridctl scan github' to inspect.` Canvas shows a yellow shield with a finding count badge. Tool calls still flow.
- **Finding-and-block (`mode: block` or per-rule override):** apply still completes; the offending tool is *quarantined* — added dynamically to the existing tool-allowlist exclusion. Canvas shows the tool greyed out behind a lock. The LLM sees the tool simply absent from `tools/list`. If it calls by name anyway, gateway returns synthetic JSON-RPC error: `tool unavailable: blocked by gridctl security policy (finding sec-2f1a)`.

Critical UX choice: **block by removing from `tools/list`, not by intercepting calls.** Reuses the existing tool-filter code path; no new failure mode for the LLM.

### Workflow Impact

The feature surfaces in three places, all reusing existing surfaces:
- **CLI:** new `gridctl scan` command modeled exactly on `gridctl pins`. Subcommands: `scan`, `scan ack`, `scan reset`, `scan report-fp`. Plus extending `gridctl traces --security` filter and a `SECURITY` column in `gridctl status`.
- **Web UI:** shield glyph on canvas server nodes (added to the existing `web/src/components/graph/Canvas.tsx`); Findings drawer in the sidebar (slot adjacent to existing Pins drawer); security verdicts as span annotations in the existing trace waterfall; reuse the pin-drift diff component for description drift.
- **stack.yaml:** new optional block under `gateway.security`. Common case: zero added lines (defaults work).

`apply`'s exit code remains 0 on findings; the gateway is up, just with quarantined tools. `gridctl status` reports `degraded` and reload prints the finding loud.

### UX Recommendations

1. **One `mode` knob covers 95% of users:** `off | warn | block | ask`. Default `warn`. The single biggest defense against config bloat.
2. **Block via dynamic allowlist, not call interception.** Reuses the existing `tools:` filter mechanism.
3. **Findings live exactly like pin drift.** `~/.gridctl/security/<stack>.json` mirrors `~/.gridctl/pins/`. Same diff component. Same `ack` semantics.
4. **Skip terminal HITL `ask` mode in v1.** Gridctl is daemonized; mid-`apply` stdin prompts would be the most un-gridctl thing in the feature. If implemented, route `ask` to a Web UI banner.
5. **Synthetic LLM error is one short sentence with a finding ID.** Verbose explanations go to operator surfaces, not into the model's context.

## Risk Mitigation: False Positives

Security scanning inherently carries the risk of false positives. They are the single most likely failure mode for this feature, and the one most likely to drive users to disable it entirely. Three mitigations are baked into v1:

1. **`mode: warn` default.** Every false positive in the default mode is a log line and a finding card — never a broken tool call. Operators get a chance to triage before any user-visible impact. Enabling `block` is an explicit, informed opt-in.

2. **Dual-view shell normalization.** When the tool-policy matcher checks an argument like `"echo ${HOME}"`, it matches against *both* the normalized form (`echo /Users/will`) and the raw form. A rule targeting `\brm\s+-rf\b` matches only the obfuscated `r${IFS}m${IFS}-rf${IFS}/` patterns it was designed to catch — not legitimate uses of `${HOME}`, `$IFS`, or brace expansion in safe commands. This is a well-known anti-FP technique in shell-pattern detection; documented in `feature-prompt.md` as a hard requirement.

3. **First-class FP feedback loop via `gridctl scan report-fp`.** Distinct from `scan ack` (which means "I've reviewed and accept this finding for now"), `scan report-fp <id>` is the explicit "this rule is wrong for this case" signal. It writes a `kind: false_positive` suppression entry with the rule name, server, tool, and detector context — and also surfaces these in `gridctl scan list-fp` so the maintainer can see which rules cause real-world FPs and tune the pattern library. This is the closed loop that prevents the feature from earning a "noisy" reputation.

4. **Pattern-library tuning is a release-cadence commitment, not a one-time build.** Each minor release reviews aggregated FP reports and either tightens the offending pattern, adds an exclusion, or splits the rule into more targeted forms. This is documented in the implementation prompt as part of v1's maintenance contract — not deferred.

If FPs become a problem operationally, the escape hatch is one config line: `gateway.security.mode: off`. Better that than a silent-pass scanner that pretends to be useful.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | OWASP MCP Top 10, MITRE ATLAS AML.T0110, 30+ MCP CVEs in 60 days, demonstrated tool-poisoning attacks against real servers |
| User impact | Narrow + Deep today | 16-star project; helps the maintainer + early adopters. Broader if gridctl grows. Honestly a strategic bet on trajectory |
| Strategic alignment | Core mission | Completes a security surface gridctl already has (pinning, skill scan, vault, allowlist). Not scope creep — completion |
| Market positioning | Catch up + Leap | Moves gridctl from "OSS gateway with nothing" tier to "OSS gateway with security baked in." Becomes the only first-class OSS MCP gateway with native scanning at this scope |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Clean seams exist (`SchemaVerifier`, `ToolCallObserver`); no architectural rewrite. Two integration points in `pkg/mcp/gateway.go` |
| Effort estimate | Medium | 4–8 weeks for v1 scope (poisoning + tool policy + response injection + drift extension; chain detection deferred). Greenfield: response scanner, shell normalization. Brownfield: extend `pkg/pins/` |
| Risk level | Medium | False positives are the primary failure mode. Mitigated by `mode: warn` default, dual-view normalization, FP feedback loop. Block-via-allowlist-removal de-risks the runtime path. Pattern-library maintenance is ongoing |
| Maintenance burden | Moderate–High | Pattern library updates, false-positive tuning. "gridctl said this tool is safe" becomes a security claim — that's a real ongoing commitment |

## Recommendation

**Build with caveats.**

### Build because:
- Strategic alignment is strong — completes a security trajectory gridctl is already on
- Market is tipping; OSS gateways shipping nothing will be benchmarked unfavorably against `mcp-context-protector`
- A clear, defensible niche: the only first-class OSS MCP gateway with native scanning at this scope
- Existing extension seams + reusable components (pins, skills scanner, tracing, vault) make this a moderate effort, not a large one
- Threat surface is concrete: real CVEs, real demonstrated attacks, named threats in OWASP MCP Top 10 + MITRE ATLAS

### Caveats:

1. **Scope-lock v1 to four pieces:**
   - Tool description scanning at `tools/list`
   - Pre-execution tool policy (regex tool-name + arg + shell normalization)
   - Response prompt injection scanning on tool results
   - Semantic drift extension to `pkg/pins/` (MCP rug-pull detection)

   **Defer chain detection** — Trail of Bits' published reference says wrapper-layer chain detection is hard to do well; complexity-to-value is poor for v1.

2. **Reuse aggressively, don't fork:**
   - `pkg/security/` mirrors `pkg/pins/` exactly (store + types + adapter)
   - Reuse `pkg/skills/scanner.go` regex pattern engine
   - Reuse the pin-drift Web UI diff component
   - Findings on existing trace spans
   - Vault for finding suppressions

3. **Honor gridctl's UX simplicity:**
   - One `mode` knob; one `policy:` list; flat shape; no DSL
   - Four CLI commands, modeled on `pins`: `scan`, `scan ack`, `scan reset`, `scan report-fp`
   - Block by removing from `tools/list`, not by intercepting calls

4. **Default to `warn`, not `block`.**

5. **Invest in the FP feedback loop from day one.** `scan report-fp` is not a v2 feature; it's a v1 requirement. The pattern library will be wrong; design for that explicitly.

6. **Acknowledge the demand reality internally.** This is a strategic build, not a user-pull build. Don't over-invest in v1 scope chasing imagined demand.

## References

- [OWASP MCP Top 10](https://owasp.org/www-project-mcp-top-10/)
- [OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)
- [Invariant Labs: MCP Tool Poisoning Attack](https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks)
- [Trail of Bits: We built the security layer MCP always needed](https://blog.trailofbits.com/2025/07/28/we-built-the-security-layer-mcp-always-needed/)
- [CyberArk: Poison Everywhere — no output from your MCP server is safe](https://www.cyberark.com/resources/threat-research-blog/poison-everywhere-no-output-from-your-mcp-server-is-safe)
- [The Hacker News: Anthropic MCP design vulnerability (April 2026)](https://thehackernews.com/2026/04/anthropic-mcp-design-vulnerability.html)
- [MCPTox arXiv benchmark](https://arxiv.org/html/2508.14925v1)
- [Vulnerable MCP Project](https://vulnerablemcp.info/)
- [CVE-2025-54136 (Cursor MCPoison)](https://nvd.nist.gov/vuln/detail/CVE-2025-54136)
- [GHSA-6xpm-ggf7-wc3p (mcp-remote RCE)](https://github.com/advisories/GHSA-6xpm-ggf7-wc3p)
- [MITRE ATLAS](https://atlas.mitre.org/)
- [IETF draft-sharif-mcps-secure-mcp-00](https://datatracker.ietf.org/doc/draft-sharif-mcps-secure-mcp/)
- [Modelcontextprotocol.io security best practices](https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices)
- [Authzed: Timeline of MCP breaches](https://authzed.com/blog/timeline-mcp-breaches)
- [Obot: 13 best MCP gateways for enterprise](https://obot.ai/blog/the-13-best-mcp-gateways-for-enterprise-teams/)
