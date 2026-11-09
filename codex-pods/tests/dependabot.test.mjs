import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { eligible, main, publishable, runAgent } from '../dependabot.mjs';

const pr = () => ({ number: 17054, title: 'Bump a dependency', author: { login: 'app/dependabot' },
  state: 'OPEN', isDraft: false, isCrossRepository: false,
  headRefName: 'dependabot/npm_and_yarn/package-1.2.3', headRefOid: 'a'.repeat(40),
  statusCheckRollup: [{ name: 'check-biome', status: 'COMPLETED', conclusion: 'FAILURE' }] });
const repair = { status: 'ready', validation: [{ command: 'yarn lint:biome', result: 'passed' }] };
const review = { approved: true, findings: [] };

test('selects failing Dependabot checks and legacy failure statuses', () => {
  assert.equal(eligible(pr()), true);
  assert.equal(eligible({ ...pr(), statusCheckRollup: [{ state: 'ERROR', context: 'CI' }] }), true);
  assert.equal(eligible({ ...pr(), statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'TIMED_OUT' }] }), true);
});

test('does not act on green, absent, cancelled, or still-running checks', () => {
  for (const checks of [[], [{ status: 'COMPLETED', conclusion: 'SUCCESS' }],
    [{ status: 'COMPLETED', conclusion: 'CANCELLED' }],
    [...pr().statusCheckRollup, { status: 'IN_PROGRESS', conclusion: '' }],
    [...pr().statusCheckRollup, { state: 'PENDING' }]]) {
    assert.equal(eligible({ ...pr(), statusCheckRollup: checks }), false);
  }
});

test('never selects human, closed, draft, fork, or non-Dependabot branches', () => {
  for (const change of [{ author: { login: 'human' } }, { state: 'MERGED' }, { isDraft: true },
    { isCrossRepository: true }, { isCrossRepository: undefined },
    { headRefName: 'main' }, { headRefOid: '--bad-ref' }]) {
    assert.equal(eligible({ ...pr(), ...change }), false);
  }
});

test('publishes only reviewed, validated repairs on the exact discovered PR head', () => {
  assert.equal(publishable(pr(), pr(), repair, review), true);
  for (const current of [{ ...pr(), headRefOid: 'b'.repeat(40) },
    { ...pr(), number: 42 }, { ...pr(), headRefName: 'dependabot/another' },
    { ...pr(), state: 'CLOSED' }, { ...pr(), statusCheckRollup: [] }]) {
    assert.equal(publishable(pr(), current, repair, review), false);
  }
  assert.equal(publishable(pr(), pr(), repair, { approved: false, findings: ['Bug'] }), false);
  assert.equal(publishable(pr(), pr(), repair, { approved: true, findings: ['Bug'] }), false);
  for (const invalid of [{ status: 'blocked', validation: repair.validation },
    { status: 'ready', validation: [] },
    { status: 'ready', validation: [{ command: 'test', result: 'failed' }] }]) {
    assert.equal(publishable(pr(), pr(), invalid, review), false);
  }
});

function fixture(t) {
  const stateDir = mkdtempSync(join(tmpdir(), 'codex-dependabot-test-'));
  const tokenFile = join(stateDir, 'token');
  writeFileSync(tokenFile, 'fixture-token', { mode: 0o600 });
  t.after(() => rmSync(stateDir, { recursive: true, force: true }));
  return { stateDir, tokenFile };
}

test('dry run discovers candidates without invoking git or Codex', async t => {
  const options = fixture(t);
  const calls = [];
  const summary = await main({ ...options, dryRun: true, run: (bin, args, config) => {
    calls.push({ bin, args });
    assert.equal(config.env.GH_TOKEN, 'fixture-token');
    assert.equal(config.env.OPENAI_API_KEY, undefined);
    return { status: 0, stdout: JSON.stringify([pr(), { ...pr(), author: { login: 'human' } }]) };
  } });
  assert.deepEqual(summary.selected, [17054]);
  assert.deepEqual(summary.repaired, []);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].bin, 'gh');
  assert.equal(readdirSync(options.stateDir).includes('app'), false);
});

test('discovery failure fails the run rather than reporting no work', async t => {
  const options = fixture(t);
  await assert.rejects(main({ ...options, run: () => ({ status: 1, stdout: '', stderr: '403' }) }),
    /gh pr list failed/);
  const runDir = readdirSync(options.stateDir).find(p => p.startsWith('run-'));
  assert.deepEqual(JSON.parse(readFileSync(join(options.stateDir, runDir, 'summary.json'))).repaired, []);
});

// Exercise the actual commit/push path against a local bare remote. Only the
// GitHub responses and model calls are simulated: ref updates and patch content
// are real, so stale/rejected reviews must leave the remote untouched.
async function runScenario(t, scenario) {
  const options = fixture(t);
  const source = join(options.stateDir, 'source');
  const remote = join(options.stateDir, 'remote.git');
  mkdirSync(source);
  const localGit = (args, cwd = source) => execFileSync('git',
    ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', ...args],
    { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  localGit(['init', '--initial-branch=main']);
  writeFileSync(join(source, 'app.js'), 'export const value = 1;\n');
  localGit(['add', 'app.js']);
  localGit(['commit', '-m', 'Initial dependency update']);
  const candidate = { ...pr(), headRefOid: localGit(['rev-parse', 'HEAD']) };
  localGit(['branch', candidate.headRefName]);
  localGit(['clone', '--bare', source, remote]);
  const calls = [];
  let lookups = 0;
  const previousExit = process.exitCode;
  let summary;
  try {
    const run = (bin, args, config) => {
      calls.push({ bin, args });
      if (bin === 'gh') {
        if (args[1] === 'list') return { status: 0, stdout: JSON.stringify([candidate]) };
        lookups++;
        if (scenario === 'remote-race' && lookups > 1) {
          // GitHub's metadata can lag a real branch update. Advance the remote
          // while still returning the old head to exercise push rejection.
          localGit(['checkout', candidate.headRefName]);
          writeFileSync(join(source, 'app.js'), 'export const value = 99;\n');
          localGit(['add', 'app.js']);
          localGit(['commit', '-m', 'Concurrent Dependabot update']);
          localGit(['push', remote, candidate.headRefName]);
        }
        const current = scenario === 'stale' && lookups > 1
          ? { ...candidate, headRefOid: 'b'.repeat(40) } : candidate;
        return { status: 0, stdout: JSON.stringify(current) };
      }
      if (bin === 'timeout') {
        const isRepair = args.includes(join(configDirForTest(), 'repair.schema.json'));
        if (isRepair) {
          writeFileSync(join(options.stateDir, 'app', 'app.js'), 'export const value = 2;\n');
          if (scenario === 'workflow') {
            mkdirSync(join(options.stateDir, 'app', '.github', 'workflows'), { recursive: true });
            writeFileSync(join(options.stateDir, 'app', '.github', 'workflows', 'unsafe.yml'), 'disabled: true\n');
          }
        } else if (scenario === 'review-edited') {
          writeFileSync(join(options.stateDir, 'app', 'app.js'), 'export const value = 3;\n');
        }
        const response = isRepair ? repair : scenario === 'rejected'
          ? { approved: false, findings: ['Incorrect compatibility fix'] } : review;
        writeFileSync(args[args.indexOf('--output-last-message') + 1], JSON.stringify(response));
        return { status: 0 };
      }
      const gitArgs = args[0] === 'clone'
        ? args.map(a => a === 'https://github.com/schoolhouse-world/app.git' ? remote : a) : args;
      return spawnSync(bin, ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', ...gitArgs], config);
    };
    summary = await main({ ...options, run, agentRun: (bin, args, config) => run('timeout', args, config) });
  } finally { process.exitCode = previousExit; }
  return { summary, candidate, calls, remoteHead: localGit(['rev-parse', `refs/heads/${candidate.headRefName}`], remote),
    remoteMain: localGit(['rev-parse', 'refs/heads/main'], remote) };
}

function configDirForTest() { return new URL('..', import.meta.url).pathname.replace(/\/$/, ''); }

test('reviewed fix fast-forwards only the original Dependabot branch', async t => {
  const result = await runScenario(t, 'approved');
  assert.deepEqual(result.summary.repaired, [17054]);
  assert.notEqual(result.remoteHead, result.candidate.headRefOid);
  assert.equal(result.remoteMain, result.candidate.headRefOid);
  const pushes = result.calls.filter(c => c.bin === 'git' && c.args[0] === 'push');
  assert.deepEqual(pushes.map(c => c.args), [['push', 'origin', `HEAD:refs/heads/${result.candidate.headRefName}`]]);
  assert.equal(result.calls.some(c => c.args[0] === 'merge' || c.args[1] === 'merge'), false);
  assert.equal(pushes.some(c => c.args.some(a => a.startsWith('--force'))), false);
});

for (const scenario of ['rejected', 'stale', 'review-edited', 'workflow']) {
  test(`${scenario} repair never updates any remote ref`, async t => {
    const result = await runScenario(t, scenario);
    assert.deepEqual(result.summary.repaired, []);
    assert.deepEqual(result.summary.failed, [17054]);
    assert.equal(result.remoteHead, result.candidate.headRefOid);
    assert.equal(result.remoteMain, result.candidate.headRefOid);
    assert.equal(result.calls.some(c => c.bin === 'git' && c.args[0] === 'push'), false);
  });
}

test('a concurrent remote update rejects the push and preserves that update', async t => {
  const result = await runScenario(t, 'remote-race');
  assert.deepEqual(result.summary.repaired, []);
  assert.deepEqual(result.summary.failed, [17054]);
  assert.notEqual(result.remoteHead, result.candidate.headRefOid);
  assert.equal(result.remoteMain, result.candidate.headRefOid);
  assert.equal(result.calls.filter(c => c.bin === 'git' && c.args[0] === 'push').length, 1);
});

for (const cause of ['timeout', 'outer-cancellation']) {
  test(`${cause} terminates an agent's surviving descendants`, async t => {
    const options = fixture(t);
    const marker = join(options.stateDir, 'late-write');
    const controller = new AbortController();
    const descendant = `process.on('SIGTERM', () => {}); setTimeout(() => require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'orphan'), 600);`;
    const parent = `process.on('SIGTERM', () => process.exit(0)); require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(descendant)}], {stdio:'ignore'}); setInterval(() => {}, 1000);`;
    const cancellation = cause === 'outer-cancellation' ? setTimeout(() => controller.abort(), 200) : undefined;
    try {
      await assert.rejects(runAgent(process.execPath, ['-e', parent], {
        input: '', stdio: ['pipe', 'ignore', 'ignore'], timeoutMs: cause === 'timeout' ? 200 : 5000,
        signal: controller.signal,
      }), cause === 'timeout' ? /timed out/ : /interrupted/);
      await new Promise(resolve => setTimeout(resolve, 800));
      assert.equal(existsSync(marker), false);
    } finally { clearTimeout(cancellation); }
  });
}
