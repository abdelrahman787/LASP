#!/usr/bin/env python3
"""GATE 0 — verify the Quran FastConformer-CTC ONNX model on a WAV file.

Per CLAUDE.md, this MUST pass (human confirms accuracy on their own voice/mic)
before any Flutter ASR code is written.

What it does:
  1. Loads `model_int8.onnx` and PRINTS its real input/output names + shapes, so
     we never guess the I/O signature (CLAUDE.md: "do NOT guess filenames").
  2. Reads a 16 kHz mono WAV, extracts 80-dim log-mel features matching NeMo's
     AudioToMelSpectrogramPreprocessor defaults (the model takes mel, not raw
     audio — CLAUDE.md fact #1).
  3. Runs the model, greedy-CTC-decodes (blank id = 1024), detokenizes via the
     SentencePiece tokenizer (or tokens.txt), and prints the recognized text + RTF.

Setup (on a machine WITH HuggingFace access — this sandbox is firewalled off HF):
    pip install onnxruntime librosa soundfile sentencepiece numpy
    huggingface-cli download Saboorhsn/quran-stt-onnx onnx/model_int8.onnx \
        tokenizer.model tokens.txt --local-dir ./quran-stt

Run:
    python tools/asr/gate0_verify.py \
        --model ./quran-stt/onnx/model_int8.onnx \
        --tokenizer ./quran-stt/tokenizer.model \
        --tokens ./quran-stt/tokens.txt \
        --wav some_ayah.wav

IMPORTANT — accuracy caveat: the #1 risk is a mel-parameter mismatch vs. how the
model was trained. These defaults follow NeMo's standard FastConformer
preprocessor, but if the printed text is garbage while the model loads fine,
cross-check the mel params against the HuggingFace model card's reference
pipeline (n_fft / win / hop / n_mels / normalize / preemph / mel norm) and tweak
the constants below. Report findings back.
"""

from __future__ import annotations

import argparse
import time

import numpy as np

# NeMo AudioToMelSpectrogramPreprocessor defaults for FastConformer (16 kHz).
SAMPLE_RATE = 16000
N_MELS = 80
WIN_LENGTH = int(0.025 * SAMPLE_RATE)   # 400
HOP_LENGTH = int(0.010 * SAMPLE_RATE)   # 160  → 10 ms hop (CLAUDE.md)
N_FFT = 512                              # next pow2 ≥ win_length
PREEMPH = 0.97
LOG_ZERO_GUARD = 2.0 ** -24             # NeMo log_zero_guard_value default


def extract_logmel(wav: np.ndarray) -> np.ndarray:
    """80-dim log-mel, NeMo-style, returned as [n_mels, T] float32."""
    import librosa

    x = wav.astype(np.float32)
    # Pre-emphasis (NeMo applies preemph before STFT).
    if PREEMPH:
        x = np.append(x[0], x[1:] - PREEMPH * x[:-1])

    # Power mel-spectrogram (slaney mel like librosa/NeMo default).
    mel = librosa.feature.melspectrogram(
        y=x, sr=SAMPLE_RATE, n_fft=N_FFT, hop_length=HOP_LENGTH,
        win_length=WIN_LENGTH, window="hann", center=True,
        n_mels=N_MELS, power=2.0, fmin=0.0, fmax=SAMPLE_RATE / 2,
    )
    feats = np.log(mel + LOG_ZERO_GUARD)

    # Per-feature normalization (NeMo normalize="per_feature"): zero mean / unit
    # std per mel bin across time.
    mean = feats.mean(axis=1, keepdims=True)
    std = feats.std(axis=1, keepdims=True)
    feats = (feats - mean) / (std + 1e-5)
    return feats.astype(np.float32)


def load_tokens(tokens_path: str | None):
    if not tokens_path:
        return None
    id2tok = {}
    with open(tokens_path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split()
            if len(parts) >= 2:
                tok, idx = parts[0], int(parts[-1])
                id2tok[idx] = tok
            elif len(parts) == 1:
                id2tok[len(id2tok)] = parts[0]
    return id2tok


def greedy_ctc(logprobs: np.ndarray, blank: int) -> list[int]:
    """logprobs [T, V] → collapsed, blank-stripped token ids."""
    best = logprobs.argmax(axis=-1)
    out, prev = [], -1
    for t in best:
        t = int(t)
        if t != prev and t != blank:
            out.append(t)
        prev = t
    return out


def detok(ids, sp, id2tok):
    if sp is not None:
        try:
            return sp.decode(ids)
        except Exception:
            pass
    if id2tok is not None:
        pieces = [id2tok.get(i, "") for i in ids]
        return "".join(pieces).replace("▁", " ").strip()  # ▁ → space
    return " ".join(map(str, ids))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--wav", required=True)
    ap.add_argument("--tokenizer", default=None, help="SentencePiece .model")
    ap.add_argument("--tokens", default=None, help="tokens.txt (id↔piece)")
    ap.add_argument("--blank", type=int, default=1024)
    args = ap.parse_args()

    import librosa
    import onnxruntime as ort

    sp = None
    if args.tokenizer:
        import sentencepiece as spm
        sp = spm.SentencePieceProcessor(model_file=args.tokenizer)
    id2tok = load_tokens(args.tokens)

    sess = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    print("=== ONNX model signature ===")
    for i in sess.get_inputs():
        print(f"  IN  {i.name:24s} {i.shape}  {i.type}")
    for o in sess.get_outputs():
        print(f"  OUT {o.name:24s} {o.shape}  {o.type}")

    wav, _ = librosa.load(args.wav, sr=SAMPLE_RATE, mono=True)
    audio_secs = len(wav) / SAMPLE_RATE

    feats = extract_logmel(wav)                 # [80, T]
    length = np.array([feats.shape[1]], dtype=np.int64)
    feats_b = feats[np.newaxis, :, :]           # [1, 80, T]

    # Map our tensors to the model's actual input names (introspected above) so
    # we don't hardcode names. FastConformer-CTC exports usually expose a mel
    # input ("audio_signal"/"features"/"x") and a length input ("length"/"len").
    feeds = {}
    for inp in sess.get_inputs():
        n = inp.name.lower()
        rank = len(inp.shape)
        if rank == 3:
            feeds[inp.name] = feats_b
        elif rank == 1 or "len" in n:
            feeds[inp.name] = length
        else:
            raise SystemExit(
                f"Unexpected input '{inp.name}' shape {inp.shape}. If this model "
                f"takes RAW audio or streaming caches, adapt feeds here per the "
                f"model card.")

    t0 = time.perf_counter()
    outs = sess.run(None, feeds)
    dt = time.perf_counter() - t0

    logits = outs[0]
    logits = np.asarray(logits)
    if logits.ndim == 3:
        logits = logits[0]                      # [T, V]
    # If the head emits logits (not logprobs) greedy argmax is identical anyway.
    ids = greedy_ctc(logits, blank=args.blank)
    text = detok(ids, sp, id2tok)

    print("\n=== RESULT ===")
    print(f"audio    : {audio_secs:.2f}s")
    print(f"infer    : {dt * 1000:.0f} ms   RTF={dt / audio_secs:.3f}")
    print(f"tokens   : {len(ids)}  (vocab dim={logits.shape[-1]}, blank={args.blank})")
    print(f"text     : {text}")


if __name__ == "__main__":
    main()
