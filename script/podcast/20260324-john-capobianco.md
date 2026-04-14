# The Cloud Gambit - From Vibes to Governed: What Building a Real Network Agent Reveals About Spec-Driven Development
## Guest: John Capobianco | Head of AI and DevRel, Itential
## Recording: March 24, 2026

---

### Cold Open

There's a phrase floating around AI circles right now - "vibe coding." You describe what you want, the model writes the code, you ship it and hope for the best. It works great for side projects and demos. It falls apart the moment you point an AI agent at a production network. Today I'm talking to someone who's been building in that exact space - and what he's built has a lot to say about why specs matter, why governance isn't optional, and why the people most qualified to build these agents are the ones who've actually had to fix a BGP session at 2am. Let's dig in.

---

### Guest Welcome

John Capobianco, welcome to The Cloud Gambit. John is the Head of AI and DevRel at Itential, a Google Developer Expert, author of two books on network automation, and the person behind NetClaw - an open-source AI network engineering agent that's been turning heads in the community. Really glad to have you on.

---

### Discussion Flow

#### Topic 1: The Parliament of Canada to Open-Source AI Agent Builder
**Context:** John spent 25+ years as a network architect, including a long run as Senior Network Architect for the Parliament of Canada. He also taught at St. Lawrence College. The practitioner depth is the whole story - he's not a developer who learned networking, he's a network engineer who learned to build software.
**Lead-in:** Let's start with the career arc, because I think it matters for everything we're going to talk about today. You didn't come up through software engineering and pick up networking along the way - it was the other way around.
**Questions:**
- Walk us through it. 25 years as a network architect, the Parliament of Canada, teaching at St. Lawrence College - how did that path eventually lead to building an AI agent?
- When you look at the people building network automation tooling today, does it matter that they've actually run a production network? What do you get wrong if you haven't?

#### Topic 2: Writing "Automate Your Network" in 2019
**Context:** John self-published "Automate Your Network" in 2019 - well before AI in networking was a mainstream conversation. He also co-authored the Cisco Press pyATS book in 2024. The 2019 book is interesting because it shows he was thinking about this transition before the hype cycle.
**Lead-in:** In 2019, you self-published "Automate Your Network." That's before most people were having this conversation in any serious way. What did you see then?
**Questions:**
- What was the argument you were making in 2019? And looking back at it now, what held up and what do you wish you'd gotten wrong?
- You followed that up with the Cisco Press pyATS book in 2024. pyATS is fundamentally about structured, testable network state - does that discipline show up in how you think about AI agents today?

#### Topic 3: What OpenClaw Is and Why He Chose It
**Context:** OpenClaw is an open-source personal AI assistant framework - runs locally, communicates through Slack/chat interfaces, supports custom skills and MCP integrations. John chose it as the foundation for NetClaw rather than rolling his own. That's an architectural decision worth unpacking.
**Lead-in:** NetClaw is built on OpenClaw. For listeners who haven't come across it - OpenClaw is an open-source personal AI assistant that runs locally and communicates through your existing chat interfaces. John, tell us why you started there instead of building from scratch.
**Questions:**
- What does OpenClaw give you out of the box that made it the right foundation for a network agent?
- There's something interesting about choosing a framework that communicates through Slack and chat interfaces - not a CLI, not a web UI, not an API. Was that a deliberate choice about how network engineers actually work, or did it come from the framework?

#### Topic 4: Walking Through NetClaw's Architecture
**Context:** NetClaw has 92 skills, 43+ MCP integrations, six workspace definition files (SOUL.md, AGENTS.md, IDENTITY.md, USER.md, TOOLS.md, HEARTBEAT.md), and GAIT - a Git-based audit trail for every action. This is not a toy agent. The complexity of specifying behavior at this scale is worth discussing directly.
**Lead-in:** Let's get into the architecture. NetClaw is not a simple agent - 92 skills, 43 MCP integrations, workspace definition files, a Git-based audit trail for every action. Walk us through how it's put together.
**Questions:**
- Start with the workspace definition files - SOUL.md, AGENTS.md, IDENTITY.md. What are those, and why does an AI agent need a soul?
- GAIT - Git-based AI Tracking - every action generates an immutable audit record. Why was that non-negotiable for you?

#### Topic 5: The Workspace Definition Files as Spec Artifacts
**Context:** SOUL.md defines expertise and personality. AGENTS.md is operating procedure. IDENTITY.md is agent identity. These are injected into the system prompt and govern behavior across all sessions - they're not prompts in the loose sense, they're structured behavioral specifications. This connects directly to the SDD angle.
**Lead-in:** Here's the thing that struck me when I dug into NetClaw. Those workspace definition files - SOUL.md, AGENTS.md - they're not really prompts in the way most people use that word. They're behavioral specifications. They define what the agent is allowed to do, how it should reason, what it should refuse.
**Questions:**
- Did you set out to build spec artifacts, or did that pattern emerge from necessity? At what point did you realize you were doing something more structured than prompt engineering?
- How do you version and evolve them? If you change SOUL.md, how do you think about what that does to the agent's behavior?

#### Topic 6: SDD's Connection to TDD - The pyATS Thread
**Context:** John has explicitly connected SDD to TDD in public writing. For someone who spent years writing pyATS test suites - structured, behavior-oriented tests that verify network state - the SDD parallel is direct. A spec for an AI agent and a test suite for a network function are doing similar work: defining expected behavior before implementation.
**Lead-in:** You've connected spec-driven development to TDD in your writing - and to me, that's the most interesting framing in this whole conversation. Someone who wrote pyATS test suites for years has already been doing a version of this.
**Questions:**
- Unpack that parallel for us. What does a pyATS test have in common with a behavioral spec for an AI agent?
- Is writing a spec for an agent meaningfully different from writing a test for a network function - or is it the same discipline applied to a different surface?

#### Topic 7: AI is Probabilistic. Production is Deterministic.
**Context:** John's core thesis: the fundamental mismatch between LLM behavior (non-deterministic, probabilistic) and what production infrastructure requires (predictable, reproducible, auditable). His answer is layering deterministic workflow logic under the LLM reasoning.
**Lead-in:** You've said something that I think is the clearest way to frame this problem: "AI is probabilistic. Production is deterministic." That tension is real, and most people building in this space are either ignoring it or hoping it goes away.
**Questions:**
- How do you actually resolve that in practice? What does the deterministic layer look like, and where does the LLM's probabilistic reasoning live?
- What happens when an agent hits the edge of its guardrails on a live network? What does that failure mode look like, and how does NetClaw handle it?

#### Topic 8: The March 2026 Multi-Agent BGP Mesh
**Context:** On March 1, 2026, John and Sean Mahoney connected two NetClaw instances to each other over BGP, tunneled through ngrok. The agents formed a routing mesh - sharing routing tables, peering directly. First known multi-human, multi-agent routing fabric.
**Lead-in:** Let's talk about what happened in March. You and Sean Mahoney connected two NetClaw instances to each other over BGP. That's not two agents chatting - that's two AI agents participating in a routing protocol with each other.
**Questions:**
- Walk us through what actually happened. What did you set up, what did you expect, and what surprised you?
- When you saw it working - two agents peering, sharing routing tables - what did that tell you about where this is going? Not the hype version, the honest version.

#### Topic 9: MCP Servers as Specification Interfaces
**Context:** NetClaw has 43 MCP integrations covering device automation, infrastructure platforms, security tools, cloud providers, observability, and orchestration. Each MCP server defines what the agent can perceive and act on. This is a natural specification layer - it constrains the agent's surface area and forces explicit definition of capabilities.
**Lead-in:** The 43 MCP integrations in NetClaw aren't just API wrappers. Each one defines what the agent can see and what it can do - it's a bounded surface. To me that's a form of specification.
**Questions:**
- Does MCP naturally push you toward a spec-first discipline, or can you still vibe your way through building MCP integrations?
- What I find interesting is the difference between an MCP server that's just a thin wrapper over an API and one that's thoughtfully scoped. How do you think about that distinction when you're building for a network agent?

#### Topic 10: ServiceNow Change Gating
**Context:** NetClaw requires ITSM approval through ServiceNow before executing configuration changes. This is human oversight built into the agent architecture - not bolted on after the fact.
**Lead-in:** NetClaw doesn't just execute configuration changes on its own - it goes through ServiceNow for approval first. That's a meaningful design choice when you're building an agent that can move at machine speed.
**Questions:**
- Why is that gating important, and how does it actually work in practice? Is it every change, or is there a classification system?
- There's a philosophical question underneath this - how much autonomy do you actually want a network agent to have? Where's the right line?

#### Topic 11: What the Career Evolution Actually Looks Like
**Context:** John's thesis is that network engineers need to evolve from equipment operators to AI orchestrators. He's lived that transition himself. This is the practical, honest version of that advice - not the marketing version.
**Lead-in:** Let's close on the career evolution question, because I know a lot of our listeners are sitting with it. The framing I keep hearing is "network engineer to AI orchestrator" - what does that actually mean for someone in the trenches right now?
**Questions:**
- What's the first concrete thing someone should build if they want to get into this space? Not a course, not a certification - something they can actually make.
- What skills from traditional network engineering translate directly into building agents? And what do you have to unlearn?

#### Topic 12: Where to Find NetClaw and the Community
**Context:** NetClaw is open source on GitHub. Automate Your Network community at automateyournetwork.ca, X at @John_Capobianco, YouTube channel. Simple close.
**Lead-in:** For people who want to dig into NetClaw or follow your work - where do they go?
**Questions:**
- GitHub link, community, where to follow you - give us the quick hit.

---

### Wrap-Up

John, this has been a great conversation. What I'm taking away is that the people who are going to build AI agents that actually survive production aren't the ones who read the most blog posts about SDD - they're the ones who've been doing the discipline for years under a different name. Test suites, change gating, audit trails - that's not new. What's new is the surface you're applying it to. Thanks for coming on The Cloud Gambit and for sharing what you've built with the community.

---

### Outro

That's a wrap on this one. Links to NetClaw, OpenClaw, and John's work are in the show notes. If this episode got you thinking, share it with someone who's still on the fence about where AI fits in network operations. Subscribe wherever you get your podcasts, and we'll see you next time.
