/**
 * The Gigabuddy mod — Gigabuddy driving this Claude Code session from its live
 * record (page:ihuoK970I4i8, decision:FWFiBJHe8lPw, decision:ajkhzRsDjEss).
 *
 * The plugin's own MCP server (`agent`) already holds the live connection to
 * Gigabuddy; this module reaches it with `$.mcp.call` and does three things:
 *
 * 1. Inbound: a loop collects what the person sent from the session view
 *    (`session_commands_wait`, bounded, re-armed from a timer so no MCP call
 *    outlives its timeout and nothing polls a server). A message is submitted
 *    as the person's own words (`$.prompt.submit` with `asUser`, a turn of its
 *    own once the session is idle); a Stop ends the running turn.
 * 2. Approvals: a `tool.check` hook. The engine's verdict first; on an `ask`,
 *    the same prompt is offered in Gigabuddy (`permission_check` mints the
 *    consent request to the sponsor — their session view, inbox, phone) and
 *    in the terminal (this mod's band above the prompt) at the same time. The
 *    first answer wins and the other closes: a keyboard answer withdraws the
 *    Gigabuddy request (`permission_settled`); a Gigabuddy answer takes the
 *    band's row down. Only the engine can draw its own dialog, so the
 *    terminal's prompt here is the mod's own (a known limit of the decision).
 * 3. The band: the open approvals, each with Allow / Deny.
 *
 * A hook's budget counts its own time only, never a `$` call in flight, so the
 * waits above cost nothing. Nothing here runs under `-p` (no one to ask).
 */
import { atom, read, update } from 'claude-code';
import type { EngineInterface, Register } from 'claude-code';

import type { GigabuddyApproval } from './types';

/** The server's key in this plugin's .mcp.json. */
const SERVER_KEY = 'agent';
/** One bounded wait on the server; the tools cap it there too. */
const WAIT_MS = 25_000;
/** Between two inbound waits — a breath, not a poll: the wait itself blocks until something arrives. */
const REARM_MS = 50;

const approvals = atom({ plugin: 'gigabuddy', key: 'approvals' } as const, [] as GigabuddyApproval[]);

type Behavior = 'allow' | 'deny';

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

/** One line of a call's input for the band: its command, path or description, cut short. */
function summarize(input: unknown): string {
  if (!input || typeof input !== 'object') return '';
  const o = input as Record<string, unknown>;
  for (const key of ['description', 'command', 'file_path', 'pattern', 'url', 'query']) {
    const v = o[key];
    if (typeof v === 'string' && v.trim()) return cut(v, 80);
  }
  return cut(JSON.stringify(o), 80);
}

function cut(text: string, max: number): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
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
  /** The band's Allow / Deny, by call: the terminal's answer to a pending approval. */
  const fromTerminal = new Map<string, (behavior: Behavior) => void>();

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

  // ── Approvals: terminal and Gigabuddy at once, first answer wins ─────────────

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e);
    const server = link.server;
    if (verdict.decision !== 'ask' || !e.tool_use_id || !server) return verdict;
    const id = e.tool_use_id;

    const began = parse(
      await $.mcp.call(server, 'permission_check', { tool_name: e.tool, tool_input: e.input, tool_use_id: id }),
    );
    if (began['status'] === 'allow')
      return { decision: 'allow', reason: 'Approved in Gigabuddy (a standing approval)' };
    if (began['status'] !== 'pending' || typeof began['requestId'] !== 'string') return verdict;
    const requestId = began['requestId'];

    const row: GigabuddyApproval = { id, tool: e.tool, summary: summarize(e.input), requestId };
    await update($, approvals, (list) => [...(list ?? []), row]);
    let over = false;
    const terminal = new Promise<{ from: 'terminal'; behavior: Behavior }>((resolve) => {
      fromTerminal.set(id, (behavior) => resolve({ from: 'terminal', behavior }));
    });
    const gigabuddy = (async (): Promise<{ from: 'gigabuddy'; behavior: Behavior | 'settled' }> => {
      while (!over) {
        const { behavior } = parse(
          await $.mcp.call(server, 'permission_wait', { request_id: requestId, timeout_ms: WAIT_MS }),
        );
        if (behavior === 'allow' || behavior === 'deny' || behavior === 'settled')
          return { from: 'gigabuddy', behavior };
      }
      return { from: 'gigabuddy', behavior: 'settled' };
    })();

    try {
      const first = await Promise.race([terminal, gigabuddy]);
      if (first.from === 'terminal') {
        // The other answer closes: Gigabuddy's copy is withdrawn.
        void $.mcp.call(server, 'permission_settled', { request_id: requestId }).catch(() => undefined);
        return {
          decision: first.behavior,
          reason: first.behavior === 'allow' ? 'Allowed at the terminal' : 'Denied at the terminal',
        };
      }
      if (first.behavior === 'settled') return verdict; // withdrawn elsewhere: the engine's own dialog decides
      return {
        decision: first.behavior,
        reason:
          first.behavior === 'allow'
            ? 'Approved by your sponsor from Gigabuddy'
            : 'Denied by your sponsor from Gigabuddy',
      };
    } finally {
      over = true;
      fromTerminal.delete(id);
      await update($, approvals, (list) => (list ?? []).filter((a) => a.id !== id));
    }
  }).catch(($, e, next) => next(e));

  // ── The band: open approvals, Allow / Deny ──────────────────────────────────

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const open = await read($, approvals);
    if (open.length === 0) return next(e);
    const { Box, Button, Text } = $.ui.resolve(e);
    return (
      <Box flexDirection="column">
        {open.map((a) => (
          <Box key={a.id}>
            <Text color="yellow">⚠ </Text>
            <Text bold>{a.tool}</Text>
            <Text dimColor> {a.summary} </Text>
            <Button
              key={`allow:${a.id}`}
              label="Allow"
              variant="primary"
              onPress={() => fromTerminal.get(a.id)?.('allow')}
            />
            <Text> </Text>
            <Button key={`deny:${a.id}`} label="Deny" onPress={() => fromTerminal.get(a.id)?.('deny')} />
            <Text dimColor> · or answer in Gigabuddy</Text>
          </Box>
        ))}
      </Box>
    );
  });
};
