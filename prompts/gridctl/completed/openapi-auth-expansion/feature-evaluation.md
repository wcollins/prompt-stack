# Feature Evaluation: OpenAPI Auth Expansion

**Date**: 2026-04-09
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium

## Summary

Expand gridctl's OpenAPI client authentication from bearer + header-only to include OAuth2 client credentials, query-parameter API keys, and mTLS. The current gap directly blocks the most common enterprise API auth pattern (OAuth2 CC) and the most common public API auth pattern (query-param API keys), making the OpenAPI gateway feature only usable for a fraction of real-world APIs. The implementation path is clean and low-risk, using the standard Go `x/oauth2/clientcredentials` library and stdlib `crypto/tls`.

## The Idea

The `OpenAPIClientConfig` in `pkg/mcp/gateway.go` and the `OpenAPIAuth` struct in `pkg/config/types.go` support two auth schemes: bearer token (static) and custom header. Three major categories of real-world API auth are unimplemented:

- **OAuth2 client credentials** — the dominant enterprise API auth pattern (Salesforce, Microsoft Graph, Workday, ServiceNow). Requires a token fetch against a `tokenUrl` with `clientId`/`clientSecret`, then injects a short-lived bearer token.
- **Query-parameter API keys** — used by most public data APIs (weather, geo, finance). The API key is appended as a URL query parameter (e.g., `?api_key=xxx`) rather than a header.
- **mTLS (mutual TLS)** — transport-layer client authentication with certificates. Required by financial services APIs (FAPI profiles), zero-trust enterprise environments.

Additionally, the OpenAPI spec already carries `components.securitySchemes` metadata that declares what auth the API requires — but gridctl never reads it, requiring fully manual auth configuration.

## Project Context

### Current State

gridctl is a production-ready MCP gateway CLI (v0.x stable) that aggregates multiple downstream MCP servers into one endpoint. The OpenAPI gateway transforms OpenAPI operations into MCP tools, proxying tool calls as HTTP requests. Auth is applied at request time via `applyAuth()` — a 12-line switch statement with two cases.

Auth config flows: YAML `auth:` block → `config.OpenAPIAuth` → `server_registrar.buildOpenAPIConfig()` (env var resolution) → `mcp.OpenAPIClientConfig` → `OpenAPIClient.applyAuth()`.

No `securitySchemes` parsing occurs today, despite kin-openapi's `openapi3.SecurityScheme` struct exposing all necessary fields (`Type`, `In`, `Name`, `Flows.ClientCredentials.TokenURL`, etc.).

### Integration Surface

| File | Change |
|------|--------|
| `pkg/config/types.go` | Add OAuth2 fields + new `OpenAPITLS` struct to `OpenAPIAuth`/`OpenAPIConfig` |
| `pkg/config/validate.go` | Extend validation for new auth types and TLS config |
| `pkg/mcp/gateway.go` | Add OAuth2/TLS fields to `OpenAPIClientConfig` |
| `pkg/controller/server_registrar.go` | Resolve new env vars in `buildOpenAPIConfig()` |
| `pkg/mcp/openapi_client.go` | Add `tokenSource`, `tlsConfig` fields; extend `NewOpenAPIClient()` and `applyAuth()` |
| `pkg/mcp/openapi_client_test.go` | New tests for each auth type |
| `tests/integration/openapi_test.go` | Integration tests with mock token endpoint and mTLS server |
| `docs/config-schema.md` | Document all new auth types |
| `examples/openapi/openapi-auth.yaml` | Expand with OAuth2, query, mTLS examples |

### Reusable Components

- `kin-openapi` (`github.com/getkin/kin-openapi`) — already parses `securitySchemes`; `openapi3.SecurityScheme.Flows.ClientCredentials.TokenURL` maps directly to OAuth2 config
- `golang.org/x/crypto` — already a dependency; `crypto/tls` stdlib handles mTLS without new deps
- `expandEnvVars()` / `os.Getenv()` — existing pattern for resolving credentials from environment
- `httptest` + existing test helpers — integration test infrastructure already handles mock HTTP servers

## Market Analysis

### Competitive Landscape

| Tool | Bearer | Header | Query Param | OAuth2 CC | mTLS | Auto-detect from spec |
|------|--------|--------|-------------|-----------|------|-----------------------|
| gridctl (current) | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| jedisct1/openapi-mcp (Rust) | ✅ | ✅ | ✅ | ❌ (pre-fetched only) | ❌ | Partial |
| awslabs/openapi-mcp-server (Python) | ✅ | ✅ | ✅ | ✅ (Cognito-specific) | ❌ | ❌ |
| ivo-toby/mcp-openapi-server (TS) | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ |
| oapi-codegen (Go) | ✅ | ✅ | ✅ | ❌ (no built-in flow) | ❌ | Partial |

### Market Positioning

- **Query-param API key**: Table stakes. Every major API client tool (Postman, Insomnia, Bruno) attempts this and has bugs doing it — gridctl's gap is not unique but is expected functionality.
- **OAuth2 client credentials with full token fetch**: Differentiator. Only awslabs' tool does it end-to-end, and it's Cognito-specific. A generic implementation with any `tokenUrl` would be ahead of the field.
- **mTLS**: Catch-up to ivo-toby's Node.js server; differentiator in the Go MCP space.

### Ecosystem Support

- `golang.org/x/oauth2/clientcredentials` — canonical Go package. `Config.TokenSource(ctx)` returns an `oauth2.TokenSource` that auto-refreshes tokens on expiry. `oauth2.Transport{Source: tokenSource}` injects `Authorization: Bearer` transparently via `http.RoundTripper`. No new third-party dep needed.
- `crypto/tls` (stdlib) — `tls.LoadX509KeyPair` + `tls.Config{Certificates: ...}` handles mTLS with zero new deps.
- `kin-openapi` `openapi3.SecurityScheme` — already parsed and available at `doc.Components.SecuritySchemes` post-`Initialize()`. The spec's `securitySchemes` data is ready to drive auto-detection in a future phase.
- MCP spec SEP-1046 (accepted) — defines OAuth2 client credentials as the server-to-server standard for MCP. Implementing it positions gridctl ahead of go-sdk (issue #627, open) and ahead of the field.

### Demand Signals

- oapi-codegen issue #1524 ("first-class auth support") is open and active
- MCP go-sdk issue #627 ("ext-auth: OAuth Client Credentials") open and actively discussed
- Bruno issue #5264 (securitySchemes import, P1), Insomnia issue #5791 (query param in wrong location), Postman issue #86 (OAuth2 not imported) — consistent demand signal across tools
- Enterprise API coverage (Salesforce, MS Graph, Workday, ServiceNow) all require OAuth2 CC for M2M

## User Experience

### Interaction Model

Users add auth config to their `stack.yaml`. The new types follow the exact same pattern as existing types:

```yaml
# Query-param API key (e.g., OpenWeatherMap)
auth:
  type: query
  paramName: appid
  valueEnv: OPENWEATHER_API_KEY

# OAuth2 client credentials (e.g., Salesforce, MS Graph)
auth:
  type: oauth2
  clientIdEnv: OAUTH_CLIENT_ID
  clientSecretEnv: OAUTH_CLIENT_SECRET
  tokenUrl: https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
  scopes:
    - https://graph.microsoft.com/.default

# mTLS (transport-layer, separate from auth type, combinable)
tls:
  certFile: ~/.gridctl/certs/client.pem
  keyFile: ~/.gridctl/certs/client-key.pem
  caFile: ~/.gridctl/certs/ca.pem  # optional
```

### Workflow Impact

- **Existing users**: Zero impact. Fully backward compatible. No config changes required.
- **New OAuth2 users**: Token lifecycle (fetch, cache, refresh on expiry) is fully transparent via `oauth2.TokenSource`. No token management burden.
- **New query-param users**: Minimal config delta vs. current header auth — change `type:` and `header:` → `paramName:`.
- **mTLS users**: Orthogonal to auth type — add a `tls:` block alongside any existing auth config.

### UX Recommendations

1. Keep mTLS as a separate `tls:` top-level block in `OpenAPIConfig` (not inside `auth:`) — it is transport-layer, not application-layer auth, and can be combined with any auth type.
2. Use `*Env` suffix naming convention already established (`clientIdEnv`, `clientSecretEnv`) — keeps the pattern that the value is read from env, not literal.
3. `tokenUrl` should be a plain string (not env var) — it is not a secret and users benefit from seeing it directly in config.
4. Add `scopes` as an optional `[]string` — OAuth2 CC flows often require specific scopes; omitting it should work for APIs that don't require scopes.
5. Fail with a clear error if `type: oauth2` is configured but the token endpoint returns an error — include the status code and token endpoint URL in the message.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Blocks majority of real-world API auth patterns |
| User impact | Broad + Deep | Affects all users connecting to enterprise or public APIs |
| Strategic alignment | Core mission | Directly enables gridctl's "connect AI to any API" promise |
| Market positioning | Catch up + Differentiate | Query-param is catch-up; OAuth2 CC + mTLS are ahead of most Go MCP tools |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Clean extension path; no architectural changes; additive config changes |
| Effort estimate | Medium | ~1-2 days total: query (small), OAuth2 (medium), mTLS (small-medium) |
| Risk level | Low | Fully backward compatible; new code only activates with explicit config; `x/oauth2` is battle-tested |
| Maintenance burden | Moderate | OAuth2 token lifecycle handled by library; mTLS cert rotation is operational burden, not code |

## Recommendation

**Build with caveats.** Implement in a single PR with three auth types in ascending complexity order:

1. **Query-param API key** (`type: query`) — Start here. Smallest change, highest frequency need, unblocks thousands of public APIs.
2. **OAuth2 client credentials** (`type: oauth2`) — Implement using `golang.org/x/oauth2/clientcredentials`. New dependency but it is the Go standard for this. Wire `oauth2.Transport` as the `http.Client`'s `Transport` for transparent token injection.
3. **mTLS** (`tls:` config block) — No new deps. Orthogonal to auth type. Wire `tls.Config` into `http.Transport` during client construction in `NewOpenAPIClient()`.

**Out of scope for this build:**
- Auto-detection of `securitySchemes` from the OpenAPI spec (strong follow-on candidate; spec data is already available via kin-openapi — just needs wiring and UX decisions around credential mapping)
- Authorization Code flow (requires user browser interaction; not applicable for M2M MCP use case)
- Cookie-based API keys (`apiKey, in: cookie`) — very rare in practice

## References

- [OpenAPI 3.1 Security Schemes Specification](https://spec.openapis.org/oas/v3.1.0#security-scheme-object)
- [RFC 6749 §4.4 — OAuth2 Client Credentials Grant](https://datatracker.ietf.org/doc/html/rfc6749#section-4.4)
- [golang.org/x/oauth2/clientcredentials package](https://pkg.go.dev/golang.org/x/oauth2/clientcredentials)
- [jedisct1/openapi-mcp Authentication Docs](https://jedisct1.github.io/openapi-mcp/docs/authentication.html)
- [awslabs/mcp openapi-mcp-server](https://awslabs.github.io/mcp/servers/openapi-mcp-server)
- [ivo-toby/mcp-openapi-server mTLS support](https://github.com/ivo-toby/mcp-openapi-server/issues/78)
- [oapi-codegen securityprovider](https://github.com/oapi-codegen/oapi-codegen/blob/main/pkg/securityprovider/securityprovider.go)
- [MCP SEP-1046 ext-auth: OAuth Client Credentials](https://modelcontextprotocol.io/specification/2025-03-26)
- [OWASP REST Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html)
- [RFC 6750 — Bearer Token Usage (query param security concerns)](https://www.rfc-editor.org/rfc/rfc6750)
- [Speakeasy — OAuth2 SDK generation for Go](https://www.speakeasy.com/docs/sdks/customize/authentication/oauth)
