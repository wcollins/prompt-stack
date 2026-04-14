# Feature Implementation: Wizard Stack Logging Config

## Context

gridctl is a Go/React MCP gateway aggregator. Backend: Go. Frontend: React 19 + TypeScript 5.9 + Tailwind CSS v4 + Zustand v5 + Vite. The wizard's StackForm handles stack-level configuration. This feature adds a Logging section to the StackForm.

## Evaluation Context

- `LoggingConfig` is fully implemented in the Go backend (`types.go` lines 21–32); all fields are `omitempty`
- No validation in `validate.go` — all validation is runtime (handled by the log rotation library)
- No logging config exists in any form, interface, or YAML serialization in the frontend
- No comparable GUI tool exposes log rotation as labeled form fields — this is a differentiator
- `extends` (stack composition) and `networks[]` (advanced network mode) are explicitly deferred
- Full evaluation: `prompt-stack/prompts/gridctl/wizard-stack-infra/feature-evaluation.md`

## Feature Description

Add a "Logging" collapsible accordion section to the StackForm with four optional fields:

- `logging.file` — path where log output is written (when set, logs go to both the file and the web UI ring buffer)
- `logging.maxSizeMB` — maximum log file size in MB before rotation (default: 100)
- `logging.maxAgeDays` — number of days to retain rotated files (default: 7)
- `logging.maxBackups` — number of compressed old log files to keep (default: 3)

The section is collapsed by default. When `file` is empty, the section badge shows nothing. When `file` is set, the badge shows the filename (or just "configured").

## Requirements

### Functional Requirements

1. A "Logging" collapsed Section accordion must appear in the StackForm (after Network, before or after Secrets)
2. The section must contain four fields: `file`, `maxSizeMB`, `maxAgeDays`, `maxBackups`
3. All four fields must be optional — the section generates no YAML when all fields are empty/zero
4. When `file` is non-empty, the YAML must include a `logging:` block with at minimum `file:`
5. `maxSizeMB`, `maxAgeDays`, `maxBackups` must serialize only when non-zero
6. `StackFormData` in yaml-builder.ts must include `logging?: { file?: string; maxSizeMB?: number; maxAgeDays?: number; maxBackups?: number }`
7. `buildStack()` must serialize the logging block when `data.logging?.file` is set
8. The accordion badge must reflect whether logging is configured (non-empty `file` field)

### Non-Functional Requirements

- `file` uses monospace font (it's a file path), placeholder: `/var/log/gridctl.log`
- Number fields use `type="number"` with `min="1"`
- Placeholder values match defaults: `maxSizeMB` → `100`, `maxAgeDays` → `7`, `maxBackups` → `3`
- Helper text under each number field: "Default: X"
- Three number fields in a 3-column grid to save vertical space
- Collapsed by default; no pre-population of any field

### Out of Scope

- `extends` field (stack composition) — deferred; underdocumented
- Advanced network mode (`networks[]` array) — deferred; requires cross-form changes
- Any log streaming or log viewer UI — this is config only

## Architecture Guidance

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `web/src/lib/yaml-builder.ts` | `StackFormData` interface (lines 66–79): add `logging` field. `buildStack()` (lines 239–288): add logging block after network block. |
| `web/src/components/wizard/steps/StackForm.tsx` | Network section is around lines 724–760. Add Logging section after it. `Section` component defined at lines 53–94. `expandedSections` state + `toggleSection` handler already present. |
| `pkg/config/types.go` | `LoggingConfig` struct (lines 21–32) — source of truth for field names and semantics. |
| `web/src/__tests__/StackForm.test.tsx` | Existing section tests — follow same pattern. |

### Integration Points

**`yaml-builder.ts` — extend `StackFormData`:**

```typescript
export interface StackFormData {
  // ... existing fields
  logging?: {
    file?: string;
    maxSizeMB?: number;
    maxAgeDays?: number;
    maxBackups?: number;
  };
}
```

**`yaml-builder.ts` — extend `buildStack()`** (add after the network block, around line 273):

```typescript
if (data.logging?.file) {
  lines.push('');
  lines.push('logging:');
  lines.push(`  file: ${yamlValue(data.logging.file)}`);
  if (data.logging.maxSizeMB) lines.push(`  maxSizeMB: ${data.logging.maxSizeMB}`);
  if (data.logging.maxAgeDays) lines.push(`  maxAgeDays: ${data.logging.maxAgeDays}`);
  if (data.logging.maxBackups) lines.push(`  maxBackups: ${data.logging.maxBackups}`);
}
```

**`StackForm.tsx` — new Logging Section** (add after Network Section, ~line 760):

```tsx
<Section
  title="Logging"
  expanded={expandedSections.has('logging')}
  onToggle={() => toggleSection('logging')}
  badge={data.logging?.file ? 'configured' : undefined}
>
  <div className="space-y-3">
    <div>
      <label className={labelClass}>Log File Path</label>
      <input
        type="text"
        value={data.logging?.file ?? ''}
        placeholder="/var/log/gridctl.log"
        className={`${inputClass} font-mono`}
        onChange={(e) => onChange({ logging: { ...data.logging, file: e.target.value } })}
      />
      <p className="text-[10px] text-text-muted mt-1">When set, logs are written to this file and the web UI ring buffer</p>
    </div>
    <div className="grid grid-cols-3 gap-2">
      <div>
        <label className={labelClass}>Max Size (MB)</label>
        <input
          type="number" min="1"
          value={data.logging?.maxSizeMB ?? ''}
          placeholder="100"
          className={inputClass}
          onChange={(e) => onChange({ logging: { ...data.logging, maxSizeMB: e.target.value ? Number(e.target.value) : undefined } })}
        />
        <p className="text-[10px] text-text-muted mt-1">Default: 100</p>
      </div>
      <div>
        <label className={labelClass}>Max Age (Days)</label>
        <input
          type="number" min="1"
          value={data.logging?.maxAgeDays ?? ''}
          placeholder="7"
          className={inputClass}
          onChange={(e) => onChange({ logging: { ...data.logging, maxAgeDays: e.target.value ? Number(e.target.value) : undefined } })}
        />
        <p className="text-[10px] text-text-muted mt-1">Default: 7</p>
      </div>
      <div>
        <label className={labelClass}>Max Backups</label>
        <input
          type="number" min="1"
          value={data.logging?.maxBackups ?? ''}
          placeholder="3"
          className={inputClass}
          onChange={(e) => onChange({ logging: { ...data.logging, maxBackups: e.target.value ? Number(e.target.value) : undefined } })}
        />
        <p className="text-[10px] text-text-muted mt-1">Default: 3</p>
      </div>
    </div>
  </div>
</Section>
```

### Reusable Components

- `Section` accordion (lines 53–94 in StackForm.tsx)
- `expandedSections` + `toggleSection` — already in StackForm state
- `inputClass` / `labelClass` — defined in StackForm
- `yamlValue()` helper in yaml-builder.ts — use for the file path

## UX Specification

- **Discovery**: "Logging" accordion collapsed by default, labeled "Logging", no badge when not configured
- **Activation**: user expands, enters a file path
- **Interaction**: file path input + 3-column grid for the rotation settings
- **Feedback**: badge shows "configured" when `file` is non-empty
- **Error states**: none — all fields are optional with no validation

## Implementation Notes

### Conventions to Follow

- YAML keys match Go struct YAML tags exactly: `file`, `maxSizeMB`, `maxAgeDays`, `maxBackups` (camelCase as defined in the struct)
- TypeScript uses the same names: `file`, `maxSizeMB`, `maxAgeDays`, `maxBackups`
- Spread pattern for nested updates: `onChange({ logging: { ...data.logging, file: e.target.value } })`
- Number inputs: parse with `Number()` and guard against empty string → `undefined` (not 0)
- Only emit the logging YAML block when `file` is set; the rotation fields are only meaningful with a file

### Potential Pitfalls

- **Do not serialize logging when `file` is empty**, even if rotation fields are set — the rotation fields have no effect without a file path
- **Number field empty string**: when user clears a number field, store `undefined` not `0` to preserve omitempty behavior in serialization
- **Section key**: use `'logging'` as the expandedSections key; confirm it doesn't conflict with existing keys in StackForm

### Suggested Build Order

1. **yaml-builder.ts**: Add `logging` to `StackFormData` interface
2. **yaml-builder.ts**: Add logging block serialization in `buildStack()`
3. **StackForm.tsx**: Add `'logging'` section and the Logging Section JSX after Network section
4. **StackForm.test.tsx**: Test that Logging section renders, all 4 fields visible on expand
5. **StackForm.test.tsx**: Test that YAML is emitted when file is set, omitted when file is empty
6. **StackForm.test.tsx**: Test that rotation fields omit from YAML when zero/empty
7. Run `npm test` in `web/`

## Acceptance Criteria

1. A "Logging" collapsed accordion appears in the StackForm
2. Expanding it reveals a "Log File Path" text input and three number inputs (Max Size MB, Max Age Days, Max Backups)
3. When Log File Path is empty, no `logging:` block appears in the YAML output
4. When Log File Path is set, the YAML output includes a `logging:` block with `file:`
5. `maxSizeMB`, `maxAgeDays`, `maxBackups` appear in the YAML only when explicitly set (non-zero)
6. The accordion badge shows "configured" when a file path is entered, nothing when empty
7. Number inputs accept positive integers only (min=1)
8. All four fields have placeholder text showing the backend default value
9. Existing StackForm tests pass unmodified
10. TypeScript build passes with no type errors

## References

- `pkg/config/types.go` — `LoggingConfig` (lines 21–32)
- `pkg/config/validate.go` — no logging validation (purely runtime)
- [Nomad log rotation request #23709](https://github.com/hashicorp/nomad/issues/23709) — evidence that this gap is felt widely
- Full evaluation: `prompt-stack/prompts/gridctl/wizard-stack-infra/feature-evaluation.md`
