// Renders Cuelume cues to WAV files in assets/sounds/ so the Rust app can embed them.
// Cuelume synthesizes live with Web Audio, so we run it in headless Chrome and swap
// its AudioContext for an OfflineAudioContext.
//
//   npm i --no-save cuelume playwright-core && node scripts/render-cues.mjs
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright-core';

const CUES = { done: 'success', error: 'error', attention: 'attention' };
const OUT = path.resolve('assets/sounds');
const ROOT = path.resolve('node_modules/cuelume/dist');

const server = http
  .createServer((req, res) => {
    if (req.url === '/') {
      res.setHeader('content-type', 'text/html');
      return res.end('<!doctype html><html></html>');
    }
    const file = path.join(ROOT, decodeURIComponent(req.url.split("?")[0]));
    if (!file.startsWith(ROOT) || !fs.existsSync(file)) return res.writeHead(404).end();
    res.setHeader('content-type', 'text/javascript');
    res.end(fs.readFileSync(file));
  })
  .listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const browser = await chromium.launch({ channel: 'chrome' });
fs.mkdirSync(OUT, { recursive: true });

for (const [state, cue] of Object.entries(CUES)) {
  // fresh page per cue: cuelume keeps one AudioContext per page
  const page = await browser.newPage();
  await page.goto(base + '/');
  const b64 = await page.evaluate(
    async ({ base, cue, state }) => {
      const rate = 48000;
      const ctx = new OfflineAudioContext(2, rate * 2, rate);
      Object.defineProperty(ctx, 'state', { get: () => 'running' });
      window.AudioContext = function () { return ctx; };
      // fresh module instance per cue, so it picks up this context
      const { play } = await import(`${base}/index.js?${state}`);
      play(cue, { emphasis: 'normal' });
      const buf = await ctx.startRendering();

      // trim trailing silence, encode 16-bit PCM WAV
      const ch = [buf.getChannelData(0), buf.getChannelData(1)];
      let end = buf.length;
      while (end > 0 && Math.abs(ch[0][end - 1]) < 1e-4 && Math.abs(ch[1][end - 1]) < 1e-4) end--;
      const view = new DataView(new ArrayBuffer(44 + end * 4));
      const str = (o, s) => [...s].forEach((c, i) => view.setUint8(o + i, c.charCodeAt(0)));
      str(0, 'RIFF'); view.setUint32(4, 36 + end * 4, true); str(8, 'WAVEfmt ');
      view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 2, true);
      view.setUint32(24, rate, true); view.setUint32(28, rate * 4, true);
      view.setUint16(32, 4, true); view.setUint16(34, 16, true);
      str(36, 'data'); view.setUint32(40, end * 4, true);
      for (let i = 0; i < end; i++)
        for (let c = 0; c < 2; c++) {
          const v = Math.max(-1, Math.min(1, ch[c][i]));
          view.setInt16(44 + i * 4 + c * 2, v * 0x7fff, true);
        }
      let s = '';
      new Uint8Array(view.buffer).forEach((b) => (s += String.fromCharCode(b)));
      return btoa(s);
    },
    { base, cue, state },
  );
  await page.close();
  const file = path.join(OUT, `${state}.wav`);
  fs.writeFileSync(file, Buffer.from(b64, 'base64'));
  console.log(`${cue} -> ${path.relative(process.cwd(), file)} (${fs.statSync(file).size} bytes)`);
}

await browser.close();
server.close();
