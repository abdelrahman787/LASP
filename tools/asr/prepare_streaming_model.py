"""Prepare the streaming NeMo CTC model for sherpa-onnx.

Two transforms in one pass:
  1. Replace required cache inputs with zero-valued ONNX initializers so the
     graph has no cache inputs from sherpa-onnx's perspective.  sherpa-onnx
     only passes audio_signal + length; everything else must have a default.
  2. Inject the sherpa-onnx required metadata keys (vocab_size,
     subsampling_factor, normalize_type, model_type).

Why zero cache?  We feed complete VAD speech segments (not raw chunk streams),
so each segment always starts fresh — zero cache is exactly correct.  The
streaming model still outperforms the offline INT8 model on silence suppression
because it was trained with a cache-aware architecture.

Cache shapes (read from the model, hard-coded here for safety):
  cache_last_channel     float32  [1, 17, 70, 512]
  cache_last_time        float32  [1, 17, 512,  8]
  cache_last_channel_len int64    [1]              (value = 0 = empty cache)

Usage:
    pip install onnx numpy
    python tools/asr/prepare_streaming_model.py \\
        --in  assets/models/streaming/model_streaming_with_encoder.q8.onnx \\
        --out assets/models/streaming/model_streaming_final.onnx

Then run Gate-2:
    flutter run -t lib/dev/gate2_main.dart
"""

from __future__ import annotations
import argparse
import sys

try:
    import numpy as np
    import onnx
    from onnx import numpy_helper
except ImportError:
    sys.exit("Missing deps.  Run: pip install onnx numpy")


# ---------------------------------------------------------------------------
# Cache tensor specs — verified from model inspection on 2026-06-28.
# Change only if the model is re-downloaded and shapes differ.
# ---------------------------------------------------------------------------
_CACHE_SPECS: dict[str, tuple[str, tuple[int, ...]]] = {
    # name → (dtype_str, shape)
    "cache_last_channel":     ("float32", (1, 17, 70, 512)),
    "cache_last_time":        ("float32", (1, 17, 512, 8)),
    "cache_last_channel_len": ("int64",   (1,)),
}

# sherpa-onnx metadata (subsampling_factor=4 per CLAUDE.md for streaming model)
_SHERPA_META = {
    "vocab_size":         "1025",
    "subsampling_factor": "4",
    "normalize_type":     "per_feature",
    "model_type":         "EncDecCTCModelBPE",
    "comment":            "prepared by tools/asr/prepare_streaming_model.py",
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in",  dest="inp", required=True, help="input .onnx path")
    ap.add_argument("--out", dest="out", required=True, help="output .onnx path")
    args = ap.parse_args()

    print(f"Loading {args.inp} …")
    model = onnx.load(args.inp)

    # --- step 1: print current inputs ---
    current_inputs = [i.name for i in model.graph.input]
    init_names = {i.name for i in model.graph.initializer}
    required_inputs = [n for n in current_inputs if n not in init_names]
    print(f"Required inputs before patch: {required_inputs}")

    # --- step 2: add zero initializers for cache inputs ---
    added = []
    for name, (dtype_str, shape) in _CACHE_SPECS.items():
        if name not in current_inputs:
            print(f"  WARNING: '{name}' not in graph inputs — skipping")
            continue
        dtype_np = np.dtype(dtype_str)
        data = np.zeros(shape, dtype=dtype_np)
        tensor = numpy_helper.from_array(data, name=name)
        model.graph.initializer.append(tensor)
        added.append(name)
        print(f"  Added zero initializer: {name} {dtype_str}{list(shape)}")

    # --- step 3: remove cache inputs from graph.input so they are
    #             treated as constants (not user-providable inputs) ---
    keep = [i for i in model.graph.input if i.name not in set(added)]
    del model.graph.input[:]
    model.graph.input.extend(keep)
    remaining = [i.name for i in model.graph.input]
    print(f"Required inputs after patch: {remaining}")

    # --- step 4: inject sherpa-onnx metadata ---
    existing_keys = {p.key for p in model.metadata_props}
    for k, v in _SHERPA_META.items():
        if k in existing_keys:
            # update
            for p in model.metadata_props:
                if p.key == k:
                    p.value = v
        else:
            model.metadata_props.add(key=k, value=v)
    print("Metadata injected:")
    for k, v in _SHERPA_META.items():
        print(f"  {k} = {v}")

    # --- step 5: save ---
    onnx.save(model, args.out)
    print(f"\nWrote: {args.out}")
    print("Next: flutter run -t lib/dev/gate2_main.dart")


if __name__ == "__main__":
    main()
