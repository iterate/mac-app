// node --test bridge/words-fetch.test.mjs — the mind's word list is one file of its config repo.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fetchWords, termCount } from "./words-fetch.mjs";

const mind = ({ files = {}, tip = async () => "abc" } = {}) => {
  const seen = [];
  const repo = {
    tip,
    readFile: async (path, options) => {
      seen.push([path, options?.commitOid]);
      if (!(path in files)) throw new Error("no such file");
      return files[path];
    },
  };
  return { seen, connect: async () => ({ itx: { repos: { get: (path) => (seen.push(path), repo) } } }) };
};

test("the list is words.md of the config repo, at its tip", async () => {
  const { seen, connect } = mind({ files: { "words.md": "# Words\n\n- itx: i t x\n- Jonas\n" } });
  assert.equal(await fetchWords({ connect }), "# Words\n\n- itx: i t x\n- Jonas\n");
  assert.deepEqual(seen, ["/repos/config", ["words.md", "abc"]]);
});

test("a mind with no word list gives an empty one", async () => {
  assert.equal(await fetchWords({ connect: mind().connect }), "");
});

test("a mind that does not answer is a failure, not an empty list", async () => {
  const { connect } = mind({ tip: async () => Promise.reject(new Error("closed")) });
  await assert.rejects(fetchWords({ connect }), /closed/);
});

test("the terms are the list items; the format's indented example is none", () => {
  assert.equal(termCount("# Words\n\n    - <term>\n\n- itx: i t x\n- Jonas\n-\n"), 2);
});
