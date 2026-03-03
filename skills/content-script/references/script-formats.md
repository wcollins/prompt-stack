# Script Formats

Templates for different content types. Each format includes the structural elements and markers used in production.

## Markers

These markers appear throughout scripts to guide production:

- `**[SCREEN]**` — Switch to screen sharing. Always followed by what to show.
- `**[CAMERA]**` — Switch to camera/talking head.
- `**[DEMO]**` — Live demonstration segment. Includes commands, expected output, and narration.
- `**[NOTE]**` — Production note (not spoken). Context for the creator.

---

## Tutorial Format

For screen sharing walkthroughs. Step-by-step, show and tell.

```markdown
# <Title>
## Date: <Month Day, Year>
## Type: Tutorial
## Estimated Length: <Short (5-10min) | Medium (10-20min) | Long (20-30min)>

---

### Opening

**[CAMERA]**

<2-4 sentences. Hook the viewer with what they'll be able to do by the end. State the problem or goal clearly.>

---

### Prerequisites

**[NOTE]** <What the viewer needs installed/configured before starting. Keep brief - link to resources.>

---

### Section 1: <Name>

**[SCREEN]** <What to show: specific file, terminal, browser tab, etc.>

<Narration for what we're looking at and why.>

**[DEMO]**
- **Action**: <What to type/click>
- **Command**: `<exact command if applicable>`
- **Expected output**: <What should appear>
- **Narration**: "<What to say while this runs>"

<Transition to next point within the section.>

### Section 2: <Name>

...

---

### Recap

**[CAMERA]**

<2-3 sentences summarizing what was built/configured. Connect back to the opening goal.>

---

### Outro

<Call to action: subscribe, next video teaser, or invitation to explore further.>
```

---

## Explainer Format

For opinion pieces and concept breakdowns. Talking head with optional visuals.

```markdown
# <Title>
## Date: <Month Day, Year>
## Type: Explainer
## Estimated Length: <Short (3-8min) | Medium (8-15min) | Long (15-25min)>

---

### Hook

**[CAMERA]**

<1-3 punchy sentences. State the core thesis or provocation. Make the viewer want to keep watching.>

---

### Context

**[CAMERA]**

<Set the stage. Why does this matter now? What's happening in the industry that makes this relevant?>

**[NOTE]** <Optional: suggest a graphic, screenshot, or headline to show briefly.>

---

### Core Argument

**[CAMERA]**

#### Point 1: <Name>
<Explanation with example. 3-5 sentences.>

**[NOTE]** <Optional visual suggestion: diagram, code snippet, screenshot.>

#### Point 2: <Name>
<Explanation with example. 3-5 sentences.>

#### Point 3: <Name>
<Explanation with example. 3-5 sentences.>

---

### Counterpoint

**[CAMERA]**

<Acknowledge the strongest opposing argument. Address it honestly. 2-4 sentences.>

---

### Takeaway

**[CAMERA]**

<Land the plane. 2-3 sentences connecting back to the hook with the new perspective established through the argument.>

---

### Outro

<Brief close. Forward look or call to action.>
```

---

## Lab Format

For hands-on technical demonstrations. Heavy on demo, light on talking head.

```markdown
# <Title>
## Date: <Month Day, Year>
## Type: Lab
## Estimated Length: <Medium (10-20min) | Long (20-40min)>
## Tools: <List of tools/software used>

---

### Opening

**[CAMERA]**

<2-3 sentences. What are we building/configuring today and why it matters.>

**[SCREEN]** <Show architecture diagram or topology if applicable.>

<Brief walkthrough of the architecture/topology. What connects to what.>

---

### Environment Setup

**[SCREEN]** Terminal

**[NOTE]** <Assumptions about the viewer's environment. What should already be installed.>

**[DEMO]**
- **Action**: Verify prerequisites
- **Commands**:
  ```
  <verification commands>
  ```
- **Expected output**: <What confirms everything is ready>
- **Narration**: "Let's make sure we have everything we need..."

---

### Phase 1: <Name>

**Goal**: <What this phase accomplishes>

**[SCREEN]** <Specific file, terminal, or tool to show>

**[DEMO]**
- **Action**: <Descriptive action>
- **Commands**:
  ```
  <exact commands>
  ```
- **Expected output**:
  ```
  <expected terminal output or result>
  ```
- **Narration**: "<What to say while doing this>"
- **Watch for**: <Common gotchas or things to point out>

<Transition narration to next demo.>

**[DEMO]**
...

---

### Phase 2: <Name>

...

---

### Verification

**[SCREEN]** Terminal

**[DEMO]**
- **Action**: Verify everything works end to end
- **Commands**:
  ```
  <verification commands>
  ```
- **Expected output**: <What proves success>
- **Narration**: "Let's make sure this all actually works..."

---

### Wrap-Up

**[CAMERA]**

<Summary of what was built. 2-3 sentences. Suggest next steps or variations to try.>

---

### Outro

<Call to action. Tease what's next if part of a series.>
```

---

## Short Format

For YouTube Shorts, social clips, and quick takes. Under 90 seconds.

```markdown
# <Title>
## Date: <Month Day, Year>
## Type: Short
## Estimated Length: <30-90 seconds>

---

### Hook (0-5 seconds)

**[CAMERA]**

<One punchy sentence. Immediately grab attention.>

---

### Point (5-50 seconds)

**[CAMERA]** or **[SCREEN]**

<The core message. 3-6 sentences max. If showing a demo, keep it to one single action with clear result.>

**[DEMO]** (optional)
- **Action**: <Single, clear action>
- **Command**: `<one command>`
- **Result**: <Immediate, visible result>

---

### Landing (50-90 seconds)

**[CAMERA]**

<1-2 sentences. Clear takeaway. No call to subscribe - just land the point.>
```

---

## Format Selection Guide

| Content Type | Best For | Demo Weight | Talk Weight |
|-------------|----------|-------------|-------------|
| Tutorial | Teaching a specific skill | 60-70% | 30-40% |
| Explainer | Opinions, concepts, trends | 0-20% | 80-100% |
| Lab | Building something from scratch | 70-80% | 20-30% |
| Short | Single point, quick take | 0-50% | 50-100% |
