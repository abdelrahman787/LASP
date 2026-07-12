"""Convert tokenizer.model (SentencePiece BPE) → tokens.txt for sherpa-onnx.

Usage:
    pip install sentencepiece
    python tools/asr/convert_tokenizer.py \
        --model  assets/models/streaming/tokenizer.model \
        --output assets/models/streaming/tokens.txt

The model vocab has 1024 tokens (ids 0–1023). We append the CTC blank token
(<blk> 1024) that sherpa-onnx requires but which the downloaded tokens.txt
omits. Running this script twice is safe (idempotent).
"""

import argparse
import sys

try:
    import sentencepiece as spm
except ImportError:
    sys.exit("sentencepiece not installed.  Run: pip install sentencepiece")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model",  default="assets/models/streaming/tokenizer.model")
    ap.add_argument("--output", default="assets/models/streaming/tokens.txt")
    args = ap.parse_args()

    sp = spm.SentencePieceProcessor()
    sp.Load(args.model)
    vocab_size = sp.GetPieceSize()   # should be 1024
    print(f"SentencePiece vocab size: {vocab_size}")

    lines = []
    for i in range(vocab_size):
        piece = sp.IdToPiece(i)
        lines.append(f"{piece} {i}")

    # Append CTC blank if missing.
    if not any(l.startswith("<blk>") for l in lines):
        lines.append(f"<blk> {vocab_size}")
        print(f"Appended <blk> {vocab_size}")
    else:
        print("<blk> already present — nothing to append.")

    with open(args.output, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print(f"Written {len(lines)} tokens → {args.output}")
    print("First 5 tokens:")
    for l in lines[:5]:
        print(" ", l)
    print("Last 3 tokens:")
    for l in lines[-3:]:
        print(" ", l)


if __name__ == "__main__":
    main()
