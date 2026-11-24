#!/usr/bin/env node
// speech-bench: speech-to-text engines on the same clips with known text, side by side (README,
// "The speech bench"). LOCAL ONLY, never in CI.
//
//   node harness/speech-bench/run.mjs [--set synthetic|owner] [--engines a,b] [--clips 01,02]
//                                     [--voices Daniel,Anna] [--text]
//
// The sets: `owner` is the owner's own voice (record.mjs, BENCH/clips); `synthetic` is each
// sentence from `say -o` in two voices (made here at the first run). Each engine of `engines/`
// gets the clips and the mind's word list, and gives per clip its partials with their times, its
// final text, the time to the first partial and from the end of the audio to the final text, and
// its setup. A streaming engine hears the audio at the pace of the clock in pieces of 0.1 s. The
// local engines run one after another; then the online ones together (each on its own
// connection), so that no engine slows another's latency. Everything goes to
// BENCH/results/runs/<time>-<set>/; score.mjs prints the table.
//
// The online engines (OpenAI) send the bench's clips, and only those, to OpenAI. Their key comes
// from Doppler (`_shared/dev`, OPENAI_API_KEY) into this process's environment; it is never printed
// or written. `--engines` without them, or no key, keeps everything on this Mac.
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { BENCH, VOICES, WORDS, clips as setClips, synthesize, wordList } from "./lib.mjs";
import { report } from "./score.mjs";

const { values } = parseArgs({
  options: {
    set: { type: "string", default: "synthetic" },
    engines: { type: "string" },
    clips: { type: "string" },
    voices: { type: "string" },
    words: { type: "string", default: WORDS },
    text: { type: "boolean" },
  },
});

const all = [];
for (const name of readdirSync(join(import.meta.dirname, "engines")).filter((name) => name.endsWith(".mjs") && name !== "worker.mjs").sort())
  all.push(...(await import(`./engines/${name}`)).default);
const chosen = values.engines ? values.engines.split(",").map((id) => all.find((engine) => engine.id === id) ?? fail(`no engine ${id}: ${all.map((e) => e.id).join(", ")}`)) : all;
function fail(message) {
  console.error(message);
  process.exit(2);
}

if (values.set === "synthetic") synthesize(values.voices ? values.voices.split(",") : VOICES);
let clips = setClips(values.set);
if (values.voices) clips = clips.filter((clip) => values.voices.split(",").includes(clip.voice));
if (values.clips) clips = clips.filter((clip) => values.clips.split(",").includes(clip.id));
if (!clips.length) fail(values.set === "owner" ? "no clips: record them first (node harness/speech-bench/record.mjs)" : "no clips");

if (chosen.some((engine) => engine.online) && !process.env.OPENAI_API_KEY) {
  try {
    process.env.OPENAI_API_KEY = execFileSync("doppler", ["secrets", "get", "OPENAI_API_KEY", "--project", "_shared", "--config", "dev", "--plain"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    console.error("no OPENAI_API_KEY from Doppler: the online engines will not run");
  }
}

const date = new Date().toISOString().slice(0, 10);
const folder = join(BENCH, "results/runs", `${new Date().toISOString().replace(/[:.]/g, "-")}-${values.set}`);
const scratch = join(folder, "scratch");
mkdirSync(scratch, { recursive: true });
copyFileSync(values.words, join(folder, "words.md"));
const entries = wordList(readFileSync(values.words, "utf8"));
const voices = [...new Set(clips.map((clip) => clip.voice))];
writeFileSync(join(folder, "run.json"), JSON.stringify({ set: values.set, date, clips: clips.length, voices, engines: chosen.map((e) => e.id) }, null, 1));
console.error(`${clips.length} clips (${voices.join(", ")}, ${Math.round(clips.reduce((sum, clip) => sum + clip.seconds, 0))} s), ${chosen.length} engines -> ${folder}`);

async function bench(engine) {
  const { run, ...about } = engine;
  const started = performance.now();
  let result;
  try {
    const heard = await run(clips, { entries, wordsFile: values.words, scratch, log: (line) => process.stderr.write(`\r${line}        `) });
    result = { ...about, setup: heard.setup, clips: clips.map((clip, index) => ({ ...clip, ...heard.clips[index] })) };
  } catch (error) {
    result = { ...about, failed: error.message };
  }
  writeFileSync(join(folder, `${engine.id}.engine.json`), `${JSON.stringify(result, null, 1)}\n`);
  console.error(`\n${engine.id}: ${result.failed ? `did not run: ${result.failed}` : "done"} (${Math.round((performance.now() - started) / 1000)} s)`);
}

for (const engine of chosen.filter((engine) => !engine.online)) await bench(engine);
await Promise.all(chosen.filter((engine) => engine.online).map(bench));

report(folder, { text: values.text });
