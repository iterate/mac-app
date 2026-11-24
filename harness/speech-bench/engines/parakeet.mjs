// parakeet.mjs: the app's own speech path, Parakeet v3 and Ultra through FluidAudio as Core ML, with
// the word list's boosting and repair: `speech-bench` (Sources/speech-bench), the app's recognizer
// on the clips, fed 0.1 s pieces at the pace of the clock. Partials come twice a second, as in the
// app. Their files are FluidAudio's, in ~/Library/Application Support/FluidAudio (shared with the
// app); the bench reads them and downloads nothing there.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "../lib.mjs";

const bench = join(ROOT, ".build/release/speech-bench");

function engine(id, name, megabytes) {
  return {
    id,
    name,
    runtime: "Core ML (FluidAudio), the app's recognizer",
    streaming: true,
    // the model and the 100 MB CTC model that hears the terms
    downloadMegabytes: megabytes + 100,
    costPerMinute: 0,
    async run(clips, { wordsFile, log }) {
      if (!existsSync(bench)) throw new Error("no speech-bench: run swift build -c release --product speech-bench");
      const lines = [];
      await new Promise((resolve, reject) => {
        const child = spawn(bench, ["--model", id, "--words", wordsFile, ...clips.map((clip) => clip.wav)], { stdio: ["ignore", "pipe", "pipe"] });
        let rest = "";
        child.stdout.on("data", (data) => {
          rest += data;
          const parts = rest.split("\n");
          rest = parts.pop();
          for (const part of parts.filter(Boolean)) {
            const line = JSON.parse(part);
            lines.push(line);
            if (line.file) log(`${id} ${lines.length - 1}/${clips.length}`);
          }
        });
        child.stderr.on("data", () => {});
        child.on("error", reject);
        child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`speech-bench exited ${code}`))));
      });
      const [load, ...heard] = lines;
      if (load.failed) throw new Error(load.failed);
      return {
        setup: { launchSeconds: load.loadSeconds, warmSeconds: load.warmSeconds, wasOnDisk: load.wasOnDisk },
        clips: clips.map((clip, index) => {
          const line = heard[index];
          if (!line || line.failed) return { error: line?.failed ?? "no line" };
          return {
            text: line.segments.map((segment) => segment.text).join(" "),
            partials: line.partials,
            firstPartialMs: line.partials[0]?.t,
            endToFinalMs: line.finalAfterEnd * 1000,
          };
        }),
      };
    },
  };
}

export default [engine("parakeet-v3", "Parakeet TDT 0.6B v3", 480), engine("parakeet-ultra", "Parakeet Ultra", 632)];
