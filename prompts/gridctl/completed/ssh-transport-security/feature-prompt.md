# Feature Implementation: SSH Transport Security Hardening

## Context

gridctl is a production MCP (Model Context Protocol) gateway orchestrator written in Go 1.25 with a React/TypeScript web UI. It aggregates MCP servers from multiple transports — SSH, Docker stdio, HTTP/SSE, and OpenAPI — into a single unified endpoint defined as reproducible YAML.

**SSH transport today**: gridctl shells out to the system `ssh` binary using `exec.Cmd` wrapped in a `ProcessClient`. It does **not** use `golang.org/x/crypto/ssh` — all hardening is done by passing `-o` flags to the subprocess. The command is built by `buildSSHCommand()` in `pkg/mcp/gateway.go`.

**Tech stack**: Go, `cobra` CLI, `slog` logging, standard library only for SSH. Config: YAML → `pkg/config` (types, loader, validate, expand) → `pkg/controller` (server_registrar) → `pkg/mcp` (gateway, process).

## Evaluation Context

- **Security posture**: `StrictHostKeyChecking=accept-new` silently connects to a changed host key. Enterprise security teams require `yes` (pre-populated known_hosts) for production.
- **Jump host gap**: No comparable MCP gateway tool supports bastion traversal. Enterprises with internal SSH infrastructure cannot use gridctl's SSH transport without workarounds.
- **Implementation approach**: Both features map directly to standard OpenSSH client flags. No new Go dependencies needed.
- **Scope**: Phase A (this prompt) = Parts 1 & 2 only: `ssh.knownHostsFile` and `ssh.jumpHost`. These are purely additive optional fields with ~30 lines of real change. Phase B = managed host key approval flow (separate follow-on; scaffolded at the end of this prompt).
- Full evaluation: `prompt-stack/prompts/gridctl/ssh-transport-security/feature-evaluation.md`

## Feature Description

Add two new optional fields to the `ssh:` block in the stack YAML:

1. **`ssh.knownHostsFile`** — path to a known_hosts file. When set, gridctl passes `-o UserKnownHostsFile=<path> -o StrictHostKeyChecking=yes` instead of `-o StrictHostKeyChecking=accept-new`. Supports `~` expansion and env vars. Validation: file must exist and be readable.

2. **`ssh.jumpHost`** — bastion/jump host specification (e.g., `user@bastion.example.com` or `bastion.example.com`). When set, gridctl passes `-J <jumpHost>` to the SSH command. Supports env var expansion. Validation: non-empty string; format `[user@]host[:port]`.

**Example YAML after implementation:**
```yaml
mcp-servers:
  - name: remote-tools
    command: ["/opt/mcp-server/bin/server"]
    ssh:
      host: "10.0.0.50"
      user: "mcp"
      identityFile: "~/.ssh/id_ed25519"
      knownHostsFile: "~/.ssh/gridctl_known_hosts"   # new
      jumpHost: "bastion.example.com"                 # new
```

## Requirements

### Functional Requirements

1. `ssh.knownHostsFile` is an optional string field on `SSHConfig`. When non-empty, `buildSSHCommand` replaces `-o StrictHostKeyChecking=accept-new` with `-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<resolved-path>`.
2. `ssh.jumpHost` is an optional string field on `SSHConfig`. When non-empty, `buildSSHCommand` appends `-J <jumpHost>` before the `user@host` argument.
3. Both fields support `~` expansion and `$ENV_VAR` substitution consistent with how `identityFile` is handled.
4. `knownHostsFile` path is resolved relative to the stack file location if not absolute (consistent with `identityFile` behavior).
5. Validation: if `knownHostsFile` is set and the file does not exist, return a `ValidationError` with a clear message including the resolved path.
6. Validation: `jumpHost`, if set, must be a non-empty string matching `[user@]host[:port]` — reject obviously malformed values.
7. Existing SSH behavior is unchanged when neither field is set (`accept-new` remains the default).
8. Both fields flow through the full config pipeline: `SSHConfig` → loader expansion → path resolution → validation → `MCPServerConfig` → `buildSSHCommand`.

### Non-Functional Requirements

- Zero new Go module dependencies.
- No changes to any existing SSH behavior when new fields are omitted.
- New test cases must keep `pkg/mcp` coverage at or above 75% (currently 76.2%).

### Out of Scope

- A gridctl-managed SSH host key store (TOFU approval flow, `gridctl ssh approve` command) — this is Phase B, scaffolded below.
- SSH certificate authority (`@cert-authority`) support.
- Changing the default `StrictHostKeyChecking` value when `knownHostsFile` is not set.
- Any changes to how the `ssh` binary is located or invoked beyond flag insertion.

## Architecture Guidance

### Recommended Approach

Follow the exact pattern already established for `identityFile`. Every step of the pipeline already handles it; just extend it:

1. Add fields to struct → 2. Expand vars in loader → 3. Resolve path in `resolveRelativePaths` → 4. Validate in validate.go → 5. Pass through in server_registrar → 6. Use in `buildSSHCommand`.

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `pkg/config/types.go:171` | `SSHConfig` struct — add new fields here |
| `pkg/config/loader.go:194` | Variable expansion for SSH fields — extend the `ssh != nil` block |
| `pkg/config/loader.go:228` | `resolveRelativePaths` — extend the SSH path resolution block |
| `pkg/config/validate.go:197` | SSH validation — add file-exists check and jumpHost format check |
| `pkg/mcp/gateway.go:29` | `MCPServerConfig` struct — add `SSHKnownHostsFile` and `SSHJumpHost` fields |
| `pkg/mcp/gateway.go:1143` | `buildSSHCommand` — where the actual flag insertion happens |
| `pkg/controller/server_registrar.go:94` | `buildServerConfig` SSH branch — pass new fields (deployment path) |
| `pkg/controller/server_registrar.go:164` | `buildConfigFromMCPServer` SSH branch — pass new fields (hot reload path) |
| `examples/transports/ssh-mcp.yaml` | Update with commented examples of new fields |

### Integration Points

**`pkg/config/types.go`** — extend `SSHConfig`:
```go
type SSHConfig struct {
    Host           string `yaml:"host"`
    User           string `yaml:"user"`
    Port           int    `yaml:"port,omitempty"`
    IdentityFile   string `yaml:"identityFile,omitempty"`
    KnownHostsFile string `yaml:"knownHostsFile,omitempty"`  // add
    JumpHost       string `yaml:"jumpHost,omitempty"`         // add
}
```

**`pkg/config/loader.go`** — extend the `ssh != nil` block at line ~194:
```go
if s.MCPServers[i].SSH != nil {
    s.MCPServers[i].SSH.Host = expand(s.MCPServers[i].SSH.Host)
    s.MCPServers[i].SSH.User = expand(s.MCPServers[i].SSH.User)
    s.MCPServers[i].SSH.IdentityFile = expand(s.MCPServers[i].SSH.IdentityFile)
    s.MCPServers[i].SSH.KnownHostsFile = expand(s.MCPServers[i].SSH.KnownHostsFile) // add
    s.MCPServers[i].SSH.JumpHost = expand(s.MCPServers[i].SSH.JumpHost)              // add
}
```

**`pkg/config/loader.go`** — extend `resolveRelativePaths` at line ~228:
```go
if s.MCPServers[i].SSH != nil && s.MCPServers[i].SSH.IdentityFile != "" {
    s.MCPServers[i].SSH.IdentityFile = expandTildeAndResolvePath(...)
}
// add:
if s.MCPServers[i].SSH != nil && s.MCPServers[i].SSH.KnownHostsFile != "" {
    s.MCPServers[i].SSH.KnownHostsFile = expandTildeAndResolvePath(
        s.MCPServers[i].SSH.KnownHostsFile, basePath)
}
```

**`pkg/config/validate.go`** — in the `server.IsSSH()` block (line ~197):
```go
if server.SSH.KnownHostsFile != "" {
    if _, err := os.Stat(server.SSH.KnownHostsFile); err != nil {
        errs = append(errs, ValidationError{
            sshPrefix + ".knownHostsFile",
            fmt.Sprintf("file not found or not readable: %s", server.SSH.KnownHostsFile),
        })
    }
}
if server.SSH.JumpHost != "" {
    // Basic sanity: non-empty, no shell metacharacters
    if strings.ContainsAny(server.SSH.JumpHost, " \t\n;|&$`") {
        errs = append(errs, ValidationError{sshPrefix + ".jumpHost", "invalid format"})
    }
}
```

**`pkg/mcp/gateway.go`** — extend `MCPServerConfig` and `buildSSHCommand`:
```go
// In MCPServerConfig struct:
SSHKnownHostsFile string
SSHJumpHost       string

// In buildSSHCommand — replace the StrictHostKeyChecking line:
if cfg.SSHKnownHostsFile != "" {
    args = append(args,
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile="+cfg.SSHKnownHostsFile,
    )
} else {
    args = append(args, "-o", "StrictHostKeyChecking=accept-new")
}

// After identity file, before user@host:
if cfg.SSHJumpHost != "" {
    args = append(args, "-J", cfg.SSHJumpHost)
}
```

**`pkg/controller/server_registrar.go`** — both SSH branches (lines 94 and 164) need:
```go
SSHKnownHostsFile: server.SSH.KnownHostsFile,  // or server.SSHKnownHostsFile
SSHJumpHost:       server.SSH.JumpHost,          // or server.SSHJumpHost
```

Note: the first SSH branch (line ~94) reads from a pre-flattened `server` struct with `SSHHost`, `SSHUser` etc. The second (line ~164) reads from `server.SSH.*`. Check both and pass fields consistently.

### Reusable Components

- `expandTildeAndResolvePath` (loader.go) — already handles `~` and relative-to-basePath resolution; use it for `KnownHostsFile`
- `expand()` (loader.go) — env var expansion; use it for both new fields
- `ValidationError` (validate.go) — use same type for new validation errors
- The `buildSSHCommand` test structure at `gateway_test.go:1733` — extend with new subtests

## UX Specification

**Discovery**: Both fields appear in the `ssh:` block alongside existing fields. IDE autocomplete (YAML schema) will surface them once added.

**Activation**: Both are opt-in. No change required for existing stacks.

**`knownHostsFile` workflow**:
1. User pre-populates a known_hosts file: `ssh-keyscan 10.0.0.50 >> ~/.ssh/gridctl_known_hosts`
2. User adds `knownHostsFile: "~/.ssh/gridctl_known_hosts"` to their stack YAML
3. gridctl applies strict host key checking on every SSH connection

**`jumpHost` workflow**:
1. User adds `jumpHost: "bastion.example.com"` to their stack YAML
2. gridctl routes the SSH connection through the bastion transparently

**Error states**:
- `knownHostsFile` path does not exist → validation error at `gridctl validate` / `gridctl apply` time with the resolved path in the message
- `jumpHost` with shell metacharacters → validation error with "invalid format" message
- Host key mismatch (when using `StrictHostKeyChecking=yes`) → SSH subprocess fails; error surfaces through `ProcessClient` stderr as a standard SSH error message

**Documentation**: Update `docs/config-schema.md` SSH section to describe both fields. Add a note that `knownHostsFile` switches to strict host key checking and that `ssh-keyscan` is the companion tool for pre-populating the file. Update `examples/transports/ssh-mcp.yaml` with commented examples.

## Implementation Notes

### Conventions to Follow

- YAML tags use camelCase (`knownHostsFile`, not `known_hosts_file`) — match existing SSH field naming
- Optional fields use `omitempty` in struct tags
- All SSH fields on `MCPServerConfig` are prefixed with `SSH` (e.g., `SSHKnownHostsFile`)
- Validation errors use dot-path format: `"servers[i].ssh.knownHostsFile"` matching the existing SSH validation pattern
- Test subtests follow the pattern in `TestGateway_buildSSHCommand` — table-driven with descriptive names

### Potential Pitfalls

- **Two registration paths**: `buildServerConfig` (used during full deployment) and `buildConfigFromMCPServer` (used by hot reload handler) both construct `MCPServerConfig` for SSH servers independently. Both must be updated or the hot reload path will silently drop the new fields.
- **`accept-new` replacement**: The replacement of `StrictHostKeyChecking=accept-new` with `yes` + `UserKnownHostsFile` must be mutually exclusive — do not emit both options.
- **Flag ordering in buildSSHCommand**: `-J` must come before `user@host`. The current function appends identity file, port, then `user@host`. Insert `-J` after port but before `user@host`.
- **Test coverage**: `pkg/mcp` has a 75% enforced threshold. Add at minimum: `buildSSHCommand` subtests for `knownHostsFile` (with and without), `jumpHost` (with and without), and both together.

### Suggested Build Order

1. `pkg/config/types.go` — add fields to `SSHConfig`
2. `pkg/config/loader.go` — add expansion and path resolution
3. `pkg/config/validate.go` — add validation
4. `pkg/mcp/gateway.go` — add to `MCPServerConfig`; update `buildSSHCommand`
5. `pkg/controller/server_registrar.go` — pass new fields in both SSH branches
6. Tests — extend `TestGateway_buildSSHCommand`; add config validation tests
7. Docs — `docs/config-schema.md`; `examples/transports/ssh-mcp.yaml`

## Acceptance Criteria

1. `ssh.knownHostsFile` in YAML populates `SSHConfig.KnownHostsFile` and flows through to `MCPServerConfig.SSHKnownHostsFile`.
2. `ssh.jumpHost` in YAML populates `SSHConfig.JumpHost` and flows through to `MCPServerConfig.SSHJumpHost`.
3. When `SSHKnownHostsFile` is set, `buildSSHCommand` emits `-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<path>` and does **not** emit `-o StrictHostKeyChecking=accept-new`.
4. When `SSHKnownHostsFile` is not set, `buildSSHCommand` emits `-o StrictHostKeyChecking=accept-new` (unchanged behavior).
5. When `SSHJumpHost` is set, `buildSSHCommand` emits `-J <jumpHost>` before `user@host`.
6. `~` and `$ENV_VAR` in both fields are expanded correctly.
7. `knownHostsFile` pointing to a non-existent file fails validation with a message containing the resolved path.
8. Both fields are documented in `docs/config-schema.md`.
9. `examples/transports/ssh-mcp.yaml` includes commented examples of both fields.
10. `pkg/mcp` test coverage remains ≥ 75%.
11. Hot reload path (`buildConfigFromMCPServer`) passes new fields through correctly.

## Phase B: Managed Host Key Approval Flow (Scaffold)

This phase is **out of scope for the current implementation** but is the right long-term design. Scaffold this as a follow-on feature once Parts 1 and 2 are validated in production.

**What it adds:**
- gridctl manages its own per-stack known_hosts file at `~/.gridctl/ssh/{stackName}.known_hosts`
- On first SSH connect: TOFU (accept and record, like `accept-new`) — no behavioral change
- On subsequent connects: strict checking against the stored key — changed keys are blocked
- New CLI: `gridctl ssh list|approve|reset <server>` (mirrors `gridctl pins list|approve|reset`)
- New REST: `GET /api/ssh/{server}`, `POST /api/ssh/{server}/approve`, `DELETE /api/ssh/{server}`
- New gateway-level config: `gateway.security.ssh_verification.enabled: true` (default false until stable)

**Architecture**: Mirror `pkg/pins` exactly. Create `pkg/sshkeys` with `KeyStore` (manages `~/.gridctl/ssh/{stack}.known_hosts`), `KeyStoreAdapter` (implements a `HostKeyVerifier` interface in `pkg/mcp`), API handlers in `internal/api/ssh.go`, and CLI in `cmd/gridctl/ssh.go`.

**Key design decision before implementing**: Should the first SSH connection auto-TOFU (record the key silently, current-behavior-preserving) or require explicit pre-approval? Recommendation: auto-TOFU on first connect, block on change — this is the same posture as `accept-new` but with change detection added.

## References

- [OpenSSH StrictHostKeyChecking options](https://man.openbsd.org/ssh_config#StrictHostKeyChecking)
- [OpenSSH ProxyJump (-J) documentation](https://man.openbsd.org/ssh#J)
- [OpenSSH 7.6 release notes — accept-new introduced](https://www.openssh.org/txt/release-7.6)
- [ssh-keyscan man page](https://man.openbsd.org/ssh-keyscan)
- [SSH ProxyJump vs ProxyCommand — Teleport](https://goteleport.com/blog/ssh-proxyjump-ssh-proxycommand/)
- [gridctl pins system — pkg/pins/store.go (Phase B reference architecture)](../../pkg/pins/store.go)
