# Feature Implementation: TS Skill Schema Extraction

## Context

gridctl is a Go-built MCP server that hosts "Agent Skills" — markdown-defined
capabilities that either ship as prompts only, or pair a SKILL.md with a typed
handler (`skill.go` for Go skills, `skill.ts` for TypeScript skills). The daemon
exposes registered skills as MCP tools through `pkg/registry`.

**Architecture for TS skills**:
- TS source is transpiled via the `esbuild` Go library (`pkg/agent/sandbox/transpile.go`).
- Transpiled JS runs inside an embedded `goja` JavaScript engine (`pkg/agent/sandbox/`).
- **No Node.js process is involved at runtime**.
- A `gridctl agent build` CLI subcommand pre-compiles TS skills to JS and writes a
  per-skill `manifest.json` (`cmd/gridctl/agent.go:runAgentBuildTS`).

**Today's gap**: every TS skill registered with the registry surfaces a hardcoded
placeholder JSON Schema `{"type":"object"}` in two places:
1. `pkg/registry/server.go:148-151` — runtime, when `Tools()` lifts walker-discovered
   TS skills into `mcp.Tool` envelopes.
2. `cmd/gridctl/agent.go:471` — build, when `runAgentBuildTS` writes
   `manifest.json` with `"input_schema": {"type":"object"}`.

The web Run Launcher (`web/src/components/agent/ide/RunLauncherModal.tsx`) renders
a Form tab using `@rjsf/core` + `@rjsf/validator-ajv8` — but only when
`schemaHasProperties()` (line 467-475) returns true. Because every TS skill exposes
the placeholder, the Form tab is hidden universally and operators are forced into
the JSON fallback.

The Go skill path already does the right thing: `pkg/agent/skill/schema.go`
reflects Go input structs into JSON Schema via `invopop/jsonschema`, strips
metadata Anthropic/OpenAI reject (`$schema`, `$id`, `$anchor`), and forbids
additional properties.

This feature extends the same fidelity to the TS path.

## Evaluation Context

Key findings from the feature evaluation that shaped this prompt:

- **Market position is catch-up, not differentiation.** FastMCP (Pydantic) and
  mcp-typescript-sdk (Zod) both auto-derive tool schemas. gridctl's Go path
  already does. Multiple in-the-wild bug reports
  (modelcontextprotocol/typescript-sdk#1643, promptfoo#5960, vercel/ai#12020)
  describe gridctl's current TS behavior as a defect.
- **Anthropic/OpenAI strict-mode tool use requires Draft 2020-12, inlined refs,
  `additionalProperties: false`, no `$schema`/`$id`/`$anchor`, no top-level
  composition keywords.** The Go-side stripper in `pkg/agent/skill/schema.go:72-80`
  is the canonical template — the TS path must apply the same post-processing.
- **Static extraction is the right approach for this project.** The user has
  explicitly chosen to preserve idiomatic-TS authoring (native `interface`
  declarations) and avoid Node.js in the daemon hot path. `ts-json-schema-generator`
  v2.5.0 (Feb 2026) is the community-recommended tool and is mature.
- **The dev/build hybrid is intentional.** Build-time extraction goes into
  `manifest.json`; dev-time extraction in the IDE watcher runs async with
  last-known-good fallback to keep canvas re-renders snappy.
- **The runtime-schema escape hatch (TypeBox/Zod inside goja) is deferred.**
  Only one TS skill exists today; the static path covers the entire existing
  authoring convention. Revisit only if a real author actively asks for runtime
  validation.

Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/ts-skill-schema-extraction/feature-evaluation.md`

## Feature Description

Extract real JSON Schemas from each TS skill's input type and surface them
through the existing registry → MCP tool → Run Launcher pipeline.

**What changes**:
- `gridctl agent build` invokes `ts-json-schema-generator` to derive a JSON
  Schema for the named input interface, post-processes it for Anthropic/OpenAI
  compatibility, and writes the result into `manifest.json`.
- The registry walker reads `manifest.json` when discovering a TS skill, caches
  the schema on the `AgentSkill`, and the registry server returns it in
  `mcp.Tool.InputSchema` instead of the `{"type":"object"}` placeholder.
- The IDE dev server watches TS files and re-extracts schemas async on save,
  with last-known-good fallback if Node is slow or unavailable.
- The manifest carries a `schema_status` field; the launcher UI shows an inline
  note in the JSON tab when extraction failed.
- The TS skill scaffold (`pkg/agent/dev/scaffold/scaffold.go`) seeds JSDoc
  descriptions on its input interface so authors learn the pattern.

**What does NOT change**:
- Skill authoring convention. Authors still write
  `interface FooInput { ... }` + `export default async function run(input: FooInput)`.
  No new API surface.
- The goja runtime, sandbox bindings, or any wire-format field. The
  `input_schema` field already exists in manifest and in `mcp.Tool`.
- The web Form tab logic. Its conditional fires automatically when
  `schema.properties` becomes non-empty.

## Requirements

### Functional Requirements

1. **Build-time extraction**: `runAgentBuildTS` in `cmd/gridctl/agent.go` MUST
   invoke `ts-json-schema-generator` on the TS source and write the extracted
   schema into `manifest.json`'s `input_schema` field. The default-export's
   first-parameter type is the extraction target.
2. **Input interface convention**: extraction looks up the type of the default
   export's first parameter. If the parameter is annotated with a named type
   (e.g. `interface TriageInput`), generate a schema for that type. If the
   parameter is inline (`run(input: { foo: string })`), still extract — but
   prefer named interfaces in the scaffold.
3. **Post-processing**: apply the same metadata strip the Go-side reflector does
   (`pkg/agent/skill/schema.go:72-80`):
   - Remove `$schema`, `$id`, `$anchor` from the top level.
   - Ensure `additionalProperties: false` on every object (where the source type
     is closed).
   - Inline `$ref` and `$defs` so the schema is self-contained
     (`ts-json-schema-generator --no-top-ref --expose all` or equivalent).
   - Reject top-level non-object schemas (a TS skill input MUST be an object).
4. **Manifest schema-status field**: extend the manifest JSON shape with
   `schema_status` (`extracted` | `fallback` | `error`) and `schema_error` (string,
   optional). Default is `extracted` when the schema came out clean.
5. **Registry load**: `pkg/registry/store.go` MUST read `manifest.json` when the
   walker discovers a TS skill with a `dist/manifest.json` (or whatever location
   the build emits), parse it, and cache `InputSchema` on the `AgentSkill`
   struct. Missing or unreadable manifest → fall back to today's placeholder.
6. **Registry server**: `pkg/registry/server.go:Tools()` MUST use the cached
   schema when present and only fall back to `defaultInputSchema()` when absent.
   The wire envelope (`mcp.Tool.InputSchema`) does not change shape.
7. **Dev watcher**: the dev server (`pkg/agent/dev/*`) MUST re-extract schemas
   on TS file save, asynchronously, with last-known-good fallback so the canvas
   re-render never blocks on Node CLI invocation. If Node is unavailable on the
   dev machine, log a one-time warning and continue with the previous schema (or
   the placeholder if no previous schema exists).
8. **Launcher UI**: surface `schema_status` to the launcher. When status ≠
   `extracted`, render a low-key inline note in the JSON tab ("freeform input —
   schema couldn't be extracted from TS"). Do NOT block the Run button.
9. **Default tab**: when `schemaHasProperties()` is true, default
   `activeTab` to `'form'` instead of `'json'`
   (`web/src/components/agent/ide/RunLauncherModal.tsx:71`).
10. **Scaffold update**: seed JSDoc descriptions on `HelloInput` properties in
    `pkg/agent/dev/scaffold/scaffold.go:208-214` so the canonical template
    propagates JSDoc usage to new skills.

### Non-Functional Requirements

- **Compatibility**: emitted schemas MUST validate as JSON Schema Draft 2020-12
  (the dialect Anthropic strict-mode requires) and MUST be acceptable to
  `@rjsf/validator-ajv8` (the launcher's client-side validator).
- **Performance**: build-time extraction adds <1s per skill on a clean tsconfig.
  Dev watcher re-extraction MUST run async and MUST NOT block canvas re-render
  on Node latency.
- **Failure isolation**: a single skill that fails extraction MUST NOT prevent
  others from registering. The walker logs the failure and uses the placeholder
  schema.
- **Determinism**: schema fingerprint (already in manifest via `source_hash`)
  guarantees the same TS source produces the same schema. Add an explicit
  `schema_hash` for downstream cache busting.

### Out of Scope

- Runtime schema validation in goja (TypeBox / Zod / Valibot). Authors keep
  using native interfaces.
- A `defineSkill({ schema, run })` wrapper API. The default-export convention
  stays.
- Schema versioning / migrations. Schemas are regenerated from source on every
  build.
- Composition keywords (`oneOf`/`anyOf`/`allOf`) at the top level — even if
  ts-json-schema-generator emits them, the post-processor MUST refuse or
  collapse them, since Anthropic strict-mode rejects them. Nested composition
  is acceptable where the LLM provider supports it.
- Bundled / multi-file TS skills. Single-file skills are the Phase C contract
  (see `pkg/agent/sandbox/transpile.go:21-22`).

## Architecture Guidance

### Recommended Approach

**Single source of truth = the manifest.json that build already emits.** The
build path enriches it; the registry reads from it; the dev watcher rewrites it
on save. One artifact, two writers (build CLI + dev watcher), one reader
(registry walker).

```
┌────────────────────┐   ts-json-schema-generator    ┌──────────────────┐
│  skill.ts (source) │ ───────────────────────────▶ │  manifest.json   │
│  interface FooIn   │                               │   input_schema   │
└────────────────────┘                               │   schema_status  │
                                                     │   schema_hash    │
                                                     └─────────┬────────┘
                                                               │
                              registry walker reads at load    │
                                                               ▼
                                                     ┌──────────────────┐
                                                     │  AgentSkill      │
                                                     │   InputSchema    │ ─▶ mcp.Tool ─▶ Run Launcher / MCP clients
                                                     └──────────────────┘
```

A small Go package wraps the Node CLI invocation:

```go
// pkg/agent/build/tsschema/extract.go (new)
package tsschema

type Result struct {
    Schema      json.RawMessage
    Status      string // "extracted" | "fallback" | "error"
    ErrorReason string
    Hash        string
}

func Extract(sourcePath string, typeName string) (Result, error)
```

This wrapper:
- Locates `ts-json-schema-generator` (prefer a project-local
  `node_modules/.bin/`, fall back to `npx`, fall back to `error`).
- Builds a synthetic tsconfig if one is not present alongside the skill.
- Invokes the CLI with `--path <sourcePath> --type <typeName> --no-top-ref`.
- Parses stdout, runs the post-processor (strip `$schema`/`$id`/`$anchor`,
  enforce `additionalProperties: false`, reject non-object root).
- Returns a `Result` the build CLI and dev watcher both use.

The post-processor lives in `pkg/agent/build/tsschema/postprocess.go` and is a
straight port of the metadata strip in `pkg/agent/skill/schema.go:72-80`. Where
possible, **share the strip logic** — extract it into a small helper both
packages call.

**Inferring the type name to extract**: the canonical pattern is
`export default async function run(input: TInput)`. A naive but reliable
approach for Phase C:

1. Use a tiny TS-source scanner (regex in Go, mirroring
   `pkg/agent/dev/parser/ts.go` style) to find the `default export`'s first
   parameter annotation.
2. If it's a named identifier (`TInput`), pass that to `--type TInput`.
3. If it's inline (`{...}`), synthesize a wrapper type `__GridctlInput`,
   compile a temporary `wrapper.ts` that re-exports it, and run the generator
   against the wrapper. (Edge case; defer if not seen in practice.)

### Key Files to Understand

Read these first, in this order:

1. **`/Users/william/code/gridctl/cmd/gridctl/agent.go`** (`runAgentBuildTS`,
   lines 437-497) — the build path that writes the manifest. This is the
   primary integration point.
2. **`/Users/william/code/gridctl/pkg/registry/server.go`** (lines 113-212) —
   `Tools()` lifting walker-discovered TS skills into `mcp.Tool` envelopes and
   the `defaultInputSchema()` fallback.
3. **`/Users/william/code/gridctl/pkg/registry/store.go`** (lines 394-519) —
   the walker that discovers skills on disk. The manifest-read hook lives here.
4. **`/Users/william/code/gridctl/pkg/registry/types.go`** — `AgentSkill`
   struct. Add a cached `InputSchema json.RawMessage` field (and a
   `SchemaStatus string` for diagnostics).
5. **`/Users/william/code/gridctl/pkg/agent/skill/schema.go`** (lines 29-81) —
   the Go-side reflector. The metadata strip (lines 72-80) is the template the
   TS post-processor must match.
6. **`/Users/william/code/gridctl/pkg/agent/sandbox/transpile.go`** — the
   "narrow Go wrapper around an esbuild library call" idiom. The new tsschema
   wrapper mirrors this shape but shells out to Node instead.
7. **`/Users/william/code/gridctl/examples/registry/items/triage-ts/skill.ts`** —
   the only existing TS skill. Use it as the first end-to-end test target.
8. **`/Users/william/code/gridctl/pkg/agent/dev/scaffold/scaffold.go`** (lines
   200-237) — the scaffold template to update with JSDoc descriptions.
9. **`/Users/william/code/gridctl/web/src/components/agent/ide/RunLauncherModal.tsx`**
   (lines 71, 290-330, 467-475) — Form tab gate and default tab. Will need a
   one-line default-tab flip + a small inline notice when schema_status ≠
   `extracted`.
10. **`/Users/william/code/gridctl/web/src/components/agent/ide/SchemaForm.tsx`** —
    the RJSF wrapper. No changes likely needed; verify it handles realistic
    nested schemas (the triage-ts schema is simple, but plan ahead).
11. **`/Users/william/code/gridctl/pkg/agent/dev/devserver/devserver.go`** —
    where the dev IDE serves skill metadata. The watcher hook lives nearby; this
    is where async extraction integrates.
12. **`/Users/william/code/gridctl/pkg/agent/dev/parser/ts.go`** — the existing
    lightweight TS source scanner. Pattern reference for the "find the default
    export's input type name" helper.

### Integration Points

| Hook | File | What changes |
|---|---|---|
| Build-time extraction | `cmd/gridctl/agent.go:runAgentBuildTS` | Replace hardcoded `input_schema` literal with `tsschema.Extract` result |
| Manifest carrier | `cmd/gridctl/agent.go:471` + manifest readers | Add `schema_status`, `schema_error`, `schema_hash` fields |
| Registry walker | `pkg/registry/store.go:loadSkills` / `detectHandler` | After detecting TS handler, look for `dist/manifest.json` sibling and parse `input_schema` |
| Registry types | `pkg/registry/types.go` | Add `InputSchema json.RawMessage` and `SchemaStatus string` to `AgentSkill` |
| Registry server | `pkg/registry/server.go:Tools()` (line 148-151) | Use cached schema when present; fall back to `defaultInputSchema()` only when absent |
| Dev watcher | `pkg/agent/dev/devserver/devserver.go` (or wherever the watcher dispatches) | On `skill.ts` save, kick off `tsschema.Extract` async; on success, rewrite manifest + push update to IDE |
| Launcher default tab | `web/src/components/agent/ide/RunLauncherModal.tsx:71` | Default `activeTab` to `form` when `schemaHasProperties()` is true |
| Launcher status note | `web/src/components/agent/ide/RunLauncherModal.tsx` (JSON tab) | When `schema_status !== 'extracted'`, render a low-key inline note above the textarea |
| Skill scaffold | `pkg/agent/dev/scaffold/scaffold.go:200-237` | Add JSDoc descriptions to `HelloInput` properties |
| MCP wire envelope | `pkg/mcp/types.go` Tool struct | No changes; field already exists |

### Reusable Components

- **`pkg/agent/skill/schema.go`** — extract the metadata-strip helper into a
  small shared internal function both Go-reflect and TS-extract paths call.
- **`pkg/agent/sandbox/transpile.go`** — pattern reference: a small,
  single-responsibility wrapper that shells out (esbuild lib in that case;
  Node CLI in ours).
- **`pkg/agent/dev/parser/ts.go`** — pattern reference for a small regex-based
  TS scanner. Use it as the template for "find the default export's parameter
  type name" if needed.
- **`pkg/registry/store.go:HandlerPath`** — the existing handler-path lookup
  already gives the registry server the disk location of skill source; the
  manifest reader needs to derive the manifest path from the same source path.
- **`pkg/controller/go_plugins.go`** (around lines 105-140) — the existing
  manifest read/decode idiom that the TS path should mirror.

## UX Specification

### Discovery
The Run Launcher Form tab appears automatically as soon as a TS skill's
extracted schema has `properties` (handled by existing
`schemaHasProperties()` at `RunLauncherModal.tsx:467`).

### Activation
Operators click "Run" on the IDE skill tile. The launcher modal opens. With
this feature live, the Form tab is the default active tab for TS skills with
extracted schemas; JSON remains a one-click escape hatch.

### Interaction
- Form tab renders RJSF fields with labels (from property names, refined by
  JSDoc descriptions), required-markers, type-appropriate controls.
- Switching Form ↔ JSON keeps state in sync (already implemented).
- Submit triggers `launchRun` exactly as today.

### Feedback
- Client-side AJV validation surfaces missing required fields and type
  mismatches on submit attempt (RJSF default; `liveValidate={false}` per
  current SchemaForm.tsx).
- When `schema_status !== 'extracted'`, the JSON tab shows a low-key inline
  note like: "freeform input — schema couldn't be extracted from TS source
  (see dev console)". The Run button stays enabled.
- The dev IDE console (`gridctl agent dev` foreground output) logs extraction
  warnings.

### Error states
- Extraction failure during `gridctl agent build` → manifest written with
  `schema_status: "error"`, `schema_error: "<reason>"`, `input_schema:
  {"type":"object"}`. Build does NOT fail — author sees stderr warning,
  artifact still ships.
- Manifest absent at registry load → walker uses placeholder (today's
  behavior), no error surfaced.
- Schema present but not a JSON object schema → walker rejects, falls back to
  placeholder, logs.

## Implementation Notes

### Conventions to Follow

- **Imperative-mood, ≤50-char commit subjects**, conventional prefix (`feat:`,
  `fix:`, `refactor:`). All commits signed (`-S`). No Co-authored-by trailers.
  No mention of Claude in commits/PRs/branches. (See `~/.claude/CLAUDE.md`.)
- **Package layout**: new package `pkg/agent/build/tsschema/` for the
  extraction wrapper + post-processor. Tests in `tsschema_test.go` with
  table-driven fixtures.
- **JSON Schema fixture-driven tests**: assert generated schemas exactly
  match expected JSON for representative inputs (the existing triage-ts +
  several constructed examples covering optional fields, enums, nested
  objects, arrays).
- **Error wrapping**: `fmt.Errorf("tsschema: %w", err)` — matches existing
  registry/skill style.
- **Doc comments**: package-level doc comment explains the build vs. dev split
  and the Node.js dependency rationale.

### Potential Pitfalls

- **Type-name discovery**: the default export's parameter type may be a
  qualified name (`run(input: types.FooInput)`), a generic instantiation, or
  inline. Handle named identifiers first; defer the harder cases or fall back
  to the placeholder with `schema_status: error`.
- **JSDoc → JSON Schema mapping**: ts-json-schema-generator does this
  natively for `@description`. Verify the post-processor doesn't strip
  description fields — they're the operator-facing label text.
- **Anthropic strict-mode**: never let `$schema`, `$id`, `$anchor`, or
  top-level `oneOf`/`anyOf`/`allOf` leak through. Add unit tests that
  explicitly assert their absence.
- **AJV draft compatibility**: AJV needs to validate against Draft 2020-12.
  Verify `@rjsf/validator-ajv8` supports the dialect (it does, but confirm
  the validator config in `SchemaForm.tsx`).
- **Goroutine leakage in the dev watcher**: async extraction must use a
  cancellable context and bound the extractor child-process so a stuck Node
  CLI doesn't leak file descriptors. Use `exec.CommandContext` with a
  reasonable timeout (e.g. 10s).
- **Node.js detection**: don't fail silently if Node is missing. Surface a
  clear one-time warning in the dev console and a build-time error message
  pointing to install docs.

### Suggested Build Order

1. **Scaffold the extractor wrapper** (`pkg/agent/build/tsschema/`): pure-Go
   structure, table-driven tests against fixture .ts files. Don't wire it in
   yet — verify in isolation that it produces the expected schemas for triage-ts
   and 3-5 constructed cases.
2. **Wire build-time** (`cmd/gridctl/agent.go:runAgentBuildTS`): replace the
   hardcoded `input_schema` with the extractor result. Add `schema_status` etc.
   to the manifest. Update build-report fixtures.
3. **Wire registry walker** (`pkg/registry/store.go` + `types.go`): read the
   manifest sidecar when discovering TS skills, cache `InputSchema` on
   `AgentSkill`. Update `pkg/registry/server.go:Tools()` to use it.
4. **End-to-end test**: build triage-ts, restart daemon, hit the registry
   `Tools()` endpoint, verify the schema appears. Open the web Launcher and
   confirm the Form tab is now visible and active by default.
5. **Wire dev watcher** (`pkg/agent/dev/*`): re-extract on save with async
   + last-known-good fallback. Update IDE skill list response shape if needed
   to carry `schema_status`.
6. **Web UI polish**: flip default tab; add the `schema_status` inline note.
7. **Scaffold JSDoc seed** (`pkg/agent/dev/scaffold/scaffold.go`).
8. **AGENTS.md / docs**: document the Node-on-build-machine dependency, the
   schema extraction flow, and the JSDoc-as-form-label tip. Per `/sync-gridctl`
   convention, keep AGENTS.md in sync with codebase reality.

## Acceptance Criteria

1. `gridctl agent build` for `examples/registry/items/triage-ts/` produces a
   `manifest.json` whose `input_schema` is the JSON Schema for `TriageInput` —
   not `{"type":"object"}`.
2. The emitted schema for `TriageInput` has
   `properties.incident_description.type === "string"`,
   `properties.affected_system.type === "string"`,
   `required === ["incident_description"]`, `additionalProperties === false`,
   and no `$schema`/`$id`/`$anchor` keys.
3. `manifest.json` includes `schema_status` (= `"extracted"` for the happy
   path) and `schema_hash` (sha256 of the schema bytes).
4. When the daemon serves the registry, the `mcp.Tool` envelope for `triage-ts`
   carries the same schema (verifiable via `curl` against the gateway tools
   endpoint or via an existing MCP-tools-list test path).
5. Opening the Run Launcher for `triage-ts` in the web IDE shows the Form
   tab as the default active tab, with labeled fields for `incident_description`
   (required) and `affected_system` (optional).
6. AJV validation in the launcher rejects submission when
   `incident_description` is blank, before the network round-trip.
7. A TS skill whose input type can't be extracted (e.g., a deliberately
   constructed conditional-type pathological case) gets `schema_status:
   "error"`, falls back to `{"type":"object"}`, and DOES NOT prevent the
   daemon from starting or the skill from being callable via the JSON tab.
   The launcher shows the inline "freeform input" note.
8. `gridctl agent dev` re-extracts schemas asynchronously on save without
   blocking the canvas re-render. Verified by editing `triage-ts/skill.ts`'s
   interface and seeing the new schema reflected in the launcher within
   a couple of seconds, while canvas re-render fires immediately on save.
9. When Node.js is unavailable on the dev machine, `gridctl agent dev`
   continues to run, logs a one-time warning, and serves the previous
   schema (or the placeholder if none).
10. `pkg/agent/dev/scaffold/scaffold.go`'s `helloSkillTS` includes JSDoc
    descriptions on `HelloInput` properties.
11. Unit tests in `pkg/agent/build/tsschema/` cover: simple required+optional
    fields, enums (TS string-literal unions), nested objects, arrays,
    JSDoc `@description` propagation, the metadata-strip, and the
    "not an object schema" rejection.
12. `make lint` (golangci-lint), `go test -race ./...`, and `npm run build`
    in `web/` all pass.

## References

- [ts-json-schema-generator (vega) — primary extraction tool](https://github.com/vega/ts-json-schema-generator)
- [MCP spec — Tool definition](https://modelcontextprotocol.io/specification/draft/schema)
- [Anthropic structured outputs / strict tool use](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
- [OpenAI function calling — strict mode](https://developers.openai.com/api/docs/guides/function-calling)
- [FastMCP type-system reference](https://gofastmcp.com/servers/tools)
- [react-jsonschema-form (RJSF) docs](https://rjsf-team.github.io/react-jsonschema-form/)
- [AJV validator (used via `@rjsf/validator-ajv8`)](https://ajv.js.org/)
- [`invopop/jsonschema` — current Go-side reflector](https://github.com/invopop/jsonschema)
- [mcp-typescript-sdk #1643 — exactly gridctl's current breakage](https://github.com/modelcontextprotocol/typescript-sdk/issues/1643)
- Internal: `pkg/agent/skill/schema.go` (Go-side reflector — strip-logic template)
- Internal: `cmd/gridctl/agent.go:runAgentBuildTS` (build path)
- Internal: `pkg/registry/server.go:Tools()` (runtime path)
- Internal: `web/src/components/agent/ide/RunLauncherModal.tsx` (consumer)
