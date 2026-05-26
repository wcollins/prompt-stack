# Feature Evaluation: TS Skill Schema Extraction

**Date**: 2026-05-14
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium

## Summary

gridctl currently surfaces every TypeScript skill with a placeholder `{"type":"object"}`
input schema. This hides the Run Launcher's Form tab universally and gives MCP
clients (Claude Desktop, Cursor, etc.) opaque tool contracts — a pattern other
ecosystems explicitly flag as broken. Extracting the real schema from each TS
skill's input interface at build time, baking it into the existing `manifest.json`,
and reading it from the registry brings TS skills to parity with Go skills and the
broader MCP ecosystem (FastMCP, mcp-typescript-sdk). The work is moderate (≈2–4
days), risk is low (gracefully falls back to today's behavior on failure), and the
leverage is broad — every TS skill, every operator, every MCP client benefits at
once.

## The Idea

Replace the hardcoded `defaultInputSchema()` `{"type":"object"}` placeholder used
for TypeScript skills with a real JSON Schema derived from each skill's input
interface (`interface FooInput { ... }`). Extraction happens at build time via
`ts-json-schema-generator`, invoked from `gridctl agent build`, and the resulting
schema is baked into the per-skill `manifest.json` (the existing artifact). The
registry reads the manifest at load and serves the real schema in `mcp.Tool`
envelopes. The web Run Launcher's Form tab — already wired and gated on
`schema.properties` being non-empty — activates automatically the moment a real
schema is present.

**Problem solved**:
1. Operators clicking "Run" in the IDE have no in-UI documentation of a TS skill's
   input shape — they read source code or trial-and-error.
2. MCP clients receive opaque tools that match documented breakage patterns
   (modelcontextprotocol/typescript-sdk#1643, promptfoo#5960, vercel/ai#12020).
3. Anthropic and OpenAI strict-mode tool use reject or silently degrade on empty
   schemas — invisibly degrading model behavior in production.

**Who benefits**:
- Operators using the Run Launcher Form tab (every TS skill becomes form-fillable).
- MCP client consumers (richer tool definitions, optional client-side validation).
- TS skill authors (JSDoc descriptions on interface properties become UI labels — a
  free legibility upgrade).
- The LLMs themselves (typed tool-use guidance instead of fabrication-from-description).

## Project Context

### Current State

- **Daemon is Go** with TS skills hosted inside an embedded `goja` JavaScript
  engine. No Node.js process anywhere. esbuild is already linked as a Go library
  (`github.com/evanw/esbuild/pkg/api`) and handles TS→JS transpile.
- **Two integration points** for schema today, both hardcoding the placeholder:
  - `pkg/registry/server.go:148-151` (runtime — Tools() lifting walker-discovered
    TS skills into mcp.Tool entries).
  - `cmd/gridctl/agent.go:471` (build — `runAgentBuildTS` writing manifest.json).
- The runtime path falls back to `defaultInputSchema()` at
  `pkg/registry/server.go:210-212`.
- **Go skills already meet 2026 MCP table-stakes**: `pkg/agent/skill/schema.go`
  uses `invopop/jsonschema` with metadata stripping (`$schema`, `$id`, `$anchor`),
  inlined refs (`DoNotReference: true`), and forbidden `additionalProperties` — all
  intentional, all aligned with Anthropic/OpenAI strict-mode requirements.
- **The Run Launcher Form tab is already implemented**
  (`web/src/components/agent/ide/RunLauncherModal.tsx:296-302`), gated on
  `schemaHasProperties()` (line 467-475). Rendered via lazy-loaded `@rjsf/core` +
  `@rjsf/validator-ajv8` — supports nested objects, enums, arrays, optionals.
- **Only one TS skill exists today** (`examples/registry/items/triage-ts/skill.ts`),
  but the scaffold template (`pkg/agent/dev/scaffold/scaffold.go:200-237`) seeds
  the same `interface FooInput` / `export default async function run` pattern, so
  any future skill inherits the convention.

### Integration Surface

The plumbing is short:

1. **Build time**: `cmd/gridctl/agent.go:runAgentBuildTS` — invoke
   `ts-json-schema-generator` against the skill source, replace the hardcoded
   `{"type":"object"}` literal with the extracted schema. Add a `schema_status`
   field to the manifest.
2. **Walker / loader**: `pkg/registry/store.go:loadSkills` — when the walker
   discovers a TS skill and finds a sibling `dist/manifest.json` (or in-tree
   sidecar), parse it and cache `InputSchema` on the `AgentSkill`. Falls back to
   no-schema if manifest absent.
3. **Registry server**: `pkg/registry/server.go:Tools()` — read the cached
   `InputSchema` from each TS skill; only fall back to `defaultInputSchema()` when
   missing.
4. **Dev watcher**: `pkg/agent/dev/*` — on TS file save, run async extraction with
   last-known-good fallback so the IDE canvas re-render never blocks on Node.
5. **Schema-status surfacing**: when extraction failed/skipped, surface the
   manifest's `schema_status` to the launcher UI as a subtle inline notice in the
   JSON tab; log to the dev console for authors.

### Reusable Components

- **`pkg/agent/skill/schema.go:reflectInputSchema`** — the Go-skill reflection
  path. Its metadata-stripping logic (lines 72-80) is the canonical template for
  what the TS path's post-processor must also do.
- **`pkg/agent/sandbox/transpile.go:TranspileTS`** — pattern for "narrow Go
  wrapper around an esbuild library call". The TS schema-extractor wrapper can
  mirror this shape.
- **`pkg/agent/dev/parser/ts.go`** — existing lightweight TS lexer for the IDE
  canvas. Not the right place to extract types (the file's own comment warns
  against embedding a TS compiler), but a precedent for the
  "lightweight-source-scan" idiom in this codebase.
- **`controller/go_plugins.go`** — manifest read/decode pattern that the TS path
  should mirror for parity.

## Market Analysis

### Competitive Landscape

- **FastMCP** (Python, jlowin/fastmcp) auto-derives JSON Schema from Pydantic
  `TypeAdapter` and auto-dereferences `$ref` for client compatibility. The same
  shape gridctl already does in Go.
- **mcp-typescript-sdk** (Anthropic) accepts a Zod schema in `registerTool` and
  auto-converts to JSON Schema. Known regression (typescript-sdk#1643): when
  conversion silently drops fields, the server emits exactly
  `{"type":"object","properties":{}}` — explicitly called out as broken.
- **LangChain MCP**, **Pydantic AI**, **Vercel AI SDK** all derive schemas from
  typed signatures and strip unsupported keywords before forwarding to providers.

### Market Positioning

**Catch up**, not differentiator. Auto-derived input schemas with form rendering
is table-stakes for 2026 MCP servers. gridctl's Go path is already there; the TS
path is the visible anomaly.

### Ecosystem Support

- `ts-json-schema-generator` v2.5.0 (Feb 2026) — active, ~1.7k stars, full JSDoc
  support, handles unions/enums/optionals/nested types. CLI: `--type FooInput
  --path skill.ts --no-top-ref` produces a clean inlined schema.
- `typescript-json-schema` — in maintenance mode; its README defers to
  ts-json-schema-generator.
- **No Go- or Rust-native equivalent exists** that emits JSON Schema from TS
  types. swc/oxc parse TS to AST but don't emit Schema. esbuild deliberately
  strips types.
- TypeBox / Zod can produce JSON Schema at runtime but require the library to run
  inside goja, which the user has explicitly chosen to defer in favor of
  preserving idiomatic-TS authoring (native interfaces).

### Demand Signals

Concrete in-the-wild reports describing gridctl's exact current state as a defect:
- promptfoo#5960 — empty `inputSchema` triggers provider validation errors.
- openai-agents-python#449 — MCP tools without `properties` break OpenAI Agents.
- gemini-cli#4301 — `inputSchema` silently dropped.
- claude-code#4753, #27337, #34249 — strict-mode constraints around schemas.
- vercel/ai#12020 — empty `input_schema` triggers downstream errors.

## User Experience

### Interaction Model

**Operator (today vs. after)**:
- Today: opens Run Launcher → only JSON tab visible → must read TS source to know
  field names → submits blind and parses server-side errors.
- After: Form tab visible by default when schema has properties, with labels,
  required-markers, type-appropriate controls (string textarea, number input,
  boolean checkbox, enum dropdown), and client-side AJV validation. JSON tab
  remains the power-user escape hatch.

**TS skill author**:
- No source-level change — still write `interface FooInput { ... }`.
- New ergonomic win: JSDoc descriptions on interface properties surface as form
  labels and help text. Worth seeding in the scaffold template.
- New dependency: Node.js must be on the build machine (and ideally on the dev
  machine). For the dev IDE loop, async extraction with last-known-good fallback
  prevents Node latency from blocking canvas re-renders.

**MCP client / LLM**:
- Today: opaque tool, LLM fabricates argument shapes from description string.
- After: typed tool-use, client-side autocomplete and validation become possible.

### Workflow Impact

Pure additive. No existing workflow breaks. The JSON tab continues to work as the
fallback when extraction fails or schemas are absent.

### UX Recommendations

1. **Default the active tab to Form when `hasRichSchema` is true** — flip the hard
   `json` default at `RunLauncherModal.tsx:71`. JSON becomes the deliberate
   escape hatch.
2. **Add `schema_status` to the manifest** (`extracted` | `fallback` | `error`)
   with the extractor's error message. The dev watcher logs warnings to console;
   the launcher surfaces a low-key inline notice ("freeform input — schema couldn't
   be extracted") in the JSON tab. Author-visible without operator-noisy.
3. **Seed JSDoc descriptions in `scaffold.go`** so the hello-world TS skill ships
   with `/** ... */` on its input properties. Authors learn the pattern by
   copy-paste.
4. **Async extraction in the dev watcher** with last-known-good fallback. Schema
   regeneration must never block the IDE canvas re-render.

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Form tab universally dead; MCP tools opaque; LLM tool-use degraded silently |
| User impact | Broad+Shallow → Broad+Deep | One TS skill today, but compounds with TS adoption and benefits every MCP client immediately |
| Strategic alignment | Core mission | gridctl is an MCP server — tool-contract fidelity is the product |
| Market positioning | Catch up | FastMCP and mcp-typescript-sdk both auto-derive; gridctl Go path already does too |

### Cost Breakdown
| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Moderate | Two-point swap (`server.go:151` + `agent.go:471`); zero wire-format churn; no web UI changes required |
| Effort estimate | Medium | ≈2–4 days: extraction wiring, manifest field, registry read, schema_status, dev watcher integration, JSDoc scaffold update, tests |
| Risk level | Low–Medium | Low: pure additive with `{"type":"object"}` fallback. Medium: Node.js as a build-time dep is a real but documented author tax |
| Maintenance burden | Moderate | Pin `ts-json-schema-generator` version; handle long-tail "complex generic doesn't extract" reports |

## Recommendation

**Build with caveats.** Scope:

1. **Static extraction at build time** via `ts-json-schema-generator` invoked from
   `runAgentBuildTS` (`cmd/gridctl/agent.go`). Schema is baked into the existing
   `manifest.json`'s `input_schema` field — no new artifact, no wire-format change.
2. **Registry reads the manifest** on walker load and caches the schema on
   `AgentSkill`. `pkg/registry/server.go:Tools()` returns the real schema when
   present, falling back to `defaultInputSchema()` only when absent or
   unreadable. The fallback path is the safety net.
3. **Post-process extracted schemas** to apply the same metadata strip the Go
   path already does (`pkg/agent/skill/schema.go:72-80`): remove `$schema`, `$id`,
   `$anchor`; enforce `additionalProperties: false` on objects; inline `$ref`. This
   keeps the wire form Anthropic-strict and OpenAI-strict compatible.
4. **Manifest carries `schema_status`** (`extracted` | `fallback` | `error`) with
   the extractor's error message when applicable. The dev watcher logs warnings
   to the IDE console for authors; the launcher surfaces a subtle inline notice
   in the JSON tab when status ≠ extracted.
5. **Dev IDE async extraction** — on save, run extraction asynchronously with
   last-known-good fallback. If Node is unavailable on the dev machine, skip
   extraction with a one-time warning rather than blocking the canvas.
6. **Scaffold update** — seed JSDoc descriptions on `HelloInput` properties in
   `pkg/agent/dev/scaffold/scaffold.go` so the pattern propagates to every new
   skill.

**Defer** (do not build now):
- TypeBox / Zod runtime-schema escape hatch. The static path covers the entire
  current authoring convention. The runtime branch adds API surface and demands a
  goja-compatibility spike for an author who hasn't appeared yet.
- A `defineSkill({ schema, run })` wrapper API. Same reasoning — preserves the
  existing native-interface authoring contract.

**Why not "Build" without caveats**: the scope above is deliberate. A wider cut
that also lands a runtime-schema API would double surface area, force a
TypeBox-in-goja spike, and ship a second-class authoring pattern with one user.
The caveats narrow scope to what the existing fleet of TS skills (one, with more
seeded by the scaffold) actually needs, while leaving the runtime path open as a
follow-up if real authors ask for it.

## References

- [ts-json-schema-generator (vega)](https://github.com/vega/ts-json-schema-generator) — Feb 2026, v2.5.0
- [typescript-json-schema (YousefED)](https://github.com/YousefED/typescript-json-schema) — maintenance mode
- [MCP spec draft schema](https://modelcontextprotocol.io/specification/draft/schema)
- [Anthropic structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
- [OpenAI function calling — strict mode](https://developers.openai.com/api/docs/guides/function-calling)
- [FastMCP type system](https://gofastmcp.com/servers/tools)
- [mcp-typescript-sdk #1643 — silent property drop](https://github.com/modelcontextprotocol/typescript-sdk/issues/1643)
- [promptfoo#5960 — empty inputSchema breaks providers](https://github.com/promptfoo/promptfoo/issues/5960)
- [openai-agents-python#449 — MCP tools without properties](https://github.com/openai/openai-agents-python/issues/449)
- [vercel/ai#12020 — empty input_schema downstream errors](https://github.com/vercel/ai/issues/12020)
- [mcpb#174 — Claude Desktop $defs failure](https://github.com/modelcontextprotocol/mcpb/issues/174)
- [react-jsonschema-form](https://github.com/rjsf-team/react-jsonschema-form) — in use at `web/src/components/agent/ide/SchemaForm.tsx`
- [invopop/jsonschema](https://github.com/invopop/jsonschema) — already in tree, used by Go skill reflection
- [esbuild Go API](https://github.com/evanw/esbuild) — already linked
