# Feature Implementation: Wizard Gateway Advanced Config

## Context

gridctl is a Go/React MCP gateway aggregator. Backend: Go. Frontend: React 19 + TypeScript 5.9 + Tailwind CSS v4 + Zustand v5 + Vite. The wizard lives in `web/src/components/wizard/`. The StackForm handles stack-level configuration including the Gateway section.

The StackForm's Gateway section currently exposes 4 of 14 supported GatewayConfig fields. This feature completes it by adding `api_key` auth type and a "Gateway Advanced" accordion section.

## Evaluation Context

- All target fields exist in the backend (Go structs fully implemented and validated)
- TracingConfig defaults: `enabled=true`, `sampling=1.0`, `retention="24h"` — UI should reflect these as placeholder defaults
- Schema pinning `action` accepts only `"warn"` or `"block"` — 2-option dropdown
- `code_mode_timeout` is meaningless when `code_mode` is off — only show it when `codeMode === "on"`
- `tokenizer` and `tokenizer_api_key` are explicitly out of scope (sensitive credential handling)
- Progressive disclosure pattern: accordion collapsed by default, sub-groups labeled
- Full evaluation: `prompt-stack/prompts/gridctl/wizard-gateway-advanced/feature-evaluation.md`

## Feature Description

Extend the StackForm's Gateway section with:

1. **`api_key` auth type** — add a third option to the existing auth type dropdown alongside "Bearer Token" and "Custom Header". When selected, show a `header` field for the custom header name (e.g., "X-API-Key"). The `token` field (which holds the API key value) is already present and shared.

2. **"Gateway Advanced" accordion section** — a new collapsible Section added after the existing gateway fields. Contains three named sub-groups:

   **Tracing:**
   - `tracing.enabled` — toggle (default: true)
   - `tracing.sampling` — number input, 0.0–1.0 (default: 1.0)
   - `tracing.retention` — text input, duration string e.g. "24h" (default: "24h")
   - `tracing.export` — dropdown: "none" (default) or "otlp"
   - `tracing.endpoint` — URL input, visible only when `export === "otlp"`

   **Schema Pinning:**
   - `security.schema_pinning.enabled` — toggle (default: false/off)
   - `security.schema_pinning.action` — dropdown: "warn" or "block", visible only when `enabled` is true

   **Performance:**
   - `gateway.code_mode_timeout` — number input in seconds (default: 30), visible only when `codeMode === "on"`
   - `gateway.maxToolResultBytes` — number input in bytes (default: 65536), always visible in this section

## Requirements

### Functional Requirements

1. The gateway auth type dropdown must include "API Key" as a third option
2. When auth type is "api_key", a "Header Name" text input must appear (for the custom header name)
3. `api_key` auth serializes as `type: api_key` with `token:` and optionally `header:` in the YAML output
4. A collapsed "Gateway Advanced" accordion must appear below the existing gateway fields
5. The accordion must contain sub-groups for Tracing, Schema Pinning, and Performance
6. All tracing fields must serialize under a `tracing:` block within `gateway:`
7. Schema pinning fields must serialize under `security.schema_pinning:` within `gateway:`
8. `tracing.endpoint` is only shown and serialized when `tracing.export === "otlp"`
9. `security.schema_pinning.action` is only shown when `security.schema_pinning.enabled` is true
10. `code_mode_timeout` is only shown when `gateway.codeMode === "on"`
11. The accordion badge must show a count of non-empty advanced fields (to signal when advanced config is set)
12. All fields must be optional; YAML must be omitted when fields are at their zero/default state (use omitempty logic matching Go struct)
13. `StackFormData` interface in yaml-builder.ts must be extended with all new fields
14. `buildStack()` must serialize all new fields correctly

### Non-Functional Requirements

- Tracing enabled toggle defaults to true in the form to match backend default
- Sampling placeholder: `1.0`; retention placeholder: `24h`; code_mode_timeout placeholder: `30`; maxToolResultBytes placeholder: `65536`
- Schema pinning action dropdown labels: "Warn (log and continue)" and "Block (reject tool calls)"
- Number inputs use `type="number"` with appropriate `min` constraints (sampling: 0–1, timeouts: positive integers)
- Follow all existing form patterns: `Section` component, `inputClass`/`labelClass`, `text-[10px] text-text-muted` helper text

### Out of Scope

- `tokenizer` and `tokenizer_api_key` fields
- Changes to MCPServerForm (covered by `wizard-spec-completeness`)
- Stack-level logging config (covered by `wizard-stack-infra`)
- Advanced network mode

## Architecture Guidance

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `web/src/lib/yaml-builder.ts` | `StackFormData` interface (lines 66–79): `gateway` shape needs extending. `buildStack()` (lines 239–288): gateway serialization block (lines 244–259) needs all new fields. |
| `web/src/components/wizard/steps/StackForm.tsx` | Gateway Section is lines 599–722. Auth type dropdown at ~line 642. Conditional header field at ~lines 674–687. Section accordion component defined at lines 53–94. Badge logic at lines 501–505. |
| `pkg/config/types.go` | `GatewayConfig` (54–93), `TracingConfig` (39–51), `GatewaySecurityConfig` (95–99), `SchemaPinningConfig` (101–109), `AuthConfig` (111–120). |
| `web/src/__tests__/StackForm.test.tsx` | Gateway section tests at lines 148–168. Follow same pattern for new fields. |

### Integration Points

**`yaml-builder.ts` — extend `StackFormData.gateway`:**

```typescript
gateway?: {
  allowedOrigins?: string[];
  auth?: { type: string; token: string; header?: string };
  codeMode?: string;
  codeModeTimeout?: number;          // ADD
  outputFormat?: string;
  maxToolResultBytes?: number;       // ADD
  tracing?: {                        // ADD
    enabled?: boolean;
    sampling?: number;
    retention?: string;
    export?: string;
    endpoint?: string;
  };
  security?: {                       // ADD
    schemaPinning?: {
      enabled?: boolean;
      action?: string;
    };
  };
};
```

**`yaml-builder.ts` — extend `buildStack()` gateway block (after existing codeMode/outputFormat lines):**

```typescript
// After existing gateway fields:
if (gw.codeModeTimeout) lines.push(`  code_mode_timeout: ${gw.codeModeTimeout}`);
if (gw.maxToolResultBytes) lines.push(`  maxToolResultBytes: ${gw.maxToolResultBytes}`);

if (gw.tracing) {
  // Only emit the tracing block if at least one field is non-default
  const t = gw.tracing;
  if (t.enabled !== undefined || t.sampling || t.retention || t.export || t.endpoint) {
    lines.push('  tracing:');
    if (t.enabled !== undefined) lines.push(`    enabled: ${t.enabled}`);
    if (t.sampling !== undefined && t.sampling !== 1.0) lines.push(`    sampling: ${t.sampling}`);
    if (t.retention && t.retention !== '24h') lines.push(`    retention: ${t.retention}`);
    if (t.export) lines.push(`    export: ${t.export}`);
    if (t.endpoint) lines.push(`    endpoint: ${yamlValue(t.endpoint)}`);
  }
}

if (gw.security?.schemaPinning?.enabled) {
  lines.push('  security:');
  lines.push('    schema_pinning:');
  lines.push(`      enabled: ${gw.security.schemaPinning.enabled}`);
  if (gw.security.schemaPinning.action) {
    lines.push(`      action: ${gw.security.schemaPinning.action}`);
  }
}
```

**`StackForm.tsx` — add api_key option to auth dropdown (~line 642):**

```tsx
<option value="api_key">API Key</option>
```

Add conditional block for api_key header field (after existing header auth block):

```tsx
{data.gateway.auth.type === 'api_key' && (
  <div>
    <label className={labelClass}>Header Name</label>
    <input
      type="text"
      value={data.gateway.auth.header ?? ''}
      placeholder="X-API-Key"
      className={inputClass}
      onChange={(e) => onChange({ gateway: { ...data.gateway, auth: { ...data.gateway!.auth!, header: e.target.value } } })}
    />
    <p className="text-[10px] text-text-muted mt-1">Header that carries the API key value</p>
  </div>
)}
```

**`StackForm.tsx` — add Gateway Advanced Section:**

Add after the closing `</Section>` of the existing Gateway section (around line 722):

```tsx
<Section
  title="Gateway Advanced"
  expanded={expandedSections.has('gateway-advanced')}
  onToggle={() => toggleSection('gateway-advanced')}
  badge={advancedGatewayBadge}
>
  {/* Tracing sub-group */}
  <div className="space-y-3">
    <p className="text-[11px] font-medium text-text-muted uppercase tracking-wide">Tracing</p>
    {/* enabled toggle */}
    {/* sampling + retention in 2-col grid */}
    {/* export dropdown */}
    {/* endpoint, conditional on export === 'otlp' */}
  </div>

  {/* Schema Pinning sub-group */}
  <div className="space-y-3 mt-4">
    <p className="text-[11px] font-medium text-text-muted uppercase tracking-wide">Schema Pinning</p>
    {/* enabled toggle */}
    {/* action dropdown, conditional on enabled */}
  </div>

  {/* Performance sub-group */}
  <div className="space-y-3 mt-4">
    <p className="text-[11px] font-medium text-text-muted uppercase tracking-wide">Performance</p>
    {/* code_mode_timeout, conditional on codeMode === 'on' */}
    {/* maxToolResultBytes */}
  </div>
</Section>
```

### Reusable Components

- `Section` component (StackForm.tsx lines 53–94) — same pattern as Gateway, Network, Secrets
- `expandedSections` state + `toggleSection` handler — already in StackForm
- Conditional rendering on `data.gateway?.codeMode === 'on'` — matches existing codeMode pattern
- `inputClass` / `labelClass` constants — defined in StackForm

## UX Specification

**api_key auth:**
- Discovery: existing auth type dropdown gains a third option
- Activation: select "API Key" → header name field appears
- The `token` field label should update context: for bearer it's "Token Env Var", for api_key it's the same — the API key value

**Gateway Advanced accordion:**
- Discovery: collapsed accordion below the main gateway fields, labeled "Gateway Advanced"
- Activation: click to expand → reveals three sub-groups
- Feedback: badge on the accordion header counts how many advanced fields are set (non-empty, non-default)
- Error states: no required fields; all optional

**Tracing sub-group:**
- `enabled` toggle: ON by default (placeholder communicates this; don't pre-populate the form, let the user explicitly set it)
- `sampling`: number input 0.0–1.0, step 0.1, placeholder "1.0"
- `retention`: text input, placeholder "24h", helper "e.g. 12h, 48h, 7d"
- `export`: dropdown with "None" (empty string) and "OTLP"
- `endpoint`: text input, visible only when export=OTLP, placeholder "http://localhost:4318"

**Schema Pinning sub-group:**
- `enabled`: toggle OFF by default
- `action`: dropdown visible when enabled, options "Warn (log and continue)" and "Block (reject tool calls)"

**Performance sub-group:**
- `code_mode_timeout`: number input, visible only when `codeMode === "on"`, placeholder "30", helper "Seconds. Default: 30"
- `maxToolResultBytes`: number input, always visible in section, placeholder "65536", helper "Bytes. Default: 64KB (65536)"

## Implementation Notes

### Conventions to Follow

- YAML keys must match Go struct YAML tags exactly: `code_mode_timeout`, `maxToolResultBytes`, `tracing`, `sampling`, `retention`, `export`, `endpoint`, `security`, `schema_pinning`, `enabled`, `action`
- Use `camelCase` in the TypeScript interface (`codeModeTimeout`, `maxToolResultBytes`, `schemaPinning`)
- Serialization: omit fields at their zero/default value where the Go struct uses `omitempty` (sampling=1.0 default should probably still be emitted if user explicitly sets it — emit when form field has a value)
- The `Section` component requires a `title` prop and `expanded`/`onToggle` for controlled state
- Badge count: compute a derived value counting non-empty/non-default advanced fields

### Potential Pitfalls

- **`tracing.enabled` is `bool` not `*bool`**: Unlike `pin_schemas`, this is a non-pointer bool. In Go, omitting the tracing block entirely means defaults apply. Only emit `tracing:` block if the user has explicitly configured at least one field. Don't emit `enabled: true` if user hasn't touched tracing (it's the default and adds noise).
- **`schema_pinning` nesting**: The YAML path is `gateway.security.schema_pinning.enabled` and `gateway.security.schema_pinning.action` — two levels deep under gateway. Don't flatten this.
- **`code_mode_timeout` visibility**: Gate on `data.gateway?.codeMode === 'on'`, not just non-null. Must be hidden when code mode is off.
- **Expanding sections state**: The `expandedSections` Set in StackForm uses string keys; pick a unique key like `'gateway-advanced'` that doesn't clash with existing section keys.

### Suggested Build Order

1. **yaml-builder.ts**: Extend `StackFormData.gateway` interface with all new fields
2. **yaml-builder.ts**: Extend `buildStack()` to serialize all new gateway fields
3. **StackForm.tsx**: Add `api_key` option to auth dropdown + conditional header field
4. **StackForm.tsx**: Add `'gateway-advanced'` section state key
5. **StackForm.tsx**: Add Gateway Advanced `Section` with Tracing sub-group
6. **StackForm.tsx**: Add Schema Pinning sub-group
7. **StackForm.tsx**: Add Performance sub-group
8. **StackForm.tsx**: Compute and pass badge count for Gateway Advanced section
9. **StackForm.test.tsx**: Tests for api_key auth type and header field
10. **StackForm.test.tsx**: Tests for Gateway Advanced section visibility and all field states
11. **StackForm.test.tsx**: Serialization tests for each sub-group
12. Run `npm test` in `web/`

## Acceptance Criteria

1. Auth type dropdown includes "API Key" as a third option alongside Bearer Token and Custom Header
2. Selecting API Key reveals a "Header Name" text input
3. `api_key` auth serializes as `type: api_key`, `token: <value>`, and optionally `header: <name>`
4. A "Gateway Advanced" collapsible accordion is present below the main gateway config
5. The accordion contains three labeled sub-groups: Tracing, Schema Pinning, Performance
6. Tracing `endpoint` field only appears when `export` is set to "otlp"
7. Schema pinning `action` dropdown only appears when `enabled` toggle is on
8. `code_mode_timeout` field only appears when `code_mode` is "on"
9. All tracing fields serialize to a `tracing:` block under `gateway:` in YAML output
10. Schema pinning serializes to `security.schema_pinning:` block in YAML output
11. The accordion badge shows a count of non-empty advanced fields
12. All fields are optional; empty/default values do not emit YAML keys
13. Existing gateway tests (bearer auth, custom header auth, code_mode, output_format) continue to pass
14. All new fields have test coverage
15. TypeScript build passes with no type errors

## References

- `pkg/config/types.go` — `GatewayConfig` (54–93), `TracingConfig` (39–51), `GatewaySecurityConfig` (95–99), `SchemaPinningConfig` (101–109), `AuthConfig` (111–120)
- `docs/config-schema.md` — gateway section with all field semantics
- [HCP Terraform Sentinel policy levels](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/policy-enforcement/manage-policy-sets) — reference for warn/block UX pattern
- [Kong Manager OpenTelemetry plugin](https://developer.konghq.com/plugins/opentelemetry/reference/) — reference for tracing form field patterns
- Full evaluation: `prompt-stack/prompts/gridctl/wizard-gateway-advanced/feature-evaluation.md`
