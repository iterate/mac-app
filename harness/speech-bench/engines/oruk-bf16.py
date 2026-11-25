# oruk-bf16.py: the original BF16 checkpoint of Oruk Fourier 2B as an MLX folder, for the speech bench (engines/oruk.mjs).
# Oruk's examples/mlx-local/prepare.py without its quantization: the HF names mapped to the Qwen layout, mlx-audio's
# sanitize (the convolution transposes), then saved. In the bench's venv:
#
#   python -I oruk-bf16.py <folder of the checkpoint> <new MLX folder>
import json, shutil, sys
from pathlib import Path
import mlx.core as mx
from mlx_audio.lm.convert import save_config, save_model
from mlx_audio.stt.models.qwen3_asr import ModelConfig, Qwen3ASRModel

def legacy_key(name):
    if name.startswith("model.audio_tower."): return "thinker." + name.removeprefix("model.")
    if name.startswith("model.language_model."): return "thinker.model." + name.removeprefix("model.language_model.")
    if name.startswith("model.multi_modal_projector.linear_"): return "thinker.audio_tower.proj" + name.removeprefix("model.multi_modal_projector.linear_")
    raise ValueError(name)

source, out = Path(sys.argv[1]), Path(sys.argv[2])
config = json.loads((source / "config.json").read_text())
model = Qwen3ASRModel(ModelConfig.from_dict(config))
weights = mx.load(str(source / "model.safetensors"))
legacy = {legacy_key(k): v for k, v in weights.items()}
model.load_weights(list(model.sanitize(legacy).items()), strict=True)
out.mkdir()
for item in ("generation_config.json", "processor_config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"):
    shutil.copyfile(source / item, out / item)
save_model(out, model, donate_model=True)
save_config(config, config_path=out / "config.json")
print("done", out)
