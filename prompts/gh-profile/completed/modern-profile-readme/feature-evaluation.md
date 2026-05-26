# Feature Evaluation: Modern GitHub Profile README

**Date**: 2026-04-16
**Project**: gh-profile
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

William's current GitHub profile README is a minimal 2021-era file with broken social icons (invisible in dark mode, stacking vertically), an outdated CDN reference, and no dynamic content — actively undermining his brand as a Director of Technical Evangelism and podcast host. A full rebuild using modern techniques (readme-typing-svg, blog-post-workflow, cdn.simpleicons.org with dark/light mode support) is high value, low effort, and low risk.

## The Idea

Redesign the `wcollins` GitHub profile README from scratch using 2024-2025 best practices. The profile should function as a content hub and professional landing page — not just a code portfolio — appropriate for a technical evangelist and podcast host.

**Problem it solves:**
- Social icons are black SVGs invisible in GitHub dark mode
- Icons stack vertically due to `align="center"` (invalid value causing block display)
- `twitter.svg` no longer exists in current simple-icons — broken image
- `target="blank"` (missing underscore) — links don't open in new tabs
- No dynamic content; profile goes stale without manual updates
- No podcast prominence despite being a core part of William's brand
- No typing animation or visual hierarchy to hook visitors in the first 3 seconds

## Project Context

### Current State
Single-file repository (`README.md`, 21 lines). Three sections: introduction, tech stack (shields.io badges), and "Let's Connect" (simple-icons SVGs). No CI/CD, no GitHub Actions.

### Integration Surface
- `README.md` — full replacement
- `.github/workflows/update-readme.yml` — new file for blog-post-workflow automation

### Reusable Components
- Existing shields.io badge URLs can be upgraded in-place (style param change only)
- Social link hrefs are correct and can be reused

## Market Analysis

### Competitive Landscape
Top technical evangelist profiles (e.g., Eddie Jaoude, Kunal Kushwaha, Rishab Kumar) share a consistent pattern: typing SVG header, auto-updated blog/content section, organized tech stack, and social icons that work in both modes. The current profile is ~3-4 years behind this standard.

### Market Positioning
A modern profile is **table-stakes** for a public-facing DevRel role. The current state is below the baseline expected for someone with William's seniority and visibility.

### Ecosystem Support
- `readme-typing-svg` (DenverCoder1) — actively maintained, Vercel-hosted
- `github-readme-streak-stats` (DenverCoder1) — actively maintained, 75+ themes
- `blog-post-workflow` (gautamkrishnar) — v4, GitHub Actions Marketplace, supports any RSS feed
- `cdn.simpleicons.org` — official Simple Icons CDN, color parameter support, no versioning needed
- `komarev.com/ghpvc` — reliable profile view counter

### Demand Signals
The `awesome-github-profile-readme` repo has 20k+ stars. The tools referenced above have tens of thousands of users. This is a well-established pattern with proven tooling.

## User Experience

### Interaction Model
1. **Hero**: Typing SVG cycling through role / podcast / specialties — hooks visitor in 3 seconds
2. **About**: 2-sentence value prop
3. **Latest Content**: Auto-updated blog posts and podcast episodes via RSS
4. **Tech Stack**: `for-the-badge` style badges, organized
5. **Connect**: `<picture>`-wrapped icons — correct in both dark and light mode, displayed horizontally
6. **Stats**: Streak card + profile views counter (supporting role)

### Workflow Impact
- Visitors immediately understand who William is and what he creates
- Podcast and blog surface automatically — no manual README edits needed after setup
- Social links work correctly (new tab, visible in both themes)

### UX Recommendations
- Avoid trophies (unreliable, cluttered, undermines senior credibility)
- Keep stats cards minimal (1 streak card is enough)
- Lead with content, not commits — evangelists are judged on what they ship publicly, not GitHub green squares

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Broken icons + stale profile for a public DevRel role |
| User impact | Broad + Deep | Every GitHub visitor; first impression for recruiters and collaborators |
| Strategic alignment | Core mission | Profile IS the brand for a technical evangelist |
| Market positioning | Catch up → Leap ahead | Modern rebuild exceeds 90% of profiles in this space |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Single README.md + one optional GitHub Actions workflow |
| Effort estimate | Small | ~1-2 hours |
| Risk level | Low | Fully reversible; worst case revert to current state |
| Maintenance burden | Minimal | blog-post-workflow automates content freshness |

## Recommendation

**Build immediately.** This is a rare case where the effort is small, the risk is negligible, and the current state is actively harming the user's professional brand. The blog-post-workflow automation means the profile stays fresh indefinitely after a one-time setup. The `<picture>` element pattern for icons is the correct modern solution and eliminates the vertical stacking and dark mode issues simultaneously.

## References

- https://github.com/anuraghazra/github-readme-stats
- https://github.com/DenverCoder1/github-readme-streak-stats
- https://github.com/DenverCoder1/readme-typing-svg
- https://github.com/gautamkrishnar/blog-post-workflow
- https://github.com/Ashutosh00710/github-readme-activity-graph
- https://github.com/antonkomarev/github-profile-views-counter
- https://simpleicons.org/
- https://github.com/abhisheknaiidu/awesome-github-profile-readme
- https://shields.io/badges
- https://github.blog/developer-skills/github/how-to-make-your-images-in-markdown-on-github-adjust-for-dark-mode-and-light-mode/
