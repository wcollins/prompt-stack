# Feature Implementation: Modern GitHub Profile README

## Context

Repository: `wcollins/wcollins` (GitHub special profile repository — the README.md renders on the GitHub profile page)
Working directory: `/Users/william/code/gh-profile`
Current file: `README.md` (21 lines, single file in the repo)
Branch: `fix/social-icons-vertical-layout` (already created)

**Owner profile:**
- Name: William Collins
- Role: Director of Technical Evangelism at [Itential](https://itential.com)
- Podcast: [The Cloud Gambit](https://www.thecloudgambit.com)
- Blog: https://wcollins.io
- GitHub username: `wcollins`
- Tech stack: Ansible, Docker, Git, GitHub, Linux, Python, Terraform, OpenTofu

**Social links:**
- LinkedIn: https://linkedin.com/in/william-collins
- Twitter/X: https://x.com/wcollins502
- Instagram: https://instagram.com/thecloudgambit
- TikTok: https://tiktok.com/thecloudgambit
- Blog/RSS: https://wcollins.io

## Evaluation Context

- Market research confirmed `simple-icons@3.0.1` (current CDN) is severely outdated (v16 is current); `twitter.svg` no longer exists in current versions — broken image
- `align="center"` on `<img>` is invalid; GitHub now treats it as `display: block` causing vertical stacking — the `<picture>` element solution eliminates this entirely
- `target="blank"` (missing underscore) means links don't open in new tabs
- Black SVGs are invisible in GitHub dark mode — `<picture>` with `cdn.simpleicons.org` color params is the correct fix
- For a technical evangelist, dynamic content (blog/podcast auto-update) is the single highest-value addition
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gh-profile/modern-profile-readme/feature-evaluation.md`

## Feature Description

Replace the existing README.md with a modern, polished GitHub profile that:
1. Hooks visitors immediately with a typing SVG animation
2. Auto-updates with latest blog posts and podcast episodes via RSS
3. Displays social icons correctly in both dark and light mode (horizontally, visible)
4. Showcases tech stack with modern badge styling
5. Includes a streak stats card and profile view counter
6. Functions as a content hub appropriate for a technical evangelist

## Requirements

### Functional Requirements

1. Typing SVG header cycling through: "Director of Technical Evangelism", "Host of The Cloud Gambit Podcast", "DevOps | IaC | NetDevOps"
2. All social icons must display **horizontally** and be **visible in both dark and light mode**
3. All external links must use `target="_blank"` (with underscore) and `rel="noopener noreferrer"`
4. Social icons must use `cdn.simpleicons.org` (not the outdated jsdelivr simple-icons@3.0.1)
5. Social icons must use `<picture>` element with dark/light mode variants
6. Tech stack badges must use `for-the-badge` style
7. A "Latest Content" section must exist with placeholder comments for blog-post-workflow
8. A GitHub Actions workflow file must be created at `.github/workflows/update-readme.yml` to auto-populate latest content from RSS
9. A streak stats card must be included
10. A profile view counter badge must be included
11. Podcast (The Cloud Gambit) must be prominently featured with a link

### Non-Functional Requirements

- README must render correctly in GitHub's markdown renderer (no raw HTML that GitHub sanitizes)
- All image sources must be reliable, hosted services (no self-hosted dependencies)
- The typing SVG, streak stats, and blog-post-workflow must use their respective hosted endpoints (demolab.com, komarev.com, GitHub Actions marketplace) — do NOT require William to self-host anything
- Dark mode: all images/icons must be legible in GitHub dark mode

### Out of Scope

- GitHub profile trophies (ryo-ma/github-profile-trophy) — excluded due to reliability issues and visual clutter
- WakaTime integration — requires WakaTime account setup
- Top languages card — not appropriate for a DevRel/evangelist profile focus
- Activity graph — conditional on contribution history, omit for now
- Custom domain or GitHub Pages setup

## Architecture Guidance

### Recommended Approach

Full replacement of `README.md`. The file is 21 lines; there is nothing to preserve structurally (only the social link hrefs and shields.io badge data are worth carrying forward).

Create `.github/workflows/update-readme.yml` as a new file for the blog-post-workflow action.

### Key Files to Read First

- `/Users/william/code/gh-profile/README.md` — current state, extract hrefs and badge slugs before replacing

### Integration Points

**README.md sections (in order):**

```
1. Profile view counter badge (top of file, right-aligned)
2. Typing SVG header
3. About / intro paragraph
4. Latest Content section (with blog-post-workflow placeholder comments)
5. Tech Stack (for-the-badge badges)
6. Let's Connect (picture-wrapped social icons)
7. GitHub streak stats card
```

**GitHub Actions workflow:**
- Path: `.github/workflows/update-readme.yml`
- Trigger: `schedule` (daily at 06:00 UTC) + `workflow_dispatch`
- Action: `gautamkrishnar/blog-post-workflow@master`
- Feed: `https://wcollins.io/feed.xml` (verify this URL exists; if not, use `https://wcollins.io/rss.xml` or `https://wcollins.io/index.xml` as fallbacks)
- Inject into README between `<!-- BLOG-POST-LIST:START -->` and `<!-- BLOG-POST-LIST:END -->` comments

### Reusable Components

Carry forward these exact hrefs from the current README:
- `https://linkedin.com/in/william-collins`
- `https://x.com/wcollins502`
- `https://instagram.com/thecloudgambit`
- `https://tiktok.com/thecloudgambit`
- `https://wcollins.io`

## UX Specification

### Typing SVG
```
https://readme-typing-svg.demolab.com?font=Fira+Code&pause=1000&color=58A6FF&center=false&vCenter=true&width=500&lines=Director+of+Technical+Evangelism;Host+of+The+Cloud+Gambit+Podcast;DevOps+%7C+IaC+%7C+NetDevOps
```
Wrap in a link to William's blog: `[![Typing SVG](URL)](https://wcollins.io)`

### Social Icons — Picture Element Pattern

Use this pattern for each icon (adjust slug and brand color per platform):

```html
<a href="LINK" target="_blank" rel="noopener noreferrer">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://cdn.simpleicons.org/SLUG/white">
    <source media="(prefers-color-scheme: light)" srcset="https://cdn.simpleicons.org/SLUG/BRAND_COLOR">
    <img alt="PLATFORM" src="https://cdn.simpleicons.org/SLUG/BRAND_COLOR" height="30" width="30">
  </picture>
</a>
```

**Icon slugs and brand colors:**
| Platform | Slug | Brand Color |
|----------|------|-------------|
| LinkedIn | `linkedin` | `0A66C2` |
| X (Twitter) | `x` | `000000` (use `white` for light too, or `1DA1F2` for Twitter blue) |
| Instagram | `instagram` | `E4405F` |
| TikTok | `tiktok` | `000000` (use `FF0050` for light) |
| RSS/Blog | `rss` | `FFA500` |

### Latest Content Section

```markdown
### 📝 Latest Content

<!-- BLOG-POST-LIST:START -->
<!-- BLOG-POST-LIST:END -->

▶ [More on wcollins.io](https://wcollins.io) · 🎙️ [The Cloud Gambit Podcast](https://www.thecloudgambit.com)
```

### Stats Section

Streak card:
```markdown
[![GitHub Streak](https://streak-stats.demolab.com?user=wcollins&theme=dark&hide_border=true)](https://git.io/streak-stats)
```

Profile views:
```markdown
![Profile Views](https://komarev.com/ghpvc/?username=wcollins&style=flat-square&color=58A6FF)
```

Place profile views badge at the top right of the README using `<div align="right">` or inline before the typing SVG.

## Implementation Notes

### Conventions to Follow
- No `Co-authored-by` trailers in commits
- No mention of Claude in commits, PRs, or branches
- Sign all commits with `-S`
- Commit message format: `fix: <subject>` or `feat: <subject>` (imperative, under 50 chars)

### Potential Pitfalls

1. **RSS feed URL**: Verify `https://wcollins.io/feed.xml` actually returns RSS before hardcoding it. Common alternatives: `/rss.xml`, `/index.xml`, `/feed/`, `/atom.xml`. The GitHub Action will silently produce no output if the feed URL is wrong.

2. **blog-post-workflow permissions**: The workflow needs `contents: write` permission to commit back to the repo. Include this in the workflow YAML:
   ```yaml
   permissions:
     contents: write
   ```

3. **`<picture>` element in GitHub Markdown**: GitHub's sanitizer allows `<picture>`, `<source>`, and `<img>` tags. Do NOT use `style=""` attributes — GitHub strips inline styles. Do NOT use `<div>` for alignment in the icons section — use `<p align="left">` as the wrapper.

4. **Streak stats dark theme**: Use `theme=dark` (not `theme=github-dark`) for the demolab endpoint — `github-dark` is a newer theme that may not render in all contexts.

5. **cdn.simpleicons.org for TikTok**: The TikTok slug is `tiktok` (not `tik-tok`). Verify at https://simpleicons.org/ before using.

6. **No trailing newline**: The current README.md has no trailing newline (`\ No newline at end of file` in the diff). Add a trailing newline in the new file.

### Suggested Build Order

1. Write the new `README.md` in full (all sections)
2. Verify all CDN URLs are syntactically correct
3. Create `.github/workflows/update-readme.yml`
4. Commit `README.md` first, then the workflow file
5. Push and create PR

## Acceptance Criteria

1. Social icons display horizontally (not vertically) in GitHub's markdown renderer
2. Social icons are visible in both GitHub light mode and dark mode
3. All social links open in a new tab (`target="_blank"`)
4. The typing SVG renders in the header
5. A "Latest Content" section exists with correct `<!-- BLOG-POST-LIST:START/END -->` placeholder comments
6. `.github/workflows/update-readme.yml` exists and references the correct RSS feed
7. Tech stack badges use `for-the-badge` style
8. Streak stats card renders (uses `wcollins` as the username)
9. Profile view counter badge is present
10. The Cloud Gambit Podcast is linked prominently
11. No `align="center"` on any `<img>` tag
12. No `simple-icons@3.0.1` jsdelivr URLs anywhere in the file

## References

- https://readme-typing-svg.demolab.com (typing SVG generator)
- https://streak-stats.demolab.com (streak stats)
- https://github.com/gautamkrishnar/blog-post-workflow (blog post automation)
- https://simpleicons.org/ (verify icon slugs)
- https://cdn.simpleicons.org (icon CDN with color params)
- https://komarev.com/ghpvc/ (profile view counter)
- https://shields.io/badges (badge reference)
- https://github.blog/developer-skills/github/how-to-make-your-images-in-markdown-on-github-adjust-for-dark-mode-and-light-mode/ (picture element dark mode)
