// agent-dots plugin for OpenCode (V1 plugin API, OpenCode 1.x).
// Link it into ~/.config/opencode/plugins/ and every OpenCode session — in a terminal,
// the desktop app, or T3 Code — shows up as a mark on the agent-dots rail.
import fs from 'node:fs';
import path from 'node:path';

const PORT = Number(process.env.AGENT_DOTS_PORT || 47321);
const DEBUG = process.env.AGENT_DOTS_DEBUG ? '/tmp/agent-dots-opencode.log' : null;

function hostApp() {
  const env = process.env;
  if (env.T3CODE_CLI_PATH || /t3code/i.test(env.__CFBundleIdentifier || '')) return 'T3 Code (Beta)';
  switch (env.TERM_PROGRAM) {
    case 'Apple_Terminal': return 'Terminal';
    case 'iTerm.app': return 'iTerm';
    case 'ghostty': return 'Ghostty';
    case 'WezTerm': return 'WezTerm';
    case 'vscode': return 'Visual Studio Code';
  }
  if (/opencode/i.test(env.__CFBundleIdentifier || '')) return 'OpenCode';
  return null;
}

function send(ev) {
  fetch(`http://127.0.0.1:${PORT}/event`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(ev),
    signal: AbortSignal.timeout(500),
  }).catch(() => {});
}

export const AgentDots = async ({ directory }) => {
  const app = hostApp();
  // Agent Dots reads T3 Code's threads from T3 itself (titles, approvals, deep links).
  if (app === 'T3 Code (Beta)') return {};
  const dir = path.basename(directory || '') || 'opencode';
  const sessions = new Map(); // id -> { title, child }
  const seen = new Set();
  const last = new Map(); // id -> last event, re-sent so an overlay restart recovers

  const set = (id, state) => {
    if (!id) return;
    const s = sessions.get(id);
    if (s?.child) return; // subagents roll up into their parent
    const title = s?.title && !/^New session/i.test(s.title) ? s.title : dir;
    const ev = { session: `opencode:${id}`, state, label: `OpenCode · ${title}`, app };
    last.set(id, ev);
    send(ev);
  };

  setInterval(() => {
    for (const [id, ev] of last) {
      if (ev.state === 'working' || ev.state === 'attention') send(ev);
      else last.delete(id); // finished: say it once, don't resurrect it after a click
    }
  }, 20_000).unref?.();

  return {
    event: async ({ event }) => {
      const p = event.properties || {};
      if (DEBUG && !seen.has(event.type)) {
        seen.add(event.type);
        fs.appendFileSync(DEBUG, `${event.type} ${JSON.stringify(p).slice(0, 300)}\n`);
      }
      switch (event.type) {
        case 'session.created':
        case 'session.updated':
          if (p.info?.id) sessions.set(p.info.id, { title: p.info.title, child: !!p.info.parentID });
          break;
        case 'session.status': {
          const t = p.status?.type;
          if (t === 'busy' || t === 'retry') set(p.sessionID, 'working');
          else if (t === 'idle') set(p.sessionID, 'done');
          break;
        }
        case 'session.idle':
          set(p.sessionID, 'done');
          break;
        case 'session.error':
          set(p.sessionID, 'error');
          break;
        case 'permission.updated':
        case 'permission.asked':
        case 'question.asked':
          set(p.sessionID, 'attention');
          break;
        case 'permission.replied':
        case 'question.replied':
        case 'question.rejected':
          set(p.sessionID, 'working');
          break;
        case 'session.deleted':
          if (p.info?.id) set(p.info.id, 'idle');
          break;
      }
    },
  };
};
