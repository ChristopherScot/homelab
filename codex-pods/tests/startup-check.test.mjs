import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const filter = fileURLToPath(new URL('../startup-check.jq', import.meta.url));
const successfulCommand = { type: 'item.completed', item: {
  type: 'command_execution', exit_code: 0, aggregated_output: 'CODEX_POD_TOOL_OK',
} };
const check = events => spawnSync('jq', ['-se', '-f', filter], {
  input: events.map(e => JSON.stringify(e)).join('\n'), encoding: 'utf8',
});

test('readiness accepts a real successful shell completion', () => {
  const result = check([{ type: 'thread.started' }, successfulCommand, { type: 'turn.completed' }]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), 'true');
});

test('readiness rejects a prose-only claim even with both success markers', () => {
  const result = check([{ type: 'item.completed', item: {
    type: 'agent_message', text: 'CODEX_POD_TOOL_OK CODEX_POD_OK',
  } }]);
  assert.equal(result.status, 1);
});

test('readiness rejects failed or unfinished commands', () => {
  assert.equal(check([{ ...successfulCommand, item: { ...successfulCommand.item, exit_code: 1 } }]).status, 1);
  assert.equal(check([{ ...successfulCommand, type: 'item.started' }]).status, 1);
});

test('readiness rejects empty output or a command without the expected marker', () => {
  assert.equal(check([]).status, 1);
  assert.equal(check([{ ...successfulCommand, item: { ...successfulCommand.item, aggregated_output: '' } }]).status, 1);
});
