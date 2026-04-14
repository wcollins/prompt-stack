# Feature Implementation: Wizard Spec Completeness (SSH + OpenAPI Auth + mTLS)

## Context

gridctl is a Go/React MCP (Model Context Protocol) gateway aggregator. The backend is written in Go; the frontend is React 19 + TypeScript 5.9 + Tailwind CSS v4 + Zustand + Vite. The visual spec-builder wizard lives in `web/src/components/wizard/` and guides users through creating MCP server configurations without editing YAML.

The wizard supports six server types. The SSH and OpenAPI types have forms, but those forms are incomplete relative to what the YAML schema and Go backend support. This feature adds the missing fields.

**Tech stack summary:**
- Frontend: React 19, TypeScript, Tailwind CSS v4, Zustand v5, Vite
- Testing: Vitest v4 + React Testing Library v16
- Icons: Lucide React
- No UI component library — custom components with Tailwind

## Evaluation Context

- **Backend complete, frontend lagging:** PR #427 (merged April 9, 2026) added OAuth2 CC, query-param, mTLS, and basic auth to the Go backend and validation layer. The wizard was not updated.
- **SSH gap established earlier:** `knownHostsFile` and `jumpHost` were added to `SSHConfig` in a prior commit but never surfaced in the wizard form.
- **No competitor has this:** gridctl is the only GUI tool in the MCP ecosystem with SSH and OpenAPI server wizard support. Completing these forms extends a unique capability rather than chasing parity.
- **UX finding:** Type-selector with conditional field rendering per auth type is table stakes in API client tools (Postman, Insomnia, Bruno). OAuth2 sub-fields should be visually grouped; mTLS should be a separate section from auth.
- **Scope decision:** Advanced network mode (`networks[]` array) is explicitly out of scope for this PR due to higher UI complexity. Do not add it.
- Full evaluation: `prompt-stack/prompts/gridctl/wizard-spec-completeness/feature-evaluation.md`

## Feature Description

Extend the wizard's MCPServerForm with:

1. **SSH advanced fields** — add `knownHostsFile` and `jumpHost` to the existing SSH config section
2. **OpenAPI auth completeness** — add `oauth2`, `query`, and `basic` auth types to the auth type dropdown, each with its own conditional field block
3. **mTLS section** — add a new "TLS / mTLS" collapsible accordion section for OpenAPI servers with `certFile`, `keyFile`, `caFile`, and `insecureSkipVerify`
4. **Per-server schema pinning override** — add a `pin_schemas` 3-state select to the Advanced section of all MCP server types

Update the TypeScript interface and YAML serialization in `yaml-builder.ts` to match. Add tests for all new fields.

## Requirements

### Functional Requirements

1. SSH form must expose `knownHostsFile` and `jumpHost` fields below `identityFile`
2. OpenAPI auth type dropdown must include `oauth2`, `query`, and `basic` options (in addition to existing `bearer` and `header`)
3. When `oauth2` is selected, show: `clientIdEnv`, `clientSecretEnv`, `tokenUrl`, `scopes`
4. When `query` is selected, show: `paramName`, `valueEnv`
5. When `basic` is selected, show: `usernameEnv`, `passwordEnv`
6. A "TLS / mTLS" section must appear for all OpenAPI servers (collapsible accordion) with: `certFile`, `keyFile`, `caFile`, `insecureSkipVerify`
7. All new fields must serialize correctly to YAML in `yaml-builder.ts`
8. `MCPServerFormData` interface in `yaml-builder.ts` must be updated to include all new fields
9. YAML preview must reflect new fields when filled in (this follows automatically from serialization)
10. All new fields must be optional (no required field additions)
11. A `pin_schemas` override selector must appear in the Advanced section of all MCP server types with three options: "Inherit from gateway" (nil/omitted), "Enable" (true), "Disable" (false)
12. `pin_schemas` must serialize as `pin_schemas: true` or `pin_schemas: false` only when explicitly set; omitted when "Inherit from gateway" is selected

### Non-Functional Requirements

- Follow all existing form patterns: 2-column grids for paired fields, monospace inputs for paths/env vars, `text-[10px] text-text-muted mt-1` helper text, `Section` accordion for new sections
- `insecureSkipVerify` toggle must include a visible danger warning
- New fields must not break any existing tests
- Frontend TypeScript must remain type-safe with no `any` casts

### Out of Scope

- Advanced network mode (`networks[]` array with simple/advanced toggle) — follow-on feature
- OAuth2 authorization code flow (only client credentials)
- Dynamic OAuth2 scope discovery
- Certificate file upload UI (paths only, consistent with `identityFile` pattern)
- TransportAdvisor per-auth-type hints (nice-to-have, not blocking)

## Architecture Guidance

### Recommended Approach

Make additive changes to four files in the following order:

1. **Update the data contract** (`yaml-builder.ts`) first — extend `MCPServerFormData.ssh` and `MCPServerFormData.openapi.auth`, add `MCPServerFormData.openapi.tls`
2. **Update YAML serialization** in the same file — extend `buildMCPServer()` SSH and OpenAPI cases
3. **Update the form** (`MCPServerForm.tsx`) — extend the SSH section and add conditional auth blocks + mTLS section
4. **Add tests** — extend `MCPServerForm.test.tsx` with new field visibility and serialization cases

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `web/src/lib/yaml-builder.ts` | TypeScript interface definitions + YAML serialization. Start here. Lines 28–48 are the SSH and OpenAPI form data shapes. Lines 147–173 are the SSH and OpenAPI serialization cases. |
| `web/src/components/wizard/steps/MCPServerForm.tsx` | Primary form component, 1,116 lines. SSH section: lines 709–785. OpenAPI auth section: lines 787–978. Pay attention to the conditional rendering pattern at 843–902. `Section` accordion component defined at lines 169–211. |
| `pkg/config/types.go` | Backend schema — source of truth for field names. `SSHConfig`: lines 194–202. `OpenAPIAuth`: lines 158–176. `OpenAPITLS`: lines 178–185. Field names must match the YAML tags exactly. |
| `web/src/__tests__/MCPServerForm.test.tsx` | Test patterns to follow. Shows default data factory, server type switching, and field visibility assertions. |
| `examples/openapi/openapi-auth.yaml` | Working YAML examples for all 5 auth types + mTLS. Use as reference for expected serialization output. |

### Integration Points

**`web/src/lib/yaml-builder.ts` — interface update (lines 28–48):**

```typescript
// SSH — add two optional fields
ssh?: {
  host: string;
  user: string;
  port?: number;
  identityFile?: string;
  knownHostsFile?: string;  // ADD
  jumpHost?: string;         // ADD
};

// OpenAPI auth — add per-type fields
auth?: {
  type: string;
  tokenEnv?: string;         // bearer
  header?: string;           // header
  valueEnv?: string;         // header / query
  paramName?: string;        // ADD: query
  clientIdEnv?: string;      // ADD: oauth2
  clientSecretEnv?: string;  // ADD: oauth2
  tokenUrl?: string;         // ADD: oauth2
  scopes?: string[];         // ADD: oauth2
  usernameEnv?: string;      // ADD: basic
  passwordEnv?: string;      // ADD: basic
};

// ADD: TLS block for openapi
tls?: {
  certFile?: string;
  keyFile?: string;
  caFile?: string;
  insecureSkipVerify?: boolean;
};
```

**`web/src/lib/yaml-builder.ts` — serialization update (lines 160–173):**

Extend the `case 'openapi':` block after the existing auth fields to serialize:
- `paramName` when `auth.type === 'query'`
- `clientIdEnv`, `clientSecretEnv`, `tokenUrl` when `auth.type === 'oauth2'`
- `scopes` as a YAML list when `auth.type === 'oauth2'` and scopes is non-empty
- `usernameEnv`, `passwordEnv` when `auth.type === 'basic'`
- A `tls:` block after the auth block when `data.openapi.tls` has any non-empty/non-false fields

Also extend `case 'ssh':` to serialize `knownHostsFile` and `jumpHost` when present.

**`web/src/components/wizard/steps/MCPServerForm.tsx` — SSH section extension:**

After the `identityFile` input (around line 780), add:
```tsx
<div>
  <label className={labelClass}>Known Hosts File</label>
  <input
    type="text"
    value={data.ssh?.knownHostsFile ?? ''}
    placeholder="~/.ssh/known_hosts"
    className={inputClass}
    onChange={(e) => onChange({ ssh: { ...data.ssh!, knownHostsFile: e.target.value } })}
  />
  <p className="text-[10px] text-text-muted mt-1">Optional — enables StrictHostKeyChecking=yes</p>
</div>
<div>
  <label className={labelClass}>Jump Host</label>
  <input
    type="text"
    value={data.ssh?.jumpHost ?? ''}
    placeholder="[user@]bastion.example.com[:22]"
    className={inputClass}
    onChange={(e) => onChange({ ssh: { ...data.ssh!, jumpHost: e.target.value } })}
  />
  <p className="text-[10px] text-text-muted mt-1">Optional — bastion/jump host for multi-hop SSH</p>
</div>
```

**`web/src/components/wizard/steps/MCPServerForm.tsx` — OpenAPI auth dropdown extension:**

The `<select>` at line ~820 currently has options: `none`, `bearer`, `header`. Add:
```tsx
<option value="query">Query Parameter</option>
<option value="oauth2">OAuth2 Client Credentials</option>
<option value="basic">Basic Auth</option>
```

Then add three new conditional blocks following the pattern of the existing `bearer` (lines 843–862) and `header` (lines 863–902) blocks:

- Query block: 2-column grid with `paramName` + `valueEnv`
- OAuth2 block: 2-column grid for `clientIdEnv`/`clientSecretEnv`, then `tokenUrl` full-width, then `scopes` (comma-separated input that splits on save, or use `CommandArrayBuilder` equivalent)
- Basic block: 2-column grid with `usernameEnv` + `passwordEnv`

**`web/src/components/wizard/steps/MCPServerForm.tsx` — mTLS Section:**

Add a new `<Section>` accordion after the auth section but before the operations section, visible only when `visibility.openapi` is true:

```tsx
{visibility.openapi && (
  <Section title="TLS / mTLS" defaultOpen={false}>
    <div className="grid grid-cols-2 gap-2">
      {/* certFile + keyFile */}
    </div>
    {/* caFile full-width */}
    {/* insecureSkipVerify toggle with warning */}
  </Section>
)}
```

The `insecureSkipVerify` toggle should use a `<label>` with checkbox or toggle input and a visible warning — e.g., a red/amber badge: "Dangerous — skip only in development".

### Reusable Components

- `Section` (defined in MCPServerForm.tsx ~line 169) — use for the mTLS accordion
- `inputClass` / `labelClass` — already defined in MCPServerForm, use throughout
- `serializeArray` in yaml-builder.ts — use for OAuth2 scopes serialization
- `CommandArrayBuilder` or a simple comma-split approach for scopes input

## UX Specification

**SSH — knownHostsFile and jumpHost:**
- Discovery: appear in the existing SSH Config section, below identityFile
- Activation: always visible when SSH server type is selected
- Interaction: plain text inputs with placeholder showing expected format
- Feedback: helper text below each field explaining the purpose
- Error states: no required validation; both are optional

**OpenAPI — new auth types:**
- Discovery: user expands auth dropdown and sees three new options
- Activation: selecting an option replaces the visible fields (conditional rendering)
- Interaction: env var name inputs (monospace) + URL input for tokenUrl + scopes input
- Feedback: placeholder text shows expected format (e.g., `OAUTH2_CLIENT_ID`, `https://auth.example.com/token`)
- Error states: follow existing pattern — highlight field with error border if validation provided

**mTLS — TLS Section:**
- Discovery: collapsible accordion "TLS / mTLS" below auth, visible for all OpenAPI servers
- Activation: user expands the section (collapsed by default since not always needed)
- Interaction: file path inputs (monospace) for certFile/keyFile/caFile; checkbox/toggle for insecureSkipVerify
- Feedback: insecureSkipVerify carries a visible danger label
- Error states: no required validation; all fields optional

## Implementation Notes

### Conventions to Follow

- YAML field names must match the Go struct YAML tags exactly: `identityFile`, `knownHostsFile`, `jumpHost`, `paramName`, `clientIdEnv`, `clientSecretEnv`, `tokenUrl`, `scopes`, `usernameEnv`, `passwordEnv`, `certFile`, `keyFile`, `caFile`, `insecureSkipVerify`
- `onChange` in MCPServerForm uses spread to preserve existing form state: `onChange({ ssh: { ...data.ssh!, newField: value } })` — maintain this pattern
- Use `data.openapi?.auth?.type === 'oauth2'` style conditional rendering (not a switch statement) to match existing auth blocks
- Follow the `font-mono` class for env var inputs and file path inputs
- The `Section` component takes `title`, `defaultOpen`, and children — use `defaultOpen={false}` for the mTLS section
- Test file uses a `defaultData()` factory — add helper variants `defaultData({ serverType: 'ssh' })` etc. where needed

### Potential Pitfalls

- **Scopes serialization**: The backend expects `scopes: [read, write]` in YAML (a list). The UI needs to collect these as a comma/space-separated string and split before serializing via `serializeArray`. Don't serialize as a plain string.
- **mTLS `insecureSkipVerify`**: This is a boolean in the YAML schema. Don't serialize it if false (omitempty behavior mirrors the Go struct). Check `data.openapi?.tls?.insecureSkipVerify === true` before writing.
- **Spread on nested SSH object**: `data.ssh` can be undefined initially. Use `{ ...data.ssh!, newField: value }` only after checking `data.ssh` is initialized (or initialize it in the server type selection handler).
- **Auth type clearing**: When the auth type changes, old type-specific fields remain in form state but won't serialize (they're gated on `auth.type`). This is fine — no need to clear them on type change.
- **Section badge count**: MCPServerForm has an `advancedCount` badge for the Advanced section. If mTLS fields are in a separate section (not Advanced), no badge count change is needed.
- **`pin_schemas` is `*bool` in Go, not `bool`**: The form state should use `undefined | true | false` (not boolean). Serialize only when not undefined: `if (data.pinSchemas !== undefined) lines.push(...)`. The UI is a 3-option `<select>`: value `""` → undefined (omit), value `"true"` → serialize `pin_schemas: true`, value `"false"` → serialize `pin_schemas: false`.

### Suggested Build Order

1. **yaml-builder.ts**: Update `MCPServerFormData` interface — add SSH fields, expand auth type, add `tls` block, add `pinSchemas?: boolean`
2. **yaml-builder.ts**: Update `buildMCPServer()` serialization — SSH case, OpenAPI case, and `pin_schemas` at the end of all cases
3. **MCPServerForm.tsx**: Add `knownHostsFile` and `jumpHost` inputs to SSH section
4. **MCPServerForm.tsx**: Extend auth type dropdown options
5. **MCPServerForm.tsx**: Add `query` auth conditional block
6. **MCPServerForm.tsx**: Add `oauth2` auth conditional block (most complex — scopes needs array handling)
7. **MCPServerForm.tsx**: Add `basic` auth conditional block
8. **MCPServerForm.tsx**: Add mTLS `Section` accordion after auth section
9. **MCPServerForm.tsx**: Add `pin_schemas` 3-state select to the Advanced section (visible for all server types)
10. **MCPServerForm.test.tsx**: Add visibility tests for new SSH fields
11. **MCPServerForm.test.tsx**: Add visibility tests for each new auth type block
12. **MCPServerForm.test.tsx**: Add tests for pin_schemas: all 3 states serialize correctly
13. **MCPServerForm.test.tsx**: Add serialization tests via yaml-builder for each new auth type
14. Run `npm test` in `web/` to verify all tests pass

## Acceptance Criteria

1. The SSH wizard form shows `knownHostsFile` and `jumpHost` fields below `identityFile` when SSH server type is selected
2. Both SSH fields serialize to the correct YAML keys (`knownHostsFile`, `jumpHost`) only when non-empty
3. The OpenAPI auth dropdown includes `Query Parameter`, `OAuth2 Client Credentials`, and `Basic Auth` options
4. Selecting `query` shows `paramName` and `valueEnv` fields; no other auth fields are visible
5. Selecting `oauth2` shows `clientIdEnv`, `clientSecretEnv`, `tokenUrl`, and `scopes` fields; no other auth fields are visible
6. Selecting `basic` shows `usernameEnv` and `passwordEnv` fields; no other auth fields are visible
7. All new auth type fields serialize to correct YAML matching the structure in `examples/openapi/openapi-auth.yaml`
8. OAuth2 `scopes` serializes as a YAML list (not a flat string)
9. A "TLS / mTLS" collapsible section is present on the OpenAPI form with `certFile`, `keyFile`, `caFile`, and `insecureSkipVerify` fields
10. `insecureSkipVerify: true` serializes to YAML; `false` or unset does not emit the key
11. mTLS fields serialize to a `tls:` block under `openapi:` in the YAML output
12. A `pin_schemas` selector appears in the Advanced section for all server types with three options: "Inherit from gateway" (default), "Enable", "Disable"
13. Selecting "Enable" serializes `pin_schemas: true`; "Disable" serializes `pin_schemas: false`; "Inherit from gateway" omits the key entirely
14. Existing tests for SSH (host/user/port/identityFile) and OpenAPI (bearer/header auth) continue to pass
15. All new form fields are covered by at least one test each
16. TypeScript build passes with no type errors (`npm run build` in `web/`)

## References

- `pkg/config/types.go` — `SSHConfig` (lines 194–202), `OpenAPIAuth` (lines 158–176), `OpenAPITLS` (lines 178–185)
- `docs/config-schema.md` — full field documentation with semantics and constraints
- `examples/openapi/openapi-auth.yaml` — reference YAML for all 5 auth types + mTLS
- `examples/transports/ssh-mcp.yaml` — reference YAML for SSH with knownHostsFile and jumpHost
- [Postman OAuth2 form pattern](https://learning.postman.com/docs/sending-requests/authorization/oauth-20) — reference for grouped OAuth2 sub-fields
- [Hoppscotch mTLS UX](https://hoppscotch.com/blog/hoppscotch-v2024-10-0) — reference for separate TLS section pattern
- Full evaluation: `prompt-stack/prompts/gridctl/wizard-spec-completeness/feature-evaluation.md`
