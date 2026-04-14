# The Cloud Gambit - Cloud Cloning and the Portability Problem
## Guests: Sharad Kumar (Co-Founder & CEO) & Harshit Omar (Co-Founder & CTO), FluidCloud
## Recording: March 5, 2026
## Episode Type: Sponsored

---

### Cold Open

If you've ever tried to move a workload from one cloud to another, you know the dirty secret - the VM is the easy part. It's everything around it that kills you. The VPCs, the IAM policies, the firewall rules, the security groups that don't translate because every cloud decided to implement the same concepts in completely different ways. Today we're talking to two founders who looked at that problem and said, "What if we could just clone the whole thing?"

---

### Sponsor Disclosure

Before we get into it - this episode is brought to you by FluidCloud. Sharad and Harshit are here as our guests today, and they're also the founders of the product we're going to dig into. Full transparency with you all - but I'll tell you this: I wouldn't have them on if the technology wasn't interesting. And it is. Let's dig in.

---

### Guest Welcome

Sharad, Harshit - welcome to The Cloud Gambit. You two are building something that attacks a problem I think a lot of our listeners have felt but maybe haven't had a clean solution for - true multi-cloud portability, not just at the VM layer, but the whole stack. Really glad to have you both on.

---

### Discussion Flow

#### Topic 1: The Founding Story
**Context:** Both founders have backgrounds in infrastructure-as-code and security (Accurics connection). Understanding why they started FluidCloud reveals the problem space.
**Lead-in:** So let's start at the beginning. What was the moment where you two looked at each other and said, "This problem is big enough to build a company around?"
**Questions:**
- Walk us through the founding story. What were you seeing in the market that told you multi-cloud portability was broken?
- You both come from the infrastructure-as-code and security world. How did that background shape what FluidCloud became?

#### Topic 2: Multi-Cloud in 2026 - Hotel vs. Second Residence
**Context:** Gartner predicts 50%+ of multi-cloud efforts won't deliver expected benefits by 2029. Multi-cloud sprawl happened instead of multi-cloud strategy. Source: InfoWorld.
**Lead-in:** Here's a stat that should make people uncomfortable - Gartner says more than half of multi-cloud efforts won't deliver expected benefits by 2029. And I think most of our listeners have lived that. You end up multi-cloud by accident, not by design.
**Questions:**
- Sharad, you've used this analogy of hotel vs. second residence when it comes to cloud. Unpack that for us - what does it mean to actually live in multiple clouds versus just visiting?
- Why did multi-cloud sprawl happen instead of multi-cloud strategy? What went wrong?

#### Topic 3: The Terraform Paradox
**Context:** Terraform unified the language but not the architecture. Same resource type - load balancer, firewall rule - requires completely different config per provider. AWS security groups vs. Azure priority-based rules vs. GCP separate ingress/egress. This is the gap FluidCloud fills.
**Lead-in:** This is something I think a lot of infrastructure engineers feel but haven't articulated well. Terraform promised us a unified language for infrastructure. And it delivered on that. But here's the thing - writing HCL for an AWS security group and writing HCL for an Azure network security rule are two completely different exercises.
**Questions:**
- Harshit, as the CTO - talk to us about this gap. The language is unified, but the architecture underneath is not. What does that actually mean for teams trying to be portable?
- How much of the complexity is in the resource translation versus the dependency mapping? Like, knowing that this security group is attached to this load balancer which feeds this subnet - that graph is different per cloud, right?

#### Topic 4: What Cloud Cloning Actually Does
**Context:** Snapshot via cloud APIs, universal intermediate representation, translation to target provider's Terraform. Patented algorithm turns factorial complexity into linear. Source: InfoWorld, NetworkWorld.
**Lead-in:** Alright, let's get into the mechanics. I want our listeners to understand what's actually happening under the hood when you "clone" a cloud environment.
**Questions:**
- Walk us through the flow. You point FluidCloud at an environment - what happens next? What are you capturing, and how does the intermediate representation work?
- You've patented the algorithm that turns what should be factorial complexity into linear. Without giving away the secret sauce, help us understand why that matters. Why is naive cloud translation a combinatorial explosion?

#### Topic 5: The 10-30% Problem
**Context:** AWS Migration Services, Azure Migrate, Google Cloud Migrate only capture VMs and storage - miss VPCs, IAM, firewall rules, K8s clusters, security configs. Source: InfoWorld.
**Lead-in:** The cloud providers all have their own migration tools - AWS has theirs, Azure has theirs, Google has theirs. And they work. For about 10 to 30 percent of the problem.
**Questions:**
- What's in that other 70%? What are the migration tools from the hyperscalers actually missing?
- Harshit, when a team discovers mid-migration that their IAM policies didn't come over, or their firewall rules got flattened - what does that look like? What's the blast radius of a partial migration?

#### Topic 6: Live Demo - Cloud Cloning in Action
**Context:** This is the key sponsored segment. Natural transition to showing the product. Let the technology speak for itself - show the scan, the intermediate representation, and the Terraform output.
**Lead-in:** Alright, we've been talking about this long enough. Let's actually see it. Sharad, Harshit - can you walk us through a live clone? I want to see what this looks like from scan to Terraform output.

**Demo Notes for Host:**
- Let the founders drive the screen share
- Ask clarifying questions as they go - "What are we looking at here?" "How long did that take?"
- Point out things that would resonate with the audience - IAM translation, security group mapping
- After the demo, react naturally - what surprised you, what would your audience care about most

**Questions:**
- [During demo] So we're looking at the intermediate representation now - this is cloud-agnostic? This is what everything gets normalized to before it gets translated?
- [After demo] For someone watching this - what's the typical time from scan to deployable Terraform? And how much of that output do teams usually need to hand-edit?

#### Topic 7: VMware Migration and the Broadcom Effect
**Context:** Broadcom acquisition created "desperate buyers." FluidCloud and Vultr partnership addresses this with instant migration. Source: Vultr partnership, Packet Pushers Startup Radar.
**Lead-in:** I'd be remiss not to bring up the elephant in the room. The Broadcom-VMware situation has created a wave of organizations that need to move, and they need to move now. You've partnered with Vultr on this.
**Questions:**
- What does a VMware exit actually look like when an enterprise decides to leave? What's the first conversation like?
- The Vultr partnership is interesting - why Vultr specifically? What does that combination unlock for teams trying to get off VMware?

#### Topic 8: Security and IAM Translation
**Context:** Each cloud has fundamentally different identity and security models. AWS policy-driven, Azure subscription-based, GCP hierarchical. Source: InfoWorld.
**Lead-in:** To me, this is the hardest part of the whole problem - and I want to spend some time here. Every cloud has a fundamentally different security and identity model.
**Questions:**
- Harshit, how do you translate security posture without introducing gaps? AWS policies don't map one-to-one to Azure RBAC, which doesn't map to GCP's hierarchy. Where do you have to make judgment calls?
- When the translation introduces a security difference - maybe something that's one rule in AWS becomes three rules in Azure - how do you surface that to the team so they can verify it?

#### Topic 9: FinOps and Cost Visibility
**Context:** FluidCloud provides cost comparisons across clouds for equivalent configurations. Claims up to 50% savings through strategic cloud selection. Source: InfoWorld.
**Lead-in:** There's a FinOps angle here that I think is underappreciated. If you can represent the same infrastructure in multiple clouds, you can actually compare apples to apples on cost.
**Questions:**
- How does cost comparison work when the configurations aren't identical across clouds? An m5.xlarge isn't exactly the same as a Standard_D4s_v3.
- The claim is up to 50% savings through strategic cloud selection. Where do those savings actually come from? Is it compute pricing, egress, licensing, all of the above?

#### Topic 10: Drift Detection and Governance
**Context:** Automated snapshots detecting configuration changes against baselines. Source: InfoWorld.
**Lead-in:** Portability is one thing, but maintaining posture after you've moved - that's a whole other challenge.
**Questions:**
- Talk to us about drift detection. Once you've cloned and deployed, how do you know your target environment hasn't drifted from what was intended?
- For compliance teams - how does this fit into a governance workflow? Can you baseline an environment and alert when something changes?

#### Topic 11: AI Agents and Infrastructure Automation
**Context:** FluidCloud building AI-powered automation for failover and a multi-cloud MCP server for natural language infra management. Source: NetworkWorld, TechIntelPro.
**Lead-in:** You're building toward something bigger here. I've seen references to AI-powered failover automation and a multi-cloud MCP server. That's ambitious.
**Questions:**
- What does "sentient infrastructure" actually mean in practice? When you say AI-powered failover, what decisions is the AI making?
- A multi-cloud MCP server for natural language infrastructure management - give us the vision. What does that interaction look like for an engineer?

#### Topic 12: The Accurics-to-FluidCloud Thread
**Context:** Both companies deal with IaC from different angles. Accurics secured it, FluidCloud makes it portable. Security mindset informs portability product. Source: founder backgrounds.
**Lead-in:** I want to pull on this thread for a second. Your backgrounds touch the Accurics world - infrastructure-as-code security. Now you're doing infrastructure-as-code portability. Those aren't as far apart as they sound.
**Questions:**
- How does a security-first mindset change the way you approach portability? Are there design decisions in FluidCloud that only exist because you thought about it through a security lens?

#### Topic 13: What CIOs Get Wrong About Multi-Cloud
**Context:** Cloud freedom as a KPI. Difference between multi-cloud by accident and multi-cloud by design. Source: TechIntelPro interview with Harshit.
**Lead-in:** Let's zoom out to the strategic level. If there's a CIO or VP of Infrastructure listening - what are they getting wrong about multi-cloud strategy?
**Questions:**
- Sharad, you've talked about cloud freedom as a KPI. What does that actually mean, and why aren't more organizations measuring it?
- What's the difference between a team that's multi-cloud by accident and one that's multi-cloud by design? What does the designed version look like?

#### Topic 14: Getting Started with FluidCloud
**Context:** Where to find the product, what workloads are a good fit. Natural sponsored close.
**Lead-in:** For folks listening who are dealing with exactly these problems - maybe they're staring down a VMware migration, or they've got workloads in AWS that they need to get to Azure for a compliance reason - where do they start?
**Questions:**
- What workloads are the best fit for trying FluidCloud? Where do you see the fastest time to value?
- Where can people find you? Website, getting started, community - give us the links.

---

### Wrap-Up

Sharad, Harshit - this has been a great conversation. I think the thing that's going to stick with our listeners is this idea that multi-cloud portability isn't just about moving VMs - it's about translating the entire architecture, security posture and all, in a way that's actually trustworthy. The Terraform paradox is real, and it's good to see someone attacking it head-on. Thanks for coming on The Cloud Gambit.

---

### Outro

That's a wrap on this episode. Quick reminder - this one was brought to you by FluidCloud. Links to everything we discussed are in the show notes. If you liked what you heard, subscribe wherever you get your podcasts, and let us know what you think. Until next time, keep building.
