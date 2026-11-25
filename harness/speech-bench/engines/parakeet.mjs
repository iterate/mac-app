// parakeet.mjs: the app's own speech path, `speech-bench` (Sources/speech-bench): the app's
// recognizer on the clips, fed 0.1 s pieces at the pace of the clock, with the word list's repair.
// Parakeet v3 and Ultra run through FluidAudio as Core ML, with the word list's boosting; partials
// come twice a second. Their files are FluidAudio's, in ~/Library/Application Support/FluidAudio
// (shared with the app); the bench reads them and downloads nothing there. `fourier-app` is Oruk
// Fourier 2B as the app runs it (`FourierModel`: MLX 8-bit in the app's own Python process, the
// terms in its prompt, a partial pass at most once a second); its files are the app's
// (`FourierRuntime`, or `ITERATE_MAC_FOURIER_FOLDER`), and a first run downloads them (2.7 GB).
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "../lib.mjs";

const bench = join(ROOT, ".build/release/speech-bench");

function engine(id, name, downloadMegabytes, { model = id, runtime = "Core ML (FluidAudio), the app's recognizer" } = {}) {
  return {
    id,
    name,
    runtime,
    streaming: true,
    downloadMegabytes,
    costPerMinute: 0,
    async run(clips, { wordsFile, log }) {
      if (!existsSync(bench)) throw new Error("no speech-bench: run swift build -c release --product speech-bench");
      const lines = [];
      await new Promise((resolve, reject) => {
        const child = spawn(bench, ["--model", model, "--words", wordsFile, ...clips.map((clip) => clip.wav)], { stdio: ["ignore", "pipe", "pipe"] });
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

// each Parakeet with the 100 MB CTC model that hears the terms
export default [
  engine("parakeet-v3", "Parakeet TDT 0.6B v3", 580),
  engine("parakeet-ultra", "Parakeet Ultra", 732),
  engine("fourier-app", "Oruk Fourier 2B, the app's path", 2680, { model: "oruk-fourier-2b", runtime: "MLX (mlx-audio), the app's recognizer" }),
];
