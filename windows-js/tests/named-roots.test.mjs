import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { inspectJavaScriptPackage } from "../src/core/archive.mjs";
import {
  resolveCodexHome,
  applyCodexHomeArgument,
} from "../runtime/codex-home.mjs";
import { zipFixture, packageFiles } from "./fixtures/zip-fixture.mjs";
test("package discovery follows identity and integrity through renamed Unicode wrapper directories", () => {
  const files = packageFiles();
  for (const prefix of [
    "",
    "GPT娘 JS 测试版/",
    "Downloads/任意名称 & (Beta)/",
  ]) {
    const renamed = Object.fromEntries(
      Object.entries(files).map(([name, bytes]) => [prefix + name, bytes]),
    );
    assert.deepEqual(
      inspectJavaScriptPackage(zipFixture(renamed), "1.3.6")
        .map((file) => file.name)
        .sort(),
      Object.keys(files).sort(),
    );
  }
});
test("renamed wrappers retain the single-program boundary and ambiguous identity rejection", () => {
  const files = packageFiles(),
    wrapped = Object.fromEntries(
      Object.entries(files).map(([name, bytes]) => ["任意目录/" + name, bytes]),
    );
  assert.throws(
    () =>
      inspectJavaScriptPackage(
        zipFixture({ ...wrapped, "outside.txt": "foreign" }),
        "1.3.6",
      ),
    /以外/,
  );
  assert.throws(
    () =>
      inspectJavaScriptPackage(
        zipFixture({ ...wrapped, "other/package.json": files["package.json"] }),
        "1.3.6",
      ),
    /多个/,
  );
  const changed = { ...wrapped, "任意目录/src/main.mjs": "tampered" };
  assert.throws(
    () => inspectJavaScriptPackage(zipFixture(changed), "1.3.6"),
    /哈希/,
  );
});
test("Codex homes preserve configured and environment roots regardless of their names", () => {
  const home = path.resolve("fixtures/用户资料");
  assert.equal(
    resolveCodexHome(null, { USERPROFILE: home }),
    path.join(home, ".codex"),
  );
  const custom = path.join(home, "账号 B & (第三方)");
  assert.equal(
    resolveCodexHome(null, { CODEX_HOME: custom, USERPROFILE: home }),
    custom,
  );
  assert.equal(
    resolveCodexHome(path.join(home, "已保存目录"), { CODEX_HOME: custom }),
    path.join(home, "已保存目录"),
  );
});
test("an explicit installer home takes effect before plugin discovery without changing global preferences", () => {
  const env = { CODEX_HOME: path.resolve("old") },
    next = path.resolve("账号 B & (目录)");
  assert.equal(applyCodexHomeArgument(["--codex-home", next], env), next);
  assert.equal(env.CODEX_HOME, next);
  for (const args of [
    ["--codex-home"],
    ["--codex-home", "relative"],
    ["--codex-home", "--target"],
  ])
    assert.throws(() => applyCodexHomeArgument(args, env), /完整/);
});
