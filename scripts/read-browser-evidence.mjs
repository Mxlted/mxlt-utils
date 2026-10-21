#!/usr/bin/env node
// Read-only CDP collection from the disposable browser fixture. No input dispatch.
import { readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const profileIndex = args.indexOf('--profile');
if (profileIndex < 0 || !args[profileIndex + 1]) {
  console.error('Usage: node scripts/read-browser-evidence.mjs --profile build/chrome-fixture.XXXXXX');
  process.exit(1);
}

async function readTarget(target, port) {
  const address = new URL(target.webSocketDebuggerUrl);
  if (address.protocol !== 'ws:' || !['127.0.0.1', 'localhost', '[::1]'].includes(address.hostname)
      || Number(address.port) !== port || !address.pathname.startsWith('/devtools/page/')) {
    throw new Error('Refusing a nonlocal fixture debugging endpoint');
  }
  const socket = new WebSocket(address);
  try {
    const result = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Fixture evidence request timed out')), 4_000);
      const finish = (error, value) => {
        clearTimeout(timeout);
        if (error) reject(error); else resolve(value);
      };
      socket.addEventListener('error', () => finish(new Error('Could not read the fixture debugging endpoint')), { once: true });
      socket.addEventListener('open', () => socket.send(JSON.stringify({
        id: 1, method: 'Runtime.evaluate',
        params: { expression: 'window.fixtureEvidence()', returnByValue: true, timeout: 2_000 }
      })), { once: true });
      socket.addEventListener('message', event => {
        try {
          const message = JSON.parse(event.data);
          if (message.id !== 1) return;
          if (message.error || message.result?.exceptionDetails) {
            finish(new Error('The fixture page did not expose valid evidence'));
          } else { finish(null, message.result?.result?.value); }
        } catch (error) { finish(error); }
      });
    });
    if (result?.fixture !== 'mxlt-utils-browser' || result?.schema !== 1) {
      throw new Error('Refusing evidence from a different page');
    }
    return { targetID: target.id, evidence: result };
  } finally { socket.close(); }
}

try {
  if (typeof WebSocket !== 'function') throw new Error('Use Node.js 22 or newer for the built-in WebSocket client');
  const build = await realpath(path.join(root, 'build'));
  const profile = await realpath(args[profileIndex + 1]);
  if (path.dirname(profile) !== build || !path.basename(profile).startsWith('chrome-fixture.')) {
    throw new Error('Use a fresh build/chrome-fixture.* profile, never a personal browser profile');
  }
  const active = (await readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/);
  const port = Number(active[0]);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !active[1]?.startsWith('/devtools/browser/')) {
    throw new Error('Invalid disposable-profile debugging endpoint');
  }
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(3_000) });
  if (!response.ok) throw new Error('Could not list disposable browser fixture tabs');
  const targets = await response.json();
  const fixtureURL = pathToFileURL(path.join(root, 'scripts/fixtures/BrowserFixture.html')).href;
  const fixtures = targets.filter(target => target.type === 'page' &&
    (target.url === fixtureURL || target.url.startsWith(`${fixtureURL}?`)));
  if (fixtures.length === 0 || fixtures.length > 20) throw new Error('Expected between 1 and 20 exact local fixture tabs');
  const tabs = [];
  for (const target of fixtures) tabs.push(await readTarget(target, port));
  console.log(JSON.stringify({
    evidence: 'Read-only CDP aggregate snapshot; input source must be recorded separately',
    fixtureTabCount: tabs.length, openedLinkTabCount: tabs.filter(tab => tab.evidence.openedLink).length, tabs
  }, null, 2));
} catch (error) {
  console.error(JSON.stringify({ passed: false, error: error.message }));
  process.exit(1);
}
