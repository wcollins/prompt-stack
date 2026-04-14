# Hot-Reload - Edit Your Stack Without Downtime
## Date: March 3, 2026
## Type: Lab
## Series: Introducing Gridctl (Episode 5 of 7)
## Tools: gridctl, Claude Desktop, Docker
## Estimated Length: Short-Medium (10-12min)

---

### Opening

**[CAMERA]**

If you've been following along, you know the drill by now. You write a stack file, deploy it, use it, and eventually tear it down. But during development, you're changing that stack file constantly. Adding a server. Removing one. Tweaking a filter. And every time, you're running destroy, deploy, re-linking your client.

It's not the end of the world, but it's friction. And friction slows you down.

Watch mode eliminates that cycle. Deploy once with a flag, edit your YAML, save, and gridctl applies the changes live. Connected clients stay connected. No restart.

---

### Prerequisites

**[NOTE]** Viewer should be comfortable with gridctl deploy/destroy and multi-server stacks. Docker running. Claude Desktop.

---

### Phase 1: Deploy with Watch Mode

**Goal**: Start a stack with hot-reload enabled.

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Deploy a stack with the --watch flag
- **Command**: `gridctl deploy multi-server.yaml --watch`
- **Expected output**: Normal deploy output, plus a message indicating watch mode is active
- **Narration**: "Same deploy command, one extra flag. --watch tells gridctl to monitor the stack file for changes. It's still running as a daemon - you get your terminal back."

**[DEMO]**
- **Action**: Check status and link client
- **Commands**:
  ```
  gridctl status
  gridctl link claude
  ```
- **Expected output**: Stack running with watch mode, client linked
- **Narration**: "Everything is up. Client is linked. Now let's start making changes."

---

### Phase 2: Add a Server Live

**Goal**: Add an MCP server to the running stack without restarting.

**[SCREEN]** Editor showing the stack YAML (split screen with terminal if possible)

**[DEMO]**
- **Action**: Edit the stack file to add a new MCP server
- **Expected output**: Add a new entry to the mcp-servers list, e.g.:
  ```yaml
  mcp-servers:
    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"

    - name: context7
      command: ["npx", "-y", "@upstash/context7-mcp"]

    # New server added
    - name: atlassian
      command: ["npx", "mcp-remote", "https://mcp.atlassian.com/v1/sse"]
  ```
- **Narration**: "I'm adding the Atlassian MCP server to my stack. Just adding the YAML block and saving."

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Save the file and watch gridctl detect the change
- **Expected output**: Gridctl logs showing file change detected, new server starting, gateway reconfigured
- **Narration**: "Saved. Watch the terminal - gridctl detects the file change, sees a new server was added, starts it up, and reconfigures the gateway. No restart. The GitHub and Context7 servers are untouched."

**[DEMO]**
- **Action**: Verify the new server is running
- **Command**: `gridctl status`
- **Expected output**: All three servers running, gateway still on the same port
- **Narration**: "Three servers now. Same gateway. Same port. If I go to Claude Desktop right now, I'll see the new Atlassian tools available without reconnecting."

**[SCREEN]** Claude Desktop

**[DEMO]**
- **Action**: Show the new tools appearing in Claude Desktop
- **Expected output**: Atlassian tools now visible alongside existing tools
- **Narration**: "There they are. Atlassian tools just showed up. My client never disconnected. The gateway updated underneath it."

---

### Phase 3: Remove a Server Live

**Goal**: Remove a server and see it disappear without disrupting the rest.

**[SCREEN]** Editor

**[DEMO]**
- **Action**: Remove the Atlassian server from the YAML and save
- **Narration**: "Now I'm removing Atlassian. Delete the block, save."

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Watch gridctl apply the removal
- **Expected output**: Gridctl detects removal, stops the Atlassian server, reconfigures gateway
- **Narration**: "Change detected. Atlassian server stops. Gateway reconfigures. GitHub and Context7 are still running. If I check Claude Desktop, the Atlassian tools are gone."

---

### Phase 4: Modify an Existing Server

**Goal**: Change configuration on a running server.

**[SCREEN]** Editor

**[DEMO]**
- **Action**: Add tool filtering to an existing server
- **Expected output**: Add a `tools` field to the github server:
  ```yaml
  - name: github
    image: ghcr.io/github/github-mcp-server:latest
    transport: stdio
    tools: ["get_issues", "get_pull_requests"]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"
  ```
- **Narration**: "Let me add tool filtering to the GitHub server. I only want get_issues and get_pull_requests exposed. Save."

**[SCREEN]** Terminal / Claude Desktop

**[DEMO]**
- **Action**: Watch the filter apply and verify in the client
- **Expected output**: Gateway reconfigures, tool list in Claude Desktop shrinks to only the filtered tools
- **Narration**: "Filter applied. Check Claude Desktop - the GitHub tools just went from the full list down to two. Live. No restart. No reconnect."

---

### Phase 5: Development Workflow

**[CAMERA]**

This is what my development loop looks like with gridctl. I deploy with --watch. I open my stack file and my LLM client side by side. I add servers, tweak filters, enable code mode, adjust access control - all while the stack is running and my client is connected.

It's the same feedback loop you get with hot-reload in web development. Edit, save, see the result. No build step, no restart ceremony.

**[SCREEN]** Show the web UI updating in real-time with changes

**[DEMO]**
- **Action**: Open the web UI and make a change to the stack file
- **Expected output**: The topology visualization updates to reflect the new configuration
- **Narration**: "The web UI reflects changes in real-time too. Add a server, it appears on the graph. Remove one, it disappears. This is useful when your stacks get complex - you get immediate visual feedback."

---

### Verification

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Confirm everything is still connected and working
- **Commands**:
  ```
  gridctl status
  ```
- **Expected output**: Clean status showing current state matches the YAML
- **Narration**: "Let's verify. Status matches what's in the YAML. Everything the watch mode touched is consistent."

---

### Wrap-Up

**[CAMERA]**

Hot-reload turns gridctl from a deploy tool into a development environment. Add, remove, and modify MCP servers without breaking your workflow. Connected clients stay connected. The gateway reconfigures underneath them.

The takeaway: deploy with --watch and stop restarting things. Your iteration speed will thank you.

---

### Outro

**[CAMERA]**

Next time, we're going beyond MCP servers. Not every service has an MCP implementation, but almost everything has a REST API with an OpenAPI spec. I'll show you how gridctl can take an OpenAPI spec and turn it into MCP tools automatically. Any API becomes agent-callable. See you there.
