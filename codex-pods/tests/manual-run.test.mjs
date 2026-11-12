import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const helper = fileURLToPath(new URL('../../scripts/codex-run.sh', import.meta.url));

function invoke(t, mode, args = []) {
  const directory = mkdtempSync(join(tmpdir(), 'codex-manual-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const calls = join(directory, 'calls.jsonl');
  writeFileSync(calls, '');
  writeFileSync(join(directory, 'sleep'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  writeFileSync(join(directory, 'kubectl'), `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2), mode = process.env.CODEX_TEST_MODE;
fs.appendFileSync(process.env.CODEX_TEST_CALLS, JSON.stringify(args) + '\\n');
if (args[0] === 'get' && args[1] === 'cronjob') {
  console.log(JSON.stringify({spec:{jobTemplate:{spec:{template:{spec:{containers:[{name:mode === 'old-template' ? 'trigger' : 'codex'}]}}}}}}));
} else if (args[0] === 'get' && args[1] === 'jobs') {
  const items = mode === 'active' ? [{metadata:{name:'existing'},status:{active:1}}]
    : mode === 'pending' ? [{metadata:{name:'existing'},status:{}}]
    : mode === 'complete' ? [{metadata:{name:'finished'},status:{conditions:[{type:'Complete',status:'True'}]}}]
    : [];
  console.log(JSON.stringify({items}));
} else if (args[0] === 'create' && args[1] === 'job') {
  console.log('job.batch/' + args[2] + ' created');
} else if (args[0] === 'logs') {
  console.log('Worker finished');
} else if (args[0] === 'get' && args[1] === 'pods') {
  const lookups = fs.readFileSync(process.env.CODEX_TEST_CALLS, 'utf8').trim().split('\\n')
    .map(JSON.parse).filter(c => c[0] === 'get' && c[1] === 'pods' && c.at(-1) === args.at(-1)).length;
  if (args.at(-1) === 'json') {
    const state = mode === 'startup-timeout' ? {waiting:{reason:'ContainerCreating'}}
      : mode === 'slow-start' && lookups === 2 ? {waiting:{reason:'ContainerCreating'}}
      : mode === 'already-finished' ? {terminated:{exitCode:0}} : {running:{}};
    console.log(JSON.stringify({items: mode === 'slow-start' && lookups === 1 ? []
      : [{status:{containerStatuses:[{name:'codex',state}]}}]}));
    process.exit(0);
  }
  console.log(mode === 'missing-status' || (mode === 'delayed-worker-failed' && lookups === 1)
    ? '' : ['worker-failed', 'delayed-worker-failed'].includes(mode) ? '7' : '0');
} else { console.error('Unexpected kubectl operation'); process.exit(99); }
`, { mode: 0o700 });
  const result = spawnSync('bash', [helper, ...args], { encoding: 'utf8', env: {
    ...process.env, PATH: directory + ':' + process.env.PATH,
    CODEX_TEST_MODE: mode, CODEX_TEST_CALLS: calls,
  } });
  return { ...result, calls: readFileSync(calls, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) };
}

test('manual start submits the managed Job template without scaling or patching', t => {
  const result = invoke(t, 'idle');
  assert.equal(result.status, 0, result.stderr);
  const creates = result.calls.filter(c => c[0] === 'create');
  assert.equal(creates.length, 1);
  assert.equal(creates[0][1], 'job');
  assert.match(creates[0][2], /^codex-manual-/);
  assert.ok(creates[0].includes('--from=cronjob/codex-dependabot'));
  assert.equal(result.calls.some(c => ['scale', 'annotate', 'patch', 'delete'].includes(c[0])), false);
  assert.equal(result.calls.some(c => c[0] === 'logs'), false);
});

for (const mode of ['active', 'pending']) {
  test(`${mode} Job prevents another manual submission`, t => {
    const result = invoke(t, mode);
    assert.equal(result.status, 75);
    assert.match(result.stderr, /already active/);
    assert.equal(result.calls.some(c => c[0] === 'create'), false);
  });
}

test('completed Jobs do not prevent a new run', t => {
  const result = invoke(t, 'complete');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.filter(c => c[0] === 'create').length, 1);
});

test('refuses the old exec-trigger template until Argo CD has migrated it', t => {
  const result = invoke(t, 'old-template');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /not deployed yet/);
  assert.equal(result.calls.some(c => c[0] === 'create'), false);
});

test('following a failed worker returns its exit code without deleting its Job', t => {
  const result = invoke(t, 'worker-failed', ['--follow']);
  assert.equal(result.status, 7, result.stderr);
  assert.equal(result.calls.filter(c => c[0] === 'logs').length, 1);
  assert.equal(result.calls.some(c => c[0] === 'delete'), false);
});

test('following waits for a delayed failure status after log EOF', t => {
  const result = invoke(t, 'delayed-worker-failed', ['--follow']);
  assert.equal(result.status, 7, result.stderr);
  assert.equal(result.calls.filter(c => c[0] === 'get' && c[1] === 'pods' && c.at(-1) !== 'json').length, 2);
});

test('missing termination status cannot silently report success', t => {
  const result = invoke(t, 'missing-status', ['--follow']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Could not confirm/);
  assert.equal(result.calls.filter(c => c[0] === 'get' && c[1] === 'pods' && c.at(-1) !== 'json').length, 30);
});

for (const mode of ['slow-start', 'already-finished']) {
  test(`following handles ${mode} before requesting logs`, t => {
    const result = invoke(t, mode, ['--follow']);
    assert.equal(result.status, 0, result.stderr);
    const logIndex = result.calls.findIndex(c => c[0] === 'logs');
    const startupQueries = result.calls.slice(0, logIndex)
      .filter(c => c[0] === 'get' && c[1] === 'pods' && c.at(-1) === 'json');
    assert.equal(startupQueries.length, mode === 'slow-start' ? 3 : 1);
  });
}

test('startup timeout fails without deleting the independently running Job', t => {
  const result = invoke(t, 'startup-timeout', ['--follow']);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /did not start within 10 minutes/);
  assert.equal(result.calls.some(c => ['logs', 'delete'].includes(c[0])), false);
});
