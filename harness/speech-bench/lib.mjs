// lib.mjs: what the speech bench's scripts share (README, "Developing", "The speech bench"). The
// bench keeps everything that is not code in BENCH (~/.cache/iterate-speech-bench): the owner's
// clips, the synthetic clips, the venvs, the models and the results. Nothing of it is in the repo.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const BENCH = process.env.SPEECH_BENCH_HOME ?? join(homedir(), ".cache/iterate-speech-bench");
export const ROOT = join(import.meta.dirname, "../..");
/** The mind's word list, as the app keeps it. The bench only reads it. */
export const WORDS = join(homedir(), "Library/Application Support/iterate-mac-app/words/iterate.com.md");
export const RATE = 16000;

/** The test set: `NN. text` lines of sentences.md, each with the kind of its heading. */
export function sentences(file = join(import.meta.dirname, "sentences.md")) {
  let kind = "";
  const list = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const heading = line.match(/^## (.+)/);
    if (heading) kind = heading[1].trim().toLowerCase();
    const item = line.match(/^(\d\d)\. (.+)$/);
    if (item) list.push({ id: item[1], kind, text: item[2].trim() });
  }
  return list;
}

/** The word list's entries, as the app's `WordList(markdown:)` reads them. */
export function wordList(markdown) {
  const order = [];
  const wrong = new Map();
  for (const line of markdown.split("\n")) {
    if (!line.startsWith("- ")) continue;
    const [first, ...rest] = line.slice(2).split(":");
    const term = first.trim();
    if (!term || term.length > 60) continue;
    const forms = rest.join(":").split(",").map((form) => form.trim()).filter(Boolean);
    if (!wrong.has(term)) order.push(term);
    wrong.set(term, [...(wrong.get(term) ?? []), ...forms]);
  }
  return order.map((term) => ({ term, wrong: wrong.get(term) }));
}

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const key = (form) => form.toLowerCase().split(/\s+/).filter(Boolean).join(" ");

/** The app's `WordList.repair`: each wrong form, and each term in another case, written as the term. */
export function repairer(entries) {
  const forms = entries
    .flatMap(({ term, wrong }) => [term, ...wrong].map((form) => ({ form, term })))
    .filter(({ form }) => form.trim())
    .sort((a, b) => b.form.length - a.form.length);
  if (!forms.length) return (text) => text;
  const terms = new Map(forms.map(({ form, term }) => [key(form), term]));
  const pattern = new RegExp(
    `(?<![\\p{L}\\p{N}])(?:${forms.map(({ form }) => form.split(/\s+/).map(escape).join("\\s+")).join("|")})(?![\\p{L}\\p{N}])`,
    "giu",
  );
  return (text) => text.replace(pattern, (match) => terms.get(key(match)) ?? match);
}

/** Whether `text` has `term` as whole words, in the term's own case (words.md: "exactly as it must appear"). */
export const hasTerm = (text, term) => new RegExp(`(?<![\\p{L}\\p{N}])${escape(term)}(?![\\p{L}\\p{N}])`, "u").test(text);

/** The clips of a set: `[{ id, kind, voice, wav, reference, seconds }]`. */
export function clips(set) {
  const kinds = new Map(sentences().map(({ id, kind }) => [id, kind]));
  const folders =
    set === "owner"
      ? [{ voice: "owner", folder: join(BENCH, "clips") }]
      : (existsSync(join(BENCH, "synthetic")) ? readdirSync(join(BENCH, "synthetic")).sort() : []).map((voice) => ({
          voice,
          folder: join(BENCH, "synthetic", voice),
        }));
  const list = [];
  for (const { voice, folder } of folders) {
    if (!existsSync(folder)) continue;
    for (const name of readdirSync(folder).sort()) {
      const id = name.match(/^(\d\d)\.wav$/)?.[1];
      if (!id || !existsSync(join(folder, `${id}.txt`))) continue;
      const wav = join(folder, name);
      list.push({ id, kind: kinds.get(id) ?? "", voice, wav, reference: readFileSync(join(folder, `${id}.txt`), "utf8").trim(), seconds: wavSeconds(wav) });
    }
  }
  return list;
}

/**
 * The synthetic set: each sentence from `say -o` (which writes a file and plays nothing) in each
 * voice, as 16 kHz mono WAVs with the sentence as the reference, in BENCH/synthetic/<voice>/.
 * Daniel is British English; Anna is a German voice reading English, the closest to an accent.
 */
export const VOICES = ["Daniel", "Anna"];
export function synthesize(voices = VOICES) {
  for (const voice of voices) {
    const folder = join(BENCH, "synthetic", voice);
    mkdirSync(folder, { recursive: true });
    for (const { id, text } of sentences()) {
      const wav = join(folder, `${id}.wav`);
      const txt = join(folder, `${id}.txt`);
      if (existsSync(wav) && existsSync(txt) && readFileSync(txt, "utf8").trim() === text) continue;
      execFileSync("say", ["-v", voice, "-o", wav, "--file-format=WAVE", "--data-format=LEI16@16000", text]);
      writeFileSync(txt, `${text}\n`);
    }
  }
}

/** A 16-bit PCM WAV's samples (mono) and rate. */
export function readWav(file) {
  const data = readFileSync(file);
  let at = 12;
  let rate = 0;
  let channels = 1;
  while (at + 8 <= data.length) {
    const id = data.toString("ascii", at, at + 4);
    const size = data.readUInt32LE(at + 4);
    if (id === "fmt ") {
      channels = data.readUInt16LE(at + 10);
      rate = data.readUInt32LE(at + 12);
      if (data.readUInt16LE(at + 22) !== 16) throw new Error(`${file}: not 16-bit PCM`);
    }
    if (id === "data") {
      const frames = new Int16Array(data.buffer.slice(data.byteOffset + at + 8, data.byteOffset + at + 8 + size));
      if (channels === 1) return { rate, samples: frames };
      const mono = new Int16Array(frames.length / channels);
      for (let i = 0; i < mono.length; i++) mono[i] = frames[i * channels];
      return { rate, samples: mono };
    }
    at += 8 + size + (size % 2);
  }
  throw new Error(`${file}: no data chunk`);
}

export const wavSeconds = (file) => {
  const { rate, samples } = readWav(file);
  return samples.length / rate;
};

/** A copy of a WAV at another rate (afconvert, macOS's own converter), in `folder`. */
export function resampled(file, rate, folder) {
  const out = join(folder, `${file.replace(/[^a-zA-Z0-9]+/g, "_")}.${rate}.wav`);
  if (!existsSync(out)) execFileSync("afconvert", ["-f", "WAVE", "-d", `LEI16@${rate}`, "-c", "1", file, out]);
  return out;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * The samples at the pace of the clock, in pieces of `pieceMs` (80–100 ms, as a microphone gives
 * them): `send(piece, index)` for each; resolves at the end of the sound with the time of the last
 * send (performance.now()). The pace is kept against the start, so that no delay adds up.
 */
export async function paced(samples, rate, send, pieceMs = 100) {
  const piece = Math.round((rate * pieceMs) / 1000);
  const started = performance.now();
  let index = 0;
  for (let at = 0; at < samples.length; at += piece) {
    const due = started + ((at + piece) / rate) * 1000;
    // a piece is sent when it has been "heard": at the end of its time
    const wait = due - performance.now();
    if (wait > 0) await sleep(wait);
    send(samples.subarray(at, Math.min(at + piece, samples.length)), index++);
  }
  return performance.now();
}

export const median = (list) => percentile(list, 50);
export function percentile(list, p) {
  const sorted = list.filter((value) => Number.isFinite(value)).sort((a, b) => a - b);
  if (!sorted.length) return undefined;
  const at = ((sorted.length - 1) * p) / 100;
  const low = Math.floor(at);
  return sorted[low] + (sorted[Math.min(low + 1, sorted.length - 1)] - sorted[low]) * (at - low);
}
