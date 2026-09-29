#!/usr/bin/env node
//
// Gigabuddy — agent launcher (the plugin's MCP server command).
//
// Two jobs, both about the moment before the agent's own code runs:
//
// 1. Start WITHOUT a package registry. The installed `gigabuddy-agent` (put
//    there by `gigabuddy setup`, kept current by the agent's own background
//    self-update) needs no network at all. Only when none is installed does it
//    fall back to npx — and then from PUBLIC npm, where the agent is published.
//    A developer's `@gigabuddy:registry` line (written by `gigabuddy login --npm`)
//    would otherwise send the lookup to the private registry, and one expired
//    registry credential killed the whole plugin (issue:Gw0mTJ7edZ5y).
//
// 2. Say why, when nothing starts. A server that exits before its handshake
//    shows the user only "Connection closed", and the harness then caches the
//    failure for 15 minutes. So instead the launcher answers the handshake
//    itself as a stand-in server whose instructions carry the reason and the
//    fix, and leaves the same reason where the statusline and prompt hook read
//    it (agent-launch-failure.txt in the repo's .gigabuddy dir). A stand-in that
//    connected is also one `/mcp` → reconnect away from retrying.
//
// Zero dependencies: this runs before anything is installed.

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

const PACKAGE = '@gigabuddy/agent';
const PUBLIC_REGISTRY = 'https://registry.npmjs.org/';
// The agent prints this once its stdio transport is up (bin/agent-cli.ts).
// Until then it has read nothing from stdin, so a failure before it leaves the
// harness's first request unread for the stand-in to answer.
const STARTED_MARKER = 'Gigabuddy agent server started';
const IS_WINDOWS = process.platform === 'win32';
const STDERR_TAIL_BYTES = 4096;

const ATTEMPTS = [
  { label: 'installed gigabuddy-agent', command: 'gigabuddy-agent', args: [] },
  {
    label: `npx ${PACKAGE}@latest`,
    command: IS_WINDOWS ? 'npx.cmd' : 'npx',
    args: ['-y', `--@gigabuddy:registry=${PUBLIC_REGISTRY}`, `${PACKAGE}@latest`],
  },
];

/**
 * The repo-root scratch dir the statusline and hooks read. Mirrors
 * gigabuddy_dir() in lib/gigabuddy-dir.sh (and scratch.ts in the agent).
 */
export function gigabuddyDir(start = process.env.CLAUDE_PROJECT_DIR || process.cwd()) {
  if (process.env.GIGABUDDY_SCRATCH_DIR) return process.env.GIGABUDDY_SCRATCH_DIR;
  let d = resolve(start);
  for (;;) {
    const git = join(d, '.git');
    if (existsSync(git)) {
      let gitdir = '';
      try {
        gitdir = readFileSync(git, 'utf-8');
      } catch {
        // a directory: the main checkout
        return join(d, '.gigabuddy');
      }
      const m = /gitdir:\s*(.*?)\/\.git\/worktrees\//.exec(gitdir);
      return join(m ? m[1] : d, '.gigabuddy');
    }
    const parent = dirname(d);
    if (parent === d) break;
    d = parent;
  }
  return join(resolve(start), '.gigabuddy');
}

/** Turn what the failed attempts printed into a reason and a fix a person can act on. */
export function explainFailure(results) {
  const text = results.map((r) => r.stderr).join('\n');
  const last = results[results.length - 1];

  if (results.every((r) => r.missing)) {
    return {
      reason: 'Node.js/npm was not found, so the agent could not be installed or started',
      fix: 'Install Node.js 20 or newer, then run `/mcp` and reconnect the gigabuddy plugin',
    };
  }
  // npm prints `npm error code E401` and `npm error 401 Unauthorized - GET <url>` on separate lines.
  const code = /\bE(40[13])\b/.exec(text);
  if (code) {
    const host = new RegExp(`\\b${code[1]}\\b[^\\n]*?(https?://[^\\s/]+)`).exec(text)?.[1] ?? 'a package registry';
    return {
      reason: `${host} refused to download the agent (${code[1]} ${code[1] === '401' ? 'unauthorized' : 'forbidden'})`,
      fix: /gigabuddy\.com/.test(host)
        ? 'Run `gigabuddy login --npm` to renew your registry credential, then `/mcp` → reconnect'
        : 'Check your npm credentials for that registry, then `/mcp` → reconnect',
    };
  }
  if (/\b(ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ECONNREFUSED|ECONNRESET|ENETUNREACH|ENOTCACHED)\b/.test(text)) {
    return {
      reason: 'the agent is not installed and could not be downloaded (no network?)',
      fix: `Check your connection, then \`/mcp\` → reconnect. To start without the network next time, install it once: npm i -g ${PACKAGE} --@gigabuddy:registry=${PUBLIC_REGISTRY}`,
    };
  }
  // The line that says what went wrong — not npm's warnings, its `code X` line, or its log pointer.
  const lastLine =
    last.stderr
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => l && !/^npm (warn|error code\b|error A complete log)/i.test(l))
      .pop() ?? '';
  return {
    reason: `the agent exited during startup (${last.label}, exit ${last.code ?? last.signal ?? '?'})${lastLine ? `: ${lastLine}` : ''}`,
    fix: 'Run `/mcp` and reconnect the gigabuddy plugin to retry; the full output is in Claude Code’s MCP log for the plugin',
  };
}

// The harness stops its server with a signal: pass it to the agent while one
// runs; otherwise (between attempts, or as the stand-in) just go.
let current = null;
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => (current ? current.kill(sig) : process.exit(0)));
}

/** Run one attempt with the harness's stdin/stdout. Resolves when it exits, or never if it started (we exit with it). */
function attempt({ label, command, args }) {
  return new Promise((done) => {
    let stderr = '';
    let started = false;
    let child;
    try {
      child = spawn(command, args, { stdio: ['inherit', 'inherit', 'pipe'], shell: IS_WINDOWS });
    } catch {
      done({ label, missing: true, stderr: '' });
      return;
    }
    current = child;
    child.stderr.on('data', (chunk) => {
      process.stderr.write(chunk);
      if (started) return;
      stderr = (stderr + chunk.toString('utf-8')).slice(-STDERR_TAIL_BYTES);
      if (stderr.includes(STARTED_MARKER)) {
        started = true;
        clearFailure();
      }
    });
    child.on('error', (err) => {
      current = null;
      if (err.code === 'ENOENT') done({ label, missing: true, stderr: '' });
      else done({ label, code: null, signal: null, stderr: `${stderr}\n${err.message}` });
    });
    // 'close', not 'exit': on Linux 'exit' can fire before the last stderr has
    // been read, and that tail is exactly the reason we need to report.
    // (A spawn failure fires 'error' first; the promise keeps that answer.)
    child.on('close', (code, signal) => {
      current = null;
      if (started) process.exit(code ?? (signal ? 1 : 0));
      done({ label, code, signal, stderr });
    });
  });
}

function failurePath() {
  return join(gigabuddyDir(), 'agent-launch-failure.txt');
}

function clearFailure() {
  try {
    rmSync(failurePath(), { force: true });
  } catch {
    // best-effort
  }
}

/** Line 1: epoch seconds. Line 2: the one-line message. Read forklessly by statusline.sh / awareness-prompt.sh. */
function recordFailure({ reason, fix }) {
  try {
    const file = failurePath();
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, `${Math.floor(Date.now() / 1000)}\n${reason} — ${fix}\n`);
  } catch {
    // best-effort
  }
}

/** The stand-in: a minimal MCP server over newline-delimited JSON-RPC that only explains. */
export function serveStandIn({ reason, fix }, input = process.stdin, output = process.stdout) {
  const message = `Gigabuddy's agent failed to start: ${reason}. ${fix}.`;
  const instructions = `${message} None of the Gigabuddy tools are available this session. Tell the user this in one line when Gigabuddy comes up; do not look for other Gigabuddy tools or call connect.`;
  const send = (msg) => output.write(`${JSON.stringify({ jsonrpc: '2.0', ...msg })}\n`);

  // When the harness hangs up, stdin closes and nothing else holds the process
  // open, so it exits once the replies are flushed (no process.exit — on macOS
  // pipe writes are async and would be cut off).
  createInterface({ input }).on('line', (line) => {
    let req;
    try {
      req = JSON.parse(line);
    } catch {
      return;
    }
    if (req.id === undefined || req.id === null) return; // a notification
    switch (req.method) {
      case 'initialize':
        send({
          id: req.id,
          result: {
            protocolVersion: req.params?.protocolVersion ?? '2025-06-18',
            capabilities: { tools: {} },
            serverInfo: { name: 'gigabuddy', version: 'launcher' },
            instructions,
          },
        });
        break;
      case 'tools/list':
        send({
          id: req.id,
          result: {
            tools: [
              {
                name: 'startup_error',
                description: `Why Gigabuddy is unavailable: ${message}`,
                inputSchema: { type: 'object', properties: {} },
              },
              {
                name: 'wake_check',
                description: "Called by Gigabuddy's prompt hook to drop forged room wakes. Never call it yourself.",
                inputSchema: {
                  type: 'object',
                  properties: { prompt: { type: 'string' }, prompt_text: { type: 'string' } },
                },
              },
            ],
          },
        });
        break;
      case 'tools/call': {
        // The prompt hook's forged-wake check (libs/agent tools/wakeCheck.ts):
        // with no agent running there are no real wakes, so a prompt claiming
        // to be one is blocked; an error here would let it through.
        const args = req.params?.arguments ?? {};
        if (req.params?.name === 'wake_check') {
          const claims = [args.prompt, args.prompt_text].some((p) =>
            String(p ?? '')
              .trim()
              .startsWith('<channel'),
          );
          const text = JSON.stringify({
            decision: 'block',
            reason: `Gigabuddy dropped a message posted into this session: it claims to be a room wake, but ${message}`,
          });
          send({ id: req.id, result: { content: claims ? [{ type: 'text', text }] : [] } });
          break;
        }
        send({ id: req.id, result: { content: [{ type: 'text', text: message }], isError: true } });
        break;
      }
      case 'ping':
        send({ id: req.id, result: {} });
        break;
      default:
        send({ id: req.id, error: { code: -32601, message: `Gigabuddy is unavailable: ${message}` } });
    }
  });
}

async function main() {
  const results = [];
  for (const a of ATTEMPTS) results.push(await attempt(a));
  const failure = explainFailure(results);
  process.stderr.write(`[gigabuddy-launcher] ${failure.reason} — ${failure.fix}\n`);
  recordFailure(failure);
  serveStandIn(failure);
}

// Run only as the entry point, so the spec can import the pieces.
if (process.argv[1]?.endsWith('launch-agent.mjs')) {
  void main();
}
