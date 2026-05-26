# The Cloud Gambit - Say the Thing: How the Network Automation Conference Circuit Shaped One SP Operator's Voice
## Guest: Joseph Nicholson | Network Operations Engineer, NTT DATA
## Recording: April 17, 2026

---

### Cold Open

There's a version of every major network automation conference where every speaker is a vendor, a consultant, or a platform company. And then there's the talk that makes the room lean forward - the one from the engineer who actually runs the network, who built the thing with their own hands, and who got on stage because nobody else was saying what needed to be said. That's Joseph Nicholson. He started at AutoCon 2 with a 10-minute lightning talk. He's been hard to stop since.

---

### Guest Welcome

Joseph Nicholson, welcome back to the Packet Pushers network - this time on The Cloud Gambit. Joseph is a Network Operations Engineer at NTT DATA's Global IP Network division, where he's been automating things that weren't supposed to be automated for years. He's a regular at NANOG and AutoCon, and his AutoCon 4 talk on modular Ansible across a multi-vendor global SP environment is exactly the kind of content this show exists for. Really glad to have you here.

---

### Discussion Flow

#### Topic 1: AutoCon as a Turning Point
**Context:** Joseph mentioned in a previous Packet Pushers episode that a contact at Nokia suggested he try AutoCon before it even launched. He went to AutoCon 0 and said he "found my people." He's been to every one since - 0 through 4 - and describes it as the one conference he can't miss. For someone who works in a role where his immediate team is small and his work can feel isolated, this community clearly matters in ways that go beyond professional development.
**Lead-in:** I want to start before the talks and before the technical content - I want to start with how you ended up in this community in the first place.
**Questions:**
- A Nokia contact pushed you toward AutoCon before it even had a track record. You went to AutoCon 0 and said you found your people. What did that actually mean? What was in that room that you weren't getting elsewhere?
- You've been to every single AutoCon - 0 through 4. That's a commitment. What does it give you that keeps pulling you back?

#### Topic 2: From Attendee to Speaker - The First Talk
**Context:** On a prior Packet Pushers episode recorded at NANOG 92, Joseph announced at the very end - nervously - that AutoCon 2 would be his very first presentation ever: a 10-minute lightning talk called "Network Automation in Baby Steps." He'd been attending conferences, absorbing talks, noticing that everyone kept saying "iterate" without actually stopping to make that the point. He decided somebody needed to say the thing out loud. That talk eventually became a NANOG 93 session too.
**Lead-in:** I actually have context here - I listened to an episode where you announced AutoCon 2 was going to be your first-ever talk. You were nervous about it. So let's go there.
**Questions:**
- What actually made you submit? You'd been in this community, you'd been watching talks - what was the moment where you thought, I should be up there?
- Walk me through standing up in front of that room at AutoCon 2 for the first time. What was that experience like?
- Your motivation was that everybody kept saying "iterate" but nobody was stopping and making that the actual point - somebody needed to say the thing out loud. Did the room receive it that way?

#### Topic 3: The Arc - From 10 Minutes to 45 Minutes
**Context:** AutoCon 2 was a 10-minute lightning talk. By AutoCon 4, Joseph was delivering a full 45-minute session titled "Scaling Network Operations with Modular Ansible: A Multi-Environment Automation Framework." He also presented at NANOG 93, NANOG 96, and Nokia SReXperts Americas. That's a significant progression from someone who had never given a talk before AutoCon 2. At AutoCon 3 he wasn't on the speaker list at all - and then by AutoCon 4 he's doing a full session.
**Lead-in:** Let's trace the arc, because it's a pretty dramatic one. AutoCon 2: 10 minutes. Then NANOG 93, AutoCon 4, NANOG 96, SReXperts. That's a real speaker career developing. What changed?
**Questions:**
- What did you learn about talking to an audience that you couldn't have known going in? What's harder than you expected, and what got easier?
- How do you go from a 10-minute lightning talk to a 45-minute technical session? Is it more content, more confidence, or something else?
- You skipped speaking at AutoCon 3 after AutoCon 2. Was that intentional, or just how it worked out?

#### Topic 4: What the Community Gave Him That the Job Couldn't
**Context:** In prior episodes, Joseph mentioned that his boss pushed Ansible, a VP at a NANOG dinner pushed him to revisit GitHub Copilot, and conference talks from AutoCon peers directly inspired his own baby steps talk. His technical direction has been shaped significantly by hallway conversations and shared sessions with people outside his organization. For someone working in a focused operational role, the conference circuit has functionally served as a peer network and ongoing technical education.
**Lead-in:** I want to ask about something that I don't think gets talked about enough - what you actually get from these communities that you can't get from inside your own org.
**Questions:**
- How much of your technical direction over the last few years has come from conversations at conferences rather than from your day job? Can you trace specific decisions back to specific conversations?
- You work in a fairly specialized role inside a large organization. Where does the community fill gaps that your immediate environment can't?

#### Topic 5: Why Operators Need to Be on Stage
**Context:** Joseph's motivation for his first talk was explicit - practitioners at conferences kept alluding to iterative improvement without ever stopping to make it the point. He felt the need to say it directly. This is a broader issue in the conference circuit: the practitioner voice is often outnumbered by vendors, consultants, and platform companies who have both the budget and the incentive to be in the room. Joseph has now given enough talks to have a view on this from the inside.
**Lead-in:** Your whole reason for getting on stage at AutoCon 2 was that somebody needed to say the thing out loud - and you decided it was going to be you. That's worth sitting with.
**Questions:**
- When you look at the speaker lineup at these conferences, how balanced is it between operators and vendors? And does it matter?
- What does the audience lose when there aren't enough practitioners on stage? What's the specific thing that vendors and consultants can't give them?
- What would you say to the engineer who has something worth sharing but hasn't submitted a talk?

#### Topic 6: How He Prepares a Talk
**Context:** Joseph has now delivered multiple conference talks across NANOG, AutoCon, and Nokia SReXperts. His talks are grounded in his actual production work - the baby steps talk used his own real projects as examples, iterating through versions to illustrate the principle. His AutoCon 4 talk was built from what he's actually deployed. Understanding how he goes from "I'm working on something interesting" to "I have a talk" is practical for others in the community considering the same path.
**Lead-in:** Let's talk about the actual craft of preparing a talk - because I think a lot of engineers assume it's just making slides about what they're working on, and it's clearly not.
**Questions:**
- How do you know when you have something worth presenting? What's the bar?
- Walk me through how you built the AutoCon 4 talk. Where did it start, and how did you figure out what the actual point was?

#### Topic 7: Modular Ansible - What It Actually Means
**Context:** Joseph's AutoCon 4 session was titled "Scaling Network Operations with Modular Ansible: A Multi-Environment Automation Framework." In prior episodes he described one Ansible repo with six playbooks and shared task files that get reused across projects - change one file and multiple playbooks update. The "modular" framing is a deliberate architectural choice. Baby steps was the starting philosophy; this is what that philosophy looks like after years of iteration at production scale in a global SP environment.
**Lead-in:** Let's get into the content of the AutoCon 4 talk, because this is new territory for me - I haven't heard you break this one down before.
**Questions:**
- "Modular Ansible" - what does that actually mean in your environment? Walk me through the architecture.
- How does modularity change the way you add new playbooks or new use cases? What does it let you do that a more monolithic structure doesn't?
- Baby steps was the philosophy. Is this the destination, or is it just the current iteration?

#### Topic 8: The Multi-Environment Problem in a Global SP
**Context:** NTT DATA's Global IP Network runs Cisco, Juniper, and Nokia across 240-260 routers in PoPs across North America, Australia, Asia, South America, and Europe. Multi-vendor support in Ansible is genuinely hard - Cisco's Ansible module has been effectively abandoned, Nokia works well with community modules, Juniper has solid support. Getting one automation framework to handle all of that consistently, across different platform generations and different operational contexts, is a real engineering problem.
**Lead-in:** The "multi-environment" piece of your AutoCon 4 talk title is doing some real work. Your network is Cisco, Juniper, Nokia, multiple platform generations, PoPs across four continents. That's not a lab setup.
**Questions:**
- What does "multi-environment" mean in your context specifically? Is it primarily the vendor differences, or is there more to it?
- Cisco's Ansible module situation is not great. How do you handle the platforms where the tooling doesn't cooperate?
- Where does the multi-vendor complexity actually bite you hardest in the automation layer?

#### Topic 9: AI in 2026 - What's Changed Since Thanksgiving Weekend
**Context:** In a prior Packet Pushers episode, Joseph described spending Thanksgiving weekend 2023 or 2024 using GitHub Copilot to build a DWDM shelf turn-up script - his "this has changed" moment with AI copilots. He was clear-eyed about the limitations: Copilot gets in loops, hallucinates, and you have to understand the code to catch when it goes wrong. Since then, AI has advanced dramatically. The question is what that looks like from his vantage point in 2026 - in a real SP environment with real operational risk.
**Lead-in:** We've talked about your early GitHub Copilot experiments on a prior episode - the Thanksgiving weekend DWDM script, learning to read what it gives you. That was a different moment in AI than we're in now. A lot has changed.
**Questions:**
- How has your use of AI tooling evolved since those early Copilot experiments? What's different about how you use it today?
- Are you seeing AI used for actual network automation at the SP level yet - not just code generation, but agents that interact with network infrastructure? What does that look like?
- Your instinct has always been "you have to understand what it's giving you." Does that still hold as the tools get more capable, or does the calculus start to shift?

#### Topic 10: What Happens to Ansible When AI Can Write Playbooks
**Context:** If an AI can generate a functional Ansible playbook for a given task in 30 seconds, it changes the value of writing playbooks by hand. Joseph's "baby steps" philosophy was grounded in learning by doing - you understand the automation because you built it yourself, iterating slowly. That learning philosophy is in some tension with AI-generated automation, which can produce working code without the engineer understanding how it works. The Pydantic example from his prior episode - where Copilot generated code he couldn't follow and he had to strip it out - illustrates the failure mode.
**Lead-in:** Here's a question that I think is genuinely open right now. If AI can write an Ansible playbook on demand in 30 seconds, what changes about what a network automation engineer actually needs to know?
**Questions:**
- Does "write it yourself and understand it" still hold when AI can write it faster and often better than you can?
- What's the failure mode when engineers start deploying AI-generated automation they can't fully read? Are you seeing that happen?
- What skills become more important, not less, as AI takes over more of the code generation?

#### Topic 11: The Next Talk
**Context:** Joseph has gone from first-time speaker at AutoCon 2 to a regular presence at NANOG and AutoCon. Each talk has been grounded in his current work - baby steps was the philosophy, modular Ansible was the architecture. The progression suggests he talks about what he's actively figuring out, not what he's already mastered. What's he working on now that might become the next talk?
**Lead-in:** You've had a talk arc that's tracked your actual work - what you're figuring out, what you needed to say. So I want to ask: what's next?
**Questions:**
- Is there a talk you want to give that you haven't given yet? What's the idea that's been sitting in the back of your head?
- What are you working on right now that you think might be worth eventually getting on a stage?

#### Topic 12: Advice for the Engineer Who Wants to Start Presenting
**Context:** Joseph went from never having presented to being a regular conference speaker across multiple major industry events. His path was: attend conferences, find the community, notice what needed to be said, submit a lightning talk, iterate. That's replicable. The barrier to entry for conference talks - particularly at AutoCon, which he's described as having a rigorous but fair submission process - is lower than most engineers assume.
**Lead-in:** Last question, and I want to make it practical. You went from never having given a talk to being a regular on the conference circuit. What would you tell the engineer who's sitting in the audience right now thinking they might have something to say?
**Questions:**
- What's the actual first step? Not the inspirational version - the practical one.
- What do you wish someone had told you before you walked onto that stage at AutoCon 2?

---

### Wrap-Up

Joseph, this has been a great conversation. What I'm taking away is that the community piece isn't separate from the technical work - it's what accelerates it. You found your people at AutoCon, they pushed your thinking, you decided to push back by getting on stage yourself, and what you built between talks kept getting better because of those conversations. That's a model worth paying attention to. Thanks for being on The Cloud Gambit.

---

### Outro

That's a wrap on this one. Joseph Nicholson is on LinkedIn - link in the show notes. If you're not already plugged into the AutoCon and NANOG communities, this is your nudge to go look at what they're building. Subscribe wherever you get your podcasts, and we'll see you next time on The Cloud Gambit.
