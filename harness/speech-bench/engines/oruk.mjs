// oruk.mjs: Oruk Fourier 2B (a Qwen3-ASR fine-tune, MLX 8-bit, CC BY-NC 4.0: not for a commercial
// app) through Python mlx-audio (`mlx.py`), the word list's terms in its prompt. Whole utterance
// after the end. Setup, once: `uv venv --python 3.12 BENCH/venv`, `uv pip install mlx-audio==0.6.7
// soundfile`, `hf download oruk/oruk-fourier-2b --revision f1efa792 --include 'mlx/8bit/*'
// --local-dir BENCH/models/oruk`.
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BENCH } from "../lib.mjs";
import { runWorker } from "./worker.mjs";

export default [
  {
    id: "oruk-fourier-2b",
    name: "Oruk Fourier 2B (MLX 8-bit)",
    runtime: "MLX (Python mlx-audio), GPU",
    streaming: false,
    downloadMegabytes: 2480,
    costPerMinute: 0,
    async run(clips, { entries, log, scratch }) {
      const python = join(BENCH, "venv/bin/python");
      const model = join(BENCH, "models/oruk/mlx/8bit");
      if (!existsSync(python) || !existsSync(model)) throw new Error(`no venv or model in ${BENCH} (see engines/oruk.mjs)`);
      const terms = join(scratch, "oruk-terms.json");
      writeFileSync(terms, JSON.stringify(entries.map(({ term }) => term)));
      return runWorker(python, ["-I", join(import.meta.dirname, "mlx.py"), model, "--hotwords", terms, "--language", "English"], clips, {
        log,
        label: "oruk-fourier-2b",
        env: { HF_HUB_OFFLINE: "1" },
      });
    },
  },
];
