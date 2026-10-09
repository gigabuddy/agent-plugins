/**
 * The Gigabuddy mod — Gigabuddy driving this Claude Code session from its live
 * record (page:ihuoK970I4i8, decision:FWFiBJHe8lPw).
 *
 * The plugin's own MCP server (`agent`) already holds the live connection to
 * Gigabuddy; this module reaches it with `$.mcp.call` and does one thing: a
 * loop collects what the person sent from the session view
 * (`session_commands_wait`, bounded, re-armed from a timer so no MCP call
 * outlives its timeout and nothing polls a server). A message is submitted as
 * the person's own words (`$.prompt.submit` with `asUser`, a turn of its own
 * once the session is idle); a Stop ends the running turn.
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

/** The first text block of an MCP result, parsed as JSON; `{}` when it is not. */
function parse(result: { content: Array<{ type: string; text?: string }> }): Record<string, unknown> {
  const text = result.content.find((c) => c.type === 'text')?.text;
  if (!text) return {};
  try {
    const parsed = JSON.parse(text) as unknown;
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** What the inbound loop needs of the module: the server's name, and the running turn for Stop. */
type Link = { server: string | null; turnId: string | null };

/** One wait on the server, then whatever came in, then the next wait. Re-armed from a timer: work that outlives a dispatch. */
async function collect($: EngineInterface, link: Link): Promise<void> {
  if (!link.server) return;
  try {
    const { commands } = parse(await $.mcp.call(link.server, 'session_commands_wait', { timeout_ms: WAIT_MS }));
    for (const command of Array.isArray(commands) ? commands : [])
      await handle($, link, command as Record<string, unknown>);
  } catch (err) {
    $.ui.log(`gigabuddy: session commands wait failed: ${String(err)}`, { to: 'debug' });
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
  /** The server's name as `$.mcp.call` takes it (null until connected), and the running turn. */
  const link: Link = { server: null, turnId: null };

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
