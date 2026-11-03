import { chmod, lstat, mkdir, open, rename, unlink } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createObserver } from './mapper.js';

const ROOT = join(homedir(), 'Library', 'Application Support', 'Agent Watch');
const EVENTS = join(ROOT, 'events');
const pending = [];
let draining = false;
export const inject = ['sessions', 'agents'];

async function ensurePrivateDirectory(path) {
  try {
    const stat = await lstat(path);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('invalid output directory');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await mkdir(path, { recursive: true, mode: 0o700 });
  }
  await chmod(path, 0o700);
}

async function drain() {
  try {
    while (pending.length) {
      const event = pending.shift();
      const temporary = join(EVENTS, `.agent-watch-${randomUUID()}.tmp`);
      let handle;
      try {
        await ensurePrivateDirectory(ROOT);
        await ensurePrivateDirectory(EVENTS);
        handle = await open(temporary, 'wx', 0o600);
        await handle.writeFile(JSON.stringify(event));
        await handle.sync();
        await handle.close();
        handle = undefined;
        await rename(temporary, join(EVENTS, `${event.id}.json`));
      } catch {
        if (handle) await handle.close().catch(() => {});
        await unlink(temporary).catch(() => {});
      }
    }
  } finally { draining = false; }
}

function enqueue(event) {
  // Never make DSH's event dispatcher wait for filesystem I/O.
  // If overloaded, drop observations; the monitor ages missing evidence to unknown.
  if (!event || pending.length >= 512) return;
  pending.push(event);
  if (!draining) {
    draining = true;
    queueMicrotask(() => { void drain(); });
  }
}

export function apply(ctx) {
  const observer = createObserver(enqueue);
  ctx.on('session/event', observer.onSessionEvent);
  ctx.on('session/disposed', observer.onSessionDisposed);
  ctx.on('agent/status', observer.onAgentStatus);
}
