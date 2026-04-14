# Feature Evaluation: Wizard Gateway Advanced Config

**Date**: 2026-04-10
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium

## Summary

The StackForm's Gateway section currently exposes only four fields (allowed origins, auth, code_mode, output_format) out of the fourteen fields the GatewayConfig struct supports. Production operators who want to configure distributed tracing, schema drift behavior, performance limits, or api_key auth must fall back to YAML. This PR adds a new "Gateway Advanced" accordion section and the missing `api_key` auth type, giving operators full control from the wizard. The tokenizer fields are deferred — they hold sensitive API keys and warrant vault-integration consideration first.

## The Idea

Add to the StackForm:
1. **`api_key` auth type** — a third option alongside bearer and header for gateway authentication, with a conditional `header` field
2. **Gateway Advanced accordion** — a new collapsible section with four sub-groups:
   - **Tracing**: `enabled`, `sampling`, `retention`, `export`, `endpoint` (endpoint conditional on export=otlp)
   - **Schema Pinning**: `security.schema_pinning.enabled`, `action` (warn/block, conditional on enabled)
   - **Performance**: `code_mode_timeout` (conditional on code_mode=on), `maxToolResultBytes`

The tokenizer fields (`tokenizer`, `tokenizer_api_key`) are explicitly out of scope for this PR.

## Project Context

### Current State

The StackForm Gateway section (lines 599–722 in StackForm.tsx) handles four fields via a `gateway?: { allowedOrigins, auth, codeMode, outputFormat }` shape in `StackFormData`. The `buildStack()` function in yaml-builder.ts serializes these but omits all advanced gateway fields entirely.

All target fields exist in the Go backend (`GatewayConfig`, `TracingConfig`, `GatewaySecurityConfig`, `SchemaPinningConfig`) and are fully validated. `TracingConfig` defaults: enabled=true, sampling=1.0, retention="24h". Schema pinning action accepts only `"warn"` (default) or `"block"`.

### Integration Surface

- `web/src/lib/yaml-builder.ts` — extend `StackFormData.gateway` interface; extend `buildStack()` gateway serialization
- `web/src/components/wizard/steps/StackForm.tsx` — add `api_key` option to auth dropdown, add "Gateway Advanced" Section accordion
- `web/src/__tests__/StackForm.test.tsx` — new test cases for all added fields

### Reusable Components

- `Section` accordion (StackForm.tsx) — already used for Gateway, Network, Secrets; use same pattern for Gateway Advanced sub-sections or as a new top-level section
- Conditional rendering on `data.gateway?.auth?.type` — already exists for header auth; extend for api_key
- Number inputs with `text-[10px] text-text-muted` helper text — established pattern

## Market Analysis

### Competitive Landscape

- **Tracing config in UI**: Kong Manager exposes OTLP endpoint + sampling rate as a flat form inside the OpenTelemetry plugin. Traefik, Istio, Gloo are YAML-only for tracing config. No tool groups primary/advanced tracing fields with progressive disclosure.
- **Schema drift policy in UI**: Bytebase offers warn/warning/error enforcement levels for schema changes. HCP Terraform Sentinel uses Advisory/Soft Mandatory/Hard Mandatory. Neither applies to gateway/runtime config — this area is blank.
- **Performance limits in UI**: No gateway UI tool exposes `max_tool_result_bytes` or code execution timeout as first-class fields.

### Market Positioning

**Leap ahead for tracing and schema pinning UI.** No MCP tool, gateway tool, or proxy exposes schema drift enforcement in a wizard form. The `warn`/`block` pattern follows HCP Terraform Sentinel's Advisory/Mandatory model, which is well-understood by operators. gridctl would be the first gateway to surface this as a guided config option.

### Demand Signals

- `code_mode_timeout` pairs with the existing `code_mode` toggle — already in the form; operators using code mode clearly need this
- Schema pinning was added to gridctl deliberately (PR history shows active investment in this feature); surfacing it in the wizard completes the loop
- `maxToolResultBytes` matters for any operator running tools that return large responses (database queries, file reads)

## User Experience

### Interaction Model

- `api_key` auth: user changes the auth type dropdown from "Bearer Token" to "API Key" → a "Header Name" field appears (defaults implied as "Authorization")
- Gateway Advanced: collapsed accordion at the bottom of the Gateway section, labeled "Advanced". Badge shows count of populated fields. Expanding reveals three sub-groups (Tracing, Schema Pinning, Performance), each with a subtle visual separator
- Tracing: enabled toggle is ON by default (matching the backend default). Sampling is a number input (0.0–1.0). Export is a dropdown ("none" or "OTLP"). Endpoint field appears only when export = "otlp"
- Schema pinning: enabled toggle OFF by default (opt-in). When enabled, action dropdown appears with "Warn" (default) and "Block"
- Performance: `code_mode_timeout` is only shown when `codeMode = "on"` (it's meaningless otherwise). `maxToolResultBytes` is always visible in this section

### Workflow Impact

Zero impact on existing workflows — the accordion is collapsed by default. Operators who never use advanced config won't see it unless they expand it.

### UX Recommendations

1. Use named sub-groups within the accordion (small headers like "Tracing", "Schema Pinning", "Performance") rather than a flat list of 9 fields
2. Default tracing `enabled` to true and `sampling` to 1.0 to match backend defaults — show placeholder text making these defaults visible
3. Schema pinning: label the `action` dropdown values as "Warn (log and continue)" and "Block (reject tool calls)" for clarity
4. `code_mode_timeout` placeholder: `30` (the backend default); label: "Timeout (seconds)"
5. `maxToolResultBytes` placeholder: `65536` (the backend default of 64KB); add helper text "Default: 64KB"

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Production operators can't configure tracing, schema enforcement, or performance from the wizard |
| User impact | Narrow+Deep | Ops-focused users specifically — exactly the ones running production gridctl deployments |
| Strategic alignment | Core mission | Wizard completeness for all GatewayConfig fields |
| Market positioning | Leap ahead | No tool exposes schema drift enforcement or tracing in a wizard UI |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Moderate | New accordion section, 4 sub-groups, conditional fields, interface + serialization + tests |
| Effort estimate | Medium | ~9 new fields, 2 forms, established patterns throughout |
| Risk level | Low | All additive; backend fully validates; no destructive changes |
| Maintenance burden | Minimal | Declarative form fields for stable backend features |

## Recommendation

**Build with caveats.** Ship: `api_key` auth type + tracing + schema pinning + performance (code_mode_timeout + maxToolResultBytes). Defer tokenizer fields — `tokenizer_api_key` holds a sensitive credential and should be implemented alongside proper vault-reference support (the vault popover exists in env field editors; applying the same pattern to this field is a separate UX consideration).

The `api_key` auth addition is trivially small and should be included. The "Gateway Advanced" accordion groups naturally and follows established StackForm patterns.

## References

- [Kong Manager OpenTelemetry plugin form](https://developer.konghq.com/plugins/opentelemetry/reference/)
- [HCP Terraform Sentinel policy enforcement levels](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/policy-enforcement/manage-policy-sets)
- [Bytebase schema drift detection](https://docs.bytebase.com/change-database/drift-detection)
- [Progressive disclosure — NN/g](https://www.nngroup.com/articles/progressive-disclosure/)
- `pkg/config/types.go` — `GatewayConfig` (lines 54–93), `TracingConfig` (lines 39–51), `GatewaySecurityConfig` (lines 95–99), `SchemaPinningConfig` (lines 101–109)
