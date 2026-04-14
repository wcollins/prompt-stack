# UX Research: Network Engineering AI Agent Tools

**Date**: 2026-04-13
**Context**: Evaluating UX patterns for `netagent` — a compiled Go CLI wrapping an MCP gateway with an AI agent loop for network engineering. Accepts natural language commands (`netagent run "check BGP health on all routers"`) with TUI, webhook (Slack/WebEx), and plain CLI output modes.

---

## 1. NetClaw (Python) — Invocation, Skill Discovery, Audit Output

### Invocation Model

NetClaw exposes two primary entry points:

- **Interactive CLI**: `openclaw chat --new` — starts a stateful session where users describe tasks in natural language
- **Background daemon**: `openclaw gateway` — listens on multiple channels simultaneously (CLI + Slack)
- **Slack-native**: monitors `#netclaw-alerts`, `#netclaw-reports`, `#netclaw-general`, `#incidents` for `@netclaw` mentions

There is no explicit command vocabulary to memorize. The user writes a sentence; the agent figures out which skill to invoke. This eliminates the "what flag do I use?" friction that kills traditional CLI tools.

### Skill Discovery Architecture

NetClaw uses a two-layer skill system:

1. **Skill index**: a condensed 60-chars-per-skill summary of all 82+ skills is injected into the system prompt at session start. The agent can see what it can do without loading full procedures.
2. **Skill files**: full markdown playbooks in `~/.openclaw/workspace/skills/` with YAML frontmatter declaring name, description, `user-invocable` flag, and required binaries/env vars.

Skills are organized into six functional domains: pyATS (9 skills), Domain Integration (7), Platform-Specific (6), Utility/Slack (10), and others. The agent selects the right skill autonomously based on the user's natural language request.

**Key insight**: skills are not commands — they are structured procedures that guide agent reasoning. The user never sees or selects skills directly; this is entirely agent-side.

### Audit Output (GAIT)

NetClaw uses GAIT (Git-based AI Tracking) for immutable audit trails:
- Every session turn is committed to a Git repo: prompt, response, and artifacts
- `gait_log` command surfaces the chronological commit history
- Configuration changes record baseline/applied/verify phases as distinct commits
- Slack reports include severity ratings and formatted tables
- CLI sessions display step-by-step progress with timestamps

**Key insight**: the audit trail is not a log file — it is a Git history. This means diffs, rollback references, and peer review are native features.

### Human-in-the-Loop Gates

NetClaw uses selective gating rather than approving every action:

| Trigger | Gate Type |
|---------|-----------|
| ISE endpoint quarantine | Explicit human confirmation required |
| `write erase`, `reload`, `delete` | Refused at MCP server level (hard block) |
| Any configuration change | ServiceNow CR must be approved first |
| P1 incidents | Bypass DND, notify incident commander |
| Uncertain operations | Rule 11: "Escalate when you're unsure" |

The model is "autonomous by default, gated at risk boundaries." This avoids approval fatigue for read operations while enforcing control on write operations.

---

## 2. Juniper Marvis AI — Interaction Model

### Natural Language to Proposed Action

Marvis combines NLP with NLU to interpret intent, not just syntax. Example query: "Why is the Orlando site slow?" triggers cross-domain data correlation across wired, WAN, and wireless domains before surfacing a root cause and remediation suggestion. As of 2025, Marvis uses multi-agent collaboration internally to handle these complex cross-domain queries.

### Two Operating Modes

**Driver-Assist (default)**: Marvis identifies issues and proposes remediations. The human clicks through an approval flow:
1. Issue appears in the Marvis Actions dashboard with category, severity, and site context
2. User drills in to see "View More" for port-level specifics
3. User clicks a Status button to progress: Open → In Progress → Resolved by User
4. Optional: Marvis validates resolution and marks "AI Validated"

**Self-Driving (opt-in)**: Marvis executes remediations autonomously within IT-approved scenarios. Actions are validated post-remediation and logged in the Marvis Actions Dashboard. Each auto-remediation shows "Marvis Self Driven" status.

### Dashboard Design

The Marvis Actions dashboard organizes issues into:
- Issue categories (Clients, AP, Switch, WAN Edge, Data Center/Application, Security)
- Time series graph (30-day default) of action volume, filterable by "Self-Driven" only
- Recommended Actions List with resolution status filters
- Per-issue audit states: Open, In Progress, AI Validated, Marvis Self Driven, Resolved by User
- Two-month history window; CSV export available

### Confidence-Based Routing

Marvis uses confidence scoring to route decisions:
- High confidence → automated remediation (self-driving)
- Medium confidence → validation agents for additional evidence
- Low confidence → escalate to human operators

This graduated trust model is explicitly designed to build engineer confidence incrementally.

### Key Design Philosophy

"The enhanced Marvis Conversational Interface marks a shift from assisted operations to autonomous networking intelligence." HPE framed this as a "morning cup of coffee" dashboard — operators arrive to a prioritized action list, not a wall of alerts. Proactive rather than reactive.

---

## 3. Cisco Catalyst Center AI — Change Proposal UX

### Interaction Model

Catalyst Center's AI Assistant is embedded natively in the Catalyst Center dashboard (not a separate CLI or chat tool). Engineers interact via a conversational panel within the existing UI. The flow:

1. Engineer enters natural language: "Configure BGP peer X with policy Y"
2. AI generates a structured change proposal with configuration preview
3. **Human-in-the-loop gate**: mandatory pause point — "Nothing touches your infrastructure without explicit sign-off"
4. Engineer reviews, adjusts parameters (e.g., VXLAN VNI ranges), and approves
5. Agent executes via MCP tool chains against CML, Catalyst Center, vManage
6. Agent validates completion and generates documentation

Cisco's agentic framework uses a three-phase gate model:
- **Plan Review Gate**: complete workflow design presented before any execution
- **Execution Phase**: only after human sign-off
- **Validation Gate**: verify + documentation before session closes

### Documented Failure Mode

Cisco explicitly acknowledges: "LLMs hallucinate — they can generate plausible-looking configurations with wrong subnet masks or nonexistent CLI commands." Human gates are the explicit architectural response to this, not a concession — "This isn't a limitation — it's the feature that makes enterprise adoption possible."

### Agentic Framework Evolution

Cisco's blog describes the shift: chatbots answer questions; agents execute changes. The key distinction is that agents own outcomes, not just responses. This requires rethinking the interaction model from "assistant that informs" to "agent that acts, with the engineer as supervisor."

---

## 4. CLI/TUI Patterns in Network Automation Tools

### scrapli

Pure library — no interactive CLI. Interaction is programmatic via Python. Users write scripts that call `driver.send_command()` or `driver.send_configs()`. The UX is entirely code-level; there is no REPL, no TUI, no natural language. Discovery happens through documentation and IDE autocomplete.

**UX characteristic**: expert-only, high ceiling, zero hand-holding. Engineers who use scrapli are already comfortable with Python network automation.

### NAPALM

Similar to scrapli — library-only. Adds `get_` methods for structured data retrieval and `load_replace_candidate()` / `compare_config()` / `commit_config()` for change management. NAPALM's UX innovation is the diff-before-commit pattern: you load a config candidate, call `compare_config()` to see the diff, then decide to commit or discard.

**Key UX insight**: NAPALM introduced the "show me what will change before I apply it" pattern to network automation. This is a dry-run primitive that predates AI agents but maps directly to what network engineers expect from any automated change tool.

### Batfish / pybatfish

Batfish introduced a Jupyter Notebook-based workflow: engineers write Python cells that call `bf.q.<question_name>().answer().frame()` to get Pandas DataFrames back. The interaction model is exploratory and query-driven — closer to SQL than CLI.

AskBatfish (an NLP layer on top) bridges from natural language questions to Batfish queries via LLMs and a Neo4j graph database. This is the same pattern `netagent` is solving: wrap a complex query interface with natural language so engineers don't need to know the API.

**Key UX insight**: Batfish's core UX problem was that the question API was powerful but required engineers to memorize dozens of question names and their parameters. Natural language wrapping directly addressed this discovery barrier.

### Ansible / AWX

AWX/Tower introduced the gold standard approval workflow for network automation teams:
- **Check mode** ("dry run"): `--check` flag runs playbook logic without making changes, reports what would happen
- **Approval nodes**: workflow execution pauses at designated nodes, requiring admin approve/deny before continuing
- **Job templates**: pre-configured playbooks with locked parameters that operators can trigger without knowing Ansible

**Key UX insight**: AWX separated "expert who builds the automation" from "operator who runs it." Job templates are the consumer-facing API. This is the model most enterprise network teams actually use — not raw Ansible CLI.

---

## 5. GitHub Copilot CLI and Claude Code — Natural Language to Execution UX

### GitHub Copilot CLI

Original `gh copilot` pattern (pre-2025):
- `gh copilot suggest <task>` — returns a suggested shell command with explanation
- `gh copilot explain <command>` — explains what a command does in natural language
- Shell aliases (`ghcs`, `ghce`) for faster invocation
- Suggested commands can be executed in-place; they are added to shell history

The "old" Copilot CLI was a single-turn tool: ask → get command → optionally execute. No persistent context, no multi-step reasoning.

**New (2026 GA) Copilot CLI**: full agentic mode with Autopilot. Persistent context, multi-step task execution, enterprise telemetry. The UX shift mirrors what `netagent` is building.

### Claude Code — Plan Mode

Claude Code's plan mode is the most directly comparable pattern to what `netagent` needs:

1. **Read-only exploration phase**: Claude analyzes files and context without making changes
2. **Plan generation**: Claude writes a structured plan (markdown) to a plans folder
3. **Human review gate**: user examines the plan, asks clarifying questions, iterates
4. **Execution approval**: user explicitly approves; Claude transitions to edit mode
5. **Execution**: Claude makes changes

The key insight from armin.ronacher's analysis: "Plan mode creates a psychological contract — the user knows nothing will happen until they approve. This trust is structural, not just stated."

**Ultraplan** (2025) added: approve plan → run in cloud → PR created. The "run it for me after I approve" pattern is now table-stakes for agentic tools.

### Common UX Pattern

Both tools converge on the same three-phase UX:
1. **Propose**: show what will happen before it happens
2. **Review**: human-readable preview with enough context to evaluate risk
3. **Execute**: single approval gesture, then hands-off

Neither tool requires the user to understand the underlying tool calls. The abstraction is complete on the "what will happen" side.

---

## 6. UX Anti-Patterns That Cause Abandonment in Network Automation

### Quantitative Context

From a Network World survey (Enterprise Management Associates):
- Only 18% of IT professionals rate their network automation strategies as fully successful
- 54% achieved partial success; 38% reported failure or uncertainty
- 57% of network tasks remain manual even in organizations with completed automation projects
- 23.7% cite tool complexity/usability as a major challenge
- 16.4% report engineer resistance to automation adoption
- 21.5% experienced tool stability problems

### Documented Anti-Patterns (in rough order of abandon-trigger severity)

**1. Silent Failures / Partial State**
The highest abandon trigger. When automation fails mid-execution and leaves devices in undefined states with no actionable error output, engineers immediately lose trust. "Your team starts to avoid automation because they've been burned by it too many times." Recovery is often worse than if the automation never ran. Mitigation: atomic operations, explicit rollback, loud failure with state dump.

**2. False Confidence / CLI-Thinking Mismatch**
Engineers assume they understand automation because they know CLI commands. Scripts work once, fail on repeated runs due to non-idempotent operations. The tool doesn't signal this risk proactively, so engineers blame the tool when their mental model was wrong. Mitigation: explicit idempotency guarantees, clear distinction between "show" and "change" operations.

**3. No Preview / No Dry Run**
Automation tools that apply changes without a "show me what will change first" step are not trusted for production use. This is not optional for network engineers — it is a hard requirement inherited from NAPALM's `compare_config()` and Ansible's `--check` mode. Tools that skip this step are categorized as toys.

**4. Opaque Reasoning / Black Box Execution**
When an AI agent takes an action and the engineer can't see why, they can't validate correctness or diagnose failures. Cisco's trust formula: "Accuracy + Transparency = Trust. And Trust → Deployment." Without reasoning visibility, agentic tools remain demos, not production tools.

**5. Approval Fatigue**
The inverse of the above: requiring explicit approval for every single operation, including read-only queries, creates friction that causes engineers to batch approvals carelessly or abandon the tool entirely. NetClaw's model — autonomous for read ops, gated for write ops — is the right balance.

**6. Inadequate Error Messages**
Network automation errors need to be diagnostic, not just informative. "Connection refused" is not useful. "SSH connection to 10.1.1.1 refused — check that management VRF is correctly configured and that the ACL permits the management station IP" is useful. Generic errors train engineers to not trust the tool's diagnostics.

**7. Automation Debt / Brittleness**
Scripts that work on device model X break silently on device model Y due to vendor CLI variations. When the automation breaks unpredictably on production changes (OS upgrades, new hardware), teams abandon it and revert to manual processes. Mitigation: structured data APIs over CLI scraping, vendor-abstracted tool layers (NAPALM, pyATS).

**8. Knowledge Silos**
Automation that lives on one engineer's laptop and has no shared repository, no documentation, and no onboarding path dies when that engineer leaves. Teams that start automation initiatives without making them team-owned assets consistently fail to sustain them.

**9. Missing Audit Trail / Compliance Invisibility**
Automation that operates outside change control is rejected by ops teams who must satisfy audit requirements. Tools that don't integrate with ITSM (ServiceNow, Jira) or generate their own tamper-evident logs are non-starters in regulated environments.

**10. Steep Initial Setup Barrier**
If the tool requires significant configuration before producing any value, engineers deprioritize it. The "time to first useful output" (TTFUO) needs to be under 10 minutes for adoption. Tools that require extensive inventory setup, credential management, and templating before returning any data lose most engineers before they get their first result.

---

## 7. Keyboard-Centric vs Conversational UI Preferences in Network Engineering

### The Preference Landscape

Network engineers are fundamentally keyboard-first users. Their entire professional practice — SSH sessions, CLI commands, text configs — is keyboard-native. This creates strong preferences that run counter to some "modern AI assistant" UX assumptions.

**What network engineers prefer:**
- Working in a terminal over switching to a browser tab
- Keyboard shortcuts over menu navigation
- Output they can pipe, grep, and process
- Persistent shell history for audit and repeat
- Low-latency interfaces (critical in high-stress incident response)
- Familiar tooling that behaves predictably

**What they tolerate in specialized contexts:**
- Dashboards for situational awareness (Marvis Actions, Grafana)
- Web UIs for approval workflows (AWX job approval, ServiceNow CR)
- Chat interfaces (Slack, WebEx) when already embedded in team workflow

### TUI Value Proposition for Network Tools

TUIs (terminal user interfaces, e.g., built with Bubble Tea/Lip Gloss in Go, or Textual in Python) occupy a specific niche:
- Provide dashboard-like organization without leaving the terminal
- Enable guided interaction (menus, confirmation dialogs) without requiring command memorization
- Perform well over high-latency SSH connections where GUIs are unusable
- Keep engineers in the mental context of CLI work

Net-TUI (Textual + Nornir) is a practical example: TUI for network automation tasks where engineers want more structure than raw commands but don't want to open a browser.

### Conversational Interface Reality

Conversational UI (chat-style) works well when:
- The query is exploratory ("why is the Orlando site slow?")
- The context spans multiple domains and a structured query interface would require 5 separate commands
- The engineer is already in a chat platform (Slack/WebEx integration makes this zero-friction)
- The task is diagnostic/read-only and the stakes of misunderstanding are low

Conversational UI struggles when:
- The engineer knows exactly what they want and natural language is slower than `show bgp summary`
- The change is high-stakes and the engineer wants deterministic, auditable input (not interpreted input)
- The network is down and speed > expressiveness
- Responses are verbose and can't be quickly scanned

### The Hybrid Model

The emerging consensus in production network AI tools is a hybrid:
- **CLI flag / command invocation** for known tasks (keyboard-first, scriptable, pipe-friendly)
- **Conversational context** for exploratory/diagnostic queries (natural language input, structured output)
- **TUI panel** for plan review and approval (visual context, keyboard-navigable confirmation)
- **Chat webhook** for NOC/team workflows (Slack/WebEx as the surface, not the CLI)

NetClaw demonstrates this: `openclaw chat --new` for interactive, `openclaw gateway` for daemon mode feeding multiple surfaces. Neither replaces the other.

---

## Synthesis: Implications for `netagent`

### What the research recommends

**Invocation model**: `netagent run "..."` is the right primary surface — it is familiar, scriptable, and maps directly to how engineers think about task delegation. Add `netagent` (bare) as an interactive REPL/TUI mode.

**Skill/capability discovery**: avoid requiring engineers to know skill names. Either expose a `netagent list` command that surfaces available capabilities as plain text (greppable), or rely on the agent to route. NetClaw's two-layer index (short summary always loaded, full playbook loaded on demand) is an efficient pattern.

**Human-in-the-loop gating**: the most critical design decision. The research is unambiguous:
- Read operations (show, verify, query): autonomous, fast, no approval
- Low-risk writes (interface description, tag update): optional approval mode
- High-risk writes (BGP policy change, route-map modification, reload): mandatory approval gate
- Destructive operations (wipe, delete): hard block at the tool/MCP layer
- All write operations: dry-run/preview output before execution (non-negotiable)

**Plan review UX (Claude Code pattern)**: before any write execution, display a structured plan in the terminal showing exactly what MCP calls will be made, which devices will be affected, and what the expected outcomes are. Require explicit `y/N` or `--auto-approve` flag to proceed.

**Audit trail**: generate a tamper-evident log (Git commit or structured append-only log) per execution with: natural language input, interpreted intent, tool calls made, device responses, execution result. Make it consumable by ServiceNow/Jira via webhook or structured output.

**Error output**: never show raw stack traces or generic errors. Map tool errors to network-contextual diagnostics. "BGP session to 192.168.1.1 not found — verify peer IP and check that BGP is enabled on this device" beats "KeyError: 'bgp_neighbors'".

**Output modes**: plain CLI (default, pipe-friendly), TUI (structured with panels, invoked by flag or when `--interactive`), Slack/WebEx (webhook mode). The TUI should be used specifically for plan review + approval, not for casual output — engineers will disable it if it slows down simple queries.

**Trust building**: progressive autonomy. Start with read-only commands only, add approval-gated writes, eventually offer `--auto-approve` for IT-approved scenarios. Never start with full autonomy.

---

## References

- [NetClaw GitHub](https://github.com/automateyournetwork/netclaw)
- [NetClaw Operational Guide — DeepWiki](https://deepwiki.com/automateyournetwork/netclaw/6-operational-guide)
- [NetClaw Getting Started — DeepWiki](https://deepwiki.com/automateyournetwork/netclaw/2-getting-started)
- [Juniper Marvis AI Assistant](https://www.juniper.net/us/en/products/cloud-services/marvis-ai-assistant.html)
- [Marvis Actions Overview — Juniper Docs](https://www.juniper.net/documentation/us/en/software/mist/mist-aiops/topics/concept/marvis-actions-overview.html)
- [HPE Accelerates Self-Driving Network Ops — HPE Newsroom](https://www.hpe.com/us/en/newsroom/press-release/2025/08/hpe-accelerates-self-driving-network-operations-with-new-mist-agentic-ai-native-innovations.html)
- [Cisco Catalyst Center AI Assistant — Cisco Docs](https://www.cisco.com/c/en/us/td/docs/cloud-systems-management/network-automation-and-management/catalyst-center/articles/cisco-catalyst-center-ai-assistant.html)
- [Beyond the Chatbot: Agentic Frameworks for Network Engineering — Cisco Blog](https://blogs.cisco.com/learning/beyond-the-chatbot-how-agentic-frameworks-change-network-engineering)
- [Making Agentic AI Observable — Cisco Blog](https://blogs.cisco.com/sp/making-agentic-ai-observable-how-deep-network-troubleshooting-builds-trust-through-transparency)
- [AI Agents for Network and Security: Expectations vs Reality — Cisco Blog](https://blogs.cisco.com/developer/ai-agents-for-network-and-security-expectations-vs-reality)
- [Network Automation Challenges Dampening Success Rates — Network World](https://www.networkworld.com/article/2075207/network-automation-challenges-are-dampening-success-rates.html)
- [Network Automation Challenges: 5 Mistakes Engineers Make — CloudMyLab](https://blog.cloudmylab.com/network-automation-challenges-mistakes-engineers)
- [Network Automation in 2025 — Selector AI](https://selector.ai/learning-center/network-automation-in-2025-technologies-challenges-and-solutions)
- [AskBatfish: Bridging Network Management with Conversational AI — Medium](https://medium.com/@amar.abane.phd/askbatfish-bridging-network-management-with-conversational-ai-304f02c8a81f)
- [Batfish GitHub](https://github.com/batfish/batfish)
- [GitHub Copilot CLI — GitHub](https://github.com/features/copilot/cli/)
- [GitHub Copilot CLI 101 — GitHub Blog](https://github.blog/ai-and-ml/github-copilot-cli-101-how-to-use-github-copilot-from-the-command-line/)
- [What Actually Is Claude Code's Plan Mode? — Armin Ronacher](https://lucumr.pocoo.org/2025/12/17/what-is-plan-mode/)
- [Claude Code Plan Mode — DataCamp](https://www.datacamp.com/tutorial/claude-code-plan-mode)
- [State of Network Automation 2024 — NetBox Labs](https://netboxlabs.com/blog/the-state-of-network-automation-in-2024/)
- [The Unseen Powerhouse: Architecting for Control with CLIs and TUIs — Golodiuk](https://www.golodiuk.com/news/ui-in-architecture-01-cli-tui/)
- [Network TUI — sohanrai09 blog](https://sohanrai09.github.io/new-blog/2023/08/network-tui/)
- [Ansible Tower Approval Nodes — Red Hat](https://docs.ansible.com/ansible-tower/latest/html/userguide/workflows.html)
