# Why I Built Gridctl
## Date: March 3, 2026
## Type: Tutorial
## Series: Introducing Gridctl (Episode 1 of 7)
## Estimated Length: Medium (18-22min)

---

### Opening

**[CAMERA]**

If you're using AI tools today - Claude Desktop, Cursor, VS Code - you've probably hit this wall. You want your agent to talk to GitHub, maybe Jira, maybe a file system tool, maybe something custom. And each one of those is its own MCP server. Its own container. Its own config. Its own port. Its own set of environment variables you have to manage.

And it works. Until it doesn't. Until you're three servers deep, juggling JSON configs, and wondering why port 8080 is already taken.

I built gridctl to fix this. One YAML file. One command. One endpoint. Every tool your agent needs, aggregated and ready. Today I'm going to show you the problem, then I'm going to show you the fix - and by the end of this video, you'll have a working MCP stack connected to your LLM client.

Let's dig in.

---

### Prerequisites

**[NOTE]** Viewer needs Docker installed and running. An LLM client like Claude Desktop, Cursor, or VS Code with MCP support. Link to Docker install docs and Claude Desktop download in the description.

---

### Section 1: The Problem

**[CAMERA]**

Quick context for anyone new to this. MCP - Model Context Protocol - is how AI agents talk to external tools. Your LLM client connects to an MCP server, and that server exposes tools the agent can call. Read a file. Create a GitHub issue. Query a database. Whatever.

The protocol itself is solid. The problem is everything around it.

**[SCREEN]** Show a Claude Desktop config JSON file (claude_desktop_config.json)

Here's what a typical Claude Desktop config looks like when you're running a few MCP servers manually.

**[DEMO]**
- **Action**: Show a manually configured claude_desktop_config.json with multiple servers
- **Expected output**: A JSON file with 3-4 mcpServers entries, each with different commands, args, env blocks
- **Narration**: "You've got your GitHub server here, maybe a filesystem server, maybe something custom. Each one has its own command, its own args, its own environment variables. And this is just one client. If you're also using Cursor or VS Code, you're maintaining this in multiple places."

**[CAMERA]**

Now multiply that by a team. Five engineers, each with slightly different configs. Different token versions. Different ports. Someone's running the old image. Someone else hardcoded a path that only exists on their machine.

That's configuration drift. And if you've worked in infrastructure - networking, cloud, DevOps - you've seen this movie before. It's the same problem we solved years ago with infrastructure-as-code. Define it once, deploy it anywhere, version control it.

That's what gridctl does for MCP.

---

### Section 2: What Gridctl Actually Is

**[CAMERA]**

Gridctl is an MCP orchestration platform. If you've ever used Containerlab for network simulation, the mental model is the same. You write a YAML file that describes your stack - which MCP servers to run, how they connect, who can access what. Then you deploy it with one command.

Gridctl spins up the containers, creates a gateway that aggregates all the tools from all your servers into one endpoint, and gives you a single URL to point your LLM client at. No manual JSON editing. No port tracking. No environment variable gymnastics.

Let me show you.

---

### Section 3: Installing Gridctl

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Install gridctl via Homebrew
- **Command**: `brew install gridctl/tap/gridctl`
- **Expected output**: Standard Homebrew install output, finishing with successful installation
- **Narration**: "Simplest way to install is through Homebrew. If you're not on macOS, there are binary downloads and you can build from source - I'll link those in the description."

**[DEMO]**
- **Action**: Verify installation
- **Command**: `gridctl version`
- **Expected output**: Version string (e.g., `gridctl version 0.1.0-alpha.10`)
- **Narration**: "Quick sanity check. We're running - good to go."

---

### Section 4: Your First Stack File

**[SCREEN]** Editor showing ~/code/stack.yaml

**[NOTE]** File lives at ~/code/stack.yaml. This is the actual stack file I use day-to-day - three real MCP servers with three different transport types.

Let me walk through what a stack file looks like. This is my actual daily driver.

**[DEMO]**
- **Action**: Show ~/code/stack.yaml in an editor
- **Expected output**:
  ```yaml
  version: "1"
  name: daily

  mcp-servers:
    - name: atlassian
      command: ["npx", "mcp-remote", "https://mcp.atlassian.com/v1/sse"]

    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"

    - name: zapier
      command:
        [
          "npx",
          "mcp-remote",
          "https://mcp.zapier.com/api/v1/connect",
          "--header",
          "Authorization: Bearer ${ZAPIER_MCP_TOKEN}",
        ]
  ```
- **Narration**: "This is my actual stack file. Three MCP servers I use every day. And I want you to notice something - these are three completely different types of servers. Atlassian is a remote service. Gridctl connects out to Atlassian's hosted endpoint over SSE - that's Server-Sent Events. No container, no local process, it's talking to Atlassian's cloud. GitHub is a Docker container. It pulls the official image and communicates over stdio - stdin and stdout piped through the container. Totally different transport. And Zapier is another remote service, but this one passes an auth token in the header. Three servers. Three different transports. Three different auth models. One file."

**[CAMERA]**

This is the core of what makes gridctl flexible. You're not locked into one way of running MCP servers. Some are containers. Some are hosted services on the other side of the internet. Some need bearer tokens, some need environment variables, some need nothing at all. Gridctl doesn't care. You describe what you want, it figures out how to wire it up. No ports to specify. No Docker run commands. No JSON-RPC endpoint configuration.

---

### Section 5: Deploy

**[SCREEN]** Terminal

**[NOTE]** Make sure GITHUB_PERSONAL_ACCESS_TOKEN and ZAPIER_MCP_TOKEN are exported before recording. Pre-pull the GitHub MCP server image to avoid long download during the demo.

**[DEMO]**
- **Action**: Deploy the stack
- **Command**: `gridctl deploy ~/code/stack.yaml`
- **Expected output**: Deploy progress showing Atlassian remote connection, GitHub container pull and start, Zapier remote connection, gateway creation on port 8180
- **Narration**: "I've already got my tokens exported. Now I just point gridctl at my stack file. Watch the output - it handles each server differently. It connects out to Atlassian's remote endpoint, pulls the Docker image for GitHub, and connects to Zapier's API with the auth header. Three different transports, three different connection methods. Gridctl sorts it all out and brings up one gateway."

**[DEMO]**
- **Action**: Check status
- **Command**: `gridctl status`
- **Expected output**: GATEWAYS table showing daily running on port 8180, CONTAINERS table showing all three servers running
- **Narration**: "Status gives me the full picture. Gateway is up on port 8180. All three servers are running - Atlassian, GitHub, Zapier. Different transports, different auth, one endpoint."

---

### Section 6: Linking Your LLM Client

**[SCREEN]** Terminal

Here's my favorite part. Normally you'd go find your Claude Desktop config file, open it in an editor, paste in the server config, restart the app. Gridctl does that for you.

**[DEMO]**
- **Action**: Link to Claude Desktop
- **Command**: `gridctl link claude`
- **Expected output**: Success message showing Claude Desktop config updated with gridctl endpoint
- **Narration**: "One command. Gridctl detects where Claude Desktop stores its config, injects the right connection details, and you're done. It supports Claude Desktop, Cursor, VS Code, Windsurf - pretty much every client that speaks MCP."

**[NOTE]** If recording with a different client, adjust the command: `gridctl link cursor`, `gridctl link vscode`, etc.

**[CAMERA]**

No JSON editing. No copy-pasting URLs. No restarting and wondering why it didn't pick up the change. Just `gridctl link` and go.

---

### Section 7: Using It End-to-End

**[SCREEN]** Claude Desktop application

Now let's see this actually work. Three servers, three transports - let's use them.

**[DEMO]**
- **Action**: Open Claude Desktop, start a new conversation
- **Narration**: "I'm opening Claude Desktop. You can see the gridctl MCP connection is active - it picked up the link config automatically. And notice the tool list - we've got tools from all three servers. GitHub tools prefixed with github__, Atlassian tools prefixed with atlassian__, Zapier tools prefixed with zapier__. Gridctl namespaces everything so nothing collides."

**[DEMO]**
- **Action**: Ask Claude something that uses a GitHub tool
- **Command**: Type a prompt like "List the open issues in the gridctl repository"
- **Expected output**: Claude calls the github__get_issues tool through gridctl, returns real GitHub data
- **Narration**: "Let me start with GitHub. I'm asking for open issues on a repo. Claude picks the GitHub tool, calls it through gridctl, and I get real data back. That tool call went through the Docker container running on my machine."

**[DEMO]**
- **Action**: In the same conversation, ask something that hits Atlassian
- **Command**: Type a follow-up like "Now find my recent Jira issues" or "Search for tickets assigned to me in Jira"
- **Expected output**: Claude calls an atlassian__ tool, returns real Jira data
- **Narration**: "Now Jira. Same conversation. Claude switches to an Atlassian tool. This call goes out to Atlassian's hosted MCP endpoint - completely different transport, completely different infrastructure. The agent doesn't know or care. It just sees tools and uses them."

**[CAMERA]**

That's the full picture. One YAML file, three MCP servers, three different transports - a Docker container talking stdio, a remote Atlassian endpoint over SSE, a remote Zapier endpoint with bearer auth. All deployed with one command, all behind one gateway, all accessible in a single conversation. The agent calls GitHub, then Atlassian, then Zapier - and it has no idea these tools are running in fundamentally different ways.

And the whole thing is reproducible. Hand that stack.yaml to someone else on your team, and they get the exact same setup. Same servers, same transports, same endpoint. No "it works on my machine."

---

### Section 8: Cleanup

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Destroy the stack
- **Command**: `gridctl destroy ~/code/stack.yaml`
- **Expected output**: Containers stopped and removed, gateway shut down
- **Narration**: "When you're done, tear it down. Containers stop, gateway shuts down, clean slate. I like my environments disposable."

**[DEMO]**
- **Action**: Verify cleanup
- **Command**: `gridctl status`
- **Expected output**: No gateways or containers running
- **Narration**: "Nothing running. Clean."

---

### Recap

**[CAMERA]**

Let's land this. The problem is real - MCP servers are powerful, but managing them manually is a mess. Scattered configs, port conflicts, environment variable juggling, different transport types you have to wire up individually, and none of it is version controlled or reproducible.

Gridctl solves that with three ideas borrowed from infrastructure-as-code: define your stack in YAML, deploy it with one command, and connect through one endpoint. You saw it today with real servers - a Docker container, two remote services, three different transports, three different auth models. One file. One deploy. One gateway. Your agent just sees tools and uses them.

---

### Outro

**[CAMERA]**

You saw how one stack file pulls together a Docker container and remote services with different transports and auth - all behind one endpoint. Next time, we're going deeper. I'll show you the web UI that gives you a live view of your stack, more transport types, and how namespacing keeps tools organized as your stacks grow.

If you want to get ahead of that, the gridctl docs and all the example stack files are linked in the description. Play around with it. Break it. That's how you learn.
