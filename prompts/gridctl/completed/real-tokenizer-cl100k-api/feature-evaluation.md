# Feature Evaluation: Real Tokenizer (cl100k + API)

**Date**: 2026-04-02
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

The heuristic 4-bytes/token counter in `pkg/token/counter.go` is not approximately accurate — it is wrong in opposite directions depending on content type, making it a correctness bug disguised as a precision trade-off. Replacing the default with an embedded cl100k_base tokenizer via `tiktoken-go` and adding an opt-in `gateway.tokenizer: api` mode that calls Anthropic's `count_tokens` endpoint is a minimal-risk, high-impact change that the codebase was architecturally prepared for before this evaluation began.

## The Idea

Replace `pkg/token/counter.go`'s `HeuristicCounter` (4 bytes/token) with a real BPE tokenizer as the default, and add an opt-in API-backed counter for exact Anthropic counts. This addresses two distinct problems:

**Problem 1 — Observability accuracy**: The heuristic overcounts ASCII/code by 40-60% and *undercounts* CJK/non-Latin text by 100-300% (in the wrong direction). Every number on the Metrics tab, every sparkline, and every "format savings" percentage is systematically wrong. Users enabling TOON or CSV based on this data are being misled. A cl100k_base tokenizer is a meaningful improvement for all content types even though it remains approximate for Claude 3+ (whose vocabulary is unpublished).

**Problem 2 — Exact cost analysis**: Some users want exact token counts for cost attribution. Anthropic's free `POST /v1/messages/count_tokens` endpoint provides this, but it is Anthropic-specific, requires network access, and is wrong for non-Anthropic models. This must be opt-in, not the default.

## Project Context

### Current State

gridctl is an MCP gateway/orchestrator (~v0.1.0-beta.4) that aggregates multiple MCP servers into a single endpoint. Token metrics are a first-class feature: the Metrics tab, sparklines, sidebar token usage widgets, and format savings percentages all derive from the `Counter` interface. The project is CGO-disabled (`CGO_ENABLED=0` in `.goreleaser.yaml`), has no AI/ML dependencies, and uses pure Go throughout.

### Integration Surface

The integration surface is deliberately narrow — the `Counter` interface was written with this swap in mind (the comment on line 7 of `counter.go` says so explicitly):

- `pkg/token/counter.go` — interface definition + heuristic impl (49 lines); add two new implementations here
- `pkg/controller/gateway_builder.go:352` — **sole instantiation point**: `token.NewHeuristicCounter(4)` → read `stack.Gateway.Tokenizer` and branch
- `pkg/config/types.go` — add `Tokenizer string` to `GatewayConfig` (matches pattern of `OutputFormat`, `CodeMode`)
- `internal/api/api.go` — extend `/api/status` response to include active tokenizer name
- `web/src/components/layout/StatusBar.tsx` — add tokenizer badge alongside existing CodeMode badge (identical pattern)

### Reusable Components

- `token.Counter` interface — no changes needed; the abstraction is correct
- `token.CountJSON` helper — works with any `Counter` implementation unchanged
- `GatewayConfig` defaults pattern in `pkg/config/types.go:SetDefaults()` — follow for `Tokenizer` default
- StatusBar CodeMode badge (lines 88-94) — copy pattern for tokenizer badge

## Market Analysis

### Competitive Landscape

No mainstream open-source MCP proxy implements an embedded tokenizer. The pattern is either (a) skip counting entirely and rely on structural optimizations, or (b) call the provider's token-counting API. LiteLLM and LangChain both treat the byte/char heuristic as a last-resort fallback of acknowledged low quality — LangChain's log message when it fires is literally "Failed to calculate number of tokens, falling back to approximate count."

### Market Positioning

Adding an accurate embedded tokenizer is a differentiator in the MCP proxy space (no comparable tool does this). The API mode matches what LiteLLM does as its primary path for supported providers.

### Ecosystem Support

- **`github.com/tiktoken-go/tokenizer`** — pure Go, no CGO, supports cl100k_base and o200k_base, ~4MB binary increase for vocab tables, actively maintained (GPT-5 support added August 2025), 426 stars. This is the only viable pure-Go option.
- **`github.com/pkoukk/tiktoken-go`** — older, no longer actively maintained. Not recommended.
- **Anthropic `POST /v1/messages/count_tokens`** — stable API (no beta header), free, returns exact counts, rate-limited (100 RPM tier 1). Official Go SDK (`github.com/anthropics/anthropic-sdk-go`) exposes `MessageService.CountTokens` but the SDK is a heavy dependency. The endpoint should be called via a lightweight direct HTTP call instead.

### Demand Signals

This item is ROADMAP #2, Tier 1. The ROADMAP entry uses the word "fabricated" to describe current token numbers and "misled" to describe the user impact. The CJK undercount alone (100-300% in the wrong direction) makes this a correctness bug with documented user harm.

## User Experience

### Interaction Model

**Default path (no config change required)**: Users get cl100k_base token counts automatically on next start. The Metrics tab shows more accurate numbers. A new badge in the StatusBar reads `cl100k` alongside the existing token counter, making the source transparent. No stack.yaml changes needed.

**Opt-in API path**: Users add `gateway.tokenizer: api` to stack.yaml. A `gateway.tokenizer_api_key` field allows explicit key override (otherwise the counter reads from `ANTHROPIC_API_KEY`). The StatusBar badge updates to `api`. Documentation clearly states this mode is Anthropic-specific, requires `api.anthropic.com` reachability, and is wrong for non-Anthropic model routing.

### Workflow Impact

Reduces friction for users trying to understand context window consumption and format savings ROI. Removes the active misinformation currently present in the Metrics tab. No existing workflow is disrupted — the default path is a drop-in replacement.

### UX Recommendations

1. **StatusBar badge**: Add a `cl100k` or `api` badge immediately adjacent to the token counter. Follow the identical pattern as the CodeMode badge (lines 88-94 of `StatusBar.tsx`). Makes tokenizer source transparent without cluttering.
2. **Status endpoint**: Extend `/api/status` to include `"tokenizer": "cl100k"` or `"tokenizer": "api"` in the gateway info block. Enables the frontend badge and informs external consumers.
3. **Counter package comment**: Add a comment in `counter.go` explaining that Claude 3+ vocabulary is unpublished, so cl100k_base is an approximation for Claude models specifically. Future maintainers need this context.
4. **Example stack.yaml**: Update `examples/gateways/gateway-basic.yaml` to document the `gateway.tokenizer` field with inline comments explaining the trade-off.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Critical | Wrong in opposite directions by content type; CJK direction inversion is a correctness bug |
| User impact | Broad+Deep | Every user of the Metrics tab; every TOON/CSV decision informed by format savings |
| Strategic alignment | Core mission | Token metrics and format savings are key differentiators; broken counts undermine the tab |
| Market positioning | Catch up + differentiate | Matches LiteLLM standard; exceeds all MCP proxy competitors (none do this) |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | 12-line interface; one instantiation point; zero consumer changes |
| Effort estimate | Medium | Phase 1 (embedded default): Small. Phase 2 (API opt-in): Small-Medium. Tests + docs: Medium |
| Risk level | Low | API counter is opt-in only; default path is a pure replacement behind a clean interface |
| Maintenance burden | Moderate | tiktoken-go needs updates for new encodings; API counter needs graceful error handling |

## Recommendation

**Build.** The Counter interface was written for this swap. The integration surface is as narrow as it gets — one file to modify per concern, one instantiation point to branch on. The value case is unusually strong: this is not an accuracy preference but a correctness bug that actively misleads users.

**Phased scope:**

- **Phase 1**: Add `tiktoken-go/tokenizer` dependency. Implement `TiktokenCounter` (pure Go, cl100k_base). Make it the default in `gateway_builder.go`. Add a `Tokenizer string` field to `GatewayConfig` defaulting to `"embedded"`. Add StatusBar badge. Update counter package comment to document Claude 3+ approximation.
- **Phase 2**: Implement `APICounter` using a lightweight direct HTTP call to `POST /v1/messages/count_tokens` (no Anthropic SDK dependency). Wire it when `gateway.tokenizer: api` is configured. Validate that an API key is available at startup; fail fast with a clear message if not. Document explicitly that this mode is Anthropic-specific.

Do not add the Anthropic SDK as a transitive dependency. The `count_tokens` call is a simple JSON POST; implement it directly in `pkg/token/` with `net/http` and `encoding/json` from stdlib.

## References

- [tiktoken-go/tokenizer — pure Go BPE tokenizer](https://github.com/tiktoken-go/tokenizer)
- [Anthropic token counting API docs](https://platform.claude.com/docs/en/build-with-claude/token-counting)
- [Anthropic tokenizer package deprecation notice](https://github.com/anthropics/anthropic-tokenizer-typescript)
- [LiteLLM token counting — heuristic fallback behavior](https://docs.litellm.ai/docs/count_tokens)
- [LangChain approximate count fallback issue](https://github.com/langchain-ai/langchain/issues/8675)
- [CJK token ratio analysis](https://tonybaloney.github.io/posts/cjk-chinese-japanese-korean-llm-ai-best-practices.html)
- [llm-calculator.com tokenization benchmarks](https://llm-calculator.com/blog/tokenization-performance-benchmark/)
- [Galileo blog — 37% miss example with emoji](https://galileo.ai/blog/tiktoken-guide-production-ai)
