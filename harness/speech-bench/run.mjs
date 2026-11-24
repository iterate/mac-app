#!/usr/bin/env node
// speech-bench: the speech models on the same clips of the owner's own voice, side by side
// (README, "Developing"). LOCAL ONLY, never in CI: the clips are the owner's captures, which hold
// their real voice, and nothing of them leaves this Mac. Nothing of them is written into the repo.
//
//   node harness/speech-bench/run.mjs [--captures <folder>] [--words <words.md>] [--models a,b]
//                                     [--oruk <folder with .venv and fourier/>] [--max 5] [--text]
//
// Clips: each capture's voice.m4a whose stored transcript.json (the mind's Whisper) has words, at
// most `--max`, and a sentence of words.md terms from `say -o`. Each model of the app's list runs
// through `speech-bench` (swift build -c release --product speech-bench), with the words.md
// boosting. `--oruk` adds Oruk Fourier 2B (MLX 8-bit, CC BY-NC 4.0) through Python mlx-audio
// (`oruk.py`), which is not a model of the app. Per model it prints: the errors on words.md terms
// (a term in the reference and not in the text, or the other way round), the word agreement with
// the reference (1 − word error rate; the reference is Whisper's text, or the sentence said), the
// seconds from the end of the sound to the final text, the start of the first segment against
// Whisper's, and the load. `--text` prints each clip's texts side by side, on this terminal only.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";

const root = join(import.meta.dirname, "../..");
const support = join(homedir(), "Library/Application Support/iterate-mac-app");
const { values } = parseArgs({
  options: {
    captures: { type: "string", default: join(support, "captures") },
    words: { type: "string", default: join(support, "words/iterate.com.md") },
    models: { type: "string", default: "parakeet-v3,parakeet-ultra" },
    oruk: { type: "string" },
    max: { type: "string", default: "5" },
    text: { type: "boolean" },
  },
});

const bench = join(root, ".build/release/speech-bench");
if (!existsSync(bench)) throw new Error("no speech-bench: run swift build -c release --product speech-bench");

// The word list's terms, as WordList reads them: `- term: wrong, wrong`.
const entries = readFileSync(values.words, "utf8")
  .split("\n")
  .filter((line) => line.startsWith("- "))
  .map((line) => ({ term: line.slice(2).split(":")[0].trim(), hasWrong: line.includes(":") }))
  .filter(({ term }) => term);
const terms = entries.map(({ term }) => term);
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const has = (text, term) => new RegExp(`(?<![\\p{L}\\p{N}])${escape(term)}(?![\\p{L}\\p{N}])`, "iu").test(text);
const normal = (text) =>
  text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}'\s]/gu, " ")
    .split(/\s+/)
    .filter(Boolean);
function wordErrors(reference, text) {
  const [a, b] = [normal(reference), normal(text)];
  let row = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const next = [i];
    for (let j = 1; j <= b.length; j++)
      next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    row = next;
  }
  return { errors: row[b.length], words: a.length };
}

// THE CLIPS
const clips = [];
for (const name of existsSync(values.captures) ? readdirSync(values.captures).sort() : []) {
  const folder = join(values.captures, name);
  const transcript = join(folder, "transcript.json");
  if (!existsSync(join(folder, "voice.m4a")) || !existsSync(transcript)) continue;
  const segments = JSON.parse(readFileSync(transcript, "utf8")).segments ?? [];
  if (!segments.some((segment) => segment.text?.trim())) continue;
  clips.push({ name, file: join(folder, "voice.m4a"), reference: segments.map((s) => s.text).join(" "), firstMs: segments[0].t });
  if (clips.length >= Number(values.max)) break;
}
const scratch = mkdtempSync(join(tmpdir(), "speech-bench-"));
// the hard terms: those a transcript already got wrong (they have wrong forms in the list)
const hard = entries.filter(({ hasWrong }) => hasWrong).map(({ term }) => term);
const sentence = `Ask ${hard.slice(0, 2).join(" and ")} why ${hard[2]} broke the ${hard[3]} in ${hard[4]}, then open ${hard[5]} with ${hard.slice(6, 9).join(", ")} and ${hard[9]}.`;
const fixture = join(scratch, "fixture.aiff");
// `say -o` writes a file and plays nothing
execFileSync("say", ["-o", fixture, sentence]);
clips.push({ name: "say fixture", file: fixture, reference: sentence });

// THE MODELS
const results = {};
for (const model of values.models.split(",").filter(Boolean)) {
  const run = spawnSync(bench, ["--model", model, "--words", values.words, ...clips.map((clip) => clip.file)], {
    encoding: "utf8",
    maxBuffer: 1 << 26,
    stdio: ["ignore", "pipe", "inherit"],
  });
  const lines = run.stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
  results[model] = { load: lines[0], clips: Object.fromEntries(lines.slice(1).map((line) => [line.file, line])) };
}
if (values.oruk) {
  const python = join(values.oruk, ".venv/bin/python");
  // 16 kHz WAV copies in the scratch folder: what mlx-audio reads without ffmpeg
  const wavs = clips.map((clip, index) => {
    const wav = join(scratch, `${index}.wav`);
    execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", clip.file, wav]);
    return wav;
  });
  const run = spawnSync(python, ["-I", join(import.meta.dirname, "oruk.py"), join(values.oruk, "fourier/mlx/8bit"), values.words, ...wavs], {
    encoding: "utf8",
    maxBuffer: 1 << 26,
    stdio: ["ignore", "pipe", "inherit"],
    env: { ...process.env, HF_HUB_OFFLINE: "1" },
  });
  const lines = run.stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
  results["oruk-fourier-2b"] = { load: lines[0], clips: Object.fromEntries(lines.slice(1).map((line, index) => [clips[index].file, line])) };
}

// THE COMPARISON
const round = (number, digits = 2) => (number === undefined || Number.isNaN(number) ? "–" : number.toFixed(digits));
console.log(`${clips.length} clips (${clips.length - 1} captures with words, 1 say fixture); ${terms.length} words.md terms`);
console.log(["model", "term errors", "terms right", "word agreement", "final after end s", "first start Δ ms", "load s"].join(" | "));
for (const [model, { load, clips: heard }] of Object.entries(results)) {
  let termErrors = 0;
  let termsWanted = 0;
  let termsRight = 0;
  let errors = 0;
  let words = 0;
  const after = [];
  const starts = [];
  for (const clip of clips) {
    const line = heard[clip.file];
    const text = (line?.segments ?? []).map((segment) => segment.text).join(" ");
    for (const term of terms) {
      const wanted = has(clip.reference, term);
      const got = has(text, term);
      termsWanted += wanted ? 1 : 0;
      termsRight += wanted && got ? 1 : 0;
      termErrors += wanted !== got ? 1 : 0;
    }
    const counted = wordErrors(clip.reference, text);
    errors += counted.errors;
    words += counted.words;
    if (line?.finalAfterEnd !== undefined) after.push(line.finalAfterEnd);
    if (clip.firstMs !== undefined && line?.segments?.[0]) starts.push(line.segments[0].t - clip.firstMs);
    if (values.text) console.log(`  [${model}] ${clip.name}\n    reference: ${clip.reference}\n    heard:     ${text}`);
  }
  const mean = (list) => list.reduce((a, b) => a + b, 0) / list.length;
  console.log(
    [
      model,
      load?.failed ? `failed: ${load.failed}` : termErrors,
      `${termsRight}/${termsWanted}`,
      `${round(100 * (1 - errors / Math.max(words, 1)), 0)}%`,
      round(mean(after)),
      starts.length ? `${round(mean(starts), 0)} (|Δ| ${round(mean(starts.map(Math.abs)), 0)})` : "–",
      round(load?.loadSeconds, 1),
    ].join(" | "),
  );
}
