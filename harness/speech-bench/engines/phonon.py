# phonon.py: Phonon-2.5 English as Core ML on the Neural Engine (FermionResearch/Phonon-2.5-English-CoreML,
# CC BY 4.0, a fine-tune of Parakeet TDT 0.6B v3) for the speech bench (engines/phonon.mjs), through the
# package's own C library (bin/libphonon_coreml.dylib) and ctypes. The hotwords: the package's CLI takes
# none, but its decoder takes the bias tables of the `fermion` package (fermion/_speech/hotwords.py, an
# Aho-Corasick automaton over the vocabulary's pieces, at most 25 words), which this builds and passes to
# `pcm_decode`.
#
#   python -I phonon.py <bundle folder> <hotwords.json>    then one WAV path a line on stdin
#
# stdout is JSON lines: the load (`loadSeconds`, all four encoder windows loaded; `compiled`: whether
# this load prepared the package for the Neural Engine, which happens once), then `{ file, text, seconds }`
# for each path. Whole utterance at once; a clip is at most 35 s, one window.
import ctypes
import json
import sys
import time
import wave

import numpy as np
from fermion._speech.hotwords import HotwordAutomaton

bundle, words_file = sys.argv[1], sys.argv[2]
words = json.load(open(words_file, encoding="utf-8"))
lib = ctypes.CDLL(f"{bundle}/bin/libphonon_coreml.dylib")
lib.pcm_needs_compile.argtypes = [ctypes.c_char_p]
lib.pcm_open.restype = ctypes.c_void_p
lib.pcm_open.argtypes = [ctypes.c_char_p, ctypes.c_int32, ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]
lib.pcm_vocab_json.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]
lib.pcm_preload_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]
lib.pcm_wait_all.argtypes = [ctypes.c_void_p]
I32 = ctypes.POINTER(ctypes.c_int32)
lib.pcm_decode.restype = ctypes.c_int32
lib.pcm_decode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int32,
                           ctypes.c_int32, ctypes.c_int32, I32, I32, I32, ctypes.c_int32, I32, ctypes.c_float,
                           I32, I32, I32, ctypes.c_int32, ctypes.POINTER(ctypes.c_double), ctypes.c_char_p, ctypes.c_int32]
err = ctypes.create_string_buffer(2048)

started = time.time()
compiled = lib.pcm_needs_compile(bundle.encode()) == 1
handle = lib.pcm_open(bundle.encode(), 4, 0, err, len(err))
if not handle:
    sys.exit(err.value.decode())
if lib.pcm_preload_all(handle, err, len(err)) != 0:
    sys.exit(err.value.decode())
lib.pcm_wait_all(handle)
size = lib.pcm_vocab_json(handle, None, 0)
buffer = ctypes.create_string_buffer(size)
lib.pcm_vocab_json(handle, buffer, size)
vocab = json.loads(buffer.value.decode())
vocab = vocab["vocab"] if isinstance(vocab, dict) else vocab
automaton = HotwordAutomaton(words, vocab) if words else None
# the runtime's own leading pad (manifest.json `leading_pad_s`)
pad = np.zeros(4000, dtype=np.float32)


def decode(samples):
    samples = np.ascontiguousarray(np.concatenate([pad, samples]), dtype=np.float32)
    cap = 4096
    tokens, frames, durations = (np.zeros(cap, dtype=np.int32) for _ in range(3))
    timing = (ctypes.c_double * 4)()
    as_i32 = lambda a: a.ctypes.data_as(I32)
    if automaton:
        a = automaton
        n = lib.pcm_decode(handle, samples.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), len(samples),
                           a.n_states, len(a.toks), as_i32(a.table), as_i32(a.toks), as_i32(a.col), len(a.col), as_i32(a.depth), a.lam,
                           as_i32(tokens), as_i32(frames), as_i32(durations), cap, timing, err, len(err))
    else:
        n = lib.pcm_decode(handle, samples.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), len(samples),
                           0, 0, None, None, None, 0, None, 0.0,
                           as_i32(tokens), as_i32(frames), as_i32(durations), cap, timing, err, len(err))
    if n < 0:
        raise RuntimeError(err.value.decode())
    return "".join(vocab[t] for t in tokens[:n] if t < len(vocab)).replace("▁", " ").strip()


decode(np.zeros(16000, dtype=np.float32))
print(json.dumps({"loadSeconds": time.time() - started, "compiled": compiled, "hotwords": automaton.words if automaton else []}), flush=True)
for line in sys.stdin:
    file = line.strip()
    if not file:
        continue
    started = time.time()
    try:
        with wave.open(file) as w:
            samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
        print(json.dumps({"file": file, "text": decode(samples), "seconds": time.time() - started}), flush=True)
    except Exception as error:
        print(json.dumps({"file": file, "error": str(error)}), flush=True)
