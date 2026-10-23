// Tracking the game process behind the runtime port.
//
// run_project spawns a game whose MCPRuntime autoload listens on the runtime
// port. Anything else can hold that port too: a game the editor runs embedded
// (it inherits GOPEAK_RUNTIME_PORT from the editor gopeak launched), or a `-d`
// run left over from an earlier session. Runtime commands used to go to
// whoever answered, so screenshots and calls silently drove a stale game.
// The autoload names itself (pid, project, embedded) in its welcome frame;
// these helpers read that and end stale runs of the same project.

import { createConnection } from 'node:net';
import { existsSync, realpathSync } from 'node:fs';
import { resolve } from 'node:path';

export const RUNTIME_HOST = '127.0.0.1';

export function getRuntimePort(): number {
  // Configurable so two projects can each run their game under runtime
  // verification at the same time. Mirrors the Godot-side autoload, which
  // reads the same variable.
  const override = Number.parseInt(process.env.GOPEAK_RUNTIME_PORT || '', 10);
  return Number.isInteger(override) && override > 0 && override < 65536 ? override : 7777;
}

export interface RuntimeIdentity {
  pid?: number;
  projectPath?: string;
  embedded?: boolean;
}

export type RuntimeProbe =
  | { state: 'free' }
  | { state: 'unresponsive' }
  | ({ state: 'up' } & RuntimeIdentity);

export function identityFromMessage(message: any): RuntimeIdentity {
  return {
    pid: typeof message?.pid === 'number' ? message.pid : undefined,
    projectPath: typeof message?.project_path === 'string' ? message.project_path : undefined,
    embedded: typeof message?.embedded === 'boolean' ? message.embedded : undefined,
  };
}

/**
 * Split a runtime TCP buffer into JSON messages. Godot's put_utf8_string()
 * frames each message with a 4-byte little-endian length; plain
 * newline-delimited JSON is accepted too. Returns the unconsumed rest.
 */
export function parseRuntimeFrames(buffer: Buffer): { messages: any[]; rest: Buffer } {
  const messages: any[] = [];
  const parseCandidate = (candidate: string) => {
    const trimmed = candidate.trim();
    if (!trimmed) return;
    try {
      messages.push(JSON.parse(trimmed));
    } catch {
      // Ignore a malformed frame/line and keep scanning.
    }
  };

  let rest = buffer;
  let offset = 0;
  while (offset + 4 <= rest.length) {
    const frameLength = rest.readUInt32LE(offset);
    if (frameLength <= 0 || offset + 4 + frameLength > rest.length) break;
    parseCandidate(rest.subarray(offset + 4, offset + 4 + frameLength).toString('utf8'));
    offset += 4 + frameLength;
  }
  if (offset > 0) rest = rest.subarray(offset);

  let newlineIndex = rest.indexOf(0x0a);
  while (newlineIndex !== -1) {
    parseCandidate(rest.subarray(0, newlineIndex).toString('utf8'));
    rest = rest.subarray(newlineIndex + 1);
    newlineIndex = rest.indexOf(0x0a);
  }
  return { messages, rest };
}

/** Who holds the runtime port: nobody, a silent holder, or a runtime that greeted us. */
export function probeRuntime(port = getRuntimePort(), timeoutMs = 2000): Promise<RuntimeProbe> {
  return new Promise((resolvePromise) => {
    let settled = false;
    let buffer = Buffer.alloc(0);
    const socket = createConnection({ port, host: RUNTIME_HOST });
    const finish = (result: RuntimeProbe) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolvePromise(result);
    };
    const timer = setTimeout(() => finish({ state: 'unresponsive' }), timeoutMs);
    socket.on('data', (chunk: Buffer) => {
      const parsed = parseRuntimeFrames(Buffer.concat([buffer, chunk]));
      buffer = parsed.rest;
      const welcome = parsed.messages.find((m) => m?.type === 'welcome');
      if (welcome) finish({ state: 'up', ...identityFromMessage(welcome) });
    });
    socket.on('error', (error: NodeJS.ErrnoException) => {
      finish(error.code === 'ECONNREFUSED' ? { state: 'free' } : { state: 'unresponsive' });
    });
    socket.on('close', () => finish({ state: 'unresponsive' }));
  });
}

export function samePath(a: string | undefined | null, b: string | undefined | null): boolean {
  if (!a || !b) return false;
  const canonical = (p: string) => {
    const absolute = resolve(p);
    const real = existsSync(absolute) ? realpathSync(absolute) : absolute;
    return real.replace(/[\\/]+$/, '');
  };
  return canonical(a) === canonical(b);
}

export function isPidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
}

export async function waitFor(check: () => boolean | Promise<boolean>, timeoutMs: number, intervalMs = 100): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await check()) return true;
    if (Date.now() >= deadline) return false;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

/** SIGTERM, then SIGKILL after graceMs. Resolves true once the pid is gone. */
export async function terminatePid(pid: number, graceMs = 3000): Promise<boolean> {
  try {
    process.kill(pid, 'SIGTERM');
  } catch {
    return !isPidAlive(pid);
  }
  if (await waitFor(() => !isPidAlive(pid), graceMs)) return true;
  try {
    process.kill(pid, 'SIGKILL');
  } catch {}
  return waitFor(() => !isPidAlive(pid), 2000);
}

/** Wait until nothing listens on the runtime port. */
export function waitForRuntimePortFree(port = getRuntimePort(), timeoutMs = 3000): Promise<boolean> {
  return waitFor(async () => (await probeRuntime(port, 500)).state === 'free', timeoutMs, 150);
}
