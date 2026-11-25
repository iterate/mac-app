// node --test bridge/cli.test.mjs — cli.mjs's changes of config.json and the keys, in a home of
// its own (`ITERATE_MAC_HOME`), with a fake `iterate provide` that makes the key and then goes live
// or is refused. (Here, not beside cli.mjs, so that `node --test 'bridge/*.test.mjs'` runs it.)
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";

const cli = join(import.meta.dirname, "..", "cli.mjs");

/** `iterate provide … --key <file>`: makes the key when it is not there, then says a state. */
const FAKE_PROVIDE = `
const args = process.argv.slice(2);
const key = args[args.indexOf("--key") + 1];
const fs = await import("node:fs");
if (!fs.existsSync(key)) fs.writeFileSync(key, "NEW");
await new Promise((resolve) => setTimeout(resolve, Number(process.env.FAKE_PROVIDE_MS || 0)));
if (process.env.FAKE_PROVIDE === "live") console.log(JSON.stringify({ state: "live" }));
else console.log(JSON.stringify({ state: "stopped", why: "refused by the test" }));
setTimeout(() => process.exit(0), 50);
`;

/** A home that is set up, with one mind under the name `old.mac` and its working key. */
function home() {
  const folder = mkdtempSync(join(tmpdir(), "cli-"));
  after(() => rmSync(folder, { recursive: true, force: true }));
  mkdirSync(join(folder, "keys"));
  writeFileSync(join(folder, "provide.mjs"), FAKE_PROVIDE);
  const keyFile = join(folder, "keys", "example.com.key");
  writeFileSync(keyFile, "OLD");
  const config = {
    spec: "test",
    node: process.execPath,
    iterateBin: join(folder, "provide.mjs"),
    bridge: "unused",
    version: "0.0.0",
    minds: [{ mind: "example.com", name: "old.mac", keyFile, wordsExpression: "kept" }],
    active: "example.com",
  };
  writeFileSync(join(folder, "config.json"), `${JSON.stringify(config, null, 2)}\n`);
  return { folder, keyFile, config: () => JSON.parse(readFileSync(join(folder, "config.json"), "utf8")) };
}

/** cli.mjs with `args`: its exit status and stderr. */
function run(folder, args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [cli, ...args], {
      env: { ...process.env, ITERATE_MAC_HOME: folder, ...env },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("close", (status) => resolve({ status, stderr }));
  });
}

test("a new name that the mind refuses leaves the config and the key that work", async () => {
  const { folder, keyFile, config } = home();
  const before = readFileSync(join(folder, "config.json"), "utf8");
  const { status, stderr } = await run(folder, ["add", "--mind", "example.com", "--name", "new.mac"], { FAKE_PROVIDE: "refuse" });
  assert.equal(status, 1);
  assert.match(stderr, /refused by the test/);
  assert.equal(readFileSync(keyFile, "utf8"), "OLD", "the working key is still there");
  assert.equal(readFileSync(join(folder, "config.json"), "utf8"), before);
  assert.deepEqual(readdirSync(join(folder, "keys")), ["example.com.key"], "the key that was not allowed went");
  assert.equal(config().minds[0].name, "old.mac");
});

test("a new name that the mind allows replaces the key only after config.json names it", async () => {
  const { folder, keyFile, config } = home();
  const { status } = await run(folder, ["add", "--mind", "example.com", "--name", "new.mac"], { FAKE_PROVIDE: "live" });
  assert.equal(status, 0);
  const [entry] = config().minds;
  assert.equal(entry.name, "new.mac");
  assert.equal(entry.wordsExpression, "kept");
  assert.notEqual(entry.keyFile, keyFile);
  assert.equal(readFileSync(entry.keyFile, "utf8"), "NEW");
  assert.equal(existsSync(keyFile), false, "the old key went after the write");
});

test("what another command saved while `add` waited for Allow stays", async () => {
  const { folder, config } = home();
  const adding = run(folder, ["add", "--mind", "example.org", "--name", "jane.mac"], { FAKE_PROVIDE: "live", FAKE_PROVIDE_MS: "1500" });
  await new Promise((resolve) => setTimeout(resolve, 700));
  assert.equal((await run(folder, ["set", "--login"])).status, 0);
  assert.equal((await adding).status, 0);
  const state = config();
  assert.equal(state.login, true, "the `set` during the add stays");
  assert.deepEqual(state.minds.map((m) => m.mind), ["example.com", "example.org"]);
  assert.equal(state.active, "example.org");
});

test("commands at the same time each keep their change", async () => {
  const { folder, config } = home();
  const results = await Promise.all([
    run(folder, ["set", "--login"]),
    run(folder, ["set", "--words-expression", "itx.a"]),
    run(folder, ["set", "--mind", "example.com", "--words-expression", "itx.b"]),
    run(folder, ["use", "example.com"]),
  ]);
  assert.deepEqual(results.map((r) => r.status), [0, 0, 0, 0]);
  const state = config();
  assert.equal(state.login, true);
  assert.equal(state.wordsExpression, "itx.a");
  assert.equal(state.minds[0].wordsExpression, "itx.b");
  assert.deepEqual(readdirSync(folder).filter((file) => /\.(new|lock)$/.test(file)), [], "no temporary file nor lock is left");
});

test("`remove` writes the config first, then deletes the key", async () => {
  const { folder, keyFile, config } = home();
  assert.equal((await run(folder, ["remove", "example.com"])).status, 0);
  assert.deepEqual(config().minds, []);
  assert.equal(config().active, null);
  assert.equal(existsSync(keyFile), false);
});
