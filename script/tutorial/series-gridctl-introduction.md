# Series: Introducing Gridctl

## Concept

A progressive video series introducing gridctl - an MCP orchestration platform that brings infrastructure-as-code principles to AI agent tooling. The series starts by framing the real problem gridctl was built to solve (MCP sprawl and configuration drift), then walks viewers through increasingly powerful features with hands-on screen sharing demos.

Each episode builds on the last. A viewer who watches the full series goes from "what even is this?" to deploying multi-server MCP stacks with access control, code mode, hot-reload, and API transformations. The first three episodes are heavily MCP-focused. Later episodes expand into agent workflows and advanced orchestration.

**Target audience**: Technical practitioners - DevOps engineers, SREs, AI/ML engineers, and infrastructure-minded developers who are exploring or already using MCP with tools like Claude Desktop, Cursor, or VS Code.

## Series Arc

1. **Frame the problem, show the solution** - Why MCP tooling is painful, then deploy and link your first stack
2. **Go deeper** - Multi-server aggregation, transports, namespacing
3. **Add control** - Tool filtering and access control for agents
4. **Optimize** - Code mode and context window management
5. **Iterate fast** - Hot-reload development workflow
6. **Extend** - Turn any REST API into MCP tools
7. **Orchestrate** - Agent skills and reusable workflows

Each episode has screen sharing demos that prove the concepts - not just talk.

## Episodes

### Episode 1: Why I Built Gridctl
- **Type**: Tutorial (explainer opening into hands-on demo)
- **Goal**: The viewer understands the MCP configuration problem, why gridctl exists, and deploys their first stack end-to-end
- **Key points**:
  - Brief MCP context (30-60 seconds) - what it is, why it matters for AI agents
  - The real pain: managing multiple MCP servers manually (ports, env vars, Docker commands, JSON configs)
  - Configuration drift across teams and environments
  - The "Containerlab for AI Agents" analogy - infrastructure-as-code solved this in networking, same principles apply here
  - One endpoint, one YAML file, one command
  - Installing gridctl (brew)
  - Anatomy of a stack file - what each field means
  - Deploy, status, link, destroy lifecycle
  - Connecting to Claude Desktop and using MCP tools end-to-end
- **Demo highlights**:
  - Show the manual way: multiple terminal windows, scattered JSON configs, port conflicts
  - Install gridctl
  - Walk through a basic stack YAML
  - `gridctl deploy` and watch containers come up
  - `gridctl status` to see what's running
  - `gridctl link claude` to auto-configure Claude Desktop
  - Open Claude Desktop, use a tool, see it work end-to-end
  - `gridctl destroy` for cleanup
- **Prerequisites**: Docker installed, an LLM client (Claude Desktop recommended)
- **Estimated length**: 18-22 minutes

### Episode 2: One Endpoint, Many Servers
- **Type**: Tutorial
- **Goal**: The viewer understands multi-server aggregation, transports, and namespacing
- **Key points**:
  - Why you'd run multiple MCP servers (GitHub + Atlassian + custom tools)
  - Transport types: stdio, HTTP, external URLs - gridctl handles the differences
  - Automatic tool namespacing (github__get_issues vs atlassian__get_issues)
  - One gateway endpoint aggregates everything
  - The web UI for visualizing your stack
- **Demo highlights**:
  - Build a stack with 2-3 MCP servers using different transports
  - Deploy and show all tools aggregated under one endpoint
  - Show namespaced tool names in Claude Desktop
  - Open the web UI (localhost:8180) to visualize the running stack
  - Call tools from different servers in a single conversation
- **Prerequisites**: Episode 1 (basic deploy/link workflow)
- **Estimated length**: 12-15 minutes

### Episode 3: Tool Filtering and Access Control
- **Type**: Tutorial
- **Goal**: The viewer can restrict which tools agents can access - both at server and agent level
- **Key points**:
  - Why unrestricted tool access is dangerous (agent calls delete instead of read)
  - Server-level filtering: hide tools from ALL consumers
  - Agent-level filtering: different agents get different tool subsets
  - Principle of least privilege applied to AI agents
  - Real-world scenario: read-only analyst vs. read-write operator
- **Demo highlights**:
  - Start with an unfiltered stack - show all tools available
  - Add server-level tool filtering - show tools disappear
  - Configure two agents with different tool access
  - Demonstrate that an agent cannot call a tool outside its filter (access denied)
  - Show the web UI reflecting different agent permissions
- **Prerequisites**: Episode 2 (multi-server stacks)
- **Estimated length**: 10-12 minutes

### Episode 4: Code Mode - Cut Your Context Window by 99%
- **Type**: Lab
- **Goal**: The viewer understands the context window problem and how code mode solves it
- **Key points**:
  - The context window explosion problem: 30+ tools = thousands of tokens just for tool definitions
  - Code mode replaces all tool definitions with two meta-tools: search and execute
  - Agents discover tools dynamically, then execute JavaScript in a sandboxed runtime
  - Same access control enforcement inside the sandbox
  - When to use code mode vs. standard mode
- **Demo highlights**:
  - Deploy a stack with many tools - show the massive tool list in standard mode
  - Enable code mode - show only search and execute tools appear
  - Agent searches for available tools, finds what it needs
  - Agent writes and executes JavaScript to call MCP tools
  - Show the sandboxed runtime handling real tool calls
  - Compare token usage: standard vs. code mode
- **Prerequisites**: Episode 3 (tool filtering concepts)
- **Estimated length**: 15-18 minutes

### Episode 5: Hot-Reload - Edit Your Stack Without Downtime
- **Type**: Lab
- **Goal**: The viewer can use watch mode for rapid MCP stack iteration
- **Key points**:
  - The pain of stop/start cycles during development
  - Watch mode: `gridctl deploy stack.yaml --watch`
  - How diff detection works (added, removed, modified servers)
  - Connected clients stay connected through reloads
  - Development workflow: edit YAML, save, tools update live
- **Demo highlights**:
  - Deploy a stack with --watch flag
  - Connect Claude Desktop to the gateway
  - Edit stack.yaml: add a new MCP server, save
  - Watch the new server come up and tools appear - without restarting anything
  - Remove a server from the YAML, save - watch it disappear
  - Modify tool filtering on an existing server - show live update
  - Show the web UI updating in real-time
- **Prerequisites**: Episode 2 (multi-server basics)
- **Estimated length**: 10-12 minutes

### Episode 6: Turn Any REST API into MCP Tools
- **Type**: Tutorial
- **Goal**: The viewer can transform OpenAPI specs into MCP-compatible tools
- **Key points**:
  - Not every service has an MCP server - but most have REST APIs with OpenAPI specs
  - Gridctl's OpenAPI transport: point it at a spec, get MCP tools automatically
  - Every endpoint becomes a callable tool
  - Authentication passthrough (API keys, bearer tokens)
  - Operation filtering to expose only the endpoints you want
  - Combining native MCP servers with OpenAPI-derived tools in one stack
- **Demo highlights**:
  - Start with the Petstore OpenAPI spec (public, no auth needed)
  - Add it to a stack file using the OpenAPI transport
  - Deploy and show the auto-generated MCP tools
  - Call the API through Claude Desktop using the generated tools
  - Add operation filtering to restrict which endpoints are exposed
  - Mix it with a native MCP server in the same stack
- **Prerequisites**: Episode 2 (multi-server stacks)
- **Estimated length**: 12-15 minutes

### Episode 7: Agent Skills and Workflows
- **Type**: Lab
- **Goal**: The viewer can create reusable agent skills and multi-step workflows
- **Key points**:
  - Skills registry: reusable markdown-based skill documents (SKILL.md)
  - Skills exposed as MCP prompts and resources
  - Skill workflows: deterministic multi-step tool orchestration
  - Sequential and parallel execution, dependencies, retry policies
  - Building composable automation with skills
- **Demo highlights**:
  - Create a skill in the registry (~/.gridctl/registry/skills/)
  - Show it appearing as an MCP prompt in Claude Desktop
  - Build a multi-step workflow skill with template expressions
  - Execute the workflow and watch steps run in sequence
  - Show the web UI workflow designer
  - Demonstrate parallel fan-out execution
- **Prerequisites**: Episode 4 (code mode concepts helpful)
- **Estimated length**: 15-20 minutes

## Series Notes

- **Recording order**: Episodes should be recorded in order since demos build on each other. Episode 1 sets the foundation for everything.
- **Recurring elements**:
  - Each episode opens with a brief camera segment framing the problem, then moves to screen sharing
  - The web UI (localhost:8180) appears in episodes 2+ as a visual anchor
  - `gridctl status` is used frequently to show system state
  - Each episode ends with a clear takeaway and teaser for the next video
- **Stack files**: Build example stack files that progress across episodes. Publish these to a GitHub repo viewers can follow along with.
- **Production notes**:
  - Keep terminal font size large for readability
  - Use a clean terminal theme with good contrast
  - Pre-stage environment variables so demos don't fumble with secrets on screen
  - Have a "known good" Docker environment - pull images before recording
- **Social media cuts**: Episodes 1, 3, and 4 have strong "aha moment" segments that can be clipped into 60-90 second shorts (the manual vs. gridctl comparison, the access denied demo, the 99% context reduction)
