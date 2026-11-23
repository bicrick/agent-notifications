# agent-dots

A slim always-on-top rail on the right edge of your Mac showing what your AI coding agents are doing.
Hover to slide out details; click a session to open its app.

| Mark | State |
|---|---|
| blue, sweeping | working |
| green | done |
| yellow, breathing | needs you |
| red, notched | failed |

Sounds are [Cuelume](https://cuelume-site.pages.dev/) cues, rendered by `scripts/render-cues.mjs`.

- `agent-dots`: run the overlay (listens on `127.0.0.1:47321`)
- `agent-dots hook claude`: Claude Code hook (stdin JSON)
- `agent-dots set <session> <state> [label] [app]`
- `agent-dots snapshot out.png [open 0..1]`: render the overlay with sample sessions to a PNG
- `integrations/opencode/agent-dots.js`: OpenCode plugin, link into `~/.config/opencode/plugins/`
