---
description: Intake and research a podcast guest  - pull Calendly data, create intake folder, deep research, generate theme and topics, fill planning template, generate host script
argument-hint: "Guest Name"
---

# Guest Intake & Research

Prepare a new guest intake for The Cloud Gambit podcast: extract scheduling data, research the guest, and produce a complete planning document.

Guest name: $ARGUMENTS

## Instructions

Follow each step in order.

---

## Gridctl Tool Execution

All Zapier tools are called via `mcp__gridctl__execute` using this async IIFE pattern:

```javascript
(async () => {
  const result = await mcp.callTool("zapier", "tool_name_without_prefix", {
    instructions: "natural language description of what to do",
    output_hint: "what data you want back",
    // ...other params
  });
  return result;
})()
```

**Important:**
- Tool name in `mcp.callTool` omits the `zapier__` prefix (e.g. `google_calendar_find_events` not `zapier__google_calendar_find_events`)
- `instructions` is required for every Zapier tool call
- To discover tools, use `mcp__gridctl__search` with exact partial names (e.g. `google_calendar_find_events`). Natural language searches return 0 results.
- `gmail_send_email` requires `to` as an array: `["email@example.com"]`
- `google_drive_add_file_sharing_preference` has no email parameter - include the email address in the `instructions` string

---

## Part 1: Intake

### Step 1: Find Guest Event and Extract Data

Calendly writes all form response data into the Google Calendar event description. Use Google Calendar as the single source of truth.

Call `google_calendar_find_events` via `mcp__gridctl__execute`:
- Search for the guest name in upcoming calendar events
- Use the `thecloudgambit@gmail.com` calendar

**Extract from the calendar event:**
- Guest full name (from event title)
- Guest email (from attendees list - exclude thecloudgambit@ and co-host addresses)
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

> **Note:** `calendly_find_user` searches Calendly account holders, not invitees - do not use it for guest lookup.

### Step 2: Create Intake Folder

Call `google_drive_create_folder` via `mcp__gridctl__execute`:
- Parent folder ID: `1O9kuIcZ8Ehk7pcPOgUXEM8xaXfn-SJ6c` (thecloudgambit/_intake)
- Folder name format: `<YYYYMMDD>-<firstname-lastname>` (all lowercase, hyphens)
- Pass the parent folder ID as the `folder` parameter

### Step 3: Copy Planning Template

Call `google_drive_copy_file` via `mcp__gridctl__execute`:
- `file`: `1n4ywVndDZ-EWR_4dpFvrebo7gnD6FwsJ99egY7OO1z4` (planning template)
- `folder`: the new intake folder ID from Step 2
- `new_name`: `<YYYYMMDD>-<firstname-lastname>-planning`

### Step 4: Fill In Calendly Data

Call `google_drive_api_request_beta` via `mcp__gridctl__execute` to POST to the Google Docs batchUpdate API:
`https://docs.googleapis.com/v1/documents/<DOC_ID>:batchUpdate`

Batch all replacements into a single request using `replaceAllText`:

| Placeholder | Replace with |
|---|---|
| `[[RecordingDate]]` | Recording date formatted as "Month Day, Year" |
| `[[EpisodeGuest]]` | Guest full name |
| `[[GuestEmail]]` | Guest email address |
| `[[PublicBio]]` | Bio text from form response |
| `[[Company]]` | Company name |
| `[[JobTitle]]` | Job title |
| `[[LinkedInProfile]]` | LinkedIn URL |
| `[[OtherLinks]]` | Other social/web links from form response |
| `[[ApprovalRequired]]` | "Yes" or "No" from form response |

**Leave these untouched** (filled later):
`[[PlanningCall]]`, `[[EpisodeTheme]]`, `[[EpisodeTopics]]`, `[[EpisodeTitle]]`, `[[EpisodeDescription]]`, `[[EpisodeLinks]]`

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
> Before I dive in - do you have any direction for this episode? This could be:
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

1. **LinkedIn profile** - Career arc, current role, recent posts/articles, career transitions. The gap between what they post about and what their job title says is often where the best conversation lives.
2. **Company website** - What the company does, the guest's role in it, recent launches. Understand it but do NOT frame topics around selling it.
3. **Personal blog / writing** - Technical depth, opinions, frameworks they've developed, recurring themes.
4. **GitHub** - Open source projects, contributions, activity patterns.
5. **Conference talks / presentations** - Recent talks, keynotes, panels. What topics do they choose when given a stage?
6. **Previous podcast appearances** - What have they already talked about? Find angles others haven't explored.
7. **Twitter/X, Bluesky, Mastodon** - Hot takes, industry commentary, debates they engage in.
8. **Publications** - Articles, white papers, RFCs, case studies, books.
9. **Industry news** - Recent mentions, awards, funding rounds, acquisitions.

**Research goals:**
- Career narrative, technical domain, current focus, recent work (last 6-12 months), point of view, industry context

**Validation:** Cross-reference claims, verify current role, note anything unverified.

### Step 8: Generate Episode Theme

Craft an episode theme based on research and user direction.

**Theme rules:**
- 1-2 sentences maximum
- Captures the "why this matters now" angle
- Technically grounded but accessible - more thesis statement than tagline
- **Must not name the guest's current employer** - vendor-agnostic, technology-first
- Other vendors (past employers, competitors, the broader market) are fine

**Examples:**
- "From SOAR to Agents: Why Practical Automation Has to Survive Contact with Real Infrastructure"
- "Progressive Delivery: Shipping Software is Just the Beginning"
- "How Infrastructure Teams Can Scale Reasoning Without Losing Control"

### Step 9: Generate Discussion Topics

Create 10-15 substantive discussion topics with natural conversational flow.

**Structure:**
- Opening (2-3): Career path, current work, bridge into theme
- Core (6-8): Technical depth, POV, specific examples, lessons learned
- Closing (2-3): Where the industry is heading, advice, where to find their work

**Topic guidelines:**
- Stay technical - problems, patterns, architectures, not sales pitches
- **Unsponsored rules**: The guest's current company provides context for expertise, but topics must not read as product marketing. Topics about past employers, the broader market, or vendor categories are fine.
- Be specific - reference concrete research hooks (a post, a talk, a project)
- Mix tactical (how), strategic (why), and reflective (what did you learn) depths

### Step 10: Present Research for Review

Before writing anything to the planning doc, present findings:

```
## Guest Profile: <Name>
<Job Title> at <Company>

### Tech Domain
<Primary area> - <specific focus>

### Career Arc
<2-3 sentence narrative>

### Current Focus
<Last 6-12 months of active work>

### Key Findings
- <Most interesting finding>
- ...

### Point of View
<Notable opinions or positions>

---

### Proposed Episode Theme
"<Theme>"

### Proposed Discussion Topics
1. <Topic> - <brief note on source/angle>
...

---

Sources consulted: <list of URLs>
```

**Ask the user:**
> How does this look? I can adjust the theme, reorder topics, swap angles, or dig deeper on anything. Say "go" to write these to the planning doc.

**Wait for approval or revision before proceeding.**

### Step 11: Update Planning Document

Call `google_drive_api_request_beta` via `mcp__gridctl__execute` to POST to:
`https://docs.googleapis.com/v1/documents/<DOC_ID>:batchUpdate`

Replace:
- `[[EpisodeTheme]]` with the approved theme
- `[[EpisodeTopics]]` with topics as a numbered list with line breaks between each

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

## Part 2b: Host Script

### Step 13: Generate Host Script

Read the podcast voice guide at `references/voice-guide.md` before writing.

**Script structure:**

```markdown
# The Cloud Gambit - <Episode Theme>
## Guest: <Guest Name> | <Job Title>, <Company>
## Recording: <Month Day, Year>

---

### Cold Open
<2-3 sentences. Hook the listener. Punchy - under 4 sentences.>

---

### Guest Welcome
<2-3 sentences. Don't read the resume - set up the conversation.>

---

### Discussion Flow

#### Topic 1: <Title>
**Context:** <1-2 sentences from research - what the host knows going in>
**Lead-in:** <Natural opening line>
**Questions:**
- <Primary question - open-ended, specific, drawn from research>
- <Follow-up if needed>

<...repeat for all approved topics...>

---

### Wrap-Up
<Thank guest, 1-2 sentence takeaway, point to their work. Warm and genuine.>

---

### Outro
<Brief energetic sign-off.>
```

**Writing rules:**
- Write in William's voice - conversational, direct, technically grounded, contractions always
- Questions must be specific to this guest's work - no generic interview questions
- Reference concrete research findings in context sections and questions
- Use single dashes only - never em dashes or en dashes

**Save the script to:** `script/podcast/<YYYYMMDD>-<firstname-lastname>.md`

### Step 14: Present Script for Review

Show the full script and save path. Ask if they want changes before proceeding. If yes, update and re-present.

---

## Part 3: Guest Email

### Step 15: Share Planning Document

Call `google_drive_add_file_sharing_preference` via `mcp__gridctl__execute`:
- Include the guest email address in the `instructions` string (no separate email parameter)
- Set `file_id` to the planning doc ID from Step 3
- Set `permission` to `commenter`

Save the sharing URL returned.

### Step 16: Compose Email

**Subject:** `The Cloud Gambit - Episode Prep | <Guest Full Name>`

**Body:**
```
<Guest Name>,

Thank you for agreeing to record an episode of The Cloud Gambit podcast! We have shared our planning guide with you which contains guidance, rules, and other important details to review prior to the recording. You should get a notice in your email and you can also click <this link> to access and review. We love for this process to be collaborative - if you see anything in the themes and topics section that you'd like to update, please do so. Also, if you have any additional ideas for topics that you think are worth discussing, feel free to add them. We look forward to our recording on <Recording Date>!

Regards,

William Collins
Founder, Co-Host
```

Replace `<this link>` with `<a href="<sharing URL>">this link</a>` in the HTML body.

### Step 17: Prompt for Approval

**Do NOT send the email without explicit approval.**

Present the composed email and ask: **Send this email? (yes / edit / skip)**

### Step 18: Send Email

Call `gmail_send_email` via `mcp__gridctl__execute`:
- `to`: array format - `["guest@email.com"]` (not a string)
- `subject`: composed subject from Step 16
- `body`: HTML body with hyperlinked planning doc
- `from`: `thecloudgambit@gmail.com`

### Step 19: Final Report

```
Prep complete for <Guest Name>

  Recording date: <Month Day, Year>
  Theme: "<Episode Theme>"
  Topics: <count> discussion topics

  Google Drive:
    Intake folder: <folder name> (<folder URL>)
    Planning doc:  <file name> (<file URL>)
    Shared with:   <guest email> (commenter)

  Host script: script/podcast/<filename>.md

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

## Podcast Context

**The Cloud Gambit** is a technical podcast on the Packet Pushers network covering cloud, infrastructure, DevOps, networking, security, AI/automation, and adjacent topics. Episodes are conversational - one host, one guest, ~45 minutes.

**Tone**: Technically substantive but approachable. Not a product demo. The best episodes feel like overhearing two experts talk shop.

**Audience**: Infrastructure engineers, cloud architects, DevOps practitioners, technical leaders. They want depth, not marketing.

## Error Handling

- **Guest not found**: Try fuzzy matching, present options, ask user
- **No calendar event found**: Use today's date as fallback, flag for user
- **Missing form fields**: Continue with available data, note gaps in report
- **Google Drive errors**: Report the error and provide manual instructions
- **Thin research results**: Note gaps, suggest the user provide additional links or context
- **User wants revisions**: Iterate on theme/topics before writing to the doc - never write without approval
- **Email send failure**: Report the error, provide the composed email for manual send

## Important

- **Always ask for direction before researching** - the user may have context you can't find online
- **Always present findings before writing** - never update the planning doc without explicit approval
- **Unsponsored episode rules**: Technology first. The guest's current employer is context, not the subject. Past employers and vendor categories are fair game.
- Do NOT modify `[[PlanningCall]]` - that is set manually
- All folder and file names should be lowercase with hyphens
- Use single dashes (-) in all generated content - never em dashes or en dashes
