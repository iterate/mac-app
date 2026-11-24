// fluid-pro.mjs: Fluid Speech Pro as Core ML through the FluidVoice fork of FluidAudio (fluid-pro.swift),
// with the fork's vocabulary boosting of the word list. Whole utterance after the end. Setup, once:
// `git clone https://github.com/altic-dev/FluidAudio BENCH/src/fluidaudio-altic`, `hf download
// FluidVoice-Labs/fluid-speech-pro-coreml --local-dir BENCH/models/fluid-speech-pro`; the first run writes a
// throwaway package in BENCH/src/fluid-pro-bench and builds it (`swift build -c release`), after a small
// patch of the clone for Xcode 16 (patchFork).
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BENCH } from "../lib.mjs";
import { runWorker } from "./worker.mjs";

const PACKAGE = `// swift-tools-version: 6.0
// A throwaway package of the speech bench (harness/speech-bench/engines/fluid-pro.mjs): not the app.
import PackageDescription
let package = Package(
    name: "fluid-pro-bench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../fluidaudio-altic")],
    targets: [.executableTarget(name: "fluid-pro-bench", dependencies: [.product(name: "FluidAudio", package: "fluidaudio-altic")], path: "Sources")]
)
`;

/**
 * The fork needs Xcode 26 (Swift 6.2): its Granite managers fail Swift 6.1's sendability checks, and two
 * switches name `MLMultiArrayDataType.int8`, which the macOS 15 SDK does not have. Neither is on Parakeet
 * Pro's path. In the bench's own clone only: the library in Swift 5 mode, and those two cases behind
 * `#if compiler(>=6.2)`. Each change is made once.
 */
function patchFork(fork) {
  const edit = (file, change) => {
    const path = join(fork, file);
    const before = readFileSync(path, "utf8");
    const after = change(before);
    if (after !== before) writeFileSync(path, after);
  };
  edit("Package.swift", (text) =>
    text.includes("swiftLanguageMode(.v5)")
      ? text
      : text.replace(/(path: "Sources\/FluidAudio",\s*exclude: \[\s*"Frameworks"\s*\])/, "$1,\n            swiftSettings: [.swiftLanguageMode(.v5)]"),
  );
  for (const file of ["Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/NemotronStreamingAsrManager.swift", "Sources/FluidAudio/TTS/Kokoro/Pipeline/Synthesize/KokoroSynthesizer+Memory.swift"])
    edit(file, (text) => (text.includes("#if compiler(>=6.2)") ? text : text.replace(/\n([ \t]*case \.int8:\n[^\n]*\n)/, "\n#if compiler(>=6.2)\n$1#endif\n")));
}

export default [
  {
    id: "fluid-speech-pro",
    name: "Fluid Speech Pro (Core ML, FluidAudio fork)",
    runtime: "Core ML (altic-dev/FluidAudio)",
    streaming: false,
    downloadMegabytes: 652,
    costPerMinute: 0,
    async run(clips, { entries, log, scratch }) {
      const fork = join(BENCH, "src/fluidaudio-altic");
      const model = join(BENCH, "models/fluid-speech-pro");
      if (!existsSync(fork) || !existsSync(model)) throw new Error(`no fork or model in ${BENCH} (see engines/fluid-pro.mjs)`);
      const folder = join(BENCH, "src/fluid-pro-bench");
      mkdirSync(join(folder, "Sources"), { recursive: true });
      writeFileSync(join(folder, "Package.swift"), PACKAGE);
      const source = join(import.meta.dirname, "fluid-pro.swift");
      const copy = join(folder, "Sources/main.swift");
      if (!existsSync(copy) || readFileSync(copy, "utf8") !== readFileSync(source, "utf8")) copyFileSync(source, copy);
      patchFork(fork);
      log("fluid-speech-pro: swift build");
      try {
        execFileSync("swift", ["build", "-c", "release", "--package-path", folder], { stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 26 });
      } catch (error) {
        throw new Error(`the fork did not build: ${String(error.stdout ?? "").split("\n").filter((line) => line.includes("error:")).slice(0, 2).join(" | ") || error.message}`);
      }
      const terms = join(scratch, "fluid-pro-terms.json");
      writeFileSync(terms, JSON.stringify(entries));
      return runWorker(join(folder, ".build/release/fluid-pro-bench"), [model, terms], clips, { log, label: "fluid-speech-pro" });
    },
  },
];
