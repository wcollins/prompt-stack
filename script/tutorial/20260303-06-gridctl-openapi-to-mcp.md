# Turn Any REST API into MCP Tools
## Date: March 3, 2026
## Type: Tutorial
## Series: Introducing Gridctl (Episode 6 of 7)
## Estimated Length: Medium (12-15min)

---

### Opening

**[CAMERA]**

Not every service has an MCP server. GitHub does. Atlassian does. But your company's internal API? That monitoring service your team uses? The vendor platform you work with daily? Probably not.

Here's what they almost certainly have - a REST API with an OpenAPI spec. And gridctl can take that spec and turn every endpoint into an MCP tool. No container. No code. You point gridctl at a spec URL, deploy, and your agent can call that API.

Today I'm going to show you how that works, starting with a public API and then mixing it with native MCP servers in the same stack.

---

### Prerequisites

**[NOTE]** Viewer should be familiar with gridctl deploy/link basics from Episode 1. Docker running. Claude Desktop.

---

### Section 1: The Gap

**[CAMERA]**

MCP is growing fast. More servers every week. But there's a long tail of services that will never build a dedicated MCP server - or at least not anytime soon. Internal tools, niche platforms, legacy systems. These are the tools you actually use every day, and they're the hardest to connect to your agents.

The bridge is OpenAPI. Most modern REST APIs publish an OpenAPI spec that describes every endpoint, its parameters, its responses. Gridctl reads that spec and generates MCP tool definitions automatically. Each operation becomes a callable tool.

---

### Section 2: Basic OpenAPI Setup

**[SCREEN]** Editor showing stack YAML

I'm going to start with the simplest possible example - the Swagger Petstore. It's a public API with a well-documented OpenAPI spec, and it doesn't require authentication. Perfect for demonstrating the concept.

**[DEMO]**
- **Action**: Show the OpenAPI stack file
- **Expected output**:
  ```yaml
  version: "1"
  name: openapi-demo

  mcp-servers:
    - name: petstore
      openapi:
        spec: https://petstore3.swagger.io/api/v3/openapi.json
  ```
- **Narration**: "Three lines under mcp-servers. A name, and an openapi block pointing at the spec URL. That's it. No image, no container, no transport configuration. Gridctl fetches the spec, parses every operation, and creates MCP tools from them."

---

### Section 3: Deploy and Explore

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Deploy the OpenAPI stack
- **Command**: `gridctl deploy openapi-demo.yaml`
- **Expected output**: Deploy showing spec fetch, tool generation, gateway startup
- **Narration**: "Deploy. Gridctl fetches the OpenAPI spec, generates tool definitions for each operation, and starts the gateway. No containers pulled - this is lightweight."

**[DEMO]**
- **Action**: Link and check status
- **Commands**:
  ```
  gridctl status
  gridctl link claude
  ```
- **Expected output**: Gateway running, tools generated from the spec
- **Narration**: "Gateway is up. Let's see what tools got generated."

**[SCREEN]** Claude Desktop

**[DEMO]**
- **Action**: Show the auto-generated MCP tools in Claude Desktop
- **Expected output**: Tools like `petstore__getPetById`, `petstore__findPetsByStatus`, `petstore__addPet`, `petstore__getInventory`, etc.
- **Narration**: "Every operation in the Petstore spec is now an MCP tool. getPetById, findPetsByStatus, addPet, getInventory. Gridctl pulled the operation IDs from the spec and created tools with proper input schemas. The agent knows what parameters each tool expects."

**[DEMO]**
- **Action**: Use a tool through Claude
- **Command**: Type "Find the pet with ID 1 in the Petstore"
- **Expected output**: Claude calls `petstore__getPetById` with id=1, returns the pet data
- **Narration**: "Let's use one. I'm asking for pet ID 1. Claude calls the generated tool, which proxies the request to the actual Petstore API, and we get real data back. The agent doesn't know this is an OpenAPI translation layer - it just sees a tool and uses it."

---

### Section 4: Operation Filtering

**[SCREEN]** Editor

You probably don't want every endpoint exposed as a tool. The Petstore has create, update, and delete operations. If you just want read access, filter them out.

**[DEMO]**
- **Action**: Show operation filtering in the stack file
- **Expected output**:
  ```yaml
  mcp-servers:
    - name: petstore-readonly
      openapi:
        spec: https://petstore3.swagger.io/api/v3/openapi.json
        operations:
          include:
            - getPetById
            - findPetsByStatus
            - findPetsByTags
            - getInventory
  ```
- **Narration**: "The operations block with an include list. Only these four endpoints become tools. addPet, updatePet, deletePet - all filtered out. Same concept as tool filtering from Episode 3, but applied at the OpenAPI level using operation IDs."

---

### Section 5: Authentication

**[CAMERA]**

The Petstore doesn't need auth, but real APIs do. Gridctl supports two patterns - bearer tokens and custom headers. Both pull credentials from environment variables so secrets stay out of your stack files.

**[SCREEN]** Editor

**[DEMO]**
- **Action**: Show authenticated OpenAPI configs
- **Expected output**:
  ```yaml
  mcp-servers:
    # Bearer token - sends Authorization: Bearer <token>
    - name: production-api
      openapi:
        spec: https://api.example.com/openapi.json
        auth:
          type: bearer
          tokenEnv: API_TOKEN

    # API key header - sends X-API-Key: <key>
    - name: vendor-api
      openapi:
        spec: https://vendor.example.com/openapi.json
        auth:
          type: header
          header: X-API-Key
          valueEnv: VENDOR_API_KEY
  ```
- **Narration**: "Two auth types. Bearer sends the standard Authorization header. Custom header lets you send any header name - X-API-Key, whatever your API expects. The tokenEnv and valueEnv fields reference environment variables. Export them before you deploy, and gridctl injects them at request time. Your tokens never touch the YAML file."

---

### Section 6: Mixing OpenAPI with Native MCP Servers

**[SCREEN]** Editor

Here's where this gets powerful. You can mix OpenAPI-backed servers with native MCP servers in the same stack.

**[DEMO]**
- **Action**: Show a combined stack
- **Expected output**:
  ```yaml
  version: "1"
  name: hybrid-stack

  mcp-servers:
    # Native MCP server (Docker container)
    - name: github
      image: ghcr.io/github/github-mcp-server:latest
      transport: stdio
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"

    # OpenAPI-backed server (no container)
    - name: petstore
      openapi:
        spec: https://petstore3.swagger.io/api/v3/openapi.json
        operations:
          include:
            - getPetById
            - findPetsByStatus
  ```
- **Narration**: "Native GitHub MCP server running in a container next to an OpenAPI-backed Petstore. One stack, one gateway, one endpoint. The agent doesn't know or care which tools come from containers and which come from OpenAPI translations. They're all just tools."

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Deploy the hybrid stack
- **Command**: `gridctl deploy hybrid-stack.yaml`
- **Expected output**: Both servers running, tools aggregated
- **Narration**: "Deploy. GitHub container starts, Petstore spec gets fetched and parsed. Both sets of tools available through one gateway."

---

### Section 7: Cleanup

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Destroy the stack
- **Command**: `gridctl destroy hybrid-stack.yaml`
- **Expected output**: Clean teardown
- **Narration**: "Clean up."

---

### Recap

**[CAMERA]**

OpenAPI support is what makes gridctl practical for real-world use. You're not limited to the services that have built MCP servers. If it has a REST API and an OpenAPI spec, gridctl can turn it into MCP tools. Add operation filtering for control, authentication for real APIs, and mix it with native MCP servers in the same stack.

The takeaway: your agent's tool surface just expanded to every API with a spec file. That's most of them.

---

### Outro

**[CAMERA]**

Next time is the last episode in this series, and we're going to talk about something that ties everything together - agent skills and workflows. Reusable, deterministic, multi-step operations that you define once and execute on demand. Skills turn your MCP tools into composable automation. See you there.
