#!/usr/bin/env python3
"""Inject the metadata sherpa-onnx requires into a NeMo FastConformer-CTC ONNX.

WHY: sherpa-onnx's OFFLINE NeMo-CTC reader REQUIRES these ONNX metadata keys
(verified against sherpa-onnx/csrc/offline-nemo-enc-dec-ctc-model.cc):
    vocab_size          (REQUIRED — error if missing)
    subsampling_factor  (REQUIRED — error if missing)
    normalize_type      (optional, but the model was trained with per_feature)
A plain `torch.onnx.export` / generic onnxruntime export (like
Saboorhsn/quran-stt-onnx) does NOT carry these, so sherpa rejects the model at
construction. This script adds them IN A COPY (never mutates the input).

Run this ONLY after Gate 1 has reported the missing-metadata error — so we patch
in response to a real failure, not speculatively.

    pip install onnx
    python tools/asr/add_sherpa_metadata.py \
        --in  assets/models/tarteel/model_int8.onnx \
        --out assets/models/tarteel/model_int8.sherpa.onnx

Then point Gate 1 at the patched file and re-run.

VALUES:
  - vocab_size:  auto-detected from the model's CTC output tensor last dim
    (CLAUDE.md: logprobs [T, 1025], blank id = 1024 → vocab_size = 1025). Override
    with --vocab-size if detection looks wrong.
  - subsampling_factor: 8. FastConformer uses an 8x depthwise-conv subsampling
    stack — this is a fixed architectural fact for FastConformer, not a guess.
  - normalize_type: "per_feature" — matches NeMo's AudioToMelSpectrogram default
    and the Gate-0 mel extraction. Override with --normalize-type if the model
    card says otherwise.

If sherpa still rejects or transcribes garbage after patching, the remaining
suspects are (a) the model was exported WITHOUT sherpa's expected I/O contract
(it must take features [B,80,T] + length and emit log-probs [B,T,V]) or (b) a
feature-extraction mismatch — at which point we re-export with sherpa's
export-onnx-ctc.py from the NeMo checkpoint, or fall back to raw onnxruntime.
Report findings; do not silently keep tweaking.
"""

from __future__ import annotations

import argparse

import onnx


def detect_vocab_size(model: onnx.ModelProto) -> int | None:
    """Last dim of the first graph output (the CTC log-probs tensor)."""
    if not model.graph.output:
        return None
    out = model.graph.output[0]
    dims = out.type.tensor_type.shape.dim
    if not dims:
        return None
    last = dims[-1]
    return last.dim_value if last.dim_value > 0 else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", dest="out", required=True)
    ap.add_argument("--vocab-size", type=int, default=None,
                    help="override auto-detected vocab size")
    ap.add_argument("--subsampling-factor", type=int, default=8)
    ap.add_argument("--normalize-type", default="per_feature")
    ap.add_argument("--model-type", default="EncDecCTCModelBPE")
    args = ap.parse_args()

    model = onnx.load(args.inp)

    print("=== existing metadata ===")
    existing = {p.key: p.value for p in model.metadata_props}
    for k, v in existing.items():
        print(f"  {k} = {v}")
    if not existing:
        print("  (none — this is why sherpa rejects it)")

    print("\n=== model outputs ===")
    for o in model.graph.output:
        dims = [d.dim_value if d.dim_value > 0 else d.dim_param
                for d in o.type.tensor_type.shape.dim]
        print(f"  {o.name}: {dims}")

    vocab = args.vocab_size or detect_vocab_size(model)
    if vocab is None:
        raise SystemExit(
            "Could not auto-detect vocab_size (output last dim is dynamic). "
            "Pass --vocab-size explicitly (CLAUDE.md says 1025).")

    new_meta = {
        "vocab_size": str(vocab),
        "subsampling_factor": str(args.subsampling_factor),
        "normalize_type": args.normalize_type,
        "model_type": args.model_type,
        "comment": "metadata injected by tools/asr/add_sherpa_metadata.py for sherpa-onnx",
    }

    # Upsert without duplicating keys.
    keep = [p for p in model.metadata_props if p.key not in new_meta]
    del model.metadata_props[:]
    model.metadata_props.extend(keep)
    for k, v in new_meta.items():
        model.metadata_props.add(key=k, value=v)

    onnx.save(model, args.out)
    print("\n=== wrote ===")
    print(f"  {args.out}")
    for k, v in new_meta.items():
        print(f"  +{k} = {v}")
    print("\nNow re-run Gate 1 pointing at the patched model.")


if __name__ == "__main__":
    main()
