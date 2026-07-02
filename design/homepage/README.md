# Homepage redesign — Claude Design bundle

Self-contained HTML previews of the redesigned projectrye.dev homepage,
extracted from the live implementation in `site/src/pages/index.astro` and
`site/src/styles/global.css`. Each file carries a first-line
`<!-- @dsCard group="…" -->` marker so the Claude Design app indexes it as a
card.

| File | Card |
| --- | --- |
| `00-foundations.html` | Color and type tokens (light + hero/dark palettes) |
| `01-hero-agent-prompt.html` | Hero with the one-sentence agent prompt and copy button |
| `02-agent-terminal.html` | Looping animated you-and-agent setup conversation |
| `03-scenario-cards.html` | Three realistic scenario cards with first-success callouts |
| `04-needs-grid.html` | "What you need" strip: Docker or a connection string |
| `05-memory-flow.html` | Evidence → candidate → gate → accepted flow (from the Codex value-prop branch) |

## Pushing to claude.ai/design

DesignSync requires design authorization, which needs an interactive
terminal. From an interactive Claude Code session in this repo:

1. Run `/design-login` and complete the authorization.
2. Ask Claude to push `design/homepage/` to a Claude Design project with
   DesignSync (create a project such as "Project Rye Homepage" if none
   exists).

The site implementation is the source of truth; regenerate these previews
from `site/` if the homepage changes.
