import type { On } from 'claude-code';
import { expect, mock, test } from 'claude-code/testing';

// The mod against the engine itself, the test's hooks standing in for the
// plugin's MCP server (`mcp.connect` / `mcp.call` beneath every plugin) and
// for the engine's own bottom of the events the mod hooks.

function bottom(on: On) {
  on('session.start', ($, e) => ({ cwd: e.cwd }));
  on('turn.start', ($, e) => ({ turnId: e.turnId }));
  on('turn.complete', () => ({ text: '', reason: 'answered' as const }));
  on('mcp.connect', () => ({ value: { isConnected: true as const, server: 'plugin:gigabuddy:agent' } }));
  return mock.clock(on);
}

/** An MCP result carrying one JSON text block. */
const result = (value: unknown, isError = false) => ({
  value: { content: [{ type: 'text', text: JSON.stringify(value) }], isError },
});

test('a message from the session view is submitted as the person, and Stop ends the turn', async ($, on) => {
  const submitted: Array<Record<string, unknown>> = [];
  const aborted: string[] = [];
  const fetched: Array<Record<string, unknown>> = [];
  let mcpWaits = 0;
  const clock = bottom(on);
  on('mcp.call', { tool: 'session_commands_socket' }, () =>
    result({ socketPath: '/tmp/gb-mod-x/commands.sock', token: 't0k' }),
  );
  on('mcp.call', { tool: 'session_commands_wait' }, () => {
    mcpWaits += 1;
    return result({ commands: [] });
  });
  on('http.fetch', ($, e) => {
    fetched.push({ url: e.url, socketPath: e.init?.socketPath, authorization: e.init?.headers?.['authorization'] });
    const commands =
      fetched.length === 1 ? [{ kind: 'message', text: 'run the tests', senderName: 'Dan' }, { kind: 'abort' }] : [];
    return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ commands }) } };
  });
  on('prompt.submit', ($, e) => {
    submitted.push({ text: e.text, origin: e.origin });
    return { text: e.text };
  });
  on('turn.abort', ($, e) => {
    aborted.push(e.turnId);
    return { value: undefined };
  });

  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true });
  await $.turn.start({ text: 'hi', turnId: 'turn_1' });
  await clock.advance(100);
  await clock.advance(100);
  expect(submitted).toEqual([{ text: 'run the tests', origin: { kind: 'plugin', name: 'gigabuddy', asUser: true } }]);
  expect(aborted).toEqual(['turn_1']);
  // The wait rides the socket, never an MCP call: one in flight becomes a task the model is told about.
  expect(fetched[0]).toEqual({
    url: 'http://agent/commands?wait=25000',
    socketPath: '/tmp/gb-mod-x/commands.sock',
    authorization: 'Bearer t0k',
  });
  expect(mcpWaits).toBe(0);
});

test('a failed wait backs off and asks the agent again — it never waits over MCP', async ($, on) => {
  const submitted: string[] = [];
  const located: number[] = [];
  let fetches = 0;
  let mcpWaits = 0;
  const clock = bottom(on);
  on('mcp.call', { tool: 'session_commands_socket' }, () => {
    located.push(fetches);
    return result({ socketPath: `/tmp/gb-mod-${located.length}/commands.sock`, token: 't0k' });
  });
  on('mcp.call', { tool: 'session_commands_wait' }, () => {
    mcpWaits += 1;
    return result({ commands: [] });
  });
  // The host can't reach the socket for four waits (an outage, a sleep), then the agent answers again.
  on('http.fetch', () => {
    fetches += 1;
    if (fetches <= 4) throw new Error('no complete answer within 30000ms');
    return {
      value: {
        status: 200,
        ok: true,
        headers: {},
        text: JSON.stringify({ commands: fetches === 5 ? [{ kind: 'message', text: 'back again' }] : [] }),
      },
    };
  });
  on('prompt.submit', ($, e) => {
    submitted.push(e.text);
    return { text: e.text };
  });
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true });
  await clock.advance(100);
  expect(fetches).toBe(1);
  // 5s, 10s, 20s between attempts: doubling, each one re-locating the socket.
  await clock.advance(5_000);
  expect(fetches).toBe(2);
  await clock.advance(9_000);
  expect(fetches).toBe(2);
  await clock.advance(1_000);
  expect(fetches).toBe(3);
  await clock.advance(20_000);
  expect(fetches).toBe(4);
  await clock.advance(40_000);
  await clock.advance(100);
  expect(submitted).toEqual(['back again']);
  expect(located).toEqual([0, 1, 2, 3, 4]);
  expect(mcpWaits).toBe(0);
});

test('an agent that cannot name a socket is asked again later, never waited on over MCP', async ($, on) => {
  let asks = 0;
  let mcpWaits = 0;
  const clock = bottom(on);
  on('mcp.call', { tool: 'session_commands_socket' }, () => {
    asks += 1;
    return result({ error: 'unknown tool' }, true);
  });
  on('mcp.call', { tool: 'session_commands_wait' }, () => {
    mcpWaits += 1;
    return result({ commands: [] });
  });
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true });
  await clock.advance(100);
  await clock.advance(5_000);
  expect(asks).toBe(2);
  // The backoff caps at a minute.
  await clock.advance(10 * 60_000);
  expect(asks).toBeLessThan(16);
  expect(mcpWaits).toBe(0);
});

test('with no agent running (the launcher stand-in) nothing waits at all', async ($, on) => {
  let waits = 0;
  const clock = bottom(on);
  on('mcp.call', { tool: 'session_commands_socket' }, () => result({ socketPath: null }));
  on('mcp.call', { tool: 'session_commands_wait' }, () => {
    waits += 1;
    return result({ commands: [] });
  });
  on('http.fetch', () => {
    waits += 1;
    return { value: { status: 200, ok: true, headers: {}, text: '{"commands":[]}' } };
  });
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true });
  await clock.advance(10_000);
  expect(waits).toBe(0);
});

test('a tool prompt is left to Claude Code — the mod decides nothing', async ($, on) => {
  const relayed: string[] = [];
  bottom(on);
  on('mcp.call', { tool: 'session_commands_socket' }, () => result({ socketPath: null }));
  on('mcp.call', { tool: 'permission_check' }, () => {
    relayed.push('check');
    return { value: { content: [{ type: 'text', text: '{"status":"none"}' }], isError: false } };
  });
  on('tool.check', () => ({ decision: 'ask' as const, reason: 'the mode asks' }));
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true });
  const verdict = await $.tool.check({ tool: 'Bash', input: { command: 'nx test x' }, tool_use_id: 'toolu_1' });
  expect(verdict.decision).toBe('ask');
  expect(relayed).toEqual([]);
});
