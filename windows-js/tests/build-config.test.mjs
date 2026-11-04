import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { currentInstalledConfig, copyConfigurationFiles } from '../scripts/build-config.mjs';

test('candidate build uses valid paths from the same current installation', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gpt-js-build-config-'));
  t.after(() => { assert.equal(path.dirname(path.resolve(dir)), path.resolve(os.tmpdir())); fs.rmSync(dir, { recursive: true, force: true }); });
  const appDir = path.join(dir, 'app'), dataDir = path.join(dir, 'data'), nodePath = path.join(dir, 'node.exe'), codexPath = path.join(dir, 'codex.exe');
  fs.mkdirSync(appDir); fs.mkdirSync(dataDir); fs.writeFileSync(nodePath, ''); fs.writeFileSync(codexPath, '');
  const frozen = { appDir, dataDir: 'old-data', nodePath: 'old-node', codexPath: 'old-codex' };
  fs.writeFileSync(path.join(appDir, 'installation.json'), JSON.stringify({ appDir, dataDir, nodePath, codexPath }));
  assert.deepEqual(currentInstalledConfig(frozen), { appDir, dataDir, nodePath, codexPath });
  fs.writeFileSync(path.join(appDir, 'installation.json'), JSON.stringify({ appDir: path.join(dir, 'other'), dataDir, nodePath, codexPath }));
  assert.deepEqual(currentInstalledConfig(frozen), frozen);
  fs.writeFileSync(path.join(appDir, 'installation.json'), JSON.stringify({ appDir, candidate: true, dataDir, nodePath, codexPath }));
  assert.deepEqual(currentInstalledConfig(frozen), frozen);
});

test('candidate settings copy retains backups and does not overwrite existing files', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gpt-js-build-backups-'));
  t.after(() => { assert.equal(path.dirname(path.resolve(dir)), path.resolve(os.tmpdir())); fs.rmSync(dir, { recursive: true, force: true }); });
  const source = path.join(dir, 'source'), target = path.join(dir, 'target');
  fs.mkdirSync(source); fs.mkdirSync(target);
  fs.writeFileSync(path.join(source, 'audio-preferences.json'), 'current');
  fs.writeFileSync(path.join(source, 'audio-preferences.json.bak'), 'backup');
  fs.writeFileSync(path.join(source, 'unrelated.txt'), 'untouched');
  copyConfigurationFiles(source, target);
  assert.equal(fs.readFileSync(path.join(target, 'audio-preferences.json'), 'utf8'), 'current');
  assert.equal(fs.readFileSync(path.join(target, 'audio-preferences.json.bak'), 'utf8'), 'backup');
  assert.equal(fs.existsSync(path.join(target, 'unrelated.txt')), false);
  assert.throws(() => copyConfigurationFiles(source, target), { code: 'EEXIST' });
  assert.equal(fs.readFileSync(path.join(target, 'audio-preferences.json.bak'), 'utf8'), 'backup');
});
