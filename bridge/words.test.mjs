// node --test bridge/words.test.mjs — the mind's word list is one file of its config repo.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fakeMind } from "./fake-mind.test-helper.mjs";
import { mindLink } from "./mind.mjs";
import { fetchWords, termCount, wordsJob } from "./words.mjs";

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
