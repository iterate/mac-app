// phonon.mjs: Phonon-2.5 English as Core ML on the Neural Engine (`phonon.py`, the package's own C library),
// with 25 hotwords: the decoder takes at most 25. Whole utterance after the end. Setup, once: `uv venv --python
// 3.12 BENCH/venv-fermion`, `uv pip install fermion-research` (for its hotword tables), `hf download
// FermionResearch/Phonon-2.5-English-CoreML --local-dir BENCH/models/phonon --exclude 'detta/*' --exclude 'ci/*'`.
// The first load prepares the package for the Neural Engine (about 4 minutes on an M4 Max), once.
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BENCH } from "../lib.mjs";
import { runWorker } from "./worker.mjs";

/**
 * The 25 terms the decoder favours: of words.md's terms, those the owner says most and a model gets wrong
 * (most have wrong forms in the list), and no term that is an everyday word.
 */
export const HOTWORDS = [
  "iterate", "Templestein", "Herdr", "Beelink", "Claude Code", "Codex", "itx", "mmkal", "Misha Kaletsky", "Jeeves",
  "garple", "Nustom", "capnweb", "liveState", "RpcTarget", "RpcStub", "workerd", "Doppler", "AGENTS.md", "Wispr Flow",
  "YubiKey", "Plannotator", "tRPC", "sqlfu", "shadcn",
];

export default [
  {
    id: "phonon-2.5-english",
    name: "Phonon-2.5 English (Core ML)",
    runtime: "Core ML (libphonon_coreml), Neural Engine",
    streaming: false,
    downloadMegabytes: 355,
    costPerMinute: 0,
    async run(clips, { entries, log, scratch }) {
      const python = join(BENCH, "venv-fermion/bin/python");
      const bundle = join(BENCH, "models/phonon");
      if (!existsSync(python) || !existsSync(join(bundle, "bin/libphonon_coreml.dylib"))) throw new Error(`no venv-fermion or package in ${BENCH} (see engines/phonon.mjs)`);
      const terms = entries.map(({ term }) => term);
      const words = join(scratch, "phonon-hotwords.json");
      writeFileSync(words, JSON.stringify(HOTWORDS.filter((term) => terms.includes(term))));
      return runWorker(python, ["-I", join(import.meta.dirname, "phonon.py"), bundle, words], clips, { log, label: "phonon" });
    },
  },
];
