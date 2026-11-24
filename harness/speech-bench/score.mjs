#!/usr/bin/env node
// score.mjs: the speech bench's scores for one run (run.mjs writes it; README, "The speech bench").
//
//   node harness/speech-bench/score.mjs [<run folder>] [--text]
//
// Per engine, over the run's clips:
// - WER: the word error rate against the reference, after the app's word-list repair (each engine's
//   text goes through it, as the app's recognizer does) and a normalization of case, punctuation,
//   number words ("fifteen" is 15) and a few spellings;
// - terms: of each words.md term in a reference, how many the text writes exactly, in the term's
//   own case; "raw" is before the repair; "false" counts terms written that the reference does not
//   have (a boosting that puts in a term that was not said);
// - literals: of each word of a reference with a slash, a digit, an underscore or a dot inside
//   (`/devices/jonas.mac`, `AGENTS.md`, `15`), how many the text writes exactly: the WER does not
//   see them, as it drops punctuation;
// - the time from the start of the audio to the first partial, and from its end to the final text
//   ("how long after I let go"), p50 and p90;
// - setup: the first ever (install, download, first load), each start of the app (the load with
//   the files on disk), each dictation once loaded; for OpenAI a new connection and its session;
// - cost per minute of audio.
// The Markdown goes to stdout; JSON to BENCH/results/<date>.json, under the run's set.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { BENCH, hasTerm, median, percentile, repairer, wordList } from "./lib.mjs";

const SMALL = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(" ");
const TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split(" ");
const SPELLING = { ok: "okay", behavior: "behaviour", "it's": "it's", gonna: "going to" };

/** Lower-case words, with number words as digits: "two hundred and forty" is 240. */
export function normal(text) {
  const words = text
    .toLowerCase()
    .replace(/[’‘]/g, "'")
    .replace(/[^\p{L}\p{N}'\s]/gu, " ")
    .split(/\s+/)
    .map((word) => word.replace(/^'+|'+$/g, ""))
    .filter(Boolean)
    .flatMap((word) => (SPELLING[word] ?? word).split(" "));
  const out = [];
  for (let i = 0; i < words.length; ) {
    let value = 0;
    let used = 0;
    let j = i;
    while (j < words.length) {
      const word = words[j];
      if (SMALL.includes(word)) value += SMALL.indexOf(word);
      else if (TENS.includes(word)) value += TENS.indexOf(word) * 10;
      else if (word === "hundred" && used) value *= 100;
      else if (word === "and" && used && words[j - 1] === "hundred" && j + 1 < words.length && (SMALL.includes(words[j + 1]) || TENS.includes(words[j + 1]))) {
      } else break;
      used++;
      j++;
    }
    if (used) {
      out.push(String(value));
      i = j;
    } else out.push(words[i++]);
  }
  return out;
}

export function wordErrors(reference, text) {
  const [a, b] = [normal(reference), normal(text)];
  let row = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const next = [i];
    for (let j = 1; j <= b.length; j++) next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    row = next;
  }
  return { errors: row[b.length], words: a.length };
}

/** The words of a reference that must be written exactly: paths, files, numbers, names with `_`. */
export const literals = (reference) =>
  reference
    .split(/\s+/)
    .map((word) => word.replace(/^[("']+|[)"',.?!;:]+$/g, ""))
    .filter((word) => /[\/_\d]|\p{L}\.\p{L}/u.test(word));
const hasLiteral = (text, literal) => new RegExp(`(?<![\\p{L}\\p{N}/_.])${literal.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\p{L}\\p{N}/_]|\\.\\p{L})`, "u").test(text);

const seconds = (ms) => (ms === undefined ? "–" : (ms / 1000).toFixed(2));
const round = (value, digits = 1) => (value === undefined || !Number.isFinite(value) ? "–" : value.toFixed(digits));

export function score(folder) {
  const run = JSON.parse(readFileSync(join(folder, "run.json"), "utf8"));
  const entries = wordList(readFileSync(join(folder, "words.md"), "utf8"));
  const repair = repairer(entries);
  const firstEver = existsSync(join(BENCH, "setup/first-ever.json")) ? JSON.parse(readFileSync(join(BENCH, "setup/first-ever.json"), "utf8")) : {};
  // the download speed of the measured downloads, for an engine whose files were already here
  const measured = Object.values(firstEver).filter((row) => row.downloadSeconds && row.megabytes);
  const rate = measured.reduce((sum, row) => sum + row.megabytes, 0) / measured.reduce((sum, row) => sum + row.downloadSeconds, 0);
  const engines = [];
  for (const name of readdirSync(folder).filter((name) => name.endsWith(".engine.json")).sort()) {
    const result = JSON.parse(readFileSync(join(folder, name), "utf8"));
    if (result.failed) {
      engines.push({ id: result.id, name: result.name, failed: result.failed });
      continue;
    }
    let errors = 0;
    let words = 0;
    let wanted = 0;
    let right = 0;
    let rawRight = 0;
    let falseTerms = 0;
    let literalsWanted = 0;
    let literalsRight = 0;
    const missed = new Map();
    const firsts = [];
    const finals = [];
    const byVoice = {};
    const byKind = {};
    let audio = 0;
    let failedClips = 0;
    const texts = [];
    for (const clip of result.clips) {
      audio += clip.seconds;
      if (clip.error) {
        failedClips++;
        texts.push({ id: clip.id, voice: clip.voice, reference: clip.reference, error: clip.error });
        continue;
      }
      const text = repair(clip.text ?? "");
      const counted = wordErrors(clip.reference, text);
      errors += counted.errors;
      words += counted.words;
      for (const [key, map] of [
        [clip.voice, byVoice],
        [clip.kind, byKind],
      ]) {
        map[key] ??= { errors: 0, words: 0 };
        map[key].errors += counted.errors;
        map[key].words += counted.words;
      }
      for (const { term } of entries) {
        if (!hasTerm(clip.reference, term)) {
          if (hasTerm(text, term)) falseTerms++;
          continue;
        }
        wanted++;
        if (hasTerm(text, term)) right++;
        else missed.set(term, (missed.get(term) ?? 0) + 1);
        if (hasTerm(clip.text ?? "", term)) rawRight++;
      }
      for (const literal of literals(clip.reference)) {
        literalsWanted++;
        if (hasLiteral(text, literal)) literalsRight++;
        else missed.set(literal, (missed.get(literal) ?? 0) + 1);
      }
      if (clip.firstPartialMs !== undefined) firsts.push(clip.firstPartialMs);
      if (clip.endToFinalMs !== undefined) finals.push(clip.endToFinalMs);
      texts.push({ id: clip.id, voice: clip.voice, reference: clip.reference, text, wer: counted.errors / counted.words });
    }
    const setup = result.setup ?? {};
    const first = firstEver[result.id];
    let firstEverSeconds;
    let firstEverEstimated = false;
    if (result.online) firstEverSeconds = setup.coldSeconds * 1000;
    else if (setup.launchSeconds !== undefined) {
      const download = first?.downloadSeconds ?? (result.downloadMegabytes ? result.downloadMegabytes / rate : undefined);
      firstEverEstimated = first?.downloadSeconds === undefined;
      firstEverSeconds = ((first?.installSeconds ?? 0) + (download ?? 0) + (first?.firstLoadSeconds ?? setup.launchSeconds)) * 1000;
    }
    engines.push({
      id: result.id,
      name: result.name,
      runtime: result.runtime,
      streaming: result.streaming,
      clips: result.clips.length,
      failedClips,
      wer: (100 * errors) / Math.max(words, 1),
      werByVoice: Object.fromEntries(Object.entries(byVoice).map(([key, row]) => [key, (100 * row.errors) / row.words])),
      werByKind: Object.fromEntries(Object.entries(byKind).map(([key, row]) => [key, (100 * row.errors) / row.words])),
      terms: { right, rawRight, wanted, false: falseTerms },
      literals: { right: literalsRight, wanted: literalsWanted },
      missed: [...missed].sort((a, b) => b[1] - a[1]),
      firstPartialP50Ms: median(firsts),
      endToFinalP50Ms: median(finals),
      endToFinalP90Ms: percentile(finals, 90),
      setup: { firstEverMs: firstEverSeconds, firstEverEstimated, launchMs: result.online ? setup.coldSeconds * 1000 : setup.launchSeconds * 1000, warmMs: (setup.warmSeconds ?? 0) * 1000, ...setup },
      costPerMinute: result.costPerMinute,
      audioMinutes: audio / 60,
      texts,
    });
  }

  const lines = [];
  const voices = [...new Set(engines.flatMap((engine) => Object.keys(engine.werByVoice ?? {})))];
  lines.push(
    `**${run.set === "owner" ? "owner" : "synthetic"}** set, ${run.clips} clips (${run.voices.join(", ")}), ${entries.length} words.md terms, ${run.date}. WER and terms after the word-list repair.`,
    "",
    "| engine | WER % | terms right (raw) | false terms | literals | first partial s | end → final p50 / p90 s | setup: first ever / app start / per dictation s | $ / min |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const engine of engines) {
    if (engine.failed) continue;
    const { setup } = engine;
    lines.push(
      `| ${engine.id} | ${round(engine.wer)} | ${engine.terms.right}/${engine.terms.wanted} (${engine.terms.rawRight}) | ${engine.terms.false} | ${engine.literals.right}/${engine.literals.wanted} | ${engine.streaming ? seconds(engine.firstPartialP50Ms) : "none"} | ${seconds(engine.endToFinalP50Ms)} / ${seconds(engine.endToFinalP90Ms)} | ${setup.firstEverMs && setup.firstEverEstimated ? "≈" : ""}${round(setup.firstEverMs / 1000, 0)} / ${round(setup.launchMs / 1000, 1)} / ${round(setup.warmMs / 1000, 2)} | ${engine.costPerMinute ? `$${engine.costPerMinute}` : "0"} |`,
    );
  }
  if (voices.length > 1 || engines.some((engine) => engine.werByKind)) {
    const kinds = [...new Set(engines.flatMap((engine) => Object.keys(engine.werByKind ?? {})))];
    lines.push("", `| WER % by | ${[...voices, ...kinds].join(" | ")} |`, `| --- | ${[...voices, ...kinds].map(() => "---:").join(" | ")} |`);
    for (const engine of engines.filter((engine) => !engine.failed))
      lines.push(`| ${engine.id} | ${[...voices.map((voice) => round(engine.werByVoice[voice])), ...kinds.map((kind) => round(engine.werByKind[kind]))].join(" | ")} |`);
  }
  const failed = engines.filter((engine) => engine.failed);
  if (failed.length) lines.push("", "Did not run:", ...failed.map((engine) => `- ${engine.id}: ${engine.failed}`));
  const online = engines.filter((engine) => !engine.failed && engine.setup.connectSeconds !== undefined);
  if (online.length)
    lines.push("", ...online.map((engine) => `- ${engine.id}: connect ${round(engine.setup.connectSeconds, 2)} s + session.update ${round(engine.setup.sessionSeconds, 2)} s (p50); ${engine.failedClips} clips failed`));
  lines.push("", "Most missed terms and literals:", ...engines.filter((engine) => !engine.failed).map((engine) => `- ${engine.id}: ${engine.missed.slice(0, 8).map(([term, count]) => `${term} ×${count}`).join(", ") || "none"}`));
  return { run, engines, markdown: lines.join("\n") };
}

/** Prints the table (and with `text`, each clip's texts) and writes the JSON. */
export function report(folder, { text = false } = {}) {
  const { run, engines, markdown } = score(folder);
  console.log(markdown);
  if (text)
    for (const engine of engines.filter((engine) => !engine.failed))
      for (const row of engine.texts) console.log(`\n[${engine.id}] ${row.voice} ${row.id}\n  ref:   ${row.reference}\n  heard: ${row.text ?? `(${row.error})`}`);
  mkdirSync(join(BENCH, "results"), { recursive: true });
  const file = join(BENCH, "results", `${run.date}.json`);
  const all = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
  all[run.set] = { run: { ...run, folder }, engines };
  writeFileSync(file, `${JSON.stringify(all, null, 1)}\n`);
  console.error(`\nJSON: ${file}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: { text: { type: "boolean" } } });
  const runs = join(BENCH, "results/runs");
  report(positionals[0] ?? join(runs, readdirSync(runs).sort().at(-1)), values);
}
