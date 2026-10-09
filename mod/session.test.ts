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

test('a message from the session view is submitted as the person, and Stop ends the turn', async ($, on) => {
  const submitted: Array<Record<string, unknown>> = [];
  const aborted: string[] = [];
  let waits = 0;
  const clock = bottom(on);
  on('mcp.call', { tool: 'session_commands_wait' }, () => {
    waits += 1;
    const commands =
      waits === 1 ? [{ kind: 'message', text: 'run the tests', senderName: 'Dan' }, { kind: 'abort' }] : [];
    return { value: { content: [{ type: 'text', text: JSON.stringify({ commands }) }], isError: false } };
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
});

test('a tool prompt is left to Claude Code — the mod decides nothing', async ($, on) => {
  const relayed: string[] = [];
  bottom(on);
  on('mcp.call', { tool: 'session_commands_wait' }, () => ({
    value: { content: [{ type: 'text', text: '{"commands":[]}' }], isError: false },
  }));
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
