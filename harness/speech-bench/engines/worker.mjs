// worker.mjs: a model that hears a whole utterance at once (not streaming), as a worker process
// that holds it: its first stdout line is the load, `{ loadSeconds }`, then each WAV path written
// to its stdin gives one line, `{ file, text }`. The bench writes a path at the end of the clip's
// sound, so the time to the line is the time from the end of the audio to the final text.
//
// Such a model does nothing while the audio streams in (it has no partials), so the bench does not
// wait out each clip: the time it measures is the same as after a real-time stream.
import { spawn } from "node:child_process";

export async function runWorker(command, args, clips, { log, label, env = {} }) {
  const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, ...env } });
  const waiting = [];
  let rest = "";
  let errors = "";
  child.stdout.on("data", (data) => {
    rest += data;
    const parts = rest.split("\n");
    rest = parts.pop();
    for (const part of parts.filter(Boolean)) waiting.shift()?.resolve(JSON.parse(part));
  });
  child.stderr.on("data", (data) => (errors = (errors + data).slice(-4000)));
  child.on("exit", (code) => {
    for (const { reject } of waiting.splice(0)) reject(new Error(`${label} exited ${code}: ${errors.trim().split("\n").slice(-3).join(" | ")}`));
  });
  const next = () => new Promise((resolve, reject) => waiting.push({ resolve, reject }));
  try {
    const started = performance.now();
    const load = await next();
    const launchSeconds = load.loadSeconds ?? (performance.now() - started) / 1000;
    const results = [];
    for (const [index, clip] of clips.entries()) {
      const line = next();
      const ended = performance.now();
      child.stdin.write(`${clip.wav}\n`);
      const heard = await line;
      const endToFinalMs = performance.now() - ended;
      results.push(heard.error ? { error: heard.error } : { text: heard.text, partials: [], endToFinalMs, modelMs: heard.seconds * 1000 });
      log(`${label} ${index + 1}/${clips.length}`);
    }
    return { setup: { launchSeconds, warmSeconds: 0 }, clips: results };
  } finally {
    child.stdin.end();
    child.kill();
  }
}
