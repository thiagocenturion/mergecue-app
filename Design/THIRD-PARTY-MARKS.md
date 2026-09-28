# Third-party marks

MergeCue shows the marks of the services it integrates with so each item is recognisable at a glance
(`repo #42` on GitHub vs. GitLab vs. Bitbucket, and which coding agent a task is handed to). The marks are used
**only to identify the integration**; they do not imply endorsement, partnership or affiliation. All trademarks
belong to their respective owners.

| Mark | Used for | Owner |
| --- | --- | --- |
| GitHub (Invertocat) | GitHub.com accounts, PRs | GitHub, Inc. |
| GitLab (tanuki) | GitLab.com accounts, MRs | GitLab Inc. |
| Bitbucket | Bitbucket Cloud accounts, PRs | Atlassian |
| Claude (starburst) | Claude Code handoff | Anthropic |
| OpenAI (blossom) | Codex CLI handoff | OpenAI |

## Source and licence

The vector path data comes from **Simple Icons** (https://simpleicons.org, slugs `github`, `gitlab`, `bitbucket`,
`claude`, `openai`; fetched from `https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/<slug>.svg`, package version
16.33.0). Simple Icons releases its SVG data under **CC0-1.0**; that licence covers the path data, not the trademarks
themselves. Use of each mark remains subject to its owner's brand guidelines.

The paths are embedded verbatim in `Sources/MergeCueUI/Components/BrandMarks.swift` (`BrandPathData`, 24 × 24 view
box) and rendered at runtime by a small SVG path parser (`SVGPathParser`) as SwiftUI shapes. Colours applied in the
app: GitHub follows the text colour of the appearance, GitLab uses its orange range, Bitbucket its blue gradient,
Claude `#D97757`, OpenAI the text colour. No mark is modified beyond scaling and fill colour.

Guidelines followed: marks are shown at their natural proportions, never combined with the MergeCue logo into a new
lock-up, and never used on their own to suggest a first-party product.
