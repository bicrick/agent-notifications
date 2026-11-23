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

## Settings

Click the line icon in the menu bar → **Settings…** (live preview included):

- **Appearance**: background (Glass, Frosted, Solid, Tinted by the most urgent state, None); marks (Bars, Line, Dots, Glow); colours (System, Vivid, Pastel, Mono); dormant style (Faint, Outline, Tick, Hidden); size, mark width, panel width; left or right edge and height.
- **Sounds**: [Cuelume](https://cuelume-site.pages.dev/) sound set (Glass, Mechanical, Bubble, Press), a cue per state (finish, needs you, fail, start), volume, a repeating reminder while something waits on you, and mute for 15 min / 1 hour / until tomorrow.
- **Sessions**: how many to show, order (needs you first, most recent, first seen), how long finished sessions stay, and sources.

The menu bar icon turns amber or red when something needs you or fails.

## Commands

- `scripts/install.sh`: build `~/Applications/Agent Dots.app`, link `~/.local/bin/agent-dots`, start at login
- `agent-dots hook claude`: Claude Code hook (stdin JSON)
- `agent-dots set <session> <state> [label] [app]`
- `agent-dots snapshot out.png [0|1] [light|dark] [key=value…]`: render the rail with sample sessions, e.g. `markStyle=dot palette=vivid`
- `agent-dots settings-snapshot out.png [appearance|sounds|sessions|about]`
- `scripts/render-cues.mjs`: re-render the Cuelume sounds (13 cues × 4 sets)
