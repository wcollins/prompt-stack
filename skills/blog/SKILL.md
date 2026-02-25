---
description: >
  Add new content to the wcollins.io blog — blog posts, talks, projects, or links.
  Blog posts are generated in William's authentic voice using his writing style guide.
  Trigger when the user mentions: new blog post, write a post, add a talk, new talk,
  add a project, new project, add a link, new content, create a post, blog about,
  write about, add content, new blog, /new-blog.
argument-hint: "blog | talk | project | link"
---

# New Content

Add new content to the wcollins.io Hugo blog. Supports blog posts, talks, projects, and links.

**Target repo**: The blog at the current working directory (must be the wcollins.io Hugo blog).

## Detect Mode

Parse `$ARGUMENTS` to determine content type:

- Contains `blog`, `post`, `write`, or is empty → **Blog Post**
- Contains `talk`, `speak`, `podcast`, `conference` → **Talk**
- Contains `project` → **Project**
- Contains `link` → **Link**

---

## Blog Post

Create a new blog post matching William's authentic writing voice.

### Step 1: Gather Input

Ask the user using AskUserQuestion:

1. **Topic/title** — What is this post about?
2. **Audience** — Who is this for? (e.g., "Cloud engineers", "Technical leaders", "General tech audience")
3. **Length** — Short (40-100 lines), Medium (100-140 lines), or Long (180-200+ lines)
4. **Key points** — 3-5 bullet points to cover

### Step 2: Study Voice

Read `references/voice-guide.md` for William's writing patterns.

Then read 3-5 existing posts from the blog to calibrate tone. Choose posts that are topically similar to the new post. Use these locations:

```
content/posts/2024/
content/posts/2023/
content/posts/2022/
```

Pay attention to: sentence structure, humor style, how technical concepts are introduced, use of analogies, paragraph length, and opinion framing.

### Step 3: Create Branch and Directory

```bash
# Slugify the title
SLUG="<lowercase-hyphenated-title>"
YEAR=$(date +%Y)

git checkout main
git pull origin main
git checkout -b blog/${SLUG}

mkdir -p content/posts/${YEAR}/${SLUG}/
```

### Step 4: Select Tags and Categories

Choose from existing tags and categories. Add new ones only if nothing fits.

**Existing tags:**
aws, azure, gcp, terraform, ansible, kubernetes, microservices, docker, linux,
github-actions, hugo, chatgpt, llm, machine-learning, go, mcp, alkira, fortinet,
zerotier, packer, bgp, dns, private-link, infracost, lightlytics,
infrastructure-as-code, site-to-site-vpn, immutable-infrastructure,
aws-community-builders, cryptocurrency, proof-of-stake, tesla, nvidia, ttpoe,
rdma, ultraethernet, venture-capital, startups, networking, tools, cloud, automation

**Existing categories:**
automation, cloud, community, ai, networking, security, tools, business

Use 2-4 tags and 1-2 categories per post. Match existing conventions.

### Step 5: Write the Post

Create `content/posts/${YEAR}/${SLUG}/index.md` with this frontmatter:

```yaml
---
title: "Post Title"
date: YYYY-MM-DDTHH:MM:SS-05:00
lastmod: YYYY-MM-DDTHH:MM:SS-05:00
tags: ["tag1", "tag2"]
categories: ["category1"]
---
```

Write the post body following these structural patterns:

1. **Opening** (2-3 sentences) — Hook with one of: personal anecdote, timely trend, direct question, problem statement, or event framing
2. **Problem/Context** — Define the challenge or motivation clearly
3. **Body** — 3-5 sections with H2 headings, H3 subsections for depth
4. **Conclusion** — Takeaway, call to action, or forward-looking statement

Use callouts where appropriate:
- `> [!TIP]` for best practices
- `> [!NOTE]` for important details
- `> [!WARNING]` for warnings
- `> [!EXAMPLE]` for real-world applications

Leave `<!-- TODO: Add image/screenshot here -->` comments where visuals would strengthen the post.

### Step 6: Confirm

Show the user:
- File path created
- Frontmatter summary (tags, categories)
- Opening paragraph preview
- Suggest: "Preview locally with `hugo server` and review the draft"

---

## Talk

Add a speaking engagement or podcast episode.

### Step 1: Determine Type

Ask the user: **Conference talk or podcast episode?**

### Step 2: Gather Details

**For conference talks:**
- Event name
- City, State (or virtual)
- Date (YYYY-MM-DD)
- GitHub repo URL for slides/materials (optional)

**For podcast episodes:**
- Podcast series name
- Episode number and title
- Date (YYYY-MM-DD)
- Audio file path (optional — user may add later)

### Step 3: Create the Entry

Generate a slug from the event/podcast name.

```bash
YEAR=$(date -d "YYYY-MM-DD" +%Y)  # Extract year from the provided date
mkdir -p content/talks/${YEAR}/${SLUG}/
```

**Conference talk** — `content/talks/${YEAR}/${SLUG}/index.md`:

```yaml
---
title: "Event Name - City, State"
subtitle: "Talk Title or Topic"
date: YYYY-MM-DD
repo: "https://github.com/wcollins/talks/tree/main/YYYY-event-slug"
build:
  render: never
---
```

**Podcast episode** — `content/talks/${YEAR}/${SLUG}/index.md`:

```yaml
---
title: "Podcast Series: ### - Episode Title"
date: YYYY-MM-DD
---

{{< audio src="filename.mp3" >}}
```

If an audio file is provided, copy it into the talk directory.

### Step 4: Confirm

Show the user the created file path and content.

---

## Project

Add a new open source project to the projects section.

### Step 1: Gather Details

Ask the user:
- Project name
- Short description (one line)
- GitHub repo path (e.g., `wcollins/project-name` or `org/repo`)
- Tags (suggest from existing: go, mcp, automation, terraform, aws, etc.)

### Step 2: Create the Entry

```bash
mkdir -p content/projects/${SLUG}/
```

Create `content/projects/${SLUG}/index.md`:

```yaml
---
title: "project-name"
description: "Short project description"
tags: ["tag1", "tag2"]
repo: "owner/repo"
showDate: false
showReadingTime: false
showAuthor: false
---
```

### Step 3: Confirm

Show the user the created file and remind them that the project card pulls live data from the GitHub API (stars, forks, recent PRs).

---

## Link

Add a new link to the links hub page.

### Step 1: Gather Details

Ask the user:
- Link label (display text)
- URL
- Section: Connect, Content, or Open Source (or suggest a new section)

### Step 2: Update Links Page

Read `content/links/index.md` and add the new button shortcode under the appropriate section:

```markdown
{{< button href="https://example.com" target="_blank" >}}
Link Label
{{< /button >}}
```

### Step 3: Confirm

Show the user the updated section.

---

## Important Rules

- Sign all commits with `-S` flag
- No Co-authored-by trailers in commits
- No mention of Claude in commits, PRs, or generated content
- Blog posts must authentically match William's voice — read `references/voice-guide.md`
- Use existing tags and categories before creating new ones
- All dates use ISO 8601 format with timezone for blogs, simple YYYY-MM-DD for talks
- Featured images (`featured.png/jpg`) are added manually by the user after generation
- Preview locally with `hugo server` before committing
