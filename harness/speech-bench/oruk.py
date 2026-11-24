# oruk.py: Oruk Fourier 2B (MLX 8-bit, CC BY-NC 4.0) on sound files, for speech-bench (run.mjs).
# Not a model of the app: it runs on Python mlx-audio, in a venv of the bench alone.
#
#   python -I oruk.py <mlx model folder> <words.md> <file.wav> ...
#
# stdout is speech-bench's JSON lines: the load, then one line for each file. The model hears a
# whole file at once, so `finalAfterEnd` is the time it takes for the file after its end. The
# word list's terms go into its prompt (`hotwords`); there is no CTC rescoring for it.
import json
import sys
import time

from mlx_audio.stt.utils import load_model

folder, words, files = sys.argv[1], sys.argv[2], sys.argv[3:]
terms = [line[2:].split(":")[0].strip() for line in open(words, encoding="utf-8") if line.startswith("- ")]
started = time.time()
model = load_model(folder)
print(json.dumps({"model": "oruk-fourier-2b", "loadSeconds": time.time() - started, "wasOnDisk": True}), flush=True)
for file in files:
    started = time.time()
    result = model.generate(file, language="English", hotwords=[term for term in terms if term])
    took = time.time() - started
    segments = getattr(result, "segments", None) or []
    timed = [{"t": int(s["start"] * 1000), "to": int(s["end"] * 1000), "text": s["text"].strip()} for s in segments if isinstance(s, dict) and "start" in s]
    print(json.dumps({"file": file, "finalAfterEnd": took, "segments": timed or [{"t": 0, "to": 0, "text": result.text.strip()}]}), flush=True)
