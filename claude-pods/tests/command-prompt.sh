#!/usr/bin/env bash
# Hash/identity validation and literal context rendering are the execution gate.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
node - "$here/../lib/command-prompt.js" "$tmp" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');
const [renderer, root] = process.argv.slice(2);
const payload = {version:1, task:{id:'t1',description:'Literal $SECRET {{workspace}} $(touch unwanted)'},
 repo:'owner/repo',stage:'test',mode:'test',branch:'fix/t1',baseSHA:'base',pr:1,reworks:0,
 timeoutSeconds:2700,result:'test-verdict-v1',instructions:'Work in {{workspace}}. Write {{verdict_file}}.',comments:[]};
for (const scenario of ['valid','tampered','wrong-command','unknown-contract','unknown-placeholder']) {
 const folder = path.join(root,scenario); fs.mkdirSync(folder);
 const input = structuredClone(payload);
 if (scenario === 'unknown-contract') input.result = 'future-v9';
 if (scenario === 'unknown-placeholder') input.instructions += '{{SECRET}}';
 const raw = JSON.stringify(input);
 const response = {version:1,task:'t1',repo:'owner/repo',stage:'test',command:'cmd1',prompt:{template:'test',templateDigest:'template',
   payload:raw,digest:crypto.createHash('sha256').update(raw).digest('hex')}};
 if (scenario === 'tampered') response.prompt.payload += ' ';
 if (scenario === 'wrong-command') response.command = 'other';
 const file = path.join(folder,'command.json'); fs.writeFileSync(file,JSON.stringify(response));
 const result = spawnSync(process.execPath,[renderer,file,'t1','owner/repo','cmd1','test','/workspace/repo'],{env:{...process.env,SECRET:'must-not-appear'}});
 if (scenario !== 'valid') { assert.notEqual(result.status,0,scenario); assert(!fs.existsSync(path.join(folder,'prompt.txt'))); continue; }
 assert.equal(result.status,0,result.stderr.toString());
 const rendered = fs.readFileSync(path.join(folder,'prompt.txt'),'utf8');
 assert(rendered.includes('Work in /workspace/repo. Write /workspace/repo/.nightly-verdict.'));
 assert(rendered.includes(payload.task.description));
 assert(!rendered.includes('must-not-appear'));
 assert.equal(fs.readFileSync(path.join(folder,'payload.json'),'utf8'),raw);
 const provenance = JSON.parse(fs.readFileSync(path.join(folder,'provenance.json'),'utf8'));
 assert.equal(provenance.renderedDigest,crypto.createHash('sha256').update(rendered).digest('hex'));
 // A second execution cannot overwrite the archived prompt for this command.
 assert.notEqual(spawnSync(process.execPath,[renderer,file,'t1','owner/repo','cmd1','test','/workspace/repo']).status,0);
}
console.log('PASS: immutable command prompt, identity/hash/contract gates, literal ticket context, audit preservation');
JS
