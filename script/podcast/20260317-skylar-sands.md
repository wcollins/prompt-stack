# The Cloud Gambit - AI and the Automation Engineer: When Your Scripts Start Writing Themselves
## Guest: Skylar Sands | Senior Automation Engineer, World Wide Technology
## Recording: March 17, 2026

---

### Cold Open

Every automation engineer has that folder - the one full of Python scripts, Ansible playbooks, and bash one-liners they've been building for years. It's their toolkit, their competitive advantage, the thing that makes them fast. But what happens when AI can generate those scripts in seconds? Today we're talking to someone who's been writing automation since the days of SSHing into Cisco switches with pexpect, and now he's figuring out what it means when the tools start writing themselves.

---

### Guest Welcome

Skylar, welcome to The Cloud Gambit. You're a Senior Automation Engineer at World Wide Technology, you came up through the Army and worked your way through networking into automation, and you've been building in this space for a while now. I'm excited to dig into how AI is changing the day-to-day for someone who lives and breathes automation. Glad to have you on.

---

### Discussion Flow

#### Topic 1: From Army Cables to Automation Engineer
**Context:** Skylar served in the U.S. Army doing network/cable infrastructure work around 2009-2011. Earned Army Achievement Medal and Good Conduct Medal. Transitioned to tech through CompTIA certs, CCNA, and a WGU degree. Classic military-to-tech pipeline.
**Lead-in:** So Skylar, I always like to start with the path. You came out of the Army - network infrastructure, cable work - and now you're a Senior Automation Engineer at a $20 billion tech company. That's not a straight line.
**Questions:**
- Walk us through that journey. What was the moment you went from pulling cables to writing code?
- How does that military background - the operational discipline, the structure - show up in how you approach automation today?

#### Topic 2: What a Senior Automation Engineer Actually Does at WWT
**Context:** WWT is a $20B privately held tech services company with 10,000+ employees. They do IT engineering, cloud migration, networking, cybersecurity, and automation. Skylar's exact day-to-day isn't publicly documented.
**Lead-in:** So let's set the stage for folks who might not know WWT. It's a massive tech services company, and "automation engineer" can mean a hundred different things depending on where you sit.
**Questions:**
- What does your Monday morning actually look like? What kinds of problems land on your desk?
- When you say automation at WWT, are we talking network automation, cloud provisioning, workflow orchestration - where does the work live?

#### Topic 3: The Evolution from CLI Scripts to Orchestration
**Context:** Skylar's GitHub (sandss) shows the progression - 2017 repos were Python/pexpect modules for Cisco IOS and WLC automation ("niah"). 2020 was Cisco DevNet study. Feb 2026 he forked Kestra, an event-driven workflow orchestration platform with 26.5k GitHub stars.
**Lead-in:** I did something I probably shouldn't admit - I went through your GitHub. And there's this really interesting timeline there. Back in 2017 you're building Python modules to SSH into Cisco switches with pexpect. Fast forward to 2026 and you're looking at Kestra, which is a whole different world.
**Questions:**
- Take us through that evolution. How did you go from writing pexpect scripts to exploring workflow orchestration platforms?
- What made you fork Kestra recently? What caught your eye about event-driven orchestration?

#### Topic 4: Where AI Actually Helps in Automation Workflows
**Context:** This is the core episode angle. Skylar is an automation practitioner at a company investing heavily in AI. The user wants to explore practical, day-to-day AI usage - not theory.
**Lead-in:** Alright, let's get into the meat of it. You're someone who writes automation for a living. AI tools are everywhere now, promising to write your code for you.
**Questions:**
- Where does AI actually show up in your workflow today? Not the pitch deck version - what are you actually using it for?
- What's something AI is genuinely good at in automation work that surprised you? And what's something it's terrible at that the demos don't show?

#### Topic 5: WWT's 2026 Priority - AI Driving Actions, Not Just Informing Them
**Context:** WWT's published 2026 automation priorities state "AI is increasingly driving automated actions rather than simply informing them." This is the shift from AI-as-advisor to AI-as-actor. WWT also debuted agentic AI systems with NVIDIA in 2025.
**Lead-in:** WWT put out their 2026 automation priorities and there's this line that really stuck with me - "AI is increasingly driving automated actions rather than simply informing them." That's a big shift.
**Questions:**
- What does that shift look like from the engineer's seat? Can you give us a concrete example of AI driving an action versus just surfacing a recommendation?
- How do you think about the handoff between AI making a suggestion and AI actually executing? Where does that trust boundary sit for you?

#### Topic 6: The "Scriptomator" Identity in the Age of AI
**Context:** Skylar's Twitter handle is @scriptomator - a portmanteau of "script" and "automator." It reveals how he identifies professionally - automation as craft. Low public profile (23 followers) suggests he's a practitioner, not an influencer.
**Lead-in:** I found your Twitter handle - @scriptomator. Script plus automator. I love it because it tells you exactly how you think about what you do. But here's the thing - when AI can generate scripts, what happens to the scriptomator?
**Questions:**
- Has AI changed what it means to be an automation engineer? Are you writing fewer scripts now, or different kinds of scripts?
- If the script-writing part gets automated, what becomes the real value of someone in your role? What can't be automated away?

#### Topic 7: Workflow Orchestration and Event-Driven Automation
**Context:** Kestra fork (Feb 2026) signals interest in event-driven orchestration. Kestra supports YAML-defined workflows, Python/R/Java, 1200+ plugins, Terraform integration. Represents a shift from imperative scripting to declarative orchestration.
**Lead-in:** Let's talk about this shift from writing scripts to orchestrating workflows. That Kestra fork isn't an accident - there's a reason you're looking at event-driven platforms.
**Questions:**
- How does thinking in events and workflows change the way you design automation compared to traditional scripting?
- For the network engineer listening who's been writing Ansible playbooks and Python scripts for years, what should they know about workflow orchestration? Is this the next thing they should be learning?

#### Topic 8: Hyperautomation in Practice
**Context:** WWT case study shows combining RPA + LLMs to process military contracts (100+ per hour), 36K lines of accounting data in 2 days vs 3 weeks, 12+ finance processes automated. Used UiPath for RPA and LLMs for document understanding.
**Lead-in:** WWT has some pretty impressive automation case studies out there - combining RPA with LLMs to process military contracts at scale, cutting weeks of accounting work down to days. That's hyperautomation in practice.
**Questions:**
- How accessible is that kind of work - combining RPA with AI - to someone who came up through network automation? Is it a big leap or a natural extension?
- When you bolt an LLM onto an automation pipeline, what new failure modes do you have to think about that you didn't have before?

#### Topic 9: The Gap Between AI Demos and Production Automation
**Context:** No direct quotes from Skylar on this, but his practitioner background and WWT's enterprise context make this a natural topic. The gap between "it works in my notebook" and "it runs reliably at 2am" is real.
**Lead-in:** Here's the thing I keep seeing - someone demos an AI-powered automation that looks amazing, and then you try to put it into production and everything falls apart.
**Questions:**
- What breaks when you try to take AI-generated automation from a demo into a real production workflow? What are the gotchas?
- How do you test automation that has AI in the loop? Traditional testing assumes deterministic behavior, and AI is anything but.

#### Topic 10: Building Trust in AI-Driven Automation
**Context:** This connects the military background (operational trust, procedures) with the AI automation angle. In the Army, you follow procedures because lives depend on it. In automation, you need similar trust frameworks.
**Lead-in:** You come from a military background where procedures exist for a reason - because things go wrong when people freelance. That's an interesting lens to bring to AI-driven automation.
**Questions:**
- When do you let AI act autonomously in your automation workflows versus keeping a human in the loop? How do you decide where that line is?
- Has your military mindset - the emphasis on procedure and verification - helped you think about AI guardrails differently than someone without that background?

#### Topic 11: Where Automation Engineering Is Heading
**Context:** WWT's agentic AI push, the Kestra exploration, and the broader industry shift toward AI-augmented operations all point to a role that's evolving rapidly.
**Lead-in:** Let's zoom out for a second. You've watched this role evolve from CLI scripting to workflow orchestration to AI-augmented automation. Where does it go from here?
**Questions:**
- What does the automation engineer role look like in two or three years? Is it fundamentally different or is it the same job with better tools?
- What should a team lead be hiring for right now if they're building an automation practice?

#### Topic 12: Advice for Engineers Starting in Automation Today
**Context:** Closing practical advice topic. Skylar's path - military, certs, self-taught - is a model many aspiring engineers follow. His perspective on where to invest time is valuable.
**Lead-in:** Last one. There's someone listening right now who's maybe a year or two into their career, they're interested in automation, and they're staring at a wall of things to learn.
**Questions:**
- If you're starting in automation today, should you learn Python first or prompt engineering first? Where do you put your energy?
- Looking back at your own path - Army, CompTIA certs, CCNA, WGU, WWT - what advice would you give yourself if you were starting over today?

---

### Wrap-Up

Skylar, this has been great. I think what stands out is this idea that AI isn't replacing automation engineers - it's raising the bar on what they can build. The scripts might write themselves now, but someone still has to know what to build, why to build it, and what happens when it breaks at 2am. Folks can find Skylar on GitHub at sandss and connect with him on LinkedIn. Skylar, thanks for coming on The Cloud Gambit.

---

### Outro

That's a wrap on this episode. If you liked what you heard, subscribe wherever you get your podcasts, and drop us a note - we'd love to hear what landed for you. Until next time, keep building.
