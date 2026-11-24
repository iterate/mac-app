# mlx.py: a speech model of Python mlx-audio for the speech bench (engines/oruk.mjs, engines/granite.mjs), in the
# bench's venv (~/.cache/iterate-speech-bench/venv). Not a model of the app.
#
#   python -I mlx.py <model folder> [--hotwords <terms.json>] [--language English]    then one WAV path a line on stdin
#
# stdout is JSON lines: the load (`loadSeconds`, with a warm-up on one second of silence, as an app would do at
# its start), then `{ file, text, seconds }` for each path, where `seconds` is the time from the call to the text.
# The model hears a whole utterance at once. `--hotwords` gives the word list's terms to a model that takes them
# (Oruk Fourier: mlx-audio folds them into its system prompt); Granite TurboCTC takes none.
import argparse
import json
import sys
import time

import numpy as np
from mlx_audio.stt.utils import load_model

parser = argparse.ArgumentParser()
parser.add_argument("model")
parser.add_argument("--hotwords")
parser.add_argument("--language")
args = parser.parse_args()
options = {}
if args.hotwords:
    options["hotwords"] = json.load(open(args.hotwords, encoding="utf-8"))
if args.language:
    options["language"] = args.language
started = time.time()
model = load_model(args.model)
model.generate(np.zeros(16000, dtype=np.float32), **options)
print(json.dumps({"loadSeconds": time.time() - started}), flush=True)
for line in sys.stdin:
    file = line.strip()
    if not file:
        continue
    started = time.time()
    try:
        result = model.generate(file, **options)
        print(json.dumps({"file": file, "text": result.text.strip(), "seconds": time.time() - started}), flush=True)
    except Exception as error:
        print(json.dumps({"file": file, "error": str(error)}), flush=True)
