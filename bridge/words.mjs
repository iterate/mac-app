// words.mjs: the job `words` of mind.mjs: the mind's word list, for the app's dictation
// (Sources/VoiceMeetMac/Words.swift).
//
// The word list is the names and terms that a speech model must get right (`- term` or
// `- term: wrong form, wrong form`). By default it is the mind's own file `words.md` at the root
// of its config repo, which every voice of the mind reads. What the job reads is a setting of the
// app: an itx expression (Settings › Dictation for every mind, a mind's own page for one mind),
// run as the person on the connection of mind.mjs, as the script on the clipboard after a capture
// is. The app sends `{ job: "words", file, expression? }`; the job evaluates the expression (or
// reads words.md, with none), checks the answer, and writes it to <file>. It says
// { done: true, terms } or { failed }. On a failure the file is left as it was: the last good list
// stays in use. A mind with no `words.md` gives an empty file: dictation then works with no list.
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export const WORDS_FILE = "words.md";
/** What runs when no expression is set: the same read as `fetchWords`. */
export const DEFAULT_EXPRESSION = 'itx.repos.get("/repos/config").readFile("words.md")';

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

const AsyncFunction = (async () => {}).constructor;

/**
 * The answer of `expression` with `itx` in scope: an expression (`itx.repos.get(…).readFile(…)`),
 * or a function of itx (`async (itx) => …`), which is then called. A text that does not parse is
 * a failure in words.
 */
export async function evaluate(expression, itx) {
  let run;
  try {
    run = new AsyncFunction("itx", `return (${expression}\n);`);
  } catch (error) {
    throw new Error(`the expression does not parse: ${error.message}`);
  }
  let value = await run(itx);
  if (typeof value === "function") value = await value(itx);
  return value;
}

/** What an answer was, in words, for a failure a person reads. */
function described(value) {
  if (value === undefined) return "nothing";
  if (value === null) return "null";
  if (typeof value === "string") {
    const text = value.trim();
    if (/^[0-9a-f]{40}$/i.test(text) || /^[0-9a-f]{64}$/i.test(text)) return "a commit id";
    if (!text.includes("\n")) return `one line of text ("${text.length > 40 ? `${text.slice(0, 40)}…` : text}")`;
    return `${text.split("\n").length} lines of text`;
  }
  if (Array.isArray(value)) return `a list of ${value.length}`;
  if (typeof value === "object") return "an object";
  return `a ${typeof value}`;
}

/**
 * The list's text from what the expression answered. Text (or its bytes) with at least one term
 * is the list; "" is no list. Anything else throws a reason a person can read.
 */
export function checkedList(value) {
  const text = value instanceof Uint8Array ? new TextDecoder().decode(value) : value;
  if (typeof text !== "string") throw new Error(`This answered ${described(value)}, not text.`);
  if (text === "") return "";
  if (termCount(text) === 0) throw new Error(`This answered ${described(text)}, with no line that starts with "- ".`);
  return text;
}

/** The text of the list that `expression` gives; with none (or the default), words.md as today. */
export async function listOf(connection, expression) {
  const wanted = expression?.trim();
  if (!wanted || wanted === DEFAULT_EXPRESSION) return fetchWords(connection);
  return checkedList(await evaluate(wanted, connection.itx));
}

/** The line `{ file, expression? }` of the app: the list into `file`, within `withinMs`. */
export async function wordsJob({ line, link, say, withinMs = 30_000 }) {
  let timer;
  try {
    const text = await Promise.race([
      link.now(withinMs).then((connection) => listOf(connection, line.expression)),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`No answer from the mind in ${withinMs / 1000} s.`)), withinMs);
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
