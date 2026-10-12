/**
 * The Gigabuddy mod — Gigabuddy driving this Claude Code session from its live
 * record (page:ihuoK970I4i8, decision:FWFiBJHe8lPw).
 *
 * The plugin's own MCP server (`agent`) already holds the live connection to
 * Gigabuddy, and this module does one thing: a loop collects what the person
 * sent from the session view (bounded waits, re-armed from a timer, so nothing
 * polls a server). A message is submitted as the person's own words
 * (`$.prompt.submit` with `asUser`, a turn of its own once the session is
 * idle); a Stop ends the running turn.
 *
 * The wait runs over the agent's private socket (`$.http.fetch`), which
 * `session_commands_socket` names. Never over `$.mcp.call` when it can be
 * helped: an MCP call in flight is moved to a background task whenever a
 * message reaches the session, and its result then reaches the MODEL as a task
 * notification. That put an "MCP task … session_commands_wait completed"
 * notice on nearly every prompt. Only an agent older than the socket gets the
 * MCP wait (`session_commands_wait`).
 *
 * It does NOT decide tool prompts. A mod can only replace Claude Code's own
 * permission dialog with a prompt of its own, which loses the dialog's choices
 * (don't ask again, this session, the suggested rules, auto mode) — Daniel,
 * 2026-10-09: not until a mod's prompt is at least as good. Answering the real
 * dialog from Gigabuddy is the channel relay's job (libs/agent channel.ts),
 * for a session launched with the channel: `claude
 * --dangerously-load-development-channels plugin:gigabuddy@gigabuddy`. The
 * server-side tools for a mod-driven approval (`permission_check` and
 * friends) stay, unused, for when that prompt is built.
 *
 * A hook's budget counts its own time only, never a `$` call in flight, so the
 * waits cost nothing. Nothing here runs under `-p` (no one to ask).
 */
import type { EngineInterface, Register } from 'claude-code';

/** The server's key in this plugin's .mcp.json. */
const SERVER_KEY = 'agent';
/** One bounded wait on the server; the tools cap it there too. */
const WAIT_MS = 25_000;
/** Between two inbound waits — a breath, not a poll: the wait itself blocks until something arrives. */
const REARM_MS = 50;
/** After a failed wait, before asking the agent again where to wait (it may have restarted). */
const RETRY_MS = 5_000;

/** A JSON object from text; `{}` when it is not one. */
function parseJson(text: string | undefined): Record<string, unknown> {
  if (!text) return {};
  try {
    const parsed = JSON.parse(text) as unknown;
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** The first text block of an MCP result, parsed as JSON; `{}` when it is not. */
function parse(result: { content: Array<{ type: string; text?: string }> }): Record<string, unknown> {
  return parseJson(result.content.find((c) => c.type === 'text')?.text);
}

/** Where the inbound loop waits: the agent's private socket, or MCP for an agent older than it. */
type Inbound = { kind: 'socket'; socketPath: string; token: string } | { kind: 'mcp' };

/** What the inbound loop needs of the module: the server, where it waits, and the running turn for Stop. */
type Link = { server: string | null; inbound: Inbound | null; socketFailures: number; turnId: string | null };

/** Socket waits that may fail in a row (the agent restarted, a fresh socket) before the loop settles for MCP. */
const SOCKET_FAILURES_MAX = 2;

/** Ask the agent where to wait. Null: nothing to collect (the launcher's stand-in, with no agent running). */
async function locate($: EngineInterface, server: string): Promise<Inbound | null> {
  try {
    const result = await $.mcp.call(server, 'session_commands_socket');
    // An agent without the verb, or one that could not open its socket.
    if (result.isError) return { kind: 'mcp' };
    const { socketPath, token } = parse(result);
    return typeof socketPath === 'string' && typeof token === 'string' ? { kind: 'socket', socketPath, token } : null;
  } catch {
    return { kind: 'mcp' };
  }
}

/** One bounded wait: everything held, the next command, or nothing after WAIT_MS. */
async function wait($: EngineInterface, server: string, inbound: Inbound): Promise<unknown> {
  if (inbound.kind === 'mcp')
    return parse(await $.mcp.call(server, 'session_commands_wait', { timeout_ms: WAIT_MS }))['commands'];
  const res = await $.http.fetch(`http://agent/commands?wait=${WAIT_MS}`, {
    socketPath: inbound.socketPath,
    headers: { authorization: `Bearer ${inbound.token}` },
  });
  if (!res.ok) throw new Error(`the agent answered ${res.status}`);
  return parseJson(res.text)['commands'];
}

/** One wait, then whatever came in, then the next wait. Re-armed from a timer: work that outlives a dispatch. */
async function collect($: EngineInterface, link: Link): Promise<void> {
  if (!link.server) return;
  if (!link.inbound) {
    const found = await locate($, link.server);
    // A socket this host cannot reach (a fetch policy, a platform without Unix sockets): wait over MCP.
    link.inbound = found?.kind === 'socket' && link.socketFailures >= SOCKET_FAILURES_MAX ? { kind: 'mcp' } : found;
  }
  if (!link.inbound) {
    $.ui.log('gigabuddy: no agent running, so nothing to collect from Gigabuddy', { to: 'debug' });
    return;
  }
  let commands: unknown;
  try {
    commands = await wait($, link.server, link.inbound);
    if (link.inbound.kind === 'socket') link.socketFailures = 0;
  } catch (err) {
    $.ui.log(`gigabuddy: session commands wait failed: ${String(err)}`, { to: 'debug' });
    if (link.inbound.kind === 'socket') link.socketFailures += 1;
    link.inbound = null;
    $.clock.after(RETRY_MS, () => void collect($, link));
    return;
  }
  for (const command of Array.isArray(commands) ? commands : []) {
    try {
      await handle($, link, command as Record<string, unknown>);
    } catch (err) {
      $.ui.log(`gigabuddy: a command from Gigabuddy failed: ${String(err)}`, { to: 'debug' });
    }
  }
  $.clock.after(REARM_MS, () => void collect($, link));
}

async function handle($: EngineInterface, link: Link, command: Record<string, unknown>): Promise<void> {
  if (command['kind'] === 'message' && typeof command['text'] === 'string' && command['text']) {
    // The person's own words, read bare; queued for a turn of its own once the session is idle.
    await $.prompt.submit({ text: command['text'], asUser: true });
    return;
  }
  if (command['kind'] === 'abort') {
    if (!link.turnId) return;
    try {
      await $.turn.abort({ turnId: link.turnId });
      $.ui.toast('Stopped from Gigabuddy');
    } catch (err) {
      $.ui.log(`gigabuddy: stop failed: ${String(err)}`, { to: 'debug' });
    }
  }
}

export const register: Register = (on) => {
  /** The server's name as `$.mcp.call` takes it (null until connected), where to wait, and the running turn. */
  const link: Link = { server: null, inbound: null, socketFailures: 0, turnId: null };

  // ── Inbound: what the person sent from the session view ─────────────────────

  on('session.start', async ($, e, next) => {
    if (!e.isInteractive) return next(e);
    const connected = await $.mcp.connect(SERVER_KEY);
    if (connected.isConnected) {
      link.server = connected.server;
      $.clock.after(REARM_MS, () => void collect($, link));
    } else {
      $.ui.log(`gigabuddy: not driving this session from Gigabuddy (${connected.message})`, { to: 'debug' });
    }
    return next(e);
  });

  on('turn.start', ($, e, next) => {
    link.turnId = e.turnId;
    return next(e);
  });

  on('turn.complete', ($, e, next) => {
    link.turnId = null;
    return next(e);
  });
};
