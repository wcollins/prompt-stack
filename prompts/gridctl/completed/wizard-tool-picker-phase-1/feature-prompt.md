# Feature Implementation: Wizard Tool Picker — Phase 1 (Picker + Existing-Topology Wiring)

## Context

**Project**: gridctl — an MCP (Model Context Protocol) gateway and orchestrator, "Containerlab for MCP." Go CLI + gateway, React/TypeScript web UI.

**Tech stack**:
- **Backend**: Go ≥1.22. Internal API at `internal/api/*`, config types at `pkg/config/types.go`, gateway at `pkg/mcp/gateway.go`.
- **Frontend**: React 19 + TypeScript in `/web`. Zustand for state (`useWizardStore`, `useStackStore`). Tailwind 4. Icons from `lucide-react`. Fuzzy search via `fuse.js` ^7.1.0. Headless command/combobox via `cmdk` ^1.1.1. **Both already in `web/package.json` — no new deps.**
- **Wizard flow**: 4 steps (Type → Template → Form → Review). Entry at `web/src/components/wizard/CreationWizard.tsx`. MCP server form at `web/src/components/wizard/steps/MCPServerForm.tsx`.

**What already exists** — the backend primitive for per-tool allowlisting is complete:
- `MCPServer.Tools []string` in `pkg/config/types.go:143`.
- Enforcement via `SetToolWhitelist()` + `filterTools()` in `pkg/mcp/client_base.go`.
- Applied per-server in `pkg/mcp/gateway.go:766-825`.
- Documented in `docs/config-schema.md`, demonstrated in `examples/access-control/tool-filtering.yaml`.
- Wizard has a current manual-text-entry component (`ToolsWhitelist` in `MCPServerForm.tsx:384-441`) that writes to the same `tools` field.

**What Phase 2 does (out of scope here)**: adds a `POST /api/servers/probe` endpoint that ephemerally spawns an MCP server to enumerate its tools before deployment. Phase 1 explicitly does not depend on this — the picker gets its tools from servers already loaded in the topology via `useStackStore.tools`.

## Evaluation Context

Key findings from the feature evaluation that shaped this prompt:

- **Market positioning**: per-tool filtering is table-stakes for MCP gateways in 2026; the UI layer with search is the still-underserved slice (MetaMCP has the tab, search is "planned"; Cursor has toggles without search).
- **Zero new dependencies** — `cmdk` and `fuse.js` are already in `web/package.json`.
- **Phase-shipping rationale**: Phase 1 ships the picker wired to already-loaded topology tools — a clean win with near-zero risk. Phase 2 adds the ephemeral probe for greenfield servers, which carries real container-lifecycle risk that deserves its own review cycle. Shipping Phase 1 alone is already a material UX improvement and provides usage signal to de-risk the Phase 2 decision.
- **UX anti-patterns to avoid** (learned from competitor review): blocking Next/Deploy on loading state, treating "no tools" as error, removing manual-entry fallback, auto-probing on every keystroke.
- Full evaluation: `prompts/gridctl/wizard-tool-picker/feature-evaluation.md`

## Feature Description

Replace the manual text-input `ToolsWhitelist` in the gridctl wizard with a searchable, multi-select `ToolsPicker` that lets users curate exactly which tools each MCP server exposes through the gateway. The picker auto-populates from live tools for servers already loaded in the topology (via `useStackStore.tools`). For servers not yet loaded, Phase 1 falls back cleanly to a manual-entry mode — Phase 2 will add the probe endpoint that removes that fallback for most cases.

Applies both when creating a new stack and when adding a new MCP server to a stack already loaded in the topology (same code path — the "Add Server" button on Canvas reuses `CreationWizard`).

Fuzzy search filters over tool name + description. Selections persist to the existing `tools:` field in stack YAML with no schema change.

## Requirements

### Functional Requirements

1. A new `web/src/components/wizard/steps/ToolsPicker.tsx` component replaces the `ToolsWhitelist` component currently at `MCPServerForm.tsx:384-441`. The picker:
   1. Accepts `value: string[]`, `onChange: (val: string[]) => void`, and context props (`serverName: string`).
   2. Renders a fuzzy-search input and a scrollable multi-select checklist of tools.
   3. Shows a tool count header (`"{selected} of {total} selected — empty means all tools exposed"`).
   4. Provides "Select all" and "Clear" quick actions.
   5. Shows a clear empty state when no tools are available for the current server (e.g., "No tools found for this server in the current topology. Enter names manually below, or deploy the server first to discover its tools."). Do **not** treat this as an error.
   6. Provides a **manual-entry mode** toggle ("Enter tool names manually") that reproduces the current `ToolsWhitelist` array editor as a subcomponent. Must always be available within one click — users may want to specify tools that don't yet exist on the server or that the topology can't see.
2. Tools auto-populate from `useStackStore.tools` filtered by the current `serverName` prefix (`${serverName}${TOOL_NAME_DELIMITER}`). See `ToolList.tsx:43-45` for the existing filter pattern and `web/src/lib/constants.ts` for `TOOL_NAME_DELIMITER`.
3. Fuzzy search built on the existing `useFuzzySearch` hook pattern (`web/src/hooks/useFuzzySearch.ts`) or a new `useFuzzyTools` variant keyed on `name` + `description`. Match the existing threshold default (0.4) unless real tool names show it misbehaves.
4. Picker state persists through the Zustand wizard store (`formData['mcp-server'].tools`), so tool selections survive step navigation and sessionStorage rehydration. No changes to `useWizardStore` required — the `tools` field already exists.
5. YAML serialization via existing `buildMCPServer` in `web/src/lib/yaml-builder.ts`. No changes needed — the `tools` field already serializes.
6. The `ToolsPicker` sits in the **Advanced section** of `MCPServerForm.tsx`, replacing the current `<ToolsWhitelist>` JSX. The `advancedCount` badge counter continues to reflect `data.tools?.length`.
7. The standalone `ToolsWhitelist` function at `MCPServerForm.tsx:384-441` is removed once all call sites are migrated. No dead code.

### Non-Functional Requirements

- **Performance**: picker must render instantly. Fuse.js must handle 500+ tools per server without noticeable lag.
- **Accessibility**: WCAG 2.1 AA. `aria-label` on picker container, search input, and Clear/Select-all buttons. Checkable items use `role="checkbox"` + `aria-checked`. Keyboard navigation (arrow keys, Enter, Space) provided by cmdk primitives.
- **Backward compatibility**: stacks with existing `tools: [...]` values render with those tools pre-checked. Empty `tools` field still means "all exposed." No YAML schema change.
- **No new dependencies**: use `cmdk` and `fuse.js` (already in tree). Do not add any library.

### Out of Scope

- The ephemeral probe endpoint (`POST /api/servers/probe`) — that's Phase 2.
- Identity-bound allowlists, policy-as-code, audit logging — separate features.
- Parameter-level restrictions within a tool — separate feature.
- Changes to config YAML schema.
- Wizard forms for resources other than MCP servers.
- Post-deploy tool re-curation on the Canvas/topology view — separate UX track.

## Architecture Guidance

### Recommended Approach

- Build `ToolsPicker.tsx` as a single self-contained component. Internally it has three display states: **checklist mode** (tools available), **empty state** (no tools for this server), and **manual-entry mode** (user chose it or never switched from it).
- Use `cmdk` primitives (`Command`, `Command.Input`, `Command.List`, `Command.Item`) for the search + checklist. Replace cmdk's default substring filter with a Fuse.js-ranked filter via cmdk's `filter` prop, so fuzzy matching is consistent with the rest of the app.
- Manual-entry mode is essentially the existing `ToolsWhitelist` logic lifted into a subcomponent of `ToolsPicker` (e.g., `<ToolsPicker.ManualEntry>` or an internal `<ManualTools>` function).
- Keep the picker styled with existing Tailwind utilities and `labelClass` / `inputClass` constants from `MCPServerForm.tsx` for visual consistency.

### Key Files to Understand

Read these first, in this order:

| File | Why |
|---|---|
| `web/src/components/wizard/steps/MCPServerForm.tsx` | Current form structure, Advanced section layout, `ToolsWhitelist` component to replace. ~1400 lines — read it fully. |
| `web/src/stores/useWizardStore.ts` | Zustand store, `formData` shape, `updateFormData` callback flow. |
| `web/src/stores/useStackStore.ts` | Shape of `tools` state — where the picker reads from. |
| `web/src/components/ui/ToolList.tsx` | Existing read-only tool display. Shows the prefix-filtering pattern. **Do not extend this** — it's a different concern (read-only vs. multi-select). |
| `web/src/hooks/useFuzzySearch.ts` | Existing Fuse.js hook pattern to mirror. |
| `web/src/lib/constants.ts` | `TOOL_NAME_DELIMITER` constant used in prefix filtering. |
| `web/src/lib/yaml-builder.ts` | `MCPServerFormData` interface — `tools?: string[]` already present. No changes needed. |
| `examples/access-control/tool-filtering.yaml` | User-facing example of `tools:` allowlist. Verify the picker still produces equivalent YAML. |

### Integration Points

| Where | What |
|---|---|
| `MCPServerForm.tsx` Advanced section | Replace `<ToolsWhitelist>` JSX with `<ToolsPicker>`. |
| `MCPServerForm.tsx:~480` `advancedCount` calculation | Unchanged — `data.tools?.length` still correct. |
| `useWizardStore` | No changes required. |
| Existing `GET /api/tools` | No changes — picker reads from `useStackStore.tools` which subscribes to it. |

### Reusable Components

- `cmdk` — base for the searchable command/combobox UI.
- `fuse.js` — fuzzy ranking over tool name + description.
- `cn()` utility in `web/src/lib/cn.ts` — class composition.
- `labelClass` / `inputClass` constants in `MCPServerForm.tsx` — consistent field styling.
- Icons from `lucide-react` (`Check`, `X`, `Search`).

## UX Specification

**Discovery**: Advanced section of the MCP server form in the wizard (new stack or "Add Server" from Canvas). Badge counter reflects selected tool count.

**Activation**: Expanding the Advanced section reveals the `ToolsPicker`.

**Interaction flow**:
1. User expands Advanced.
2. If tools are available from the topology: checklist renders with fuzzy-search input at top. User types to filter; clicks items to toggle.
3. If no tools are available (server not in topology yet): empty state with helpful text and a prominent "Enter tool names manually" action. User can switch to manual-entry mode.
4. In manual-entry mode: user sees the existing `ToolsWhitelist`-style array editor (add/remove rows). A "Back to search" link returns to checklist mode if tools are available.
5. Selections persist through step navigation via Zustand.
6. "Select all" in header selects all *visible* (filtered) tools. "Clear" deselects all.

**Feedback**:
- Tool count in header: `"{selected} of {total} selected — empty means all tools exposed"`.
- Empty filter result: "No tools match '{query}'"

**Error states**:
- None expected in Phase 1 — all failure modes (no tools, server not in topology) are neutral empty states, not errors.

## Implementation Notes

### Conventions to Follow

- **React conventions**: functional components, hooks, TypeScript strict mode. State via `useState` or Zustand.
- **Styling**: Tailwind utility classes; no CSS modules.
- **File naming**: PascalCase for components (`ToolsPicker.tsx`), camelCase for hooks.
- **Testing**: match existing `*.test.ts*` convention. Frontend uses Vitest + Testing Library (verify via `web/package.json`).
- **Commit format**: `feat(wizard): add searchable tools picker` etc. Signed commits (`-S`). No Claude mentions in commits/PRs/branches.
- **PR discipline**: keep under ~600 lines if possible. One logical change.

### Potential Pitfalls

- **`/api/tools` and future probe endpoint are not interchangeable.** Phase 1 only uses `useStackStore.tools` (aggregated live tools). Don't design the picker in a way that hard-codes assumptions about topology presence — Phase 2 will inject a second data source.
- **cmdk default filter is substring, not fuzzy.** Provide a custom `filter` prop that calls Fuse.js to match the rest of the app's fuzzy behavior. Verify the cmdk v1.1.1 API.
- **Fuse.js threshold 0.4** is the app default for skills — test it on real tool names (some MCP servers use snake_case or dotted notation) and adjust only if it's actually wrong.
- **Manual-entry fallback cannot be removed.** Users may want to pre-specify tools not yet on the server. Always keep the toggle visible.
- **Check for name collisions** — the filename `ToolsPicker.tsx` is new; make sure nothing in the codebase already claims it.
- **Don't duplicate ToolList logic.** `ToolList.tsx` is read-only with param-detail expansion. The picker is multi-select without param details. Keep them separate.

### Suggested Build Order

1. Read all key files above. Run the wizard locally (`make build && ./gridctl web`) to see the current `ToolsWhitelist` in action.
2. Create `ToolsPicker.tsx` skeleton with props, Zustand wiring, and a placeholder render. Verify it compiles and the wizard still renders.
3. Implement the fuzzy-search + checklist UI on top of cmdk, populated from `useStackStore.tools` filtered by `serverName`.
4. Implement the empty state with the manual-entry switch.
5. Implement the manual-entry subcomponent by lifting the existing `ToolsWhitelist` logic verbatim.
6. Wire the "Back to search" link when tools become available.
7. Delete the original standalone `ToolsWhitelist` function. Replace the JSX usage in `MCPServerForm.tsx` Advanced section.
8. Write component tests (select/clear/search/toggle-manual) and a wizard-flow persistence test.
9. Manual QA: (a) open wizard with an existing loaded stack, verify picker shows the server's tools; (b) select some tools, navigate steps, come back, verify selection persists; (c) switch to manual entry, add a tool, switch back; (d) verify stacks with existing `tools:` values render pre-checked.
10. Open PR.

## Acceptance Criteria

1. `ToolsPicker` renders in the Advanced section of the MCP server wizard form for both new-stack and add-to-existing-stack flows.
2. For servers already loaded in the topology, the picker auto-populates from `useStackStore.tools`, filtered by the server's prefix.
3. Fuzzy search (via Fuse.js) filters the checklist as the user types, scoring against tool name + description.
4. Tool selections persist through wizard step navigation and survive sessionStorage rehydration.
5. "Select all" and "Clear" quick actions work as described.
6. The empty state (no tools in topology for this server) renders clearly and is **not** treated as an error.
7. Manual-entry fallback is reachable within one click and reproduces the current `ToolsWhitelist` behavior (add/remove named tools).
8. Selected tools serialize to the `tools:` field in stack YAML with no schema change.
9. Existing stacks with `tools: [...]` render with those tools pre-checked in the picker.
10. Component tests cover picker interaction (select, clear, search, toggle manual entry); wizard-flow test covers persistence across steps.
11. The old standalone `ToolsWhitelist` function is removed. No dead code remains.
12. No new dependencies added to `web/package.json`. Only `cmdk` and `fuse.js` (already present) are used.
13. Accessibility: picker passes a keyboard-navigation smoke test; all interactive elements have appropriate `aria-*` attributes.

## References

- Full evaluation: `prompts/gridctl/wizard-tool-picker/feature-evaluation.md`
- Phase 2 prompt: `prompts/gridctl/wizard-tool-picker-phase-2/feature-prompt.md`
- [cmdk docs](https://github.com/pacocoursey/cmdk)
- [Fuse.js docs](https://www.fusejs.io/)
- [MCP spec — tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- Competitor reference (VS Code tools picker): [GitHub Copilot MCP docs](https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp/use-the-github-mcp-server)
- Existing gridctl example: `examples/access-control/tool-filtering.yaml`
