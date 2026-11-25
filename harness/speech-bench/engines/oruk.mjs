// oruk.mjs: Oruk Fourier 2B (a Qwen3-ASR fine-tune, CC BY-NC 4.0: not for a commercial app) through
// Python mlx-audio (`mlx.py`), the word list's terms in its prompt. Whole utterance after the end.
// Two forms: MLX 8-bit (Oruk's `mlx/8bit`, what the app runs) and BF16 (the original checkpoint,
// converted to MLX by `oruk-bf16.py`). Setup, once: `uv venv --python 3.12 BENCH/venv`,
// `uv pip install mlx-audio==0.6.7 soundfile`, `hf download oruk/oruk-fourier-2b --revision f1efa792
// --include 'mlx/8bit/*' --local-dir BENCH/models/oruk`; for BF16, `hf download … --include
// model.safetensors '*.json' chat_template.jinja --local-dir BENCH/models/oruk/bf16-source`, then
// `BENCH/venv/bin/python -I engines/oruk-bf16.py BENCH/models/oruk/bf16-source BENCH/models/oruk/mlx/bf16`.
// `ORUK_BF16_MODEL` names another BF16 folder. The app's own path is `fourier.mjs`.
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BENCH } from "../lib.mjs";
import { runWorker } from "./worker.mjs";

function engine(id, name, folder, downloadMegabytes) {
  return {
    id,
    name,
    runtime: "MLX (Python mlx-audio), GPU",
    streaming: false,
    downloadMegabytes,
    costPerMinute: 0,
    async run(clips, { entries, log, scratch }) {
      const python = join(BENCH, "venv/bin/python");
      const model = folder();
      if (!existsSync(python) || !existsSync(model)) throw new Error(`no venv in ${BENCH} or no model in ${model} (see engines/oruk.mjs)`);
      const terms = join(scratch, `${id}-terms.json`);
      writeFileSync(terms, JSON.stringify(entries.map(({ term }) => term)));
      return runWorker(python, ["-I", join(import.meta.dirname, "mlx.py"), model, "--hotwords", terms, "--language", "English"], clips, {
        log,
        label: id,
        env: { HF_HUB_OFFLINE: "1" },
      });
    },
  };
}

export default [
  engine("oruk-fourier-2b", "Oruk Fourier 2B (MLX 8-bit)", () => join(BENCH, "models/oruk/mlx/8bit"), 2480),
  engine("oruk-fourier-2b-bf16", "Oruk Fourier 2B (MLX BF16)", () => process.env.ORUK_BF16_MODEL ?? join(BENCH, "models/oruk/mlx/bf16"), 4080),
];
