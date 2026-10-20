import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {resolveCodexExecutable} from '../runtime/usage.mjs';

const bundled=app=>path.join(app,'Contents/Resources/codex-cli/bin/codex');
const absent=()=>Object.assign(new Error('Isolated missing candidate'),{code:'ENOENT'});
function virtualFiles(t,files){
  const present=new Set(files);
  t.mock.method(fs,'statSync',file=>{if(present.has(file))return {isFile:()=>true};throw absent();});
  return present;
}
function homeFixture(t){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-mac-cli-'));
  const realStat=fs.statSync.bind(fs);
  // Default system app roots must never discover the test runner's real login.
  t.mock.method(fs,'statSync',file=>{
    if(typeof file!=='string' || !path.resolve(file).startsWith(path.resolve(root)+path.sep))throw absent();
    return realStat(file);
  });
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  return {root,write(relative){const file=path.join(root,relative);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,'isolated CLI fixture');return file;}};
}

test('Finder-style empty PATH finds the CLI inside system ChatGPT.app',t=>{
  const cli=bundled('/Applications/ChatGPT.app');virtualFiles(t,[cli]);
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{PATH:''}}),cli);
});
test('a real user Applications/ChatGPT.app fixture is found without PATH or symlinks',t=>{
  const {root,write}=homeFixture(t);const cli=write('Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex');
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{HOME:root}}),cli);
});
test('a valid explicit executable wins over either app bundle',t=>{
  const configured=path.join('/custom bin','codex');
  virtualFiles(t,[configured,bundled('/Applications/Codex.app'),bundled('/Applications/ChatGPT.app')]);
  assert.equal(resolveCodexExecutable(configured,{platform:'darwin',env:{}}),configured);
});
test('existing system Codex.app priority is preserved when both apps exist',t=>{
  const codex=bundled('/Applications/Codex.app');virtualFiles(t,[codex,bundled('/Applications/ChatGPT.app')]);
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{}}),codex);
});
test('existing user Codex.app priority is preserved ahead of the new user fallback',t=>{
  const {root,write}=homeFixture(t);const codex=write('Applications/Codex.app/Contents/Resources/codex-cli/bin/codex');
  write('Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex');
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{HOME:root}}),codex);
});
test('the next refresh discovers a move from Codex.app to ChatGPT.app',t=>{
  const {root,write}=homeFixture(t);const codex=write('Applications/Codex.app/Contents/Resources/codex-cli/bin/codex');
  const env={HOME:root};assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env}),codex);
  fs.unlinkSync(codex);
  const chatgpt=write('Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex');
  assert.equal(resolveCodexExecutable(codex,{platform:'darwin',env}),chatgpt);
});
test('user app paths containing spaces are returned intact',t=>{
  const {root,write}=homeFixture(t);const home=path.join(root,'Person Name');
  const cli=write('Person Name/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex');
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{HOME:home}}),cli);
});
for(const relative of ['Contents/Resources/codex-cli/bin/codex','Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex','Contents/Resources/codex']){
  test('ChatGPT.app uses the existing supported layout: '+relative,t=>{
    const cli=path.join('/Applications/ChatGPT.app',relative);virtualFiles(t,[cli]);
    assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{}}),cli);
  });
}
test('an explicit app root remains isolated from default bundle discovery',t=>{
  const app=path.join('/alternate folder','ChatGPT.app'),cli=bundled(app);
  virtualFiles(t,[cli,bundled('/Applications/Codex.app')]);
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{GPT_NIANG_CODEX_APP:app}}),cli);
});
test('PATH remains the last fallback when neither app bundle has a CLI',t=>{
  const cli=path.join('/opt/homebrew/bin','codex');virtualFiles(t,[cli]);
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{PATH:'/usr/local/bin:/opt/homebrew/bin'}}),cli);
});
test('missing bundles preserve the original failure path',t=>{
  virtualFiles(t,[]);
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{}}),'codex');
});
test('a directory named codex does not count as a bundled executable',t=>{
  t.mock.method(fs,'statSync',file=>{if(file===bundled('/Applications/ChatGPT.app'))return {isFile:()=>false};throw absent();});
  assert.equal(resolveCodexExecutable('codex',{platform:'darwin',env:{}}),'codex');
});
