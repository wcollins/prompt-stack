# Feature Evaluation: Wizard Spec Completeness

**Date**: 2026-04-10
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

The visual spec-builder wizard supports 6 MCP server types but is missing critical fields for SSH (knownHostsFile, jumpHost), three of five OpenAPI auth types (OAuth2 CC, query-param, basic), and mTLS configuration — all of which are fully implemented in the backend. Because gridctl is the only GUI tool in the MCP ecosystem with SSH and OpenAPI server support, completing the wizard fulfills a unique and already-differentiated value proposition. The work is additive, low-risk, and follows established patterns throughout the codebase.

## The Idea

The spec-builder wizard guides users through creating MCP server configurations without editing YAML. It has forms for six server types, including SSH and OpenAPI. However, the SSH form exposes only 4 of 6 schema fields (missing `knownHostsFile` and `jumpHost`), the OpenAPI auth form covers only 2 of 5 auth types (missing OAuth2 CC, query-param, and basic), and the mTLS TLS block is entirely absent from the UI. Users who need these configurations hit dead ends and fall back to hand-editing YAML — defeating the purpose of the guided flow. PR #427 completed the backend support for all missing auth types in April 2026 but did not update the wizard.

**Advanced network mode** (the `networks[]` array in the YAML schema) is also absent from the wizard but is scoped as a follow-on due to higher UI complexity (toggle + dynamic array builder vs. simple field additions).

## Project Context

### Current State

gridctl is a Go/React production-grade MCP gateway aggregator. The backend is mature; the wizard is labeled experimental. The tech stack is React 19 + TypeScript 5.9 + Tailwind CSS v4 + Zustand + Vite. Frontend test coverage is strong (Vitest + React Testing Library). The codebase is clean, well-typed, and architecturally well-suited for these additions.

### Integration Surface

The changes are confined to four files:

- `web/src/components/wizard/steps/MCPServerForm.tsx` — primary form rendering (1,116 lines)
- `web/src/lib/yaml-builder.ts` — TypeScript interfaces + YAML serialization
- `web/src/__tests__/MCPServerForm.test.tsx` — form unit tests
- (Optional) `web/src/components/wizard/TransportAdvisor.tsx` — inline auth hints

### Reusable Components

- `Section` accordion component (MCPServerForm lines 169–211) — extend SSH and OpenAPI sections
- 2-column grid pattern (`grid grid-cols-2 gap-2`) — used for paired fields like host/user
- Conditional rendering on `data.openapi?.auth?.type` — extend for three new auth types
- `serializeArray` / `serializeMap` in yaml-builder.ts — for OAuth2 scopes serialization
- `KeyValueEditor` / `CommandArrayBuilder` — available for dynamic fields

## Market Analysis

### Competitive Landscape

No other MCP GUI tool exposes SSH or OpenAPI as configurable server types with form fields. The closest tools are:

- **LiteLLM**: Supports OAuth in its MCP form, but only for remote Streamable HTTP — not OpenAPI spec-to-tools
- **Copilot Studio**: Single-screen MCP form with transport + auth, but no OpenAPI spec type
- **Cursor / Claude Desktop**: Name+URL forms; everything else is JSON config files
- **mcp-manager / GUI variants**: Toggle-only; no transport/auth configuration

Among API client tools (Postman, Insomnia, Bruno, Hoppscotch), conditional field rendering per auth type is table stakes — a type dropdown that swaps visible fields is expected in any auth configuration form.

### Market Positioning

**Leap ahead.** gridctl already differentiates with SSH and OpenAPI server types in a guided wizard. Completing these forms extends a unique lead rather than catching up to anyone. The risk of not completing is reputational: a half-baked wizard is worse than no wizard, because it creates false expectations.

### Ecosystem Support

No external libraries needed. The form patterns and type-safe serialization are already in place. The backend schema (`OpenAPIAuth`, `OpenAPITLS`, `SSHConfig`) is the single source of truth — all field names and semantics are already documented in `docs/config-schema.md` and `examples/openapi/openapi-auth.yaml`.

### Demand Signals

- Community demand for SSH MCP tooling is high (7+ independent SSH MCP server implementations, multiple GitHub issues on SSH remote support in Cursor/Claude Code)
- OpenAPI-to-MCP tooling has strong traction (FastMCP, Stainless, AWS Labs, CNCF tooling)
- PR #427 itself (merged April 9, 2026) signals active investment in OpenAPI auth completeness at the backend level
- beta.3 CHANGELOG shows ongoing wizard fixes — the feature is actively being iterated

## User Experience

### Interaction Model

Users arrive at the SSH form or OpenAPI form through the existing wizard flow (type selection → template → configure → review). The new fields extend those existing forms. No new wizard steps are introduced.

- **SSH**: `knownHostsFile` and `jumpHost` appear below `identityFile` in the SSH config section, with helper text explaining each
- **OpenAPI auth**: The existing auth type dropdown gains three new options (`oauth2`, `query`, `basic`); selecting each reveals only the relevant fields
- **mTLS**: A new "TLS / mTLS" collapsible section appears below the auth section for all OpenAPI servers

### Workflow Impact

Reduces friction significantly for targeted users. Users who previously hit dead ends now complete their config in the wizard. Users on simple flows (bearer, no jump host) are unaffected — the new fields are conditional and only appear when relevant.

### UX Recommendations

1. **Extend SSH section in-place** — add `knownHostsFile` and `jumpHost` below `identityFile` with descriptive placeholders (`~/.ssh/known_hosts`, `[user@]bastion.example.com[:22]`) and `text-[10px] text-text-muted` helper text
2. **OAuth2 grouped sub-section** — display `clientIdEnv`/`clientSecretEnv` in a 2-column grid, `tokenUrl` full-width, `scopes` as a comma-separated or array-editor input
3. **Query auth** — 2-column grid with `paramName` + `valueEnv` (mirrors the header auth pattern)
4. **Basic auth** — 2-column grid with `usernameEnv` + `passwordEnv`
5. **mTLS as separate accordion** — `certFile`/`keyFile` in 2-column grid, `caFile` full-width, `insecureSkipVerify` toggle with a "Dangerous" warning badge
6. **No changes to YAMLPreview** — the generic key regex already handles new field names

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Hard dead-ends for SSH jump host and 3/5 OpenAPI auth types |
| User impact | Broad+Deep | Affects all users of SSH-relay and API-backed MCP stacks, not edge cases |
| Strategic alignment | Core mission | Wizard's purpose is no-YAML required; incomplete forms directly contradict this |
| Market positioning | Leap ahead | Only GUI tool with these server types; completion extends a unique lead |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | Backend complete, frontend work is additive field additions |
| Effort estimate | Small | ~4 files, established patterns throughout; OAuth2 sub-section most complex |
| Risk level | Low | No destructive changes, no migrations; worst case is a field mis-serializing |
| Maintenance burden | Minimal | Declarative form fields for stable protocols |

## Recommendation

**Build.** The backend work is done. The wizard is simply lagging. This is finishing work that was half-started, not new investment. The architecture is clean, the patterns are established, and the risk is low. Every day this gap exists, users who encounter it lose trust in the guided creation flow.

**Scope:** Primary PR covers SSH advanced fields (`knownHostsFile`, `jumpHost`) + all three missing OpenAPI auth types (OAuth2 CC, query-param, basic) + mTLS section. Advanced network mode (`networks[]` array with simple/advanced toggle) is scoped as a follow-on — it has higher UI complexity and different implementation concerns than the field additions.

## References

- [Bruno OAuth2 docs — client_assertion gap (Issue #5205)](https://github.com/usebruno/bruno/issues/5205)
- [Hoppscotch v2024.10.0: mTLS/client certificate support](https://hoppscotch.com/blog/hoppscotch-v2024-10-0)
- [Postman OAuth 2.0 Auth docs](https://learning.postman.com/docs/sending-requests/authorization/oauth-20)
- [Insomnia auth types reference](https://developer.konghq.com/insomnia/request-authentication/)
- [FastMCP OpenAPI integration](https://gofastmcp.com/integrations/openapi)
- [Progressive disclosure — NN/g](https://www.nngroup.com/articles/progressive-disclosure/)
- [gridctl PR #427: expand OpenAPI auth](https://github.com/wcollins/gridctl/pull/427)
- [Claude Code #9869: mTLS for SSE MCP](https://github.com/anthropics/claude-code/issues/9869)
