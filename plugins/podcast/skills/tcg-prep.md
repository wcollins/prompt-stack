---
description: Intake and research a podcast guest  - pull Calendly data, create intake folder, deep research, generate theme and topics, fill planning template
argument-hint: "Guest Name"
---

# Guest Intake & Research

Prepare a new guest intake for The Cloud Gambit podcast: extract scheduling data, research the guest, and produce a complete planning document.

Guest name: $ARGUMENTS

## Instructions

Follow each step in order. Use TaskCreate to track progress.

---

## Part 1: Intake

### Step 1: Find Guest Event and Extract Data

Calendly writes all form response data into the Google Calendar event description. Use Google Calendar as the single source of truth.

Use `mcp__gridctl__zapier__google_calendar_find_events` to find the scheduled recording session:
- Search for the guest name in upcoming calendar events
- Use the `thecloudgambit@gmail.com` calendar

**Extract from the calendar event:**
- Guest full name (from event title)
- Guest email (from attendees list  - exclude thecloudgambit@ and co-host addresses)
- Recording date and time (from event start)
- Format date as `YYYYMMDD` for folder naming and `Month Day, Year` for the document

**Extract from the event description** (Calendly form responses):
- Bio text
- Photo URL
- Company
- Job title
- LinkedIn profile URL
- Other links (Twitter, blogs, etc.)
- Approval required (yes/no)

> If a field is missing from the form response, note it as "Not provided" and continue.

> **Note:** `calendly_find_user` searches Calendly account holders, not invitees  - do not use it for guest lookup.

### Step 2: Create Intake Folder

Create a new folder in Google Drive under `_intake` for this guest.

**Folder details:**
- Parent folder ID: `1O9kuIcZ8Ehk7pcPOgUXEM8xaXfn-SJ6c` (thecloudgambit/_intake)
- Folder name format: `<YYYYMMDD>-<firstname-lastname>` (all lowercase, hyphens)
- Example: `20260315-john-doe`
- Use the recording date from Step 1 for the date prefix

Use `mcp__gridctl__zapier__google_drive_create_folder` to create the folder.

### Step 3: Copy Planning Template

Copy the planning template to the new intake folder.

**Template details:**
- Template file ID: `1n4ywVndDZ-EWR_4dpFvrebo7gnD6FwsJ99egY7OO1z4` (Google Doc in _templates/)
- New file name: `<YYYYMMDD>-<firstname-lastname>-planning` (e.g., `20260315-john-doe-planning`)

Use `mcp__gridctl__zapier__google_drive_copy_file` with:
- `file`: the template file ID
- `folder`: the new intake folder ID from Step 2
- `new_name`: the formatted file name

### Step 4: Fill In Calendly Data

Replace placeholders in the copied Google Doc with data extracted in Step 1.

**Placeholder mapping (Calendly data only):**

| Placeholder | Replace with |
|---|---|
| `[[RecordingDate]]` | Recording date formatted as "Month Day, Year" |
| `[[EpisodeGuest]]` | Guest full name |
| `[[GuestEmail]]` | Guest email address |
| `[[PublicBio]]` | Bio URL or bio text from form response |
| `[[Company]]` | Company name |
| `[[JobTitle]]` | Job title |
| `[[LinkedInProfile]]` | LinkedIn URL |
| `[[OtherLinks]]` | Other social/web links from form response |
| `[[ApprovalRequired]]` | "Yes" or "No" from form response |

**Leave these untouched** (filled in Part 2 or manually):
- `[[PlanningCall]]`  - manual entry
- `[[EpisodeTheme]]`  - filled in Step 8
- `[[EpisodeTopics]]`  - filled in Step 8
- `[[EpisodeTitle]]`  - filled later
- `[[EpisodeDescription]]`  - filled later
- `[[EpisodeLinks]]`  - filled later

> Only replace placeholders where data was collected. Leave placeholders intact for fields marked "Not provided" so they're visually obvious during review.

**How to edit:**

Use `mcp__gridctl__zapier__google_drive_api_request_beta` to POST to the Google Docs batchUpdate API:
`https://docs.googleapis.com/v1/documents/<DOC_ID>:batchUpdate`

Use `replaceAllText` requests to swap each placeholder with its value. Batch all replacements into a single request.

Example batchUpdate body:
```json
{"requests":[{"replaceAllText":{"containsText":{"text":"[[RecordingDate]]","matchCase":true},"replaceText":"March 3, 2026"}}]}
```

### Step 5: Intake Report

Present a summary before moving to research:

```
Intake complete for <Guest Name>

  Calendly data:
    Name:     <name>
    Email:    <email>
    Company:  <company>
    Title:    <job title>
    LinkedIn: <url>
    Bio:      <url or text>
    Approval: <yes/no>

  Recording date: <Month Day, Year>

  Google Drive:
    Intake folder: <folder name>
    Planning doc:  <file name>
```

Flag any missing data.

---

## Part 2: Research

### Step 6: Ask for Direction

**Before doing any research**, present the guest's info and ask the user:

> I'm about to research **<Guest Name>** (<Job Title> at <Company>).
>
> Before I dive in  - do you have any direction for this episode? This could be:
> - A specific angle or topic you want to explore
> - LinkedIn posts, articles, or threads from the guest that caught your eye
> - A recent event, launch, or controversy you want to dig into
> - Anything you've discussed with the guest already
>
> Or say "go" and I'll research broadly based on their profile.

**Wait for the user's response before proceeding.** Incorporate their direction into every subsequent step.

### Step 7: Deep Research

Conduct thorough research on the guest using WebSearch and WebFetch. Treat this like preparing a senior journalist for an interview.

**Research sources (in priority order):**

1. **LinkedIn profile**  - Career arc, current role, recent posts/articles, endorsements, career transitions. Pay attention to what they post about vs. what their job title says  - the gap is often where the best conversation lives.

2. **Company website**  - What the company does, the guest's role in it, recent product launches or announcements. Understand the company but do NOT frame topics around selling it.

3. **Personal blog / writing**  - Technical depth, opinions, frameworks they've developed, recurring themes.

4. **GitHub**  - Open source projects, contributions, activity patterns. What they build in the open.

5. **Conference talks / presentations**  - Recent talks, keynotes, panels. What topics do they choose when given a stage?

6. **Previous podcast appearances**  - What have they already talked about elsewhere? Identify angles The Cloud Gambit can explore that others haven't.

7. **Twitter/X, Bluesky, Mastodon**  - Hot takes, industry commentary, debates they engage in.

8. **Publications**  - Articles, white papers, RFCs, case studies, books.

9. **Industry news**  - Recent mentions, awards, company funding rounds, acquisitions.

**Research goals  - build a complete picture:**

- **Career narrative**: Where did they start? What transitions defined their path? What's the throughline?
- **Technical domain**: What area of tech do they live in? (cloud, security, networking, infrastructure, DevOps, AI/ML, identity, observability, etc.)
- **Current focus**: What specific problems are they solving right now? What's their day-to-day?
- **Recent work**: Last 6-12 months  - launches, posts, talks, projects. What's freshest?
- **Point of view**: What opinions do they hold? Where do they disagree with conventional wisdom?
- **Industry context**: What trends or shifts make their work relevant right now?

**Validation:**
- Cross-reference claims across multiple sources
- Verify current role and company (people change jobs)
- Note anything that couldn't be verified
- Prioritize primary sources (their own writing/talks) over third-party summaries

### Step 8: Generate Episode Theme

Based on your research and any user direction from Step 6, craft an episode theme.

**The Cloud Gambit theme style:**
- 1-2 sentences maximum
- Captures the "why this matters now" angle
- Connects the guest's expertise to a broader industry trend or challenge
- Technically grounded but accessible
- Not a tagline or marketing copy  - more like a thesis statement

**Examples from real episodes:**
- "Agents and Identity – Navigating What We Can't Predict"
- "Progressive Delivery: Shipping Software is Just the Beginning"
- "How Infrastructure Teams Can Scale Reasoning Without Losing Control"
- "Governing AI Agents for Real-World Infrastructure"

**What makes a good theme:**
- Specific enough to set expectations, broad enough to allow conversation to breathe
- Hints at tension, a shift, or a non-obvious insight
- Avoids buzzword soup and corporate jargon
- Would make a technical listener curious enough to press play

### Step 9: Generate Discussion Topics

Create 10-15 substantive discussion topics organized with natural conversational flow.

**Structure:**

**Opening (2-3 topics):**
- Guest's path to their current role  - focus on the interesting turns, not the resume
- What they're working on right now and why it matters
- Bridge from their background into the episode's core theme

**Core Discussion (6-8 topics):**
- Deep dive into their area of expertise
- Specific technical challenges they've solved or are solving
- Their point of view on industry trends  - especially where they diverge from consensus
- Concrete examples, architectures, patterns, or approaches they advocate
- Lessons learned, failures, or things they'd do differently

**Closing (2-3 topics):**
- Where the industry is heading  - their honest prediction
- What they'd tell someone entering this space
- Where to find their work (open source, blog, talks)  - keep it brief and natural

**Topic guidelines:**

- **Stay technical**: Topics should be about the technology, the problems, the patterns  - not the company's sales pitch
- **Unsponsored rules**: The guest's company provides context for their expertise, but topics must not read as product marketing. "How <Company> approaches X" is fine. "Why teams should adopt <Product>" is not.
- **Be specific**: "The challenge of scaling Kubernetes across hybrid environments" is better than "Cloud challenges"
- **Include hooks**: Each topic should reference something concrete from your research  - a blog post, a talk, a project, a LinkedIn post. This gives the host material to reference during the conversation.
- **Mix depths**: Some topics should be tactical (how), some strategic (why), some reflective (what did you learn)
- **Account for user direction**: If the user provided specific angles in Step 6, make sure they're prominently reflected in the topics

### Step 10: Present Research for Review

Before writing anything to the planning doc, present your findings:

```
## Guest Profile: <Name>
<Job Title> at <Company>

### Tech Domain
<Primary area>  - <specific focus within that area>

### Career Arc
<2-3 sentence narrative of their career path>

### Current Focus
<What they're actively working on, last 6-12 months>

### Key Findings
- <Most interesting finding from research>
- <Second finding>
- <Third finding>
- ...

### Point of View
<Their notable opinions or positions>

---

### Proposed Episode Theme
"<Theme>"

### Proposed Discussion Topics
1. <Topic>  - <brief note on source/angle>
2. <Topic>  - <brief note>
...

---

Sources consulted: <list of URLs>
```

**Ask the user:**
> How does this look? I can adjust the theme, reorder topics, swap angles, or dig deeper on anything. Say "go" to write these to the planning doc.

**Wait for approval or revision before proceeding.**

### Step 11: Update Planning Document

Once approved, write the theme and topics to the planning doc using the Google Docs batchUpdate API.

Use `mcp__gridctl__zapier__google_drive_api_request_beta` to POST to:
`https://docs.googleapis.com/v1/documents/<DOC_ID>:batchUpdate`

**Replacements:**

| Placeholder | Value |
|---|---|
| `[[EpisodeTheme]]` | The approved episode theme |
| `[[EpisodeTopics]]` | The approved topics as a formatted list |

Format topics as a numbered list with line breaks between each topic. Include source links inline where relevant.

### Step 12: Research Report

```
Research complete for <Guest Name>

  Recording date: <Month Day, Year>
  Theme: "<Episode Theme>"
  Topics: <count> discussion topics

  Google Drive:
    Intake folder: <folder name> (<folder URL>)
    Planning doc:  <file name> (<file URL>)

  Placeholders filled: <count>
  Placeholders remaining: [[PlanningCall]], [[EpisodeTitle]], [[EpisodeDescription]], [[EpisodeLinks]]

  Sources consulted: <count>
  Research gaps: <any areas where info was thin>
```

---

## Part 3: Guest Email

### Step 13: Share Planning Document

Share the planning doc with the guest so they can comment.

Use `mcp__gridctl__zapier__google_drive_add_file_sharing_preference` to share:
- `file_id`: the copied planning doc ID from Step 3
- `permission`: commenter access for the guest's email address

Save the sharing URL returned - this is the `[[PlanningDoc]]` link.

### Step 14: Compose Email

Build the guest email from the email-template (ID: `1ChLS8AKddlZ3V_-NOM5cPebp4eH4cL7ZOlbIi2ovNPI`).

**Subject:**
```
The Cloud Gambit - Episode Prep | <Guest Full Name>
```

**Body placeholders:**

| Placeholder | Replace with |
|---|---|
| `[[EpisodeGuest]]` | Guest full name (used as salutation) |
| `[[PlanningDoc]]` | The text `this link` as a clickable hyperlink to the planning doc sharing URL |
| `[[RecordingDate]]` | Recording date formatted as "Month Day, Year" |

**Composed body** (after replacement):
```
<Guest Name>,

Thank you for agreeing to record an episode of The Cloud Gambit podcast! We have shared our planning guide with you which contains guidance, rules, and other important details to review prior to the recording. You should get a notice in your email and you can also click <this link> to access and review. We love for this process to be collaborative - if you see anything in the themes and topics section that you'd like to update, please do so. Also, if you have any additional ideas for topics that you think are worth discussing, feel free to add them. We look forward to our recording on <Recording Date>!

Regards,

William Collins
Founder, Co-Host
```

### Step 15: Prompt for Approval

**Do NOT send the email without explicit approval.**

Present the composed email to the user:

> **Ready to send guest email:**
>
> **To:** `<guest email>`
> **Subject:** The Cloud Gambit - Episode Prep | `<Guest Name>`
>
> ---
> <full composed email body>
> ---
>
> **Planning doc link:** `<sharing URL>`
>
> Send this email? (yes / edit / skip)

- If **yes**: proceed to Step 16
- If **edit**: apply the user's changes and re-present
- If **skip**: skip the email, note it in the final report

**Wait for the user's response before proceeding.**

### Step 16: Send Email

Use the Zapier Gmail MCP tool to send the email:
- **To**: guest email address from Step 1
- **Subject**: composed subject from Step 14
- **Body**: composed HTML body from Step 14 - use `<a href="<sharing URL>">this link</a>` for the `[[PlanningDoc]]` hyperlink
- **From**: thecloudgambit@gmail.com

> **Note:** The exact Zapier Gmail tool name may vary (e.g., `mcp__gridctl__zapier__gmail_send_email`). Use ToolSearch to find the available Gmail send action if the name doesn't match.

### Step 17: Final Report

```
Prep complete for <Guest Name>

  Recording date: <Month Day, Year>
  Theme: "<Episode Theme>"
  Topics: <count> discussion topics

  Google Drive:
    Intake folder: <folder name> (<folder URL>)
    Planning doc:  <file name> (<file URL>)
    Shared with:   <guest email> (commenter)

  Email:
    Sent to:  <guest email>
    Subject:  The Cloud Gambit - Episode Prep | <Guest Name>
    Status:   <sent / skipped>

  Placeholders remaining: [[PlanningCall]], [[EpisodeTitle]], [[EpisodeDescription]], [[EpisodeLinks]]
  Research gaps: <any areas where info was thin>
```

---

## Google Drive Reference

| Resource | ID |
|---|---|
| thecloudgambit root | `1_MG-vwV_DLh4Vc6hDeZekufkt4NZecEc` |
| _templates folder | `1ClW1-X2cUYDKSRT0TxYt9ZPCwPDVxdOV` |
| _intake folder | `1O9kuIcZ8Ehk7pcPOgUXEM8xaXfn-SJ6c` |
| planning-template | `1n4ywVndDZ-EWR_4dpFvrebo7gnD6FwsJ99egY7OO1z4` |
| email-template | `1ChLS8AKddlZ3V_-NOM5cPebp4eH4cL7ZOlbIi2ovNPI` |

## Calendly Reference

- Calendar URL: https://calendly.com/d/cw95-9y5-4dv/the-cloud-gambit
- Search by guest name, prefer most recent future event

## Podcast Context

**The Cloud Gambit** is a technical podcast on the Packet Pushers network covering cloud, infrastructure, DevOps, networking, security, AI/automation, and adjacent topics. Episodes are conversational  - one host, one guest, ~45 minutes.

**Tone**: Technically substantive but approachable. Not a product demo. The best episodes feel like overhearing two experts talk shop.

**Audience**: Infrastructure engineers, cloud architects, DevOps practitioners, technical leaders. They want depth, not marketing.

## Error Handling

- **Guest not found**: Try fuzzy matching, present options, ask user
- **No calendar event found**: Use today's date as fallback, flag for user
- **Missing form fields**: Continue with available data, note gaps in report
- **Google Drive errors**: Report the error and provide manual instructions
- **Thin research results**: Note gaps, suggest the user provide additional links or context
- **User wants revisions**: Iterate on theme/topics before writing to the doc  - never write without approval
- **Gmail tool not found**: Use ToolSearch to locate the Gmail send action. If unavailable, present the composed email for the user to send manually
- **Email send failure**: Report the error, provide the composed email for manual send

## Important

- **Always ask for direction before researching**  - the user may have context you can't find online
- **Always present findings before writing**  - never update the planning doc without explicit approval
- **Unsponsored episode rules**: Technology first. The guest's company is context, not the subject.
- Do NOT modify `[[PlanningCall]]`  - that is set manually
- All folder and file names should be lowercase with hyphens
- Use single dashes (-) in all generated content - never use em dashes or en dashes
