#!/usr/bin/env node
// End-to-end check that run_project / stop_project track the game they start
// and deal with stale runs squatting the runtime port. Spawns real (headless)
// Godot games, so it is opt-in: npm run test:runtime-process. Needs a build.
import { spawn } from 'node:child_process';
import { createServer, createConnection } from 'node:net';
import { cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const GODOT_BIN = [process.env.GODOT_PATH, '/Applications/Godot.app/Contents/MacOS/Godot', '/usr/local/bin/godot', '/usr/bin/godot']
  .filter(Boolean).find((p) => existsSync(p));
if (!GODOT_BIN) {
  console.log('runtime process test skipped (Godot not found; set GODOT_PATH)');
  process.exit(0);
}

const root = mkdtempSync(join(tmpdir(), 'gopeak-runtime-process-'));
const serverJs = new URL('./build/index.js', import.meta.url).pathname;
const PORT = 20000 + Math.floor(Math.random() * 20000);
const GODOT = join(root, 'godot-headless.sh');
// exec keeps the pid, so the pid the server spawns is the game's.
writeFileSync(GODOT, `#!/bin/sh\nexec "${GODOT_BIN}" --headless "$@"\n`);
chmodSync(GODOT, 0o755);

function makeProject(name, withRuntime) {
  const dir = join(root, name);
  mkdirSync(join(dir, 'addons'), { recursive: true });
  cpSync(new URL('./src/addon/godot_mcp_runtime', import.meta.url).pathname, join(dir, 'addons', 'godot_mcp_runtime'), { recursive: true });
  writeFileSync(join(dir, 'project.godot'), `config_version=5\n\n[application]\nconfig/name="${name}"\nrun/main_scene="res://main.tscn"\n`
    + (withRuntime ? '\n[autoload]\nMCPRuntime="*res://addons/godot_mcp_runtime/mcp_runtime_autoload.gd"\n' : ''));
  writeFileSync(join(dir, 'main.gd'), 'extends Node2D\nvar alive: bool = true\nfunc teleport(to: Vector2, keep_alive: bool) -> String:\n\tposition = to\n\talive = keep_alive\n\treturn "%s %s" % [position, alive]\n');
  writeFileSync(join(dir, 'main.tscn'), '[gd_scene format=3]\n\n[ext_resource type="Script" path="res://main.gd" id="1"]\n\n[node name="Main" type="Node2D"]\nscript = ExtResource("1")\n');
}
makeProject('projA', true);
makeProject('projB', true);
makeProject('projC', false);

const env = { ...process.env, GOPEAK_RUNTIME_PORT: String(PORT), GODOT_PATH: GODOT, GOPEAK_BRIDGE_PORT: String(PORT + 1), GOPEAK_TOOL_PROFILE: 'full' };
const results = [];
const check = (name, ok, detail = '') => { results.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${ok ? '' : `\n     ${String(detail).slice(0, 600)}`}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

function welcome() {
  return new Promise((resolve) => {
    const s = createConnection({ port: PORT, host: '127.0.0.1' });
    let buf = Buffer.alloc(0);
    const t = setTimeout(() => { s.destroy(); resolve(null); }, 1000);
    s.on('data', (c) => { buf = Buffer.concat([buf, c]); if (buf.length >= 4 && buf.length >= 4 + buf.readUInt32LE(0)) { clearTimeout(t); s.destroy(); resolve(JSON.parse(buf.subarray(4, 4 + buf.readUInt32LE(0)).toString())); } });
    s.on('error', () => { clearTimeout(t); resolve(null); });
  });
}
async function startStray(project) {
  const p = spawn(GODOT, ['--path', `${root}/${project}`], { env, stdio: 'ignore', detached: true });
  p.unref();
  for (let i = 0; i < 60; i++) { const w = await welcome(); if (w?.pid === p.pid) return p.pid; await sleep(250); }
  throw new Error(`stray ${project} never answered`);
}

const srv = spawn(process.execPath, [serverJs], { env, stdio: ['pipe', 'pipe', 'pipe'] });
let out = '';
const pending = new Map();
srv.stdout.on('data', (c) => { out += c; let i; while ((i = out.indexOf('\n')) >= 0) { const line = out.slice(0, i); out = out.slice(i + 1); try { const m = JSON.parse(line); pending.get(m.id)?.(m); } catch {} } });
let nextId = 1;
const rpc = (method, params) => new Promise((resolve) => { const id = nextId++; pending.set(id, resolve); srv.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); });
const call = async (name, args) => { const r = await rpc('tools/call', { name, arguments: args }); return r.result?.content?.map((c) => c.text).join('\n') ?? JSON.stringify(r); };

try {
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'e2e', version: '1' } });
  srv.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} }) + '\n');
  const A = `${root}/projA`;

  // 1. A stray run of projA squats the runtime port; run_project must end it and own the port.
  let stray = await startStray('projA');
  let text = await call('get_runtime_status', { projectPath: A });
  check('status attaches to an editor/stray run when run_project started nothing', text.includes('"connected": true') && text.includes(`"pid": ${stray}`), text);
  text = await call('run_project', { projectPath: A });
  const ourPid = Number(/pid (\d+)\)\. Use/.exec(text)?.[1]);
  check('run_project ends the stale same-project run', text.includes('Ended a stale run') && !alive(stray), text);
  check('run_project waits for its own runtime', text.includes(`Runtime addon answering on port ${PORT} (pid ${ourPid})`) && (await welcome())?.pid === ourPid, text);

  // 2. Runtime values reach the new game, converted.
  text = await call('set_runtime_property', { projectPath: A, nodePath: '/root/Main', property: 'position', value: '[10, 20]' });
  check('set_runtime_property Vector2 from "[10, 20]"', /"new_value":\s*{[^}]*"x": 10\.0,\s*"y": 20\.0/s.test(text) || text.includes('"x": 10'), text);
  text = await call('set_runtime_property', { projectPath: A, nodePath: '/root/Main', property: 'alive', value: 'false' });
  check('set_runtime_property bool from "false"', text.includes('"new_value": false'), text);
  text = await call('call_runtime_method', { projectPath: A, nodePath: '/root/Main', method: 'teleport', args: ['{"x": 3, "y": 4}', 'true'] });
  check('call_runtime_method converts typed args', text.includes('(3.0, 4.0) true'), text);

  // 3. stop_project ends our run and waits for it.
  text = await call('stop_project', { reason: 'e2e' });
  check('stop_project ends the run_project game', text.includes(`"pid": ${ourPid}`) && !alive(ourPid) && (await welcome()) === null, text);

  // 4. stop_project with nothing started still ends a stray run of this project.
  stray = await startStray('projA');
  text = await call('stop_project', { reason: 'e2e', projectPath: A });
  check('stop_project ends a stray run of the same project', text.includes(`"pid": ${stray}`) && !alive(stray), text);

  // 5. Another project's game on the port is not touched, and run_project refuses.
  const strayB = await startStray('projB');
  text = await call('run_project', { projectPath: A });
  check('run_project refuses when another project holds the port', text.includes('projB') && alive(strayB), text);
  text = await call('stop_project', { reason: 'e2e', projectPath: A });
  check('stop_project leaves another project alone', text.includes('No active Godot process') && alive(strayB), text);
  process.kill(strayB, 'SIGKILL');
  await sleep(500);

  // 6. A stale holder that appears after run_project is refused, not driven.
  text = await call('run_project', { projectPath: `${root}/projC` });
  const pidC = Number(/pid (\d+)\)\. Use/.exec(text)?.[1]);
  const fake = createServer((sock) => {
    const body = Buffer.from(JSON.stringify({ type: 'welcome', pid: 999999, project_path: '/elsewhere', embedded: true }) + '\n');
    const len = Buffer.alloc(4); len.writeUInt32LE(body.length);
    sock.write(Buffer.concat([len, body]));
    sock.on('data', () => { fakeGotCommand = true; });
  });
  let fakeGotCommand = false;
  await new Promise((r) => fake.listen(PORT, '127.0.0.1', r));
  text = await call('call_runtime_method', { projectPath: `${root}/projC`, nodePath: '/root/Main', method: 'teleport', args: [] });
  check('runtime command refused when a different pid holds the port', text.includes('Refused') && text.includes('999999') && text.includes('editor-embedded') && !fakeGotCommand, text);
  await new Promise((r) => fake.close(r));
  text = await call('stop_project', { reason: 'e2e' });
  check('stop_project ends a run without the runtime addon', text.includes(`"pid": ${pidC}`) && !alive(pidC), text);
} finally {
  srv.kill('SIGTERM');
  await sleep(500);
  rmSync(root, { recursive: true, force: true });
}
console.log(results.every(Boolean) ? 'ALL PASS' : 'SOME FAILED');
process.exit(results.every(Boolean) ? 0 : 1);
