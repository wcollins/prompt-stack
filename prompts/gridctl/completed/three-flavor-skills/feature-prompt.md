# Feature Implementation: Three-Flavor Skill Authoring Surface (Brief 4)

## Context

**Project**: gridctl — an MCP gateway/orchestrator written in Go (CLI + Vite/React web UI). Single human contributor. Stable on a `v0.1.0-beta` line.

**Tech stack**:
- Go 1.26; cobra CLI; goja+esbuild sandbox (`pkg/agent/sandbox`); MCP gateway (`pkg/mcp`); `pkg/registry` is a directory-based persistent skill store.
- Web: Vite 8 + React 19 + TypeScript 6 + `@xyflow/react ^12.10.0` (the IDE — not touched by this brief).
- CI: lint, race tests, per-package coverage floors, govulncheck, integration matrix on Docker AND Podman, `scripts/check-eino-boundary.sh`.

**Constitutional articles relevant to this work** (see `CONSTITUTION.md`):
- Article I (Library-First): permits Apache 2.0 / MIT Go libraries for foundational concerns where the alternative reinvents a runtime / sandbox / schema validator. Go's stdlib `plugin` package is in scope.
- Article III (Test-First): all exported funcs MUST have tests before merge.
- Article IV (No Mocks in Integration Tests): integration tests MUST exercise real dependencies; MUST run with `-race`.
- Article V (Error Propagation, Not Panic): no `panic` in `pkg/`/`internal/` library code.
- Article VI (Context Propagation): I/O-performing funcs accept `ctx context.Context` first.
- Article X (Machine-Parseable CLI Output): all structured-data commands MUST support `--format json`.
- Article XIV (Structured Logging): `log/slog` only.
- Article XV (Changelog Discipline): every user-visible change goes in `CHANGELOG.md` `[Unreleased]` before merge.

## Evaluation Context

This implementation prompt is informed by a feature evaluation that verified Brief 4's premises against current code and surfaced three small adjustments — folded into this prompt below. Read the full evaluation: `prompts/gridctl/three-flavor-skills/feature-evaluation.md`. Lineage: this completes the thread started by `prompts/gridctl/completed/code-first-agent-runtime/feature-evaluation.md` (Brief 3, the broader agent-runtime evaluation).

Key decisions from the evaluation:

- **Premises hold.** The "file presence is the discriminator" model is real in code; the Phase H deferred path, the TS-only scaffold, the missing CLI flags, and the unwired `SetSkillRegistry` are all confirmed. Don't redesign — connect the named hooks.
- **`Define[I, O]` blast radius is three call sites, not two.** The brief named two callers (skill test fixtures + hello scaffold). The third is `pkg/agent/sandbox/recursive_test.go:46` — the cross-package recursive composition smoke test. All three are first-party; the migration is tractable. Audit explicitly.
- **Mirror the `HelloSkillTS` test-channel pattern.** `pkg/agent/dev/scaffold/scaffold.go:121-126` exports `HelloSkillTS(name string) string` so the regression suite runs scaffold output through the sandbox verbatim. The Go scaffold should export `HelloSkillGo` so a Go-side test channel exists from day one.
- **Hybrid pattern is all-flavors-at-once, not Go-only.** The brief framed `ctx.SkillBody()` as a Go-only accessor. A TS skill running in the goja sandbox needs the same surface or the "all flavors first-class" invariant breaks silently. The hook is already there: `sandbox.Bindings` (`pkg/agent/sandbox/sandbox.go:58`) and `BindingsProvider func(ctx, skillName)` (`dispatcher.go:45`). Add `SkillBody string` + `SkillName string` to `Bindings`; expose them as `skill.body` / `skill.name` (or `context.body` / `context.name`) globals in the JS sandbox. Land Go and TS parity in the same PR.
- **Manifest guardrails for Go plugins.** Record `go_version` (the toolchain `runtime.Version()`) and a sha256 of `go.mod` in the Go skill's `manifest.json` at `agent build` time. At `loadGoSkillPlugins` time, check both against the running daemon and emit an actionable `slog.Warn` on mismatch ("plugin built with Go 1.26.3, daemon running 1.27.0 — rebuild with `gridctl agent build <name>`") instead of letting the opaque `plugin.Open` error confuse the operator. This is the single highest-value Day-2 addition.
- **Don't add `kind:` to the SKILL.md frontmatter.** File presence is the discriminator; adding `kind:` would force the agentskills.io ecosystem to special-case gridctl skills.
- **Go plugins, not sub-process MCP servers.** `go build -buildmode=plugin` is the cheapest path to typed Go skills without inventing IPC. Operational sharp edges (host/plugin version match, no unloading, Linux/macOS only) are real — document them honestly. If plugins prove operationally unworkable in real use, the sub-process fallback is the documented escape hatch; do not preempt. Keep `manifest.json`'s `handler` field naming-flexible enough that a future `handler: "go-binary"` (or similar) doesn't require a schema migration.
- **Pre-1.0 breaking-change cut, no shim.** The richer execution context for `Define[I, O]` is a clean cut. Two-step migration is overkill at this stage.

## Feature Description

Close the three remaining gaps in the skill authoring surface so the three-flavor model — prompt / code-ts / code-go, with an explicit hybrid pattern — is fully shipped:

1. **Go-handler scaffold and build.** Replace the `Phase H` deferred error in `cmd/gridctl/agent.go` with a real `go build -buildmode=plugin` path; emit a `manifest.json` with the same shape as the TS path; wire `SetSkillRegistry` registration at gateway-builder time so `.so` artifacts adjacent to Go-handler skills self-register via a `RegisterSkill(*skill.Registry) error` plugin symbol.
2. **`ctx.SkillBody()` accessor.** Extend the typed `Define[I, O]` first argument from `context.Context` to a richer execution context type that exposes the parsed post-frontmatter markdown body and the registered skill name. Pre-1.0 breaking change.
3. **Scaffold flavor flags.** Add `--lang ts|go` (default `ts`) and `--prompt-only` (mutually exclusive with `--lang go`) to `agent init`.

Plus: a vendored Anthropic skill compatibility test, three new example skills (triage-ts, triage-go, incident-triage-hybrid), and a `docs/skills.md` that names the three flavors as a coherent set.

## Requirements

### Functional Requirements

1. `gridctl agent init --prompt-only --name foo` creates a directory containing only `SKILL.md` (no `skill.ts`, no `skill.go`, no `agent.json`). Result validates and is loadable by `store.Load()`.
2. `gridctl agent init --lang go --name foo` creates a directory containing `SKILL.md` + `skill.go` + `skill_test.go`. The `skill.go` body imports `pkg/agent/skill` and `pkg/agent/llm`, defines typed input/output structs with `json` and `jsonschema` tags, declares `New() *skill.Definition` returning a `Define[HelloInput, HelloOutput]` registration, and exercises one tool call and one `llm.Generate` — same primitives the TS hello hits. Result compiles via `go build`.
3. `gridctl agent init --lang ts --name foo` continues to produce the existing TS scaffold. Default behavior unchanged when no flags are passed.
4. `--prompt-only` and `--lang go` are mutually exclusive. Passing both returns a clear error: `--prompt-only is mutually exclusive with --lang go`.
5. `gridctl agent build foo` for a Go skill on Linux or macOS produces `dist/skill.so` and `dist/manifest.json`. The manifest has the TS shape plus two Go-specific guardrail fields: `name`, `description`, `handler: "go"`, `handler_path: "skill.so"`, `source_hash` (sha256 of `skill.go` source bytes), `input_schema`, **`go_version`** (the build-time `runtime.Version()` value, e.g., `"go1.26.3"`), and **`go_mod_hash`** (sha256 of the `go.mod` bytes resolved relative to the skill source). Status `"ok"`.
6. `gridctl agent build foo` for a Go skill on Windows returns a clear error: `go skill build requires Linux or macOS — Go plugins are not available on Windows`. No opaque `plugin.Open` failure leaks through.
7. At gateway start, `pkg/controller/gateway_builder.go`'s `Build()` walks the registry for skills with `HandlerLanguage == "go"`, opens the adjacent `dist/skill.so` for each, looks up a known `RegisterSkill(*skill.Registry) error` symbol, and calls it against a single `*skill.Registry` instance shared with `registryServer.SetSkillRegistry(reg)`. **Before** `plugin.Open` is invoked, the loader reads the adjacent `dist/manifest.json` and compares `go_version` against `runtime.Version()` and `go_mod_hash` against a fresh hash of the daemon's resolved `go.mod`. On mismatch the loader skips the plugin and emits an actionable `slog.Warn` (e.g., `"go skill foo: plugin built with go1.26.3, daemon running go1.27.0 — rebuild with 'gridctl agent build foo'"`); a missing manifest also logs and skips. Failure to open or look up a symbol on a guardrails-passing plugin also logs a warning and continues — one broken skill does not block gateway start.
8. A skill with `skill.go` registered via the gateway-builder hook is callable via `gridctl run foo` and emits the same MCP tool envelope as a TS or prompt skill — the upstream client cannot tell them apart.
9. The typed handler signature changes from `func(ctx context.Context, input I) (O, error)` to `func(ctx skill.RunContext, input I) (O, error)`. `skill.RunContext` is an interface that embeds `context.Context` and adds `SkillBody() string` and `SkillName() string` accessors. The body and name are loaded at registration time inside `Define[I, O]` (closure capture from the parsed `AgentSkill.Body` already exposed by the registry store) and surfaced as a simple field read with no per-call I/O.

9a. **TS hybrid parity.** The same accessors are available to TS skills running in the goja sandbox. `sandbox.Bindings` (`pkg/agent/sandbox/sandbox.go:58`) gains two fields: `SkillBody string` and `SkillName string`. The `BindingsProvider` (`dispatcher.go:45`) — already passed `skillName` — also resolves the skill's body from the registry store and includes both in the returned `Bindings`. A new sandbox binding exposes the values to JS as a top-level `skill` object: `skill.body` (string) and `skill.name` (string). The `incident-triage-hybrid` example demonstrates the pattern in Go; an analogous `triage-hybrid-ts` (or extend `triage-ts/`) demonstrates `skill.body` carrying the same SRE prose into a `llm()` call's `system` field. Recursive composability invariant: a TS skill that handoffs to another skill receives that other skill's body — body is per-skill, not per-run.
10. The post-scaffold hint differentiates by flavor: TS/Go print `run: gridctl agent dev --root <dir>`; prompt-only prints `run: gridctl skill list --remote && gridctl run <name>`.
11. `tests/integration/anthropic_skill_compat_test.go` vendors a real prompt-only skill from `github.com/anthropics/skills/document-skills/pdf-processing/` (or equivalent small, frontmatter-only skill), drops it verbatim into a temp registry root, and asserts: `store.Load()` succeeds, the skill's frontmatter validates, `registry.Server.Tools()`/prompts surface the body unchanged, `gridctl skill validate <name>` returns valid. Runs in CI.
12. Three new example skills under `examples/registry/items/` exercise the typed surface: `triage-ts/` (basic typed pattern in TS), `triage-go/` (Go equivalent), `incident-triage-hybrid/` (Go skill that uses `ctx.SkillBody()` to pass the markdown body as the LLM system prompt; body contains real SRE-shaped severity + runbook prose).
13. `docs/skills.md` exists and covers the three flavors as a coherent set: one prose section per flavor, one section on the hybrid pattern, one section on recursive composability, and one "what we do NOT support, and why" section.

### Non-Functional Requirements

- `scripts/check-eino-boundary.sh` continues to pass — no Eino types leak across the adapter boundary in any of this work.
- All four LLM provider packages (`pkg/agent/llm/{anthropic,openai,google,gateway,observed}`) remain unchanged.
- The Go plugin path documents its operational sharp edges in the package doc that introduces plugin loading: host/plugin must use identical Go versions and dep graphs, plugins can't be unloaded, builds are platform-specific. Document them where someone debugging a `plugin.Open` failure will read first.
- All new code-skill scaffolds preserve the "fallacy of the graph applies — code is canon" line that the existing TS scaffold carries (`scaffold.go:117`).
- Article X compliance: any new CLI subcommand or flag-driven path supports `--format json` and emits structured output.
- Article XIV compliance: no `fmt.Println`/`log.Printf` in new library code; warnings go through `slog`.
- The Go scaffold is exercised by an end-to-end test that the regression suite invokes against the scaffolded output verbatim — same pattern `HelloSkillTS` enables for the TS path.

### Out of Scope

- Any change to the SKILL.md frontmatter schema. The current schema is deliberately agentskills.io-compliant; do not add `kind:`, `runtime:`, `entry:`, or any other gridctl-specific field. The existing `state:` and `acceptance_criteria:` extensions stay; nothing new gets added.
- Changes to the IDE under `web/src/components/agent/ide/`. The IDE already correctly handles all three flavors — prompt skills as a single node, code skills as a parsed graph.
- The `allowed_providers` field that an earlier draft of Brief 4 proposed. Provider gating is a runtime / vault concern (Brief 3's auth model), not a skill manifest concern.
- Skill marketplace publishing. The existing `pkg/skills` git-import infrastructure already covers all three flavors; no flavor-specific publishing logic.
- Any rework of `gridctl run` or `gridctl runs`. Both work for runnable handlers as-is. Prompt-only skills are exposed as MCP prompts/tools to upstream clients, not invoked through `gridctl run` — this is correct behavior.
- A sub-process / `hashicorp/go-plugin`-style fallback for Go skills. Documented as the escape hatch if `plugin.Open` proves operationally unworkable, but not built now. Keep the `manifest.json` `handler` field naming-flexible (`"go"` today, leaving room for `"go-binary"` or similar later) so the schema doesn't paint into a corner — but do not preemptively introduce a `mechanism` field or a `handler_kind` field. YAGNI applies until the sub-process fallback has a concrete trigger.

## Architecture Guidance

### Recommended Approach

The brief's architecture is right; connect existing hooks. Four code work-streams:

**Work-stream 1 — Go scaffold (`pkg/agent/dev/scaffold/scaffold.go`):**
- Add `Language string` to `Options` (`""` and `"ts"` both default to TS for back-compat; `"go"` and `"prompt"` are the new branches).
- Branch `starterFiles(opts)` on `opts.Language`:
  - `"go"` → `[SKILL.md, skill.go, skill_test.go]`
  - `"prompt"` → `[SKILL.md]`
  - default (TS) → `[SKILL.md, skill.ts, agent.json]` (unchanged).
- Add `helloSkillGo(name string) string` mirroring `helloSkillTS(name)`'s shape: import `pkg/agent/skill` + `pkg/agent/llm`; define `HelloInput` + `HelloOutput` structs with `json` + `jsonschema` tags; declare `func New() *skill.Definition`; the `Run` body calls one tool and one `llm.Generate`.
- Add `helloSkillGoTest(name string) string` for the `skill_test.go` body — minimal table test exercising `Define[HelloInput, HelloOutput]`.
- Export `HelloSkillGo(name string) string` so the regression suite can run scaffold output verbatim, mirroring `HelloSkillTS`.
- Update `helloSkillMD(name)` to handle the prompt-only case: when `Language == "prompt"`, the body should be a real prompt-shaped markdown rather than the TS-flavored hello-world prose.
- `agent.json` continues to be written for TS only. Go skills don't need it (the Go runtime resolves provider config through the gateway directly), and prompt-only skills don't need it.

**Work-stream 2 — Go build (`cmd/gridctl/agent.go` `runAgentBuild`):**
- Add a `runAgentBuildGo(store *registry.Store, sk *registry.AgentSkill) error` mirroring `runAgentBuildTS`.
- Body: resolve `handlerPath` via `store.HandlerPath(sk.Name)`; resolve `outDir` (`agentBuildOutDir` or `<skill_dir>/dist/`); on Windows, return `errors.New("go skill build requires Linux or macOS — Go plugins are not available on Windows")` before invoking the toolchain (probe `runtime.GOOS`); else `exec.Command("go", "build", "-buildmode=plugin", "-o", filepath.Join(outDir, "skill.so"), handlerPath).Run()` and surface `stderr` on failure.
- Compute `source_hash` from the same `os.ReadFile(handlerPath)` bytes the TS path uses.
- **Compute the two guardrail fields**: `go_version` from `runtime.Version()` (the toolchain version baked into the running gridctl binary, which is the same toolchain that just ran `exec.Command("go", "build", ...)`) and `go_mod_hash` from sha256 of the `go.mod` resolved by walking up from `handlerPath` (use `golang.org/x/mod/modfile` or a simple parent-directory walk to find the nearest `go.mod`; if none found, omit `go_mod_hash` and log at warn).
- Write `manifest.json` with `handler: "go"`, `handler_path: "skill.so"`, plus `go_version` and `go_mod_hash`. Same `agentBuildReport` envelope, `Status: "ok"`.
- Replace the deferred error path at line 348-362 with a call to `runAgentBuildGo(store, sk)`.
- `agent validate` for Go handlers stays non-invasive but adds a stdlib `go/parser`-based symbol check (recommended, not a hard requirement): parse `skill.go` via `parser.ParseFile`, walk top-level `*ast.FuncDecl`s, and report a clear validate error if no exported `RegisterSkill(*skill.Registry) error`-shaped declaration is present. Catches the most common copy-paste mistake before the user wastes a `go build` round-trip. Don't try to run `go build` from validate — that's expensive and belongs in `agent build`.

**Work-stream 3 — Gateway-builder plugin discovery (`pkg/controller/gateway_builder.go`):**
- At the existing `Build()` site (around line 178-220 where `registryStore` is created and `SetTSDispatcher` is wired), add a new helper `loadGoSkillPlugins(store *registry.Store, reg *skill.Registry, logger *slog.Logger)`.
- Body: iterate `store.ListSkills()`, filter to `sk.HandlerLanguage == "go"`, resolve the `.so` path and the adjacent `manifest.json` path, **read the manifest first** and check the two guardrails — `go_version` against `runtime.Version()`, `go_mod_hash` against a fresh sha256 of the daemon's `go.mod`. On any guardrail mismatch (or missing manifest), `slog.Warn` with an actionable rebuild instruction and skip the plugin. Only after guardrails pass: `plugin.Open` it, `plugin.Lookup("RegisterSkill")`, type-assert to `func(*skill.Registry) error`, and call it. Each per-skill failure is `slog.Warn`-logged and the loop continues — one broken skill does not block gateway start.
- Construct the shared `*skill.Registry` once in `Build()` (alongside or just before the `dispatcher` construction): `goSkillRegistry := skill.NewRegistry(); loadGoSkillPlugins(registryStore, goSkillRegistry, slog.New(b.existingHandler)); registryServer.SetSkillRegistry(goSkillRegistry)`.
- The `SetSkillRegistry` call MUST happen before `inst.Gateway.Router().AddClient(registryServer)` — currently around line 242 — so the router's `RefreshTools` sees Go skills on the first refresh.
- Do not wire `plugin.Open` failures into a fatal error path. Skills that fail to load surface as missing tools at call time, which is the correct user-visible signal.

**Work-stream 4 — `ctx.SkillBody()` accessor (`pkg/agent/skill/typed.go` + `skill.go`):**
- Define a new `RunContext` interface in `pkg/agent/skill/typed.go`:
  ```go
  type RunContext interface {
      context.Context
      SkillBody() string
      SkillName() string
  }
  ```
- Define a private `runContext` struct embedding `context.Context` and carrying `body string` and `name string` fields. Expose constructor `newRunContext(parent context.Context, body, name string) *runContext`.
- Change `TypedRunner[I, O]` to `func(ctx RunContext, input I) (O, error)`.
- Change `Define[I, O](name, description string, run TypedRunner[I, O])` to also accept the body. Two clean shapes:
  - **Option A**: extend the signature: `Define[I, O](name, description, body string, run TypedRunner[I, O])`. Most explicit; forces callers to be honest about whether they have a body.
  - **Option B**: add a separate `DefineWithBody[I, O]` variant. Avoids a signature break for non-hybrid callers.
  - Choose Option A. The breaking change is intentional — three first-party callers, all manageable. Option B introduces two parallel APIs that drift; the brief explicitly rejects "two-step migration" as overkill.
- The invoker closure constructs the `runContext` per call: `rc := newRunContext(ctx, body, name); output, err := run(rc, input)`.
- The body is captured by the closure at `Define` time, not loaded per-call. The registry store already parses `AgentSkill.Body` (`pkg/registry/types.go:36`); the gateway-builder hook plumbs it through to `Define` at registration time. For programmatically-registered Go skills (the `RegisterSkill` plugin entry point), the loader resolves the skill's body from the store before calling `Define`.
- Document the hybrid pattern in the package doc with a worked example: `llm.Generate[Triage](ctx, llm.Request{System: ctx.SkillBody(), Prompt: input.IncidentDescription})`.

**Work-stream 5 — TS hybrid parity (`pkg/agent/sandbox/`):**
- Add `SkillBody string` and `SkillName string` fields to `sandbox.Bindings` (`pkg/agent/sandbox/sandbox.go:58`). The fields are populated by the `BindingsProvider` (`dispatcher.go:45`) — the provider is already called with `skillName`, and the dispatcher already has access to the registry store, so resolving the body is a one-line lookup: `body, _ := registryStore.GetSkill(skillName).Body` (or equivalent).
- Wire the JS-side surface in `pkg/agent/sandbox/bindings.go` alongside the existing `tool()` / `llm()` / `handoff()` registrations: expose a top-level `skill` object with `body` and `name` properties (read-only). Pattern is the same as the other bindings — read from the `Bindings` struct on each Execute, register the value as a goja global.
- Update the `makeDispatcherBindings` closure in `pkg/controller/gateway_builder.go:785-797` to also populate `SkillBody` + `SkillName` from the registry store.
- This MUST land in the same PR as the `RunContext` change in work-stream 4 — Go and TS parity in one cut keeps the "all flavors first-class" invariant intact and avoids a window where the docs claim parity that the code doesn't deliver.

**Cross-cutting — caller migration:**
- Three first-party call sites of `skill.Define` exist today and must be updated:
  1. `pkg/agent/skill/skill_test.go` — `helloRunner` and inline test funcs.
  2. `pkg/agent/sandbox/recursive_test.go:46` — the cross-package recursive composition smoke test (registers a `greet` skill).
  3. The new Go scaffold introduced in work-stream 1 (writes a fresh call site per scaffolded skill).
- Audit for any additional callers via `rg "skill\.Define\[|skill\.MustDefine\[|TypedRunner" --glob '*.go'` before landing the signature change.
- Bump the typed SDK package doc to note the pre-1.0 cut.

### Key Files to Understand

Read these first to orient:

- `pkg/agent/skill/skill.go` — the package doc + `Definition`/`Registry` types. The two-layer mental model (Definition/Registry runtime-facing, `Define[I, O]` author-facing) is named here.
- `pkg/agent/skill/typed.go` — the `Define[I, O]` factory you'll be modifying. ~90 lines.
- `pkg/agent/dev/scaffold/scaffold.go` — the existing TS scaffold. Pattern is "one inline string per file, no embed dependency." Preserve that pattern in the Go branch.
- `cmd/gridctl/agent.go` — the `agent init` / `agent build` command shapes. `runAgentBuildTS` (line 374) is the model for `runAgentBuildGo`.
- `cmd/gridctl/run.go` — already routes `gridctl run <skill>` based on `sk.HandlerLanguage`. The Go branch currently returns "Phase H deferred"; the brief says it stays deferred for the standalone CLI path (Go skills run through the gateway, which loads plugins on start). Don't try to load plugins from the standalone `gridctl run` invocation; the rationale is that standalone-CLI plugin loads have to repeat the gateway-builder's work and add a second loader path that can drift.
- `pkg/registry/types.go` — `AgentSkill` shape, including `Body`, `HandlerLanguage`, `HandlerPath`. No changes here.
- `pkg/registry/store.go` line 506-518 (`detectHandler`) — the file-presence-as-discriminator logic. No changes needed; just confirm what the walker already does.
- `pkg/registry/server.go` line 95-102 (`SetSkillRegistry`) and line 170-202 (`CallTool`) — the existing `SetSkillRegistry` surface and the registry-first-then-TS-dispatcher lookup order. No server changes needed.
- `pkg/controller/gateway_builder.go` line 178-244 — where the registry store is loaded, the TS dispatcher is wired, and the registry server is added to the router. The Go-plugin loader sits alongside `SetTSDispatcher`.
- `examples/registry/items/code-review/SKILL.md` — the prompt-only example shape. The new prompt-only scaffold output should match this style.
- `pkg/agent/sandbox/recursive_test.go` — the recursive composability invariant the SDK protects. Don't break it.

### Integration Points

- `cmd/gridctl/agent.go:241-244` — add `--lang` and `--prompt-only` flags here. Validate mutual exclusion in `RunE`.
- `cmd/gridctl/agent.go:175-178` — pass `Language: agentInitLang` (or computed from `--prompt-only`) into `scaffold.Options`.
- `cmd/gridctl/agent.go:191-196` — branch the post-scaffold hint on flavor.
- `cmd/gridctl/agent.go:345-362` — replace the deferred `case "go"` body with `return runAgentBuildGo(store, sk)`.
- `pkg/controller/gateway_builder.go` — between line 184 (`registryStore := registry.NewStore(regDir)`) and line 217 (`dispatcher, err := sandbox.NewDispatcher(...)`), insert the Go-skill registry construction + plugin loader call + `registryServer.SetSkillRegistry(...)`.
- `pkg/agent/skill/typed.go` — change `Define[I, O]`'s signature; add `RunContext` interface and the private `runContext` struct.

### Reusable Components

- `sha256Hex` (`cmd/gridctl/agent.go:31`) — fingerprint Go source bytes the same way TS source is fingerprinted.
- `agentBuildReport` and `agentBuildOutDir` — the TS path's report shape and out-dir flag work verbatim for Go.
- `Server.SetSkillRegistry` (`pkg/registry/server.go:98`) — already in place; the gateway-builder's Go plugin loader is its first real caller.
- `Store.HandlerPath(name)` (`pkg/registry/store.go:63`) — resolves the absolute path to a typed skill's handler. Use it both in `runAgentBuildGo` and in `loadGoSkillPlugins`.

## UX Specification

- **Discovery**: `gridctl agent init --help` lists all three flavors with one-line examples (`agent init`, `agent init --lang go`, `agent init --prompt-only`).
- **Activation**: `gridctl agent init --lang go --name foo` writes the directory and prints `created <files>` + the per-flavor post-scaffold hint.
- **Interaction**: `gridctl agent build foo` produces artifacts; `gridctl run foo --input '<json>'` exercises the skill end-to-end. For prompt-only skills, `gridctl run` is not the path — `gridctl skill list --remote` then invocation through an upstream MCP client (Claude Desktop, etc.) is.
- **Feedback**: `agent build` prints `✓ built foo -> <manifest path>` on success; on Windows for Go, prints the explicit platform error before the toolchain probe runs.
- **Error states**: Three classes —
  1. Mutually exclusive flags (`--prompt-only` + `--lang go`) — clear pre-flight error.
  2. Platform-unsupported (Go plugins on Windows) — clear error before `go build` is invoked.
  3. Plugin load failure at gateway start — `slog.Warn` with the skill name and underlying `plugin.Open` error; gateway continues; the skill surfaces as a missing tool at call time.

## Implementation Notes

### Conventions to Follow

- **Naming**: stick with the existing `agent*Cmd`/`run<Subject>*` naming (e.g., `runAgentBuildGo`, `agentInitLang`).
- **File structure**: scaffold templates stay inline in `pkg/agent/dev/scaffold/scaffold.go` per the existing pattern. No `embed` dependency.
- **Error handling**: `fmt.Errorf("...: %w", err)` for wrapping; `errors.New` for synthesized terminal errors. Don't silently swallow `plugin.Open` failures — log at warn and continue.
- **Testing**: every exported func gets a test (Article III). Integration tests for the scaffold round-trip + the Anthropic compat fixture run with `-race`. The `tests/integration/` directory is the home for the Anthropic fixture.
- **Comment voice**: William's. Direct, no hedging, single hyphens, infrastructure analogies fine. The existing scaffold's doc comments and the `pkg/agent/skill/skill.go` package doc are the style reference.

### Potential Pitfalls

1. **Go plugin host/plugin version match.** The host (gridctl daemon) and the plugin (`skill.so`) must build with identical Go versions and identical dep-graph hashes. If a user upgrades their Go toolchain and rebuilds the daemon without rebuilding the skill plugin, `plugin.Open` returns a "plugin was built with a different version of package X" error. Document this in the package doc that introduces plugin loading. There is no fix at the runtime level — the operator has to rebuild plugins after a daemon rebuild.
2. **`plugin.Open` is one-way.** Plugins can't be unloaded. A daemon hot-reload that reads a new skill-set must accept that previously-loaded plugins stay resident. Don't try to "refresh" Go plugins during a hot reload — only refresh on daemon start.
3. **`runtime.GOOS == "windows"` check before `go build`.** Returning the platform error early avoids a confusing "go: -buildmode=plugin not supported on windows/amd64" toolchain message and gives the user an actionable hint.
4. **`store.HandlerPath` can return `false`.** Always check the `ok` return; don't assume Go-handler skills always have a sibling source file at registration time (e.g., a hand-built fixture without one would surface here).
5. **The `RegisterSkill` plugin symbol is the contract.** Plugins that don't export the exact symbol name and signature `RegisterSkill(*skill.Registry) error` will fail `plugin.Lookup`. Document the symbol name in `docs/skills.md` and in the Go scaffold's generated `skill.go` body.
6. **`AgentSkill.Body` plumbing.** The body is parsed by the registry store into `AgentSkill.Body` already. The new wiring point is between the store and `Define[I, O]` — the gateway-builder loader resolves the body before calling `Define` (or before invoking `RegisterSkill` for plugin-loaded skills, which means the plugin's `RegisterSkill` body must accept enough state to plumb the body through, or — simpler — the gateway-builder loader calls `Define` itself after `RegisterSkill` hands back a registry, and re-decorates with body. Pick the cleanest approach when implementing; reading `pkg/agent/skill/skill.go` will make the right shape obvious).
7. **Three callers, not two.** Audit `pkg/agent/sandbox/recursive_test.go:46` when migrating the `Define[I, O]` signature. The brief named two; the third is real and matters for the recursive composability invariant.
8. **Don't ship Go-only hybrid.** The temptation is to land `ctx.SkillBody()` for Go first and add TS parity in a follow-up. Resist — a window where the docs claim "all flavors first-class" but the code disagrees is the kind of drift that erodes the invariant Brief 3 named as non-negotiable. One PR for both.
9. **Manifest guardrail false negatives.** A `go.mod` parent-directory walk that fails to find a `go.mod` should log at warn and omit `go_mod_hash` from the manifest, not fail the build. The check at load time treats a missing `go_mod_hash` as "skip the check" rather than "skip the plugin" — otherwise standalone skill scaffolds without a `go.mod` parent (rare but possible) become unloadable.
10. **`go/parser` validate is recommended-not-required.** If the symbol check adds meaningful complexity (e.g., handling generic syntax, build-tag filtering), defer it to a follow-up rather than blocking Phase 4. The hard requirement is the build path; the validate enhancement is a nice-to-have.

### Suggested Build Order

1. **Phase 1 — Scaffold flag plumbing.** Add `Language` to `scaffold.Options`; add `--lang` / `--prompt-only` flags to `agent init`; branch `starterFiles` on language; ship the prompt-only branch first because it's a strict subset (just `SKILL.md`). Test against `store.Load()`.
2. **Phase 2 — Go scaffold body.** Add `helloSkillGo` + `helloSkillGoTest`; export `HelloSkillGo`. Extend the regression suite to run the Go scaffold output through `go build` (compile-check, no plugin yet).
3. **Phase 3 — `ctx.SkillBody()` cut + TS parity.** Land the `RunContext` interface and the `Define[I, O]` signature change in Go AND the `SkillBody`/`SkillName` extension to `sandbox.Bindings` + the `skill.body`/`skill.name` JS globals in the same PR. Migrate the three first-party call sites. Update the Go scaffold body to use `RunContext`. Update the `makeDispatcherBindings` closure in `gateway_builder.go` to populate the new bindings fields. Auditable diff but a wider one — keep it scoped to "the parity cut" and resist folding in unrelated cleanup.
4. **Phase 4 — Go build path + manifest guardrails.** Replace the deferred error in `runAgentBuild`; add `runAgentBuildGo` with the platform-gate and `go build -buildmode=plugin` invocation; emit `manifest.json` with `go_version` + `go_mod_hash` populated. Add the `go/parser` symbol check to `agent validate` for Go handlers.
5. **Phase 5 — Gateway-builder plugin loader.** Wire `loadGoSkillPlugins` + `SetSkillRegistry` in `gateway_builder.go`. The loader reads `manifest.json` first and enforces the `go_version` + `go_mod_hash` guardrails before `plugin.Open`. End-to-end smoke: scaffold a Go skill, build it, restart the daemon, call it via `gridctl run` and via an upstream MCP client. Then deliberately mutate `manifest.json`'s `go_version` and confirm the daemon emits the actionable warning and skips the plugin.
6. **Phase 6 — Examples + compat test.** Land the three example skills and the vendored Anthropic fixture compatibility test. The hybrid example specifically demonstrates `ctx.SkillBody()` carrying real prose into a model call. Add a TS-flavored variant (or extend `triage-ts/`) that demonstrates the same prose flowing through `skill.body` to prove parity end-to-end.
7. **Phase 7 — Docs.** `docs/skills.md` lands last; it cites the example skills and the working `agent init --lang go` / `--prompt-only` paths.

Each phase is independently shippable — none of phases 1, 2, 4, 5, 6, 7 require landing as one PR. Phase 3 is the one whose diff should not be split.

## Acceptance Criteria

1. `gridctl agent init --prompt-only --name foo` creates a directory with only `SKILL.md` (no `skill.ts`, no `skill.go`, no `agent.json`). The result validates and is loadable by `store.Load()`.
2. `gridctl agent init --lang go --name foo` creates `SKILL.md` + `skill.go` + `skill_test.go`. The result compiles via `go build`.
3. `gridctl agent init --lang ts --name foo` (and `gridctl agent init --name foo` with no flag) continues to produce the existing TS scaffold unchanged.
4. `--prompt-only` with `--lang go` returns a clear mutual-exclusion error before any files are written.
5. `gridctl agent build foo` for a Go skill on Linux or macOS produces `dist/skill.so` and `dist/manifest.json`. Manifest has `handler: "go"`, `handler_path: "skill.so"`, sha256 source hash, and `Status: "ok"`.
6. `gridctl agent build foo` for a Go skill on Windows returns the explicit platform-unsupported error; no toolchain output leaks.
7. A Go-handler skill's `dist/skill.so` is loaded at gateway start via the gateway-builder hook. Calling the skill via `gridctl run foo` emits the same MCP tool envelope as a TS or prompt skill — upstream cannot tell them apart.
8. A typed handler whose `Run` body calls `ctx.SkillBody()` receives the post-frontmatter markdown body as a string, suitable for use as `llm.Request.System`. `ctx.SkillName()` returns the registered name.

8a. A TS skill running in the goja sandbox can read its own markdown body via `skill.body` (string) and the registered name via `skill.name` (string). The values match what a Go skill would receive via `ctx.SkillBody()` / `ctx.SkillName()` for the same skill registered against the same registry.

8b. Go-skill `manifest.json` includes `go_version` and `go_mod_hash`. At gateway start, a Go skill whose manifest's `go_version` does not match `runtime.Version()` is skipped with an actionable `slog.Warn` ("plugin built with X, daemon running Y — rebuild with `gridctl agent build <name>`"). Same for `go_mod_hash` mismatch. Missing-manifest is also a skip-with-warn, not a hard error.

8c. `gridctl agent validate <go-skill>` reports a clear error when the `skill.go` source does not declare an exported `func RegisterSkill(*skill.Registry) error`.
9. `tests/integration/anthropic_skill_compat_test.go` passes against a vendored Anthropic skill fixture in CI: store loads, frontmatter validates, body surfaces unchanged, `gridctl skill validate` returns valid.
10. Three example skills under `examples/registry/items/` (`triage-ts/`, `triage-go/`, `incident-triage-hybrid/`) run end-to-end. The hybrid example demonstrates `ctx.SkillBody()` carrying real prose into a model call.
11. `docs/skills.md` exists and covers prompt / code-ts / code-go / hybrid as a coherent set, plus recursive composability and explicit non-features.
12. `scripts/check-eino-boundary.sh` continues to pass.
13. The post-scaffold hint differentiates: TS/Go print `gridctl agent dev --root <dir>`; prompt-only prints `gridctl skill list --remote && gridctl run <name>`.
14. `pkg/agent/sandbox/recursive_test.go` is migrated to the new `RunContext` signature and continues to assert recursive composability.
15. The Go scaffold's exported `HelloSkillGo` is exercised by a regression test that runs the scaffolded source through `go build` verbatim — same parity guarantee `HelloSkillTS` provides.
16. `CHANGELOG.md` `[Unreleased]` entry covers all four work-streams + the test + examples + docs.

## References

- Anthropic open skills repo (compat fixture source): `github.com/anthropics/skills/document-skills/`
- agentskills.io specification — the SKILL.md frontmatter standard.
- Go plugins documentation (`go doc plugin`) — operational sharp edges to enumerate in the package doc.
- Prior evaluation: `prompts/gridctl/three-flavor-skills/feature-evaluation.md`
- Lineage: `prompts/gridctl/completed/code-first-agent-runtime/feature-evaluation.md` (Brief 3, the broader agent-runtime evaluation this brief completes).
