// granite.mjs: IBM Granite Speech 5.0 470M TurboCTC (Apache 2.0, English, CTC: no word list) through Python
// mlx-audio (`mlx.py`, `granite_speech5_ctc`) on the GPU. Its text is lower case with no punctuation; the app's
// word-list repair writes the terms in their case. Whole utterance after the end. Granite-MLX
// (kylehowells/Granite-MLX, the Swift port) does not run here: its release's Metal library needs macOS 26, and
// a build from source needs Swift 6.2. Setup, once: the venv of oruk.mjs, then `hf download
// ibm-granite/granite-speech-5.0-470m-turboctc --local-dir BENCH/models/granite-turboctc`.
import { existsSync } from "node:fs";
import { join } from "node:path";
import { BENCH } from "../lib.mjs";
import { runWorker } from "./worker.mjs";

export default [
  {
    id: "granite-speech-5.0-470m-turboctc",
    name: "Granite Speech 5.0 470M TurboCTC (MLX)",
    runtime: "MLX (Python mlx-audio), GPU",
    streaming: false,
    downloadMegabytes: 948,
    costPerMinute: 0,
    async run(clips, { log }) {
      const python = join(BENCH, "venv/bin/python");
      const model = join(BENCH, "models/granite-turboctc");
      if (!existsSync(python) || !existsSync(join(model, "model.safetensors"))) throw new Error(`no venv or model in ${BENCH} (see engines/granite.mjs)`);
      return runWorker(python, ["-I", join(import.meta.dirname, "mlx.py"), model], clips, { log, label: "granite", env: { HF_HUB_OFFLINE: "1" } });
    },
  },
];
