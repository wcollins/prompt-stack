# Feature Evaluation: SSH Transport Security Hardening

**Date**: 2026-04-06
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Small (Parts 1 & 2) / Medium (Part 3)

## Summary

gridctl's SSH transport uses `StrictHostKeyChecking=accept-new` with no per-stack known_hosts store, creating silent MITM exposure on host key changes. Parts 1 and 2 (`ssh.knownHostsFile` and `ssh.jumpHost`) are minimal-cost, high-value additions that should ship immediately. Part 3 (gridctl-managed host key approval flow) is the right long-term design but warrants its own scope due to deployment-blocking UX complexity.

## The Idea

`buildSSHCommand` in `pkg/mcp/gateway.go` hardcodes `StrictHostKeyChecking=accept-new`. This means a changed host key — from a MITM, a server rebuild, or a key rotation — silently connects rather than alerting the operator. There is also no bastion/jump host support, which is the standard routing pattern in enterprises with internal SSH infrastructure.

**Proposed additions:**
- `ssh.knownHostsFile` — path to a known_hosts file; enables `StrictHostKeyChecking=yes` via `-o UserKnownHostsFile=<path>`
- `ssh.jumpHost` — bastion host specification; maps to `-J <bastion>` flag
- (Phase B) gridctl-managed host key store with TOFU-on-first-connect, block-on-change, and `gridctl ssh approve <server>` command

## Project Context

### Current State

gridctl is a production MCP gateway orchestrator (Go 1.25, React UI, Apache 2.0, OpenSSF certified). It aggregates SSH, Docker stdio, HTTP/SSE, and OpenAPI transports into a single endpoint, defined as reproducible YAML.

SSH transport is fully implemented: `pkg/config/types.go` defines `SSHConfig{Host, User, Port, IdentityFile}`, and `buildSSHCommand()` at `gateway.go:1143` constructs the subprocess command. gridctl shells out to the system `ssh` binary via `ProcessClient` — it does **not** use `golang.org/x/crypto/ssh` directly. All hardening is done by passing additional `-o` flags to the subprocess.

The codebase already has a mature TOFU schema pinning system (`pkg/pins`) that stores SHA256 tool hashes in `~/.gridctl/pins/{stack}.json`, with a `gridctl pins approve` CLI command and `POST /api/pins/{server}/approve` REST endpoint. Part 3 of this feature is architected identically.

### Integration Surface

| File | Change Required |
|------|----------------|
| `pkg/config/types.go` | Add `KnownHostsFile` and `JumpHost` fields to `SSHConfig` |
| `pkg/config/loader.go` | Expand variables and resolve tilde in new path fields |
| `pkg/config/validate.go` | Validate `knownHostsFile` path exists; validate `jumpHost` format |
| `pkg/mcp/gateway.go` | Add `SSHKnownHostsFile` and `SSHJumpHost` to `MCPServerConfig`; update `buildSSHCommand` |
| `pkg/controller/server_registrar.go` | Pass new fields from `config.MCPServer` to `mcp.MCPServerConfig` |
| `docs/config-schema.md` | Document new SSH fields |
| `examples/transports/ssh-mcp.yaml` | Add commented examples |

### Reusable Components

- `config/loader.go` path expansion logic (already used for `identityFile` — apply same pattern)
- `buildSSHCommand` function structure — additive flag insertion, no restructuring needed
- `pkg/pins` architecture as the blueprint for Part 3's state store

## Market Analysis

### Competitive Landscape

| Tool | SSH Host Key Handling | Jump Host Support |
|------|-----------------------|-------------------|
| Ansible | Delegates to system SSH; no own store | `-J` via `ansible_ssh_common_args` |
| Terraform SSH provisioner | Disabled by default; optional `host_key` pin | Not supported natively |
| Fabric/Paramiko | `AutoAddPolicy` default (insecure, flagged as open issue) | Not supported |
| Teleport/StrongDM | CA-signed certificates; eliminates TOFU entirely | Full proxy model |
| MCP community SSH tools | No host key management; no jump hosts | Not supported in any surveyed tool |

gridctl currently matches the worst-practice tier (effective `accept-new`, no explicit known_hosts, no jump hosts). Parts 1 and 2 would move it to responsible-default tier. Part 3 would establish it as the only MCP gateway with a managed SSH trust store.

### Market Positioning

- **`ssh.knownHostsFile`**: Table stakes security hygiene. Provides the mechanism; user manages the known_hosts file.
- **`ssh.jumpHost`**: Meaningful differentiator. No other MCP gateway tool supports bastion traversal. Unlocks enterprise deployments where direct SSH to internal servers is firewalled.
- **Part 3 approval flow**: Strong differentiator. Unique in the MCP ecosystem.

### Ecosystem Support

- No Go library needed — gridctl shells out to the system `ssh` binary. All features map to standard OpenSSH client flags (`-J`, `-o UserKnownHostsFile`, `-o StrictHostKeyChecking`).
- `ssh-keyscan` (standard OpenSSH utility) is the natural companion for pre-populating `knownHostsFile`.

### Demand Signals

The feature request originates from firsthand assessment of the codebase. The bastion gap is well-known in DevOps tooling — Ansible, Terraform, and others have open issues requesting better jump host and host key verification handling. Regulated industries (finance, healthcare, defense) universally route SSH through bastions.

## User Experience

### Interaction Model

**Parts 1 & 2 — passive configuration:**
```yaml
mcp-servers:
  - name: remote-tools
    ssh:
      host: "10.0.0.50"
      user: "mcp"
      identityFile: "~/.ssh/id_ed25519"
      knownHostsFile: "~/.ssh/known_hosts"   # new: enables strict checking
      jumpHost: "bastion.example.com"         # new: routes through bastion
    command: ["/opt/mcp-server/bin/server"]
```

Both fields are optional. If `knownHostsFile` is omitted, behavior remains `accept-new` (no regression). If specified, strict mode activates automatically — the UX contract is: "you supplied the file, gridctl trusts it completely."

**Part 3 — active approval flow:**
```bash
# First deploy — host key recorded (TOFU)
gridctl apply

# Key changes (server rebuilt, potential MITM)
gridctl status   # shows remote-tools: HOST KEY CHANGED

# Review fingerprint, then approve
gridctl ssh approve remote-tools

# Redeploy to reconnect with new key
gridctl apply
```

### Workflow Impact

- **Parts 1 & 2**: Zero friction for existing users (fields are optional). Users who add `knownHostsFile` gain strict verification at the cost of needing a pre-populated known_hosts file (`ssh-keyscan host >> known_hosts_file`).
- **Part 3**: Adds a first-deployment step before SSH servers become reachable. This is a lifecycle difference from schema pins (post-deployment) vs SSH keys (must exist pre-deployment or on first connect).

### UX Recommendations

1. When `knownHostsFile` is set but the host key is missing, emit a clear error: `SSH host key verification failed for remote-tools — run 'ssh-keyscan 10.0.0.50 >> ~/.ssh/known_hosts' or set ssh.knownHostsFile to a pre-populated file`.
2. Document `ssh-keyscan` as the companion tool in the SSH section of config-schema.md.
3. For Part 3: implement auto-TOFU on first connect (not require-explicit), matching current behavior, then block on drift. This minimizes transition friction while adding the critical protection (changed key detection).
4. Error on host key change should surface through `gridctl status` as a distinct health state, not just a connection failure.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Silent MITM on host key change is a real attack vector in enterprise networks |
| User impact | Narrow+Deep | SSH users are a subset, but they run production infrastructure; high stakes |
| Strategic alignment | Core mission | "Secure reproducible MCP infrastructure" — directly on mission |
| Market positioning | Differentiator | Jump host support is unique across all surveyed MCP gateway tools |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity (Parts 1&2) | Minimal | ~30 lines across 5 files; purely additive |
| Integration complexity (Part 3) | Moderate | New state store + API + CLI; well-precedented by pins system |
| Effort estimate | Small (Parts 1&2) / Medium (Part 3) | Parts 1&2 are an afternoon; Part 3 is a focused sprint |
| Risk level | Low (Parts 1&2) / Medium (Part 3) | Parts 1&2 are optional fields; Part 3 can block deployments if defaulted poorly |
| Maintenance burden | Minimal (Parts 1&2) / Moderate (Part 3) | Part 3 adds a second TOFU store alongside pins |

## Recommendation

**Build with caveats.** Ship Parts 1 and 2 as the primary deliverable; scaffold Part 3 as Phase B in the same implementation prompt.

**Parts 1 & 2 (ship now):** The cost is minimal (30 lines, purely additive, optional fields) and the value is immediate: users can opt into strict SSH host key checking today by pointing to a `known_hosts` file, and enterprises routing through bastions are unblocked. No risk of regression.

**Part 3 (ship as follow-on):** The managed approval flow is the right long-term design — it mirrors the pins system and provides a complete TOFU lifecycle for SSH host keys. However, the deployment-blocking behavior (SSH keys must be approved before a server connects, unlike schema pins which surface post-deployment) requires careful UX design around error messages, `gridctl status` health states, and the auto-TOFU vs. require-explicit first-connect decision. This UX design work deserves its own scope.

**What would tip toward skipping Part 3:** If the target user base is primarily individual developers (who manage their own `~/.ssh/known_hosts`), Part 3 may be unnecessary overhead. If the target is enterprise teams (shared stacks, multiple operators), Part 3 is essential.

## References

- [OpenSSH 7.6 Release Notes — StrictHostKeyChecking=accept-new introduced](https://www.openssh.org/txt/release-7.6)
- [OpenSSH/Cookbook/Proxies and Jump Hosts — ProxyJump documentation](https://en.wikibooks.org/wiki/OpenSSH/Cookbook/Proxies_and_Jump_Hosts)
- [SSH ProxyJump vs ProxyCommand — Teleport Blog](https://goteleport.com/blog/ssh-proxyjump-ssh-proxycommand/)
- [Fabric default SSH host key policy is insecure — GitHub Issue #2071](https://github.com/fabric/fabric/issues/2071)
- [Terraform SSH host key verification gap — GitHub Issue #17269](https://github.com/hashicorp/terraform/issues/17269)
- [NISTIR 7966 — NIST SSH Security Guidance](https://csrc.nist.gov/pubs/ir/7966/final)
- [MCP Security Best Practices — modelcontextprotocol.io](https://modelcontextprotocol.io/specification/draft/basic/security_best_practices)
- [Bastion Host Market Size 2025 — Market Research Intellect](https://www.marketresearchintellect.com/product/bastion-host-market/)
- [14 Best Practices to Secure SSH Bastion Host — Teleport](https://goteleport.com/blog/security-hardening-ssh-bastion-best-practices/)
