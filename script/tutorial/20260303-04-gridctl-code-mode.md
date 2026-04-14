# Code Mode - Cut Your Context Window by 99%
## Date: March 3, 2026
## Type: Lab
## Series: Introducing Gridctl (Episode 4 of 7)
## Tools: gridctl, Claude Desktop, Docker
## Estimated Length: Medium (15-18min)

---

### Opening

**[CAMERA]**

Let me give you a number. If you're running ten MCP servers with five tools each, that's fifty tool definitions your agent has to load into its context window before it can even start thinking about your actual request. Each tool definition has a name, description, input schema, sometimes examples. We're talking thousands of tokens consumed just by the tool catalog.

Now scale that to thirty servers. Fifty tools each. You've just burned through a chunk of your context window on metadata. The agent hasn't done anything useful yet.

Code mode fixes this. Instead of loading every tool definition upfront, gridctl gives your agent two meta-tools: search and execute. The agent discovers tools on demand and calls them through JavaScript in a sandboxed runtime. Same access control. Fraction of the context.

Let me show you how it works.

---

### Prerequisites

**[NOTE]** Viewer should understand multi-server stacks and tool filtering from Episodes 2-3. Docker running. Claude Desktop or similar.

---

### Phase 1: The Problem - Tool Definition Bloat

**Goal**: Visualize the context window cost of standard MCP tool loading.

**[SCREEN]** Claude Desktop or terminal

**[DEMO]**
- **Action**: Deploy a stack with multiple MCP servers in standard mode and show the tool list
- **Commands**:
  ```
  gridctl deploy multi-server.yaml
  gridctl link claude
  ```
- **Expected output**: A long list of tools from all servers in Claude Desktop
- **Narration**: "I've deployed a stack with several MCP servers. Standard mode. Let me show you what the agent sees."

**[DEMO]**
- **Action**: Show the full tool list in Claude Desktop
- **Expected output**: Dozens of tools listed with full definitions
- **Narration**: "Look at this. Every tool from every server, fully loaded. Names, descriptions, parameter schemas. This is what's eating your context window. And the agent has to process all of this before it picks the one or two tools it actually needs."

**[CAMERA]**

Here's the thing - most conversations only use a handful of tools. But the agent loads all of them, every time. It's like downloading an entire encyclopedia to look up one word.

---

### Phase 2: Enabling Code Mode

**Goal**: Deploy the same stack in code mode and show the difference.

**[SCREEN]** Editor showing stack YAML

**[DEMO]**
- **Action**: Show the code mode configuration
- **Expected output**:
  ```yaml
  version: "1"
  name: code-mode-demo

  gateway:
    code_mode: "on"
    code_mode_timeout: 30

  mcp-servers:
    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"

    - name: context7
      command: ["npx", "-y", "@upstash/context7-mcp"]
  ```
- **Narration**: "Two changes. I added a gateway section with code_mode set to on, and a timeout for how long code can execute in the sandbox. That's it. Or if you want to skip the YAML change, just pass the flag on deploy."

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Deploy with code mode (either via YAML or CLI flag)
- **Commands**:
  ```
  gridctl destroy multi-server.yaml
  gridctl deploy code-mode-demo.yaml
  ```
  Or: `gridctl deploy multi-server.yaml --code-mode`
- **Expected output**: Deploy succeeds, gateway shows code mode enabled
- **Narration**: "Deploy. Notice in the status output - code mode is on."

**[DEMO]**
- **Action**: Check status to confirm code mode
- **Command**: `gridctl status`
- **Expected output**: GATEWAYS table with CodeMode column showing "on"
- **Narration**: "There it is. Code mode is active on this gateway."

---

### Phase 3: Search and Execute

**Goal**: Show the two meta-tools in action.

**[SCREEN]** Claude Desktop

**[DEMO]**
- **Action**: Open Claude Desktop and show the available tools
- **Expected output**: Only two tools visible: "search" and "execute" (instead of dozens)
- **Narration**: "Look at the tool list now. Two tools. Search and execute. That's all the agent sees. Instead of fifty tool definitions, it sees two. The context savings are massive."

Now let's see how the agent uses them.

**[DEMO]**
- **Action**: Ask Claude to find and use GitHub tools
- **Command**: Type a prompt like "Find all available GitHub tools and list the open issues in the gridctl repository"
- **Expected output**:
  1. Claude calls `search` with a query like "github issues"
  2. Search returns matching tool names and descriptions
  3. Claude writes JavaScript using `mcp.callTool("github", "get_issues", {...})`
  4. Claude calls `execute` with the JavaScript code
  5. Results come back from the sandbox
- **Narration**: "Watch the flow. First the agent searches for GitHub tools - it finds what's available without loading all definitions upfront. Then it writes JavaScript to call the tool it needs. The code runs in a sandboxed runtime, and the results come back. Same data, fraction of the context."

**[CAMERA]**

What I find interesting about this is the agent is essentially writing its own integration code on the fly. It searches for what it needs, writes the code to get it, and executes. It's dynamic tool discovery instead of static tool loading.

---

### Phase 4: The Sandbox

**Goal**: Explain what's running under the hood.

**[SCREEN]** Terminal or editor showing JavaScript examples

**[CAMERA]**

Let me break down what's happening inside that sandbox. Gridctl uses goja - a JavaScript runtime written in Go. When the agent calls execute with JavaScript code, that code runs in an isolated sandbox.

**[DEMO]**
- **Action**: Show example JavaScript that the agent would write
- **Expected output**:
  ```javascript
  // The agent writes something like this:
  const issues = mcp.callTool("github", "get_issues", {
    repo: "wcollins/gridctl",
    state: "open"
  });

  console.log(`Found ${issues.length} open issues`);
  issues.forEach(issue => {
    console.log(`#${issue.number}: ${issue.title}`);
  });
  ```
- **Narration**: "The agent gets access to mcp.callTool - that's the bridge back to your MCP servers. It passes the server name, tool name, and arguments. The sandbox runs it, captures console output, and returns everything to the agent. Modern JavaScript syntax - arrow functions, template literals, destructuring. All supported."

**[CAMERA]**

And here's the important part - the access control from the previous episode still applies inside the sandbox. If an agent doesn't have access to a server, mcp.callTool will reject it. Code mode doesn't bypass your filtering. It respects it.

---

### Phase 5: When to Use Code Mode

**[CAMERA]**

Code mode isn't always the right choice. Let me give you the quick decision framework.

Use code mode when you've got a lot of tools. If your stack has more than ten or fifteen tools, the context savings matter. The agent spends less time processing tool definitions and more time on your actual request.

Stick with standard mode when you've got a small number of tools and the agent needs to see them all upfront. Simple stacks with three or four tools - code mode adds a step without saving much.

The sweet spot is large stacks where agents only use a subset of available tools per conversation. That's where the 99% savings show up.

---

### Verification

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Verify end-to-end with a multi-step request
- **Command**: In Claude Desktop, ask something that requires searching for tools and executing multiple calls
- **Expected output**: Agent discovers tools, writes JavaScript, executes, returns results - all through search and execute
- **Narration**: "Let's make sure this all actually works end-to-end with a more complex request. Multiple tool calls, multiple servers, all through code mode."

---

### Wrap-Up

**[CAMERA]**

Code mode is one of those features that sounds complicated but does something simple - it stops your context window from being dominated by tool metadata. Two meta-tools replace dozens of definitions. The agent discovers what it needs on demand and executes through a sandboxed runtime. Access control still applies.

The takeaway: if you're running more than a handful of MCP tools, code mode gives your agent its context window back.

---

### Outro

**[CAMERA]**

Next time, we're looking at the development workflow. When you're iterating on a stack - adding servers, changing configs, tuning filters - the stop-start cycle gets old fast. I'll show you hot-reload with watch mode. Edit your YAML, save, and everything updates live. No restarts. Connected clients stay connected. See you there.
