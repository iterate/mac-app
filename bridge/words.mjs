// words.mjs: the job `words` of mind.mjs: the mind's word list, for the app's dictation
// (Sources/VoiceMeetMac/Words.swift).
//
// The word list is the mind's own file: `words.md` at the root of its config repo, the names and
// terms that a speech model must get right (`- term` or `- term: wrong form, wrong form`). Every
// voice of the mind reads it; the app's local speech model reads this copy. The app sends
// `{ job: "words", file }`; on the connection of mind.mjs (the person's own sign-in) it reads that
// one file and writes it to <file>. A mind with no `words.md` gives an empty file: dictation then
// works with no list. It says { done: true, terms } or { failed }.
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export const WORDS_FILE = "words.md";

/** The list's text, or "" when the mind has no such file. A mind that does not answer throws. */
export async function fetchWords({ itx }) {
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

/** The line `{ file }` of the app: the list into `file`, within `withinMs`. */
export async function wordsJob({ line, link, say, withinMs = 30_000 }) {
  let timer;
  try {
    const text = await Promise.race([
      link.now(withinMs).then(fetchWords),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`no answer from the mind in ${withinMs / 1000} s`)), withinMs);
      }),
    ]);
    mkdirSync(dirname(line.file), { recursive: true });
    // whole or not at all: the app may read the file at any moment
    writeFileSync(`${line.file}.new`, text);
    renameSync(`${line.file}.new`, line.file);
    say({ done: true, terms: termCount(text) });
  } catch (error) {
    say({ failed: String(error?.message ?? error).slice(0, 300) });
  } finally {
    clearTimeout(timer);
  }
}
