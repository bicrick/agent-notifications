# agent-dots

A native macOS (SwiftUI) slim always-on-top rail on the right edge of your Mac showing what your AI coding agents are doing.
Hover to slide out details; click a session to open it.

Sources:
- **T3 Code**: read from T3's own state (`~/.t3/userdata/statev2.sqlite`, read-only), so every T3 thread shows whatever its provider, and a click opens that exact thread.
- **Claude Code** outside T3: hooks in `~/.claude/settings.json` calling `agent-dots hook claude`.
- **OpenCode** outside T3: `integrations/opencode/agent-dots.js`, linked into `~/.config/opencode/plugins/`.

| Mark | State |
|---|---|
| blue, sweeping | working |
| green | done |
| yellow, breathing | needs you |
| red, notched | failed |

Sounds are [Cuelume](https://cuelume-site.pages.dev/) cues, rendered by `scripts/render-cues.mjs`.

- `scripts/install.sh`: build `~/Applications/Agent Dots.app`, link `~/.local/bin/agent-dots`, start at login
- `agent-dots`: run the overlay (listens on `127.0.0.1:47321`)
- `agent-dots hook claude`: Claude Code hook (stdin JSON)
- `agent-dots set <session> <state> [label] [app]`
- `agent-dots snapshot out.png [open 0..1]`: render the overlay with sample sessions to a PNG (`0` closed, `1` open)
- `integrations/opencode/agent-dots.js`: OpenCode plugin, link into `~/.config/opencode/plugins/`
