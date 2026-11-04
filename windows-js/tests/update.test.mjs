import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import {
  compareVersions,
  selectRelease,
  verifyHash,
  allowedUrl,
  DAY,
  RELEASE_API,
} from "../src/core/update-network.mjs";
import {
  readPackageZip,
  inspectJavaScriptPackage,
  safePackagePath,
} from "../src/core/archive.mjs";
import { Updater, acquireLock } from "../src/core/updater.mjs";
import { zipFixture, packageFiles } from "./fixtures/zip-fixture.mjs";
const temporary = (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-js-update-"));
  t.after(() => {
    if (!path.resolve(root).startsWith(path.resolve(os.tmpdir()) + path.sep))
      throw Error("Unexpected cleanup path");
    fs.rmSync(root, { recursive: true, force: true });
  });
  return root;
};
const release = (bytes, version = "1.3.6") => {
  const name = `gpt-niang-usage-widget-v${version}-windows-js.zip`,
    base = `https://github.com/T7moris/GPT-Niang/releases/download/v${version}/`;
  return {
    tag_name: "v" + version,
    assets: [
      {
        name,
        size: bytes.length,
        digest: "sha256:" + createHash("sha256").update(bytes).digest("hex"),
        browser_download_url: base + name,
      },
      { name: "SHA256SUMS.txt", browser_download_url: base + "SHA256SUMS.txt" },
    ],
  };
};
function setup(t, bytes = zipFixture(packageFiles())) {
  const dataDir = temporary(t),
    r = release(bytes),
    sums = Buffer.from(
      r.assets[0].digest.slice(7) + "  " + r.assets[0].name + "\n",
    );
  let calls = 0;
  const updater = new Updater({
    root: path.join(dataDir, "app"),
    dataDir,
    version: "1.3.5",
    candidate: true,
    fetchBytes: async (url) => {
      calls++;
      return url === RELEASE_API
        ? Buffer.from(JSON.stringify(r))
        : url.endsWith("SHA256SUMS.txt")
          ? sums
          : bytes;
    },
  });
  return { updater, dataDir, r, bytes, sums, calls: () => calls };
}
test("release versions, URLs, checksums and GitHub asset digest retain strict verification", () => {
  assert.equal(compareVersions("1.10.0", "1.9.9"), 1);
  assert.equal(compareVersions("1.3.5", "1.3.5"), 0);
  assert.equal(compareVersions("1.3.5-beta", "1.3.5"),-1);
  assert.throws(() => compareVersions("1.3.5-beta.01", "1.3.5"));
  const bytes = Buffer.from("data"),
    r = release(bytes),
    s = selectRelease(r, "1.3.5");
  assert.equal(s.version, "1.3.6");
  assert.equal(selectRelease(r, "2.0.0"), null);
  assert.equal(selectRelease({ ...r, prerelease: true }, "1.3.5"), null);
  verifyHash(
    bytes,
    Buffer.from(r.assets[0].digest.slice(7) + "  " + r.assets[0].name),
    r.assets[0],
  );
  assert.throws(() =>
    verifyHash(
      Buffer.from("changed"),
      Buffer.from(r.assets[0].digest.slice(7) + "  " + r.assets[0].name),
      r.assets[0],
    ),
  );
  for (const url of [
    "http://github.com/x",
    "https://example.com/x",
    "https://github.com/evil/repo/releases/download/x/file",
  ])
    assert.throws(() => allowedUrl(url));
});
test('JavaScript updater selects its own asset when a legacy bridge is published in the same release',()=>{
  const r=release(Buffer.from('javascript')),legacy={...r.assets[0],name:'gpt-niang-usage-widget-v1.3.6-windows.zip',browser_download_url:'https://github.com/T7moris/GPT-Niang/releases/download/v1.3.6/gpt-niang-usage-widget-v1.3.6-windows.zip'};
  r.assets.unshift(legacy);
  assert.ok(selectRelease(r,'1.3.5').zip.name.endsWith('-windows-js.zip'));
  r.assets=r.assets.filter(x=>!x.name.endsWith('-windows-js.zip'));
  assert.throws(()=>selectRelease(r,'1.3.5'),/missing or duplicated/);
});

test("ZIP validates CRC, local names, overlapping records, links and Windows path rules", () => {
  const files = packageFiles(),
    bytes = zipFixture(files);
  assert.equal(readPackageZip(bytes).length, Object.keys(files).length);
  for (const name of [
    "../x",
    "x/../../y",
    "C:/file",
    "x\\file",
    "CON.txt",
    "name.",
    "a//b",
    "a/.git/config",
    "/root",
  ])
    assert.throws(() => safePackagePath(name));
  assert.throws(() => readPackageZip(zipFixture({ "../x": "x" })));
  assert.throws(() => readPackageZip(zipFixture({ a: "x", A: "y" })));
  assert.throws(() => readPackageZip(zipFixture({ a: "x", "a/b": "y" })));
  assert.throws(() => readPackageZip(zipFixture({ a: "x" }, { mode: 0xa000 })));
  const corrupted = Buffer.from(bytes);
  corrupted[45] ^= 1;
  assert.throws(() => readPackageZip(corrupted));
  const mismatch = zipFixture({ abc: "x" });
  mismatch[30] = 100;
  assert.throws(() => readPackageZip(mismatch));
});
test("JS packages require architecture, version, complete manifest and every verified file", () => {
  const files = packageFiles(),
    zip = zipFixture(files);
  assert.equal(
    inspectJavaScriptPackage(zip, "1.3.6").length,
    Object.keys(files).length,
  );
  assert.throws(() => inspectJavaScriptPackage(zip, "1.3.7"));
  assert.throws(() =>
    inspectJavaScriptPackage(
      zipFixture({
        "package.json": JSON.stringify({
          name: "gpt-niang-usage",
          version: "1.3.6",
        }),
      }),
      "1.3.6",
    ),
  );
  const wrong = {
    ...files,
    "native/GPTNiang.Native.exe": Buffer.from("tampered"),
  };
  assert.throws(() => inspectJavaScriptPackage(zipFixture(wrong), "1.3.6"));
  assert.throws(() =>
    inspectJavaScriptPackage(
      zipFixture({ ...files, "unexpected.exe": "extra" }),
      "1.3.6",
    ),
  );
  const missing = { ...files };
  delete missing["runtime/usage.mjs"];
  assert.throws(() => inspectJavaScriptPackage(zipFixture(missing), "1.3.6"));
});
test("verified download stages every file and candidate never installs", async (t) => {
  const { updater, dataDir } = setup(t);
  await updater.check();
  assert.equal(updater.state.status, "ready");
  assert.ok(
    fs.existsSync(
      path.join(updater.state.directory, "native", "GPTNiang.Native.exe"),
    ),
  );
  assert.ok(
    fs.existsSync(path.join(updater.state.directory, "verified-package.zip")),
  );
  let installed = 0;
  updater.onInstall = () => installed++;
  updater.tick(true);
  assert.equal(installed, 0);
  assert.equal(
    fs.existsSync(path.join(dataDir, "update-installing.json")),
    false,
  );
});
test("legacy PowerShell package is rejected before any staging or installation", async (t) => {
  const { updater } = setup(
    t,
    zipFixture({
      "package.json": JSON.stringify({
        name: "gpt-niang-usage",
        version: "1.3.6",
      }),
      "widget.ps1": "legacy",
    }),
  );
  await updater.check();
  assert.equal(updater.state.status, "error");
  assert.match(updater.state.message, /旧架构/);
  assert.equal(updater.state.directory, undefined);
});
test("automatic setting, delay, Retry-After and manual checks retain their boundaries", async (t) => {
  const { updater, calls } = setup(t);
  updater.automatic(false);
  await updater.check("automatic");
  assert.equal(calls(), 0);
  updater.state.retryAfterAt = Date.now() + 60000;
  await updater.check("manual");
  assert.equal(calls(), 0);
  updater.state.retryAfterAt = 0;
  await updater.check("manual");
  assert.equal(updater.state.status, "ready");
  const before = calls();
  await updater.check("manual");
  assert.equal(calls(), before);
});
test("rate-limit failure persists a retry deadline that manual checks respect", async (t) => {
  const { updater } = setup(t);
  let calls = 0;
  updater.fetchBytes = async () => {
    calls++;
    const e = Error("limited");
    e.retryAfterMs = 120000;
    throw e;
  };
  const start = Date.now();
  await updater.check();
  assert.equal(updater.state.status, "error");
  assert.ok(updater.state.retryAfterAt >= start + 120000);
  assert.ok(updater.state.nextCheckAt >= start + DAY);
  assert.match(updater.state.message, /限制请求.*分钟后重试/);
  await updater.check();
  assert.equal(calls, 1);
});

test('manual check during server cooldown explains the wait without a new request or schedule change',async t=>{
 const {updater,calls}=setup(t);let changed=0;updater.onChange=()=>changed++;
 updater.state={status:'error',message:'old rate-limit error',retryAfterAt:Date.now()+30000,nextCheckAt:Date.now()+DAY};
 const next=updater.state.nextCheckAt;await updater.check('manual');
 assert.match(updater.state.message,/限制请求.*分钟后重试/);assert.equal(changed,1);assert.equal(calls(),0);assert.equal(updater.state.nextCheckAt,next);
 assert.equal(fs.existsSync(path.join(updater.dataDir,'javascript-update.lock')),false);
});
test("update lock is exclusive and an unrelated token cannot release ownership", (t) => {
  const dir = temporary(t),
    lock = acquireLock(dir);
  assert.ok(lock);
  assert.equal(acquireLock(dir), null);
  const owner = path.join(dir, "javascript-update.lock", "owner.json");
  fs.writeFileSync(owner, JSON.stringify({ pid: process.pid, token: "other" }));
  lock.release();
  assert.ok(fs.existsSync(owner));
});
test("changing a verified staging file blocks installation and keeps the existing app", async (t) => {
  const { updater, dataDir } = setup(t);
  await updater.check();
  updater.candidate = false;
  updater.launch = async () => assert.fail("must not launch");
  fs.mkdirSync(updater.root);
  fs.writeFileSync(path.join(updater.root, "old.txt"), "old");
  fs.writeFileSync(
    path.join(updater.state.directory, "ui", "index.html"),
    "changed",
  );
  await updater.install();
  assert.equal(updater.state.status, "error");
  assert.match(updater.state.message, /改变/);
  assert.equal(
    fs.readFileSync(path.join(updater.root, "old.txt"), "utf8"),
    "old",
  );
});
test("prepared update publishes installing state before launching the external agent",async t=>{
  const {updater,dataDir}=setup(t);await updater.check();updater.candidate=false;updater.root=fileURLToPath(new URL('../',import.meta.url));let called=0;
  updater.launch=async ({agent,job})=>{called++;const state=JSON.parse(fs.readFileSync(path.join(dataDir,'javascript-update-state.json'),'utf8')),spec=JSON.parse(fs.readFileSync(job,'utf8'));
    assert.equal(state.status,'installing');assert.equal(state.transactionId,spec.token);assert.ok(fs.existsSync(path.join(agent,'runtime','process-identity.mjs')));};
  await updater.install();assert.equal(called,1);assert.equal(updater.state.status,'installing');
});
test("disabling automatic updates during preparation prevents launching the agent",async t=>{
  const {updater,dataDir}=setup(t);await updater.check('automatic');updater.candidate=false;updater.root=fileURLToPath(new URL('../',import.meta.url));let called=0;updater.launch=async()=>called++;
  const running=updater.install();updater.automatic(false);await running;
  assert.equal(called,0);assert.equal(updater.state.status,'ready');assert.equal(updater.preferences.automatic,false);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dataDir,'javascript-update-journal.json'),'utf8')).phase,'rolled-back');
});

test('manual update can use a cached automatic download while automatic updates stay disabled',async t=>{
  const {updater,calls}=setup(t);await updater.check('automatic');updater.automatic(false);
  const downloaded=updater.state.directory,requests=calls();
  await updater.check('manual');
  assert.equal(updater.state.mode,'manual');assert.equal(updater.preferences.automatic,false);
  assert.equal(updater.state.directory,downloaded);assert.equal(calls(),requests);
  updater.candidate=false;let installs=0;updater.install=async()=>installs++;
  updater.tick(false);assert.equal(installs,0);updater.tick(true);assert.equal(installs,1);
});

test('opening an editor during update preparation defers replacement until idle again',async t=>{
  const {updater,dataDir}=setup(t);await updater.check('automatic');updater.candidate=false;
  updater.root=fileURLToPath(new URL('../',import.meta.url));
  let idle=true,launched=0;updater.isIdle=()=>idle;updater.launch=async()=>launched++;
  const preparing=updater.install();idle=false;await preparing;
  assert.equal(launched,0);assert.equal(updater.state.status,'ready');
  const journal=JSON.parse(fs.readFileSync(path.join(dataDir,'javascript-update-journal.json'),'utf8'));
  assert.equal(journal.phase,'rolled-back');assert.equal(journal.keepSource,true);
  assert.ok(fs.existsSync(updater.state.directory));
  idle=true;await updater.install();assert.equal(launched,1);assert.equal(updater.state.status,'installing');
});
