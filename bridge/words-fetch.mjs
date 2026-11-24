#!/usr/bin/env node
// words-fetch.mjs: the mind's word list, for the app's dictation (Sources/VoiceMeetMac/Words.swift).
//
//   node words-fetch.mjs <file> --iterate <iterate.js> --mind <address>
//
// The word list is the mind's own file: `words.md` at the root of its config repo, the names and
// terms that a speech model must get right (`- term` or `- term: wrong form, wrong form`). Every
// voice of the mind reads it; the app's local speech model reads this copy. It connects as the
// person (the iterate CLI's own sign-in), reads that one file and writes it to <file>. A mind with
// no `words.md` gives an empty file: dictation then works with no list.
//
// stdout is one JSON line: { done: true, terms } or { failed }. It exits 0 after `done`.
import { mkdirSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

export const WORDS_FILE = "words.md";

/** The list's text, or "" when the mind has no such file. A mind that does not answer throws. */
export async function fetchWords({ connect }) {
  const { itx } = await connect();
  const repo = itx.repos.get("/repos/config");
  // the tip first: it fails when the mind does not answer, so a missing file is told from that
  const tip = await repo.tip();
  try {
    return String(await repo.readFile(WORDS_FILE, { commitOid: tip }));
  } catch {
    return "";
  }
}

export const termCount = (text) => text.split(/\r?\n/).filter((line) => /^- \S/.test(line)).length;

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const say = (line) => process.stdout.write(`${JSON.stringify(line)}\n`);
  try {
    const { positionals, values } = parseArgs({
      allowPositionals: true,
      options: { iterate: { type: "string" }, mind: { type: "string" } },
    });
    const file = positionals[0];
    if (!file || !values.iterate || !values.mind)
      throw new Error("node words-fetch.mjs <file> --iterate <iterate.js> --mind <address>");
    const { addressOf, connectMind } = await import(
      pathToFileURL(join(dirname(dirname(values.iterate)), "dist/node.mjs")).href
    );
    let timer;
    const text = await Promise.race([
      fetchWords({ connect: () => connectMind({ address: addressOf(values.mind), signIn: false }) }),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("no answer from the mind in 30 s")), 30_000);
      }),
    ]);
    clearTimeout(timer);
    mkdirSync(dirname(file), { recursive: true });
    // whole or not at all: the app may read the file at any moment
    writeFileSync(`${file}.new`, text);
    renameSync(`${file}.new`, file);
    say({ done: true, terms: termCount(text) });
    process.exit(0);
  } catch (error) {
    say({ failed: String(error?.message ?? error).slice(0, 300) });
    process.exit(1);
  }
}
