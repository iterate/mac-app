#!/usr/bin/env node
// record.mjs: the owner's own voice for the speech bench (README, "The speech bench"). It shows one
// sentence of sentences.md at a time and records the Mac's default microphone (ffmpeg's avfoundation,
// 16 kHz mono) into BENCH/clips/NN.wav, with the sentence as NN.txt: the reference. The clips stay in
// ~/.cache/iterate-speech-bench, never in the repo. macOS asks once for the microphone for this terminal.
//
//   node harness/speech-bench/record.mjs [--from NN] [--missing] [--list]
//
// Enter starts a take, Enter ends it. Then: Enter or n for the next sentence, r to say it again,
// l to listen to the take, p for the previous one, q to quit. Say each sentence as you would say it
// to an agent, and end the take as you would let go of fn: the end of the take is "let go".
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { BENCH, sentences, wavSeconds } from "./lib.mjs";

const { values } = parseArgs({ options: { from: { type: "string" }, missing: { type: "boolean" }, list: { type: "boolean" } } });
const folder = join(BENCH, "clips");
const list = sentences();
const recorded = (id) => existsSync(join(folder, `${id}.wav`));
const bold = (text) => `\x1b[1m${text}\x1b[0m`;
const dim = (text) => `\x1b[2m${text}\x1b[0m`;

function overview() {
  for (const { id, kind, text } of list) console.log(`${recorded(id) ? "✓" : " "} ${id} ${dim(`[${kind}]`)} ${text}`);
  console.log(dim(`\n${list.filter(({ id }) => recorded(id)).length} of ${list.length} recorded, in ${folder}`));
}

if (values.list || !process.stdin.isTTY) {
  overview();
  if (!values.list) console.log("\nrecord.mjs needs a terminal: run it yourself, in Terminal or Ghostty.");
  process.exit(0);
}
if (spawnSync("ffmpeg", ["-version"]).status !== 0) {
  console.error("record.mjs needs ffmpeg (brew install ffmpeg)");
  process.exit(1);
}
mkdirSync(folder, { recursive: true });

let index = values.from ? Math.max(0, list.findIndex(({ id }) => id === values.from.padStart(2, "0"))) : 0;
if (values.missing) index = Math.max(0, list.findIndex(({ id }) => !recorded(id)));

/** keys, one at a time */
process.stdin.setRawMode(true);
process.stdin.setEncoding("utf8");
const key = () => new Promise((resolve) => process.stdin.once("data", (data) => resolve(data === "\u0003" ? "q" : data)));

/** One take: starts at once, ends at the next Enter. Resolves with the file, or nothing if it was too short. */
async function take(id) {
  const part = join(folder, `${id}.part.wav`);
  const ffmpeg = spawn("ffmpeg", ["-hide_banner", "-nostats", "-f", "avfoundation", "-i", ":default", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-y", part], {
    stdio: ["pipe", "ignore", "pipe"],
  });
  let log = "";
  // speak once ffmpeg has the microphone open: it says so before it writes
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 3000);
    ffmpeg.stderr.on("data", (data) => {
      log += data;
      if (/Press \[q\]|Output #0/.test(log)) clearTimeout(timer), resolve();
    });
    ffmpeg.on("exit", () => (clearTimeout(timer), resolve()));
  });
  if (ffmpeg.exitCode !== null) {
    console.log(`\nffmpeg did not record:\n${log.trim().split("\n").slice(-4).join("\n")}`);
    console.log("If macOS denied the microphone: System Settings › Privacy & Security › Microphone › this terminal.");
    return;
  }
  const started = Date.now();
  const clock = setInterval(() => process.stdout.write(`\r\x1b[31m● recording\x1b[0m ${((Date.now() - started) / 1000).toFixed(1)} s · Enter to stop `), 100);
  while ((await key()) !== "\r");
  clearInterval(clock);
  const ended = new Promise((resolve) => ffmpeg.on("exit", resolve));
  ffmpeg.stdin.write("q");
  await ended;
  process.stdout.write("\r\x1b[K");
  const seconds = existsSync(part) ? wavSeconds(part) : 0;
  if (seconds < 1) {
    console.log(`too short (${seconds.toFixed(1)} s): not kept`);
    return;
  }
  const wav = join(folder, `${id}.wav`);
  renameSync(part, wav);
  console.log(`kept ${seconds.toFixed(1)} s → ${wav}`);
  return wav;
}

console.log(bold("The speech bench: your own voice"));
console.log(dim("Enter starts a take, Enter ends it. Say it as you would say it to an agent; stop as you would let go of fn.\n"));
while (index < list.length) {
  const { id, kind, text } = list[index];
  console.log(`\n${bold(`${id}/${list.length}`)} ${dim(`[${kind}]${recorded(id) ? " · recorded" : ""}`)}\n\n  ${bold(text)}\n`);
  console.log(dim("Enter: record · n: next · p: previous · q: quit"));
  let next = await key();
  if (next === "q") break;
  if (next === "p") {
    index = Math.max(0, index - 1);
    continue;
  }
  if (next === "n") {
    index++;
    continue;
  }
  if (next !== "\r") continue;
  for (;;) {
    const wav = await take(id);
    if (wav) writeFileSync(join(folder, `${id}.txt`), `${text}\n`);
    console.log(dim(wav ? "Enter or n: next · r: again · l: listen · q: quit" : "r: again · n: next · q: quit"));
    next = await key();
    while (next === "l" && wav) {
      spawnSync("afplay", [wav]);
      next = await key();
    }
    if (next !== "r") break;
  }
  if (next === "q") break;
  index++;
}
process.stdin.setRawMode(false);
console.log();
overview();
console.log(`\nThen: node harness/speech-bench/run.mjs --set owner`);
process.exit(0);
