import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHmac } from 'node:crypto';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';

const dispatcher = fileURLToPath(new URL('../dispatcher/dispatch.mjs', import.meta.url));
const pr = (state = 'MERGED', number = 98) => ({ number, state,
  headRefOid: 'a'.repeat(40), headRefName: 'fix/task-1', isCrossRepository: false });

async function fixture(t, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'reconcile-merged-'));
  const bin = join(dir, 'bin'); mkdirSync(bin);
  const path = join(dir, 'fixture.json'), callsPath = join(dir, 'calls');
  const state = { column: 'in-review', prs: [pr()], ...options };
  writeFileSync(path, JSON.stringify(state)); writeFileSync(callsPath, '');
  writeFileSync(join(dir, 'key'), 'fixture-key');
  writeFileSync(join(dir, 'signature'), 'fixture-signature');
  for (const command of ['gh', 'kaneo', 'kubectl']) {
    writeFileSync(join(bin, command), `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2), state = JSON.parse(fs.readFileSync(process.env.RECONCILE_FIXTURE));
fs.appendFileSync(process.env.RECONCILE_CALLS, JSON.stringify({command:${JSON.stringify(command)},args})+'\\n');
if (${JSON.stringify(command)} === 'gh') {
  if (state.ghFails) { console.error('fixture GitHub unavailable'); process.exit(1); }
  console.log(JSON.stringify(args[0] === 'pr' ? state.prs : 1));
} else if (${JSON.stringify(command)} === 'kaneo') {
  if (state.moveFails) { console.error('fixture update failed'); process.exit(1); }
  if (!state.noopMove) state.currentStatus = 'done'; fs.writeFileSync(process.env.RECONCILE_FIXTURE, JSON.stringify(state));
} else { console.error('Unexpected worker wake'); process.exit(1); }
`, { mode: 0o700 });
  }
  const api = createServer((req, res) => {
    const s = JSON.parse(readFileSync(path));
    const task = { id: 'task-1', projectId: 'project', status: s.currentStatus ?? s.column,
      createdAt: new Date(Date.now() - 6 * 3600_000).toISOString() };
    let result;
    if (req.url === '/api/task/tasks/project') {
      const columns = [{ id: 'source-column', slug: s.column, tasks: [task] }];
      if (!s.missingDone) columns.push({ id: 'done-column', slug: 'done', tasks: [] });
      result = { data: { columns } };
    } else if (req.url === '/api/label/task/task-1') result = [{ name: `repo:${s.repo ?? 'testrepo'}` }];
    else if (req.url === '/api/activity/task-1') result = [{ type: 'status_changed',
      createdAt: new Date(Date.now() - (s.recent ? 1000 : 6 * 3600_000)).toISOString() }];
    else if (req.url === '/api/task/task-1') result = task;
    else { res.writeHead(404).end(); return; }
    res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(result));
  });
  api.listen(0, '127.0.0.1'); await once(api, 'listening');
  const reservation = createServer(); reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
  const port = reservation.address().port; await new Promise(r => reservation.close(r));
  let logs = '';
  const child = spawn(process.execPath, [dispatcher], { env: {
    ...process.env, PORT: String(port), KANEO_PROJECT_ID: 'project', NIGHTLY_OWNER: 'TestOwner',
    KANEO_API_URL: `http://127.0.0.1:${api.address().port}`,
    DISPATCH_API_KEY_FILE: join(dir, 'key'), DISPATCH_SECRET_FILE: join(dir, 'signature'),
    RECONCILE_FIXTURE: path, RECONCILE_CALLS: callsPath, PATH: `${bin}:${process.env.PATH}`,
  }, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', b => { logs += b; }); child.stderr.on('data', b => { logs += b; });
  t.after(async () => {
    child.kill(); if (child.exitCode === null) await once(child, 'exit');
    await new Promise(r => api.close(r)); rmSync(dir, { recursive: true, force: true });
  });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(url + '/healthz')).ok) break; } catch {}
    await delay(20);
  }
  async function sweep(dry = false) {
    const before = logs.length;
    const signature = createHmac('sha256', 'fixture-signature').update('').digest('hex');
    const result = await fetch(url + '/reconcile' + (dry ? '?dry' : ''), {
      method: 'POST', headers: { 'X-Kaneo-Signature': signature }, body: '',
    });
    assert.equal(result.status, 202);
    for (let i = 0; i < 150; i++) {
      if (/RECONCILE (done|failed)/.test(logs.slice(before))) { await delay(20); return logs.slice(before); }
      await delay(20);
    }
    assert.fail('Sweep did not finish: ' + logs);
  }
  const calls = () => readFileSync(callsPath, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  return { sweep, calls };
}

for (const column of ['in-review', 'in-progress', 'needs-human-review', 'mergeable', 'to-do']) {
  test(`merged PR completes a card in ${column} without waking workers`, async t => {
    const f = await fixture(t, { column });
    const logs = await f.sweep();
    assert.deepEqual(f.calls().filter(c => c.command === 'kaneo').map(c => c.args), [['task', 'status', 'task-1', 'done']]);
    assert.equal(f.calls().some(c => c.command === 'kubectl'), false);
    assert.match(logs, /completed=1/);
  });
}

test('merged completion does not wait for the retry age window', async t => {
  const f = await fixture(t, { recent: true }); await f.sweep();
  assert.equal(f.calls().filter(c => c.command === 'kaneo').length, 1);
});
test('dry run reports completion without changing cards or waking workers', async t => {
  const f = await fixture(t); const logs = await f.sweep(true);
  assert.equal(f.calls().some(c => c.command !== 'gh'), false);
  assert.match(logs, /completed=1/); assert.match(logs, /dry-run/);
});
test('newer open PR prevents an older merged PR from completing its card', async t => {
  const f = await fixture(t, { prs: [pr(), pr('OPEN', 99)] }); await f.sweep();
  assert.equal(f.calls().some(c => c.command === 'kaneo'), false);
});
test('closed unmerged PR does not complete the card', async t => {
  const f = await fixture(t, { prs: [pr('CLOSED')] }); await f.sweep();
  assert.equal(f.calls().some(c => c.command === 'kaneo'), false);
});
test('fork PR cannot complete the card', async t => {
  const f = await fixture(t, { prs: [{ ...pr(), isCrossRepository: true }], recent: true }); await f.sweep();
  assert.equal(f.calls().some(c => c.command !== 'gh'), false);
});
for (const failure of [{ ghFails: true }, { missingDone: true }, { moveFails: true }, { noopMove: true }]) {
  test(`completion failure is reported and never dispatches a worker: ${JSON.stringify(failure)}`, async t => {
    const f = await fixture(t, failure); const logs = await f.sweep();
    assert.match(logs, /errors=1/); assert.match(logs, /completed=0/);
    assert.equal(f.calls().some(c => c.command === 'kubectl'), false);
  });
}
test('card changed since board snapshot is left alone', async t => {
  const f = await fixture(t, { currentStatus: 'needs-human-review' }); await f.sweep();
  assert.equal(f.calls().some(c => c.command !== 'gh'), false);
});
test('already completed card is not updated again on a repeated sweep', async t => {
  const f = await fixture(t); await f.sweep(); await f.sweep();
  assert.equal(f.calls().filter(c => c.command === 'kaneo').length, 1);
});
test('fully qualified repository is used for the merge lookup', async t => {
  const f = await fixture(t, { repo: 'AnotherOwner/testrepo' }); await f.sweep();
  const lookup = f.calls().find(c => c.command === 'gh');
  assert.equal(lookup.args[lookup.args.indexOf('--repo') + 1], 'AnotherOwner/testrepo');
});

for (const column of ['backlog', 'done']) {
  test(`${column} remains outside reconciliation`, async t => {
    const f = await fixture(t, { column }); await f.sweep();
    assert.deepEqual(f.calls(), []);
  });
}
test('unmerged human-review card remains parked', async t => {
  const f = await fixture(t, { column: 'needs-human-review', prs: [pr('OPEN')] }); await f.sweep();
  assert.equal(f.calls().some(c => c.command !== 'gh'), false);
});
