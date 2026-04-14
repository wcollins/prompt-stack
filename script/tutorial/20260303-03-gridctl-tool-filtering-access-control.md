# Tool Filtering and Access Control
## Date: March 3, 2026
## Type: Tutorial
## Series: Introducing Gridctl (Episode 3 of 7)
## Estimated Length: Short-Medium (10-12min)

---

### Opening

**[CAMERA]**

Here's the thing about giving an AI agent access to all your tools. It's convenient - until it deletes something you didn't want deleted. Or creates a pull request when it should have just read the code. Or writes to your production Jira board when you were testing.

Unrestricted tool access is the default in most MCP setups. Every tool is visible to every client. That's fine for tinkering. It's not fine for anything real.

Today I'm going to show you how gridctl handles access control. Two levels of filtering - server-level and agent-level - so you can apply least privilege to your AI agents the same way you'd apply it to any other system.

---

### Prerequisites

**[NOTE]** Viewer should be familiar with multi-server stacks from Episode 2. Docker running.

---

### Section 1: Why This Matters

**[CAMERA]**

If you've ever worked with IAM policies, RBAC, or network ACLs, you know the principle: give each actor the minimum permissions they need and nothing more. We do this for users, for service accounts, for API keys. But most MCP setups give every agent the keys to everything.

Think about it. Your GitHub MCP server exposes tools for reading issues, creating pull requests, deleting branches, managing releases. Do you want every agent that connects to have access to all of that? Probably not.

Gridctl gives you two layers of control.

---

### Section 2: Server-Level Filtering

**[SCREEN]** Editor showing stack YAML

The first layer is server-level filtering. This controls which tools a server exposes to the entire system. If you filter a tool out here, no agent can see it, period.

**[DEMO]**
- **Action**: Show a stack file with server-level tool filtering
- **Expected output**:
  ```yaml
  version: "1"
  name: tool-filtering-demo

  mcp-servers:
    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      tools: ["get_issues", "get_pull_requests", "list_commits"]
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"
  ```
- **Narration**: "See that tools field? I'm telling gridctl to only expose these three tools from the GitHub server. The server might have twenty or thirty tools - create_issue, delete_branch, merge_pull_request - but none of those make it through the gateway. They're filtered out before any agent ever sees them."

**[CAMERA]**

This is your security boundary. It doesn't matter what an agent requests - if the tool isn't in that list, the gateway won't expose it. Think of it like a firewall rule for tools.

---

### Section 3: Agent-Level Filtering

**[SCREEN]** Editor showing stack YAML with agents

The second layer is per-agent. Different agents get access to different subsets of tools from the same servers.

**[DEMO]**
- **Action**: Show a stack file with agent-level tool filtering
- **Expected output**:
  ```yaml
  version: "1"
  name: access-control-demo

  mcp-servers:
    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"

  agents:
    - name: reader-agent
      image: alpine:latest
      description: "Read-only agent"
      uses:
        - server: github
          tools: ["get_issues", "get_pull_requests"]
      command: ["sh", "-c", "sleep infinity"]

    - name: operator-agent
      image: alpine:latest
      description: "Read-write agent"
      uses:
        - server: github
          tools: ["get_issues", "get_pull_requests", "create_issue", "create_pull_request"]
      command: ["sh", "-c", "sleep infinity"]
  ```
- **Narration**: "Two agents, same GitHub server, different access. The reader agent can only get issues and pull requests - it's read-only. The operator agent can read and create. Both connect to the same gateway, but they see different tool sets based on their role."

**[CAMERA]**

This is least privilege in action. Your analyst agent doesn't need write access. Your automation agent doesn't need delete access. You define the boundaries in YAML, and gridctl enforces them.

---

### Section 4: Deploy and Verify

**[SCREEN]** Terminal

Let's deploy this and see it working.

**[DEMO]**
- **Action**: Deploy the access control stack
- **Command**: `gridctl deploy access-control-demo.yaml`
- **Expected output**: Deploy progress showing servers and agents starting, gateway running
- **Narration**: "Deploy as usual. Both agents come up, the GitHub server is running, gateway is active."

**[DEMO]**
- **Action**: Check status to see agents and their access
- **Command**: `gridctl status`
- **Expected output**: GATEWAYS and CONTAINERS tables showing the full stack
- **Narration**: "Both agents are running. Let's see what tools each one has access to."

---

### Section 5: Seeing the Difference

**[SCREEN]** Web UI or Claude Desktop showing tool differences

**[DEMO]**
- **Action**: Show the web UI with different agent tool access visualized, or connect as each agent and list available tools
- **Expected output**: Reader agent sees 2 tools, operator agent sees 4 tools from the same server
- **Narration**: "Here's the reader agent - two tools. Get issues, get pull requests. That's it. Now look at the operator agent - four tools. Same server, different access. And if the reader agent tries to call create_issue, it gets denied. The gateway enforces it."

**[CAMERA]**

This isn't just a nice-to-have. When you're running agents in production - or even just testing with real data - you want to know exactly what each agent can and can't do. The filtering is declarative. It's in your YAML. It's version controlled. And it's enforced at the gateway level, not in the agent code.

---

### Section 6: Layering Both Levels

**[SCREEN]** Editor

**[NOTE]** Quick visual showing how the two levels interact.

To me, this is where it clicks. You can combine both layers. Server-level filtering sets the ceiling - the maximum tools available. Agent-level filtering sets the floor for each agent.

**[DEMO]**
- **Action**: Show a stack file with both levels
- **Expected output**:
  ```yaml
  mcp-servers:
    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      tools: ["get_issues", "get_pull_requests", "create_issue"]
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"

  agents:
    - name: viewer
      image: alpine:latest
      uses:
        - server: github
          tools: ["get_issues"]
    - name: contributor
      image: alpine:latest
      uses:
        - github
  ```
- **Narration**: "The server exposes three tools. The viewer agent can only use get_issues - one tool. The contributor agent uses the string shorthand which means all tools the server exposes - so it gets all three. But neither agent can access delete_branch or merge_pull_request because those were filtered at the server level. Two layers, one clean policy."

---

### Section 7: Cleanup

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Destroy the stack
- **Command**: `gridctl destroy access-control-demo.yaml`
- **Expected output**: Clean teardown
- **Narration**: "Tear it down."

---

### Recap

**[CAMERA]**

Two levels of access control. Server-level filtering sets the maximum tools available to anyone. Agent-level filtering gives each agent exactly what it needs and nothing more. It's declarative, it's in your YAML, and it's enforced at the gateway - not on the honor system.

The takeaway: treat your AI agents like you treat your service accounts. Least privilege isn't optional just because the consumer is an LLM.

---

### Outro

**[CAMERA]**

Next time, we're tackling something that annoys me about MCP in general - context window consumption. When you've got thirty, forty, fifty tools, your agent spends thousands of tokens just loading the tool definitions before it even starts thinking. I'll show you code mode - how gridctl cuts that by 99 percent. See you in the next one.
