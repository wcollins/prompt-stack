# Feature Implementation: OpenAPI Auth Expansion

## Context

**Project**: gridctl — a production-ready MCP (Model Context Protocol) gateway CLI written in Go. It aggregates multiple downstream MCP servers (Docker containers, local processes, SSH, HTTP, and OpenAPI-backed REST APIs) into a single endpoint for LLM clients like Claude Desktop and Claude Code.

**Tech stack**: Go 1.25.x, `github.com/getkin/kin-openapi` for OpenAPI spec parsing, `gopkg.in/yaml.v3` for config, `net/http` stdlib for HTTP, `go.uber.org/mock` for test mocks.

**Architecture**: Config YAML → `pkg/config/types.go` structs → `pkg/config/validate.go` validation → `pkg/controller/server_registrar.go` (env var resolution) → `pkg/mcp/gateway.go` (`OpenAPIClientConfig`) → `pkg/mcp/openapi_client.go` (`OpenAPIClient`). Auth is applied in `applyAuth()` at request time.

**Full evaluation**: `/Users/william/code/prompt-stack/prompts/gridctl/openapi-auth-expansion/feature-evaluation.md`

## Evaluation Context

- **Market finding**: No Go MCP+OpenAPI tool does all three auth types end-to-end. The awslabs Python server is the only one with OAuth2 CC automation, and it's Cognito-specific. This implementation would be the most complete in the Go MCP space.
- **UX decision**: mTLS is implemented as a separate `tls:` block in `OpenAPIConfig` (not inside `auth:`) because it is transport-layer, not application-layer. This allows combining mTLS with any auth type.
- **Scope**: Three auth types in one PR. Auto-detection of securitySchemes from the spec is explicitly out of scope — keep for a follow-on feature.
- **Risk mitigation**: All new auth types are opt-in via explicit config; zero impact on existing bearer/header users.
- **Dependency**: `golang.org/x/oauth2` is the only new dependency (for OAuth2 CC). `crypto/tls` (stdlib) handles mTLS with no new deps.

## Feature Description

Expand gridctl's OpenAPI gateway authentication from two types (bearer token, custom header) to five:

1. **`type: query`** — API key injected as a URL query parameter (e.g., `?api_key=xxx`). Used by most public data APIs (OpenWeatherMap, many geocoding, finance APIs).
2. **`type: oauth2`** — OAuth2 client credentials flow (RFC 6749 §4.4). Fetches a short-lived bearer token from a `tokenUrl` using `clientId`/`clientSecret`, caches it, and re-fetches on expiry. Used by enterprise APIs: Salesforce, Microsoft Graph, Workday, ServiceNow.
3. **`type: basic`** — HTTP Basic Auth (`Authorization: Basic <b64(user:password)>`). Simple to add while touching the same code paths.
4. **`tls:` block** — mTLS client certificate configuration. Transport-layer client authentication; combinable with any auth type. No new deps (stdlib `crypto/tls`).

## Requirements

### Functional Requirements

1. `type: query` auth injects the API key as a query parameter with the configured `paramName` on every request, resolved from `valueEnv`.
2. `type: oauth2` auth fetches a token from `tokenUrl` using `clientId`/`clientSecret` resolved from `clientIdEnv`/`clientSecretEnv`, injects `Authorization: Bearer <token>`, and transparently re-fetches when the token expires.
3. `type: oauth2` supports an optional `scopes` list for APIs that require specific OAuth2 scopes.
4. `type: basic` auth injects `Authorization: Basic <base64(user:password)>` resolved from `usernameEnv`/`passwordEnv`.
5. A `tls:` block in `OpenAPIConfig` configures mTLS: `certFile` + `keyFile` (required together for mTLS), optional `caFile` for custom CA, optional `insecureSkipVerify` (default false).
6. mTLS config is transport-layer: it can be combined with any `auth.type` or with no auth.
7. Validation at config load time reports clear errors for:
   - Unknown `auth.type` values
   - Missing required fields per auth type
   - `tls.certFile` set without `tls.keyFile` (or vice versa)
   - File not found for `tls.certFile`, `tls.keyFile`, `tls.caFile` (if set)
8. Existing `type: bearer` and `type: header` auth continue to work exactly as before.
9. All new auth types support the established `*Env` naming convention for secret values (read from environment variables via `os.Getenv()`).

### Non-Functional Requirements

- Fully backward compatible — no breaking changes to existing config schema
- OAuth2 token caching must be goroutine-safe (use `golang.org/x/oauth2/clientcredentials.TokenSource`)
- mTLS `http.Client` construction must not affect the shared default client
- Query-param API keys must be URL-encoded to prevent injection
- No secrets (clientSecret, API key values) logged at any log level

### Out of Scope

- Auto-detection of auth type from OpenAPI `securitySchemes` (follow-on feature)
- Authorization Code / PKCE flow (requires user interaction; not applicable for M2M)
- Cookie-based API keys (`apiKey, in: cookie`)
- Token rotation / vault integration (credentials come from env vars only)
- `openIdConnect` scheme support

## Architecture Guidance

### Recommended Approach

**Query-param**: Extend `applyAuth()` with a `query` case that appends the param to the request URL. Use `req.URL.Query()` + `req.URL.RawQuery = query.Encode()`.

**OAuth2 client credentials**: In `NewOpenAPIClient()`, when `authType == "oauth2"`, create a `clientcredentials.Config` and store its `TokenSource(context.Background())` in a new `tokenSource oauth2.TokenSource` field on `OpenAPIClient`. In `applyAuth()`, call `tokenSource.Token()` to get the current token and inject `Authorization: Bearer <token>`. The `TokenSource` from `x/oauth2/clientcredentials` is goroutine-safe and auto-refreshes.

**mTLS**: In `NewOpenAPIClient()`, when `cfg.TLSConfig != nil`, build a `tls.Config` with loaded certs and wrap the `http.Client.Transport` with an `http.Transport` that has the custom `TLSClientConfig`. The `http.Client` is already created in `NewOpenAPIClient()` so this is a natural extension point.

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `pkg/mcp/openapi_client.go` | Core client; `applyAuth()` (line 654), `NewOpenAPIClient()` (line 60), `executeOperation()` (line 575) |
| `pkg/mcp/gateway.go` | `OpenAPIClientConfig` struct (line 53); add new fields here |
| `pkg/config/types.go` | `OpenAPIAuth` struct (line 156); `OpenAPIConfig` (line 147); add `OpenAPITLS` struct here |
| `pkg/config/validate.go` | Auth validation logic around line 232; extend for new types |
| `pkg/controller/server_registrar.go` | `buildOpenAPIConfig()` (line 214); resolve new env vars here |
| `pkg/mcp/openapi_client_test.go` | Existing auth test patterns (`TestApplyAuth_*` around line 471) |
| `tests/integration/openapi_test.go` | Integration test patterns; add mock token endpoint server here |

### Integration Points

**`pkg/config/types.go`**:
```go
type OpenAPIAuth struct {
    Type            string   `yaml:"type"`
    // Existing fields (unchanged):
    TokenEnv        string   `yaml:"tokenEnv,omitempty"`
    Header          string   `yaml:"header,omitempty"`
    ValueEnv        string   `yaml:"valueEnv,omitempty"`
    // New: query
    ParamName       string   `yaml:"paramName,omitempty"`
    // New: oauth2
    ClientIdEnv     string   `yaml:"clientIdEnv,omitempty"`
    ClientSecretEnv string   `yaml:"clientSecretEnv,omitempty"`
    TokenUrl        string   `yaml:"tokenUrl,omitempty"`
    Scopes          []string `yaml:"scopes,omitempty"`
    // New: basic
    UsernameEnv     string   `yaml:"usernameEnv,omitempty"`
    PasswordEnv     string   `yaml:"passwordEnv,omitempty"`
}

// New struct (add to OpenAPIConfig)
type OpenAPITLS struct {
    CertFile           string `yaml:"certFile,omitempty"`
    KeyFile            string `yaml:"keyFile,omitempty"`
    CaFile             string `yaml:"caFile,omitempty"`
    InsecureSkipVerify bool   `yaml:"insecureSkipVerify,omitempty"`
}

type OpenAPIConfig struct {
    // ... existing fields ...
    TLS        *OpenAPITLS       `yaml:"tls,omitempty"`  // NEW
}
```

**`pkg/mcp/gateway.go`** — extend `OpenAPIClientConfig`:
```go
type OpenAPIClientConfig struct {
    // ... existing fields ...
    // New OAuth2 fields:
    OAuth2ClientID     string
    OAuth2ClientSecret string
    OAuth2TokenURL     string
    OAuth2Scopes       []string
    // New query param:
    AuthQueryParam     string
    // New basic auth:
    BasicUsername      string
    BasicPassword      string
    // New TLS:
    TLSCertFile        string
    TLSKeyFile         string
    TLSCAFile          string
    TLSInsecureSkipVerify bool
}
```

**`pkg/mcp/openapi_client.go`** — extend `OpenAPIClient` struct and constructor:
```go
type OpenAPIClient struct {
    // ... existing fields ...
    authQueryParam string
    basicUsername  string
    basicPassword  string
    tokenSource    oauth2.TokenSource  // non-nil for oauth2 auth type
}

func NewOpenAPIClient(name string, cfg *OpenAPIClientConfig) (*OpenAPIClient, error) {
    c := &OpenAPIClient{...} // existing fields

    // Configure HTTP client with TLS if needed
    transport := http.DefaultTransport.(*http.Transport).Clone()
    if cfg.TLSCertFile != "" {
        cert, err := tls.LoadX509KeyPair(cfg.TLSCertFile, cfg.TLSKeyFile)
        if err != nil {
            return nil, fmt.Errorf("loading TLS cert: %w", err)
        }
        tlsCfg := &tls.Config{Certificates: []tls.Certificate{cert}}
        if cfg.TLSCAFile != "" {
            // load CA pool
        }
        tlsCfg.InsecureSkipVerify = cfg.TLSInsecureSkipVerify
        transport.TLSClientConfig = tlsCfg
    }
    c.httpClient = &http.Client{Timeout: defaultOpenAPITimeout, Transport: transport}

    // Build OAuth2 token source
    if cfg.AuthType == "oauth2" {
        ccCfg := &clientcredentials.Config{
            ClientID:     cfg.OAuth2ClientID,
            ClientSecret: cfg.OAuth2ClientSecret,
            TokenURL:     cfg.OAuth2TokenURL,
            Scopes:       cfg.OAuth2Scopes,
        }
        c.tokenSource = ccCfg.TokenSource(context.Background())
    }

    return c, nil
}
```

**`applyAuth()`**:
```go
func (c *OpenAPIClient) applyAuth(req *http.Request) error {
    switch c.authType {
    case "bearer":
        // existing
    case "header":
        // existing
    case "query":
        q := req.URL.Query()
        q.Set(c.authQueryParam, c.authValue)
        req.URL.RawQuery = q.Encode()
    case "basic":
        req.SetBasicAuth(c.basicUsername, c.basicPassword)
    case "oauth2":
        tok, err := c.tokenSource.Token()
        if err != nil {
            return fmt.Errorf("fetching OAuth2 token: %w", err)
        }
        req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
    }
    return nil
}
```

Note: `applyAuth()` currently returns nothing. Changing it to `error` requires updating all call sites (`executeOperation` and `Ping`). This is a necessary, small breaking change internal to the package.

### Reusable Components

- `expandEnvVars()` — used by spec loading; follow same pattern for any new inline config values
- Existing `TestApplyAuth_Bearer` / `TestApplyAuth_Header` tests — copy these as templates for new auth type tests
- `httptest.NewServer()` — used throughout integration tests; use to mock the OAuth2 token endpoint

## UX Specification

**Discovery**: New `type:` values documented in `docs/config-schema.md` alongside the existing ones; expanded `examples/openapi/openapi-auth.yaml` with working examples for each type.

**Activation** (query-param):
```yaml
auth:
  type: query
  paramName: appid
  valueEnv: OPENWEATHER_API_KEY
```

**Activation** (OAuth2 client credentials):
```yaml
auth:
  type: oauth2
  clientIdEnv: OAUTH_CLIENT_ID
  clientSecretEnv: OAUTH_CLIENT_SECRET
  tokenUrl: https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
  scopes:
    - https://graph.microsoft.com/.default
```

**Activation** (mTLS, combined with bearer):
```yaml
auth:
  type: bearer
  tokenEnv: API_TOKEN
tls:
  certFile: ~/.gridctl/certs/client.pem
  keyFile: ~/.gridctl/certs/client-key.pem
  caFile: ~/.gridctl/certs/ca.pem
```

**Error states**:
- `type: oauth2` but token endpoint unreachable → `"fetching OAuth2 token: Post "https://...": <network error>"` propagated to the tool call result with `IsError: true`
- Token endpoint returns 401 → `"fetching OAuth2 token: oauth2: cannot fetch token: 401 Unauthorized; ..."` — include the server response in the error
- mTLS cert file not found → caught at config validation time, before any requests

## Implementation Notes

### Conventions to Follow

- Auth type strings are lowercase: `"bearer"`, `"header"`, `"query"`, `"oauth2"`, `"basic"`
- Config field names follow the `*Env` suffix pattern for env var references: `clientIdEnv`, not `clientId`
- New fields on `OpenAPIClientConfig` use plain Go types (string, []string, bool), no pointers
- File path fields (`TLSCertFile`, etc.) should support `~` expansion — check if the codebase has a `expandHome()` helper; if not, use `os.UserHomeDir()` + `strings.Replace`
- Validation errors follow the existing `ValidationError{field, message}` pattern in `pkg/config/validate.go`
- Test file for unit tests: `pkg/mcp/openapi_client_test.go`; follow the `TestApplyAuth_*` naming pattern

### Potential Pitfalls

1. **`applyAuth()` return type**: Currently `func (c *OpenAPIClient) applyAuth(req *http.Request)` returns nothing. OAuth2 token fetch can fail — you must change the signature to `error`. Update `executeOperation()` and `Ping()` call sites.

2. **`context.Background()` for token source**: `clientcredentials.TokenSource(ctx)` takes a context — use `context.Background()` in `NewOpenAPIClient()` so the token source outlives individual requests. Individual request contexts should not be passed to the long-lived token source.

3. **`http.DefaultTransport` mutation**: Never mutate `http.DefaultTransport`. Use `http.DefaultTransport.(*http.Transport).Clone()` to create a new transport before setting `TLSClientConfig`.

4. **`golang.org/x/oauth2` import**: Run `go get golang.org/x/oauth2` to add the dependency. Import path for client credentials: `golang.org/x/oauth2/clientcredentials`.

5. **Integration test for OAuth2**: You need a mock token endpoint in the integration test. Use `httptest.NewServer()` with a handler that validates the `grant_type=client_credentials` POST and returns `{"access_token":"test-token","token_type":"Bearer","expires_in":3600}`. Then configure the OpenAPI client's `tokenUrl` to point to this test server.

6. **Query param ordering**: When both operation query params and auth query params are set, auth param should be added last (in `applyAuth()`). Since `applyAuth()` is called after `executeOperation()` builds the URL with operation params, the existing call order is already correct.

7. **`noExpand` flag**: The `noExpand` flag disables env var expansion in the spec file — it does not affect auth credentials, which always use `os.Getenv()`.

### Suggested Build Order

1. **Add `golang.org/x/oauth2` dependency** (`go get golang.org/x/oauth2`)
2. **Extend config structs** (`pkg/config/types.go`) — add all new fields to `OpenAPIAuth` and new `OpenAPITLS` struct
3. **Extend validation** (`pkg/config/validate.go`) — add cases for `query`, `oauth2`, `basic`; add `tls:` block validation
4. **Extend `OpenAPIClientConfig`** (`pkg/mcp/gateway.go`) — add new fields
5. **Extend `buildOpenAPIConfig()`** (`pkg/controller/server_registrar.go`) — resolve new env vars
6. **Extend `OpenAPIClient` struct** (`pkg/mcp/openapi_client.go`) — add `tokenSource`, `authQueryParam`, `basicUsername`, `basicPassword` fields
7. **Extend `NewOpenAPIClient()`** — wire OAuth2 token source and TLS transport
8. **Change `applyAuth()` to return `error`** — update signature and all call sites
9. **Add unit tests** — `TestApplyAuth_Query`, `TestApplyAuth_OAuth2`, `TestApplyAuth_Basic`, `TestApplyAuth_mTLS`
10. **Add integration tests** — with mock token endpoint server for OAuth2, query param propagation test, mTLS server test
11. **Update docs and examples** — `docs/config-schema.md`, `examples/openapi/openapi-auth.yaml`

## Acceptance Criteria

1. `type: query` appends the configured `paramName` with the resolved `valueEnv` value to every request URL.
2. `type: oauth2` successfully fetches a token from a mock `tokenUrl` in integration tests and injects `Authorization: Bearer <token>`.
3. An expired OAuth2 token (simulated by short expiry in test) is automatically re-fetched without any user intervention or error.
4. `type: basic` injects the correct `Authorization: Basic <b64>` header.
5. A `tls:` block with `certFile` + `keyFile` creates an `http.Client` with the loaded certificate; a mock mTLS server in integration tests accepts the connection.
6. mTLS can be combined with `type: bearer` — both the TLS client cert and the Authorization header are present on the request.
7. All existing `TestApplyAuth_Bearer` and `TestApplyAuth_Header` tests continue to pass unchanged.
8. `go test ./...` passes (no race conditions — run with `-race` flag).
9. `golangci-lint run` passes with no new warnings.
10. Config validation returns a clear error for `type: oauth2` missing `clientIdEnv`, `tokenUrl`.
11. Config validation returns a clear error for `tls.certFile` set without `tls.keyFile`.
12. `docs/config-schema.md` documents all four new auth types with working YAML examples.

## References

- [golang.org/x/oauth2/clientcredentials package docs](https://pkg.go.dev/golang.org/x/oauth2/clientcredentials)
- [RFC 6749 §4.4 — OAuth2 client_credentials grant](https://datatracker.ietf.org/doc/html/rfc6749#section-4.4)
- [crypto/tls — Go stdlib mTLS](https://pkg.go.dev/crypto/tls#LoadX509KeyPair)
- [OpenAPI 3.1 securitySchemes](https://spec.openapis.org/oas/v3.1.0#security-scheme-object)
- [kin-openapi SecurityScheme struct](https://pkg.go.dev/github.com/getkin/kin-openapi/openapi3#SecurityScheme)
- [oapi-codegen securityprovider — Go auth provider reference](https://github.com/oapi-codegen/oapi-codegen/blob/main/pkg/securityprovider/securityprovider.go)
- [OWASP REST Security — query param secrets](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html)
