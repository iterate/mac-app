// node --test bridge/words.test.mjs — the mind's word list is one file of its config repo.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fakeMind } from "./fake-mind.test-helper.mjs";
import { mindLink } from "./mind.mjs";
import { checkedList, DEFAULT_EXPRESSION, evaluate, fetchWords, listOf, termCount, wordsJob } from "./words.mjs";

const connection = (mind) => mind.connect();

test("the list is words.md of the config repo, at its tip", async () => {
  const mind = fakeMind();
  mind.repo.files["words.md"] = "# Words\n\n- itx: i t x\n- Jonas\n";
  assert.equal(await fetchWords(await connection(mind)), "# Words\n\n- itx: i t x\n- Jonas\n");
  assert.deepEqual(mind.repo.reads, ["/repos/config", ["words.md", "abc"]]);
});

test("a mind with no word list gives an empty one", async () => {
  assert.equal(await fetchWords(await connection(fakeMind())), "");
});

test("a mind that does not answer is a failure, not an empty list", async () => {
  const mind = fakeMind();
  mind.repo.tip = async () => Promise.reject(new Error("closed"));
  await assert.rejects(fetchWords(await connection(mind)), /closed/);
});

test("the terms are the list items; the format's indented example is none", () => {
  assert.equal(termCount("# Words\n\n    - <term>\n\n- itx: i t x\n- Jonas\n-\n"), 2);
});

test("the job writes the list into the file and says how many terms it has", async () => {
  const mind = fakeMind();
  mind.repo.files["words.md"] = "- Herdr: herder\n- Beelink\n";
  const folder = mkdtempSync(join(tmpdir(), "words-"));
  const link = mindLink({ name: "test", connect: mind.connect, sleep: mind.sleep, say: () => {} });
  const said = [];
  try {
    await wordsJob({ line: { file: join(folder, "words", "example.com.md") }, link, say: (line) => said.push(line) });
    assert.deepEqual(said, [{ done: true, terms: 2 }]);
    assert.equal(readFileSync(join(folder, "words", "example.com.md"), "utf8"), "- Herdr: herder\n- Beelink\n");
  } finally {
    link.stop();
    rmSync(folder, { recursive: true, force: true });
  }
});

test("an expression of the setting is evaluated with itx in scope", async () => {
  const mind = fakeMind();
  mind.repo.files["terms.md"] = "- Herdr\n";
  assert.equal(await listOf(await connection(mind), 'itx.repos.get("/repos/config").readFile("terms.md")'), "- Herdr\n");
  assert.equal(await listOf(await connection(mind), "async (itx) => `- ${await itx.repos.get('/repos/config').tip()}`"), "- abc");
});

test("the default expression reads words.md as the job always did: no file is no list", async () => {
  const mind = fakeMind();
  assert.equal(await listOf(await connection(mind), DEFAULT_EXPRESSION), "");
  assert.equal(await listOf(await connection(mind), undefined), "");
});

test("an answer that is no list is a failure in words", async () => {
  const mind = fakeMind();
  await assert.rejects(listOf(await connection(mind), 'itx.repos.get("/repos/config").tip()'), /answered one line of text \("abc"\), with no line that starts with "- "/);
  assert.throws(() => checkedList("8f3c2a9d0b1e4f5a6c7d8e9f0a1b2c3d4e5f6a7b"), /This answered a commit id, with no line that starts with "- "\./);
  assert.throws(() => checkedList(42), /This answered a number, not text\./);
  assert.throws(() => checkedList(undefined), /This answered nothing, not text\./);
  assert.equal(checkedList(""), "");
  assert.equal(checkedList(new TextEncoder().encode("- itx\n")), "- itx\n");
  await assert.rejects(evaluate("itx.(", {}), /the expression does not parse/);
});

test("a failed expression leaves the last good list in its file", async () => {
  const mind = fakeMind();
  mind.repo.files["words.md"] = "- Herdr\n- Beelink\n";
  const folder = mkdtempSync(join(tmpdir(), "words-"));
  const file = join(folder, "words", "example.com.md");
  const link = mindLink({ name: "test", connect: mind.connect, sleep: mind.sleep, say: () => {} });
  const said = [];
  try {
    await wordsJob({ line: { file }, link, say: (line) => said.push(line) });
    await wordsJob({ line: { file, expression: "itx.repos.get('/repos/config').tip()" }, link, say: (line) => said.push(line) });
    assert.deepEqual(said[0], { done: true, terms: 2 });
    assert.match(said[1].failed, /no line that starts with "- "/);
    assert.equal(readFileSync(file, "utf8"), "- Herdr\n- Beelink\n");
  } finally {
    link.stop();
    rmSync(folder, { recursive: true, force: true });
  }
});
