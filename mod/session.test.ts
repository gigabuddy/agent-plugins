import { expect, mock, test } from 'claude-code/testing';

// The mod against the engine itself, the test's hooks standing in for the
// plugin's MCP server (`mcp.connect` / `mcp.call` beneath every plugin) and
// for the engine's own bottom of the events the mod hooks.

type On = Parameters<Parameters<typeof test>[1]>[1];

function bottom(on: On) {
  on('session.start', ($, e) => ({ cwd: e.cwd }));
  on('turn.start', ($, e) => ({ turnId: e.turnId }));
  on('turn.complete', () => ({}));
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

test('an ask is offered in Gigabuddy and the terminal; the Gigabuddy answer decides, the band row goes', async ($, on) => {
  const calls: string[] = [];
  bottom(on);
  on('mcp.call', { tool: 'session_commands_wait' }, () => ({
    value: { content: [{ type: 'text', text: '{"commands":[]}' }], isError: false },
  }));
  on('mcp.call', { tool: 'permission_check' }, () => {
    calls.push('check');
    return { value: { content: [{ type: 'text', text: '{"requestId":"mod_1","status":"pending"}' }], isError: false } };
  });
  on('mcp.call', { tool: 'permission_wait' }, () => {
    calls.push('wait');
    return { value: { content: [{ type: 'text', text: '{"behavior":"allow"}' }], isError: false } };
  });
  on('tool.check', () => ({ decision: 'ask' as const, reason: 'the mode asks' }));

  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true });
  const verdict = await $.tool.check({ tool: 'Bash', input: { command: 'nx test x' }, tool_use_id: 'toolu_1' });
  expect(verdict.decision).toBe('allow');
  expect(calls).toEqual(['check', 'wait']);
});

test('a verdict that is not an ask, or a query with no call, passes through untouched', async ($, on) => {
  bottom(on);
  on('mcp.call', { tool: 'session_commands_wait' }, () => ({
    value: { content: [{ type: 'text', text: '{"commands":[]}' }], isError: false },
  }));
  on('tool.check', () => ({ decision: 'allow' as const }));
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true });
  expect((await $.tool.check({ tool: 'Read', input: { file_path: 'a' }, tool_use_id: 'toolu_2' })).decision).toBe(
    'allow',
  );
});
