# Agent Skills and Workflows
## Date: March 3, 2026
## Type: Lab
## Series: Introducing Gridctl (Episode 7 of 7)
## Tools: gridctl, Claude Desktop, Docker, curl
## Estimated Length: Medium-Long (15-20min)

---

### Opening

**[CAMERA]**

Throughout this series, we've been giving agents access to individual tools. Get this issue. Create that pull request. Call this API. The agent decides what to do, how to chain calls together, and in what order.

That works for exploratory tasks. But when you have a repeatable process - review a PR and post a summary, gather metrics from three sources and format a report, run a multi-step deployment check - you don't want the agent improvising every time. You want deterministic, reusable, orchestrated workflows.

That's what agent skills are. You define a skill as a markdown document with YAML frontmatter. It specifies inputs, a sequence of tool calls with dependencies and template expressions, and an output format. Deploy it to the registry, activate it, and it becomes callable - through the API, through the web UI, or through your LLM client as an MCP prompt.

Let's build some.

---

### Prerequisites

**[NOTE]** Viewer should be comfortable with gridctl stacks and tool concepts from previous episodes. Docker running.

---

### Phase 1: Understanding Skills

**Goal**: Explain what a skill is and how it fits into the gridctl ecosystem.

**[CAMERA]**

A skill in gridctl is a SKILL.md file. Markdown document, YAML frontmatter. The frontmatter defines the skill metadata, inputs, workflow steps, and output. The markdown body is documentation - what the skill does, how to use it.

Skills live in a registry at ~/.gridctl/registry/skills/. Each skill gets its own directory. They have lifecycle states - draft, active, disabled. Only active skills are exposed through MCP.

**[SCREEN]** File browser or terminal showing the registry directory structure

**[DEMO]**
- **Action**: Show the registry directory structure
- **Commands**:
  ```
  ls ~/.gridctl/registry/skills/
  ```
- **Expected output**: Directory listing (may be empty initially)
- **Narration**: "This is the skills registry. Each subdirectory is a skill, and inside each one is a SKILL.md file. Let's create our first one."

---

### Phase 2: Building a Sequential Workflow

**Goal**: Create and execute a basic skill with step dependencies.

**[SCREEN]** Editor

**[DEMO]**
- **Action**: Show the SKILL.md for a basic sequential workflow
- **Expected output**:
  ```markdown
  ---
  name: workflow-basic
  description: Add two numbers and echo the result
  tags:
    - workflow
    - demo
  allowed-tools: local-tools__add, local-tools__echo
  state: draft

  inputs:
    a:
      type: number
      description: First number
      required: true
    b:
      type: number
      description: Second number
      required: true

  workflow:
    - id: add-numbers
      tool: local-tools__add
      args:
        a: "{{ inputs.a }}"
        b: "{{ inputs.b }}"

    - id: echo-result
      tool: local-tools__echo
      args:
        message: "The sum is: {{ steps.add-numbers.result }}"
      depends_on: add-numbers

  output:
    format: last
  ---

  # Basic Workflow

  A two-step sequential workflow. Adds two numbers, then echoes the result.
  ```
- **Narration**: "Let me walk through this. The frontmatter defines everything. Name, description, tags. The allowed-tools field is an access control list - this skill can only call these two tools, nothing else. Inputs define what the skill needs - two numbers. The workflow is a list of steps. Step one calls the add tool with our inputs. Step two depends on step one and echoes the result using a template expression. The double-curly-brace syntax lets you reference inputs and previous step results."

**[CAMERA]**

Notice the depends_on field on the second step. That tells gridctl this step can't run until add-numbers completes. The workflow engine builds a dependency graph and executes steps in the right order. If a step has no dependencies, it can run in parallel with other independent steps. More on that in a minute.

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Deploy the registry stack and copy the skill
- **Commands**:
  ```
  gridctl deploy registry-basic.yaml
  mkdir -p ~/.gridctl/registry/skills/workflow-basic
  cp workflow-basic/SKILL.md ~/.gridctl/registry/skills/workflow-basic/
  ```
- **Expected output**: Stack deployed, skill copied to registry
- **Narration**: "I've deployed a stack with a local tools server that provides our add and echo tools. Now I'm copying the skill into the registry."

**[DEMO]**
- **Action**: Activate the skill
- **Command**: `curl -X POST http://localhost:8180/api/registry/skills/workflow-basic/activate`
- **Expected output**: Success response confirming skill is active
- **Narration**: "Skills start as drafts. I'm activating it through the API. Now it's visible to MCP clients as a prompt."

**[DEMO]**
- **Action**: Execute the skill
- **Command**:
  ```
  curl -X POST http://localhost:8180/api/registry/skills/workflow-basic/execute \
    -H 'Content-Type: application/json' \
    -d '{"arguments": {"a": 5, "b": 3}}'
  ```
- **Expected output**: JSON response showing step execution and final result: "The sum is: 8"
- **Narration**: "Execute it with inputs. The workflow runs - step one adds 5 and 3, step two echoes the result. Deterministic. Repeatable. Same inputs, same output, every time."

---

### Phase 3: Parallel Execution

**Goal**: Show fan-out parallelism with a more complex workflow.

**[SCREEN]** Editor

**[DEMO]**
- **Action**: Show the parallel workflow SKILL.md
- **Expected output**:
  ```markdown
  ---
  name: workflow-parallel
  description: Fan-out computation - parallel operations merged into a summary
  tags:
    - workflow
    - parallel
  allowed-tools: local-tools__add, local-tools__echo, local-tools__get_time
  state: draft

  inputs:
    x:
      type: number
      description: Base number
      required: true
      default: 10

  workflow:
    - id: add-five
      tool: local-tools__add
      args:
        a: "{{ inputs.x }}"
        b: 5

    - id: add-ten
      tool: local-tools__add
      args:
        a: "{{ inputs.x }}"
        b: 10

    - id: timestamp
      tool: local-tools__get_time

    - id: summary
      tool: local-tools__echo
      args:
        message: "x+5={{ steps.add-five.result }}, x+10={{ steps.add-ten.result }} (at {{ steps.timestamp.result }})"
      depends_on: [add-five, add-ten, timestamp]

  output:
    format: last
  ---
  ```
- **Narration**: "This is where it gets interesting. Three steps with no dependencies on each other - add-five, add-ten, and timestamp. These run in parallel. Gridctl builds a DAG - a directed acyclic graph - and identifies which steps can execute concurrently. The summary step depends on all three, so it waits for them to finish before running."

**[CAMERA]**

Think about this in a real scenario. You need to gather data from three different APIs, then combine the results. Without parallel execution, you're waiting for each one sequentially. With the DAG execution, independent steps run at the same time. The depends_on array on the summary step is the fan-in point.

```
Level 0:  add-five  |  add-ten  |  timestamp   (concurrent)
Level 1:  summary                               (after all)
```

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Copy, activate, and execute the parallel workflow
- **Commands**:
  ```
  cp -r workflow-parallel ~/.gridctl/registry/skills/
  curl -X POST http://localhost:8180/api/registry/skills/workflow-parallel/activate
  curl -X POST http://localhost:8180/api/registry/skills/workflow-parallel/execute \
    -H 'Content-Type: application/json' \
    -d '{"arguments": {"x": 42}}'
  ```
- **Expected output**: Result showing x+5=47, x+10=52, with timestamp
- **Narration**: "Copy it in, activate, execute. You can see in the response that the three parallel steps completed and the summary merged their results. 42 plus 5, 42 plus 10, and the current timestamp. All composed through template expressions."

---

### Phase 4: Skills in the Web UI

**Goal**: Show the visual workflow designer.

**[SCREEN]** Browser at localhost:8180

**[DEMO]**
- **Action**: Open the web UI and navigate to the skills/registry section
- **Expected output**: Skills listed with their status (active/draft), workflow visualization
- **Narration**: "The web UI gives you a visual view of your skills registry. You can see which skills are active, their inputs, and - this is the part I like - a visual representation of the workflow DAG. The parallel steps show up side by side, dependencies show as connections."

**[DEMO]**
- **Action**: Show the workflow designer view for the parallel workflow
- **Expected output**: Visual DAG showing three parallel nodes flowing into one summary node
- **Narration**: "There's the parallel workflow. Three independent steps, one merge point. You can build and test workflows right in the UI if you prefer that over editing YAML."

---

### Phase 5: Skills as MCP Prompts

**Goal**: Show skills being used through Claude Desktop.

**[SCREEN]** Claude Desktop

**[DEMO]**
- **Action**: Show the active skill appearing as an MCP prompt in Claude Desktop
- **Expected output**: The workflow-basic and workflow-parallel skills visible as available prompts
- **Narration**: "Active skills are exposed through MCP as prompts. In Claude Desktop, you can see our skills in the prompt list. The agent can discover and invoke them just like any other MCP capability."

**[DEMO]**
- **Action**: Use a skill through Claude Desktop
- **Command**: Ask Claude to run the workflow with specific inputs
- **Expected output**: Claude invokes the skill, shows the execution steps and result
- **Narration**: "I'm asking Claude to run the basic workflow with inputs 10 and 20. The skill executes - add, then echo. Deterministic, controlled, and the agent didn't have to figure out the orchestration itself."

---

### Verification

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Verify the full registry state
- **Commands**:
  ```
  curl http://localhost:8180/api/registry/skills | python3 -m json.tool
  ```
- **Expected output**: JSON listing all skills with their states and metadata
- **Narration**: "Quick check on the registry. Both skills are active, metadata looks right. Everything is consistent."

---

### Wrap-Up

**[CAMERA]**

Skills take gridctl from tool access to tool orchestration. Instead of giving an agent loose tools and hoping it chains them correctly, you define the workflow once. Inputs, steps, dependencies, output. Sequential execution for ordered operations. Parallel execution for independent steps. Template expressions to pass data between steps.

And because they're SKILL.md files in a directory, they're portable. Version control them. Share them. Build a library of reusable workflows your team can invoke.

---

### Outro

**[CAMERA]**

That wraps up this series. We started with the problem - MCP sprawl and configuration drift. Then we worked through the solution layer by layer. Single stacks, multi-server aggregation, access control, code mode, hot-reload, OpenAPI integration, and now skills and workflows.

Gridctl is still early. It's alpha. Things will change, features will get added, rough edges will get polished. But the core idea is solid - bring infrastructure-as-code principles to AI agent tooling. Define it in YAML. Deploy with one command. One endpoint. Zero drift.

If you found this useful, the project is open source. All the stack files from this series are in the repo. Give it a try, open issues if you hit something, and if you build something interesting with it - I'd love to see it.

Play around with it. Break it. That's how you learn.
