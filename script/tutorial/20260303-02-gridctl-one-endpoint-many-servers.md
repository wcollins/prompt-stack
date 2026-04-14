# One Endpoint, Many Servers
## Date: March 3, 2026
## Type: Tutorial
## Series: Introducing Gridctl (Episode 2 of 7)
## Estimated Length: Medium (12-15min)

---

### Opening

**[CAMERA]**

Last time we deployed a single MCP server - GitHub - and connected it to Claude Desktop through gridctl. That's useful, but it's not where things get interesting. In the real world, you don't just need GitHub. You need GitHub and Jira and a filesystem tool and maybe a documentation server and whatever custom thing your team built last week.

The question is: how do you run all of those behind one endpoint without everything colliding? That's what we're covering today - multi-server stacks, different transport types, and how gridctl namespaces everything so your tools stay organized.

Let's dig in.

---

### Prerequisites

**[NOTE]** Viewer should have watched Episode 1 or be familiar with gridctl deploy/link/destroy basics. Docker running. Claude Desktop or similar client. GitHub token exported.

---

### Section 1: The Multi-Server Problem

**[CAMERA]**

When you're running one MCP server, life is simple. One container, one set of tools, done. But the moment you add a second server, you start hitting problems.

Both servers might expose a tool called "search." Your LLM client sees two tools with the same name and doesn't know which one to call. Or you've got one server running in a Docker container using stdio, another one running as a hosted service over HTTP, and a third that's a local process on your machine. Three different transports, three different connection methods.

Without something in the middle to sort this out, you're back to managing each server individually. Gridctl is that something in the middle.

---

### Section 2: Building a Multi-Server Stack

**[SCREEN]** Editor showing a multi-server stack YAML

I'm going to build a stack with three MCP servers, each using a different transport type.

**[DEMO]**
- **Action**: Show the multi-server stack file
- **Expected output**:
  ```yaml
  version: "1"
  name: multi-server

  mcp-servers:
    # Docker container using stdio transport
    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"

    # Local process - runs directly on your machine
    - name: context7
      command: ["npx", "-y", "@upstash/context7-mcp"]

    # External service - connects to a remote URL
    - name: atlassian
      command: ["npx", "mcp-remote", "https://mcp.atlassian.com/v1/sse"]
  ```
- **Narration**: "Three servers. Three different ways they run. GitHub is a Docker container communicating over stdio. Context7 is a local process - gridctl spawns it on your machine and talks to it through stdin and stdout. Atlassian is an external service - gridctl connects out to Atlassian's hosted MCP endpoint. All three defined in one file."

**[CAMERA]**

Notice I didn't have to specify ports, configure networking between them, or write any glue code. Gridctl figures out the transport for each server and handles the connection. Your YAML describes intent - gridctl handles implementation.

---

### Section 3: Deploy and Explore

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Deploy the multi-server stack
- **Command**: `gridctl deploy multi-server.yaml`
- **Expected output**: Progress showing each server starting, gateway creation on port 8180
- **Narration**: "Deploy just like before. Gridctl starts each server using its transport type - Docker for GitHub, local process for Context7, outbound connection for Atlassian. One gateway aggregates everything."

**[DEMO]**
- **Action**: Check status
- **Command**: `gridctl status`
- **Expected output**: GATEWAYS table showing multi-server on 8180, CONTAINERS table showing all three servers
- **Narration**: "Status shows all three servers running behind one gateway. One port, one endpoint."

---

### Section 4: Namespacing

**[SCREEN]** Claude Desktop or terminal showing tool list

Here's where it gets clever. When you aggregate tools from multiple servers, names can collide. Two servers might both have a "search" tool. Gridctl prevents this with automatic namespacing.

**[DEMO]**
- **Action**: Show the aggregated tool list in Claude Desktop (or via API)
- **Expected output**: Tools prefixed with server names: `github__get_issues`, `github__create_pull_request`, `context7__resolve_library_id`, `context7__get_library_docs`, `atlassian__get_jira_issue`, etc.
- **Narration**: "Every tool gets prefixed with its server name. GitHub tools start with github__, Context7 tools start with context7__, Atlassian tools start with atlassian__. No collisions. Your agent always knows which server a tool belongs to."

**[CAMERA]**

This is subtle but important. When you're running thirty or forty tools across multiple servers, namespacing is what keeps things sane. The LLM can see exactly which server provides which capability, and there's zero ambiguity about what gets called.

---

### Section 5: Using Multiple Servers in One Conversation

**[SCREEN]** Claude Desktop

Let me show this working in practice. I'm going to have one conversation that uses tools from all three servers.

**[DEMO]**
- **Action**: Ask Claude a question that requires multiple servers
- **Command**: Type a prompt like "Look up the open issues in [repo] on GitHub, then find the relevant React documentation using Context7 for the most recent issue"
- **Expected output**: Claude calls github__list_issues first, then context7__resolve_library_id and context7__get_library_docs
- **Narration**: "Watch the tool calls. First it hits GitHub through the github server to get the issues. Then it calls Context7 to pull up documentation. Two different servers, two different transports, one seamless conversation. The agent doesn't care how these servers are connected - it just sees tools and uses them."

---

### Section 6: The Web UI

**[SCREEN]** Browser at localhost:8180

One more thing. Gridctl ships with a web UI that gives you a visual picture of your stack.

**[DEMO]**
- **Action**: Open localhost:8180 in a browser
- **Expected output**: React Flow visualization showing the gateway, connected servers, agents, and network topology
- **Narration**: "This is your stack visualized. You can see the gateway in the center, each MCP server connected to it, the transport types, status indicators. When something goes wrong, you can see it here before you dig into logs."

**[CAMERA]**

I find this especially useful when stacks get bigger. Five, six, seven servers - the visual makes it immediately obvious what's connected and what's not.

---

### Section 7: Cleanup

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Destroy the stack
- **Command**: `gridctl destroy multi-server.yaml`
- **Expected output**: All servers stopped, gateway shut down
- **Narration**: "Clean up is the same as before. One command, everything comes down."

---

### Recap

**[CAMERA]**

Today you saw the real power of having a gateway in the middle. Multiple MCP servers, different transports, all aggregated behind one endpoint with automatic namespacing. No port management, no transport configuration, no name collisions.

The takeaway here is simple - your agents shouldn't care how tools are connected. They should just have access to the tools they need. Gridctl makes that happen.

---

### Outro

**[CAMERA]**

Next time, we're adding access control. Because right now, every agent that connects to our gateway sees every tool. And in production, that's not what you want. I'll show you how to filter tools at the server level and the agent level - least privilege for AI agents. See you there.
