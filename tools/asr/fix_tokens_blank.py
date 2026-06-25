#!/usr/bin/env python3
"""Append the CTC blank token to a NeMo tokens.txt for sherpa-onnx.

WHY: Saboorhsn/quran-stt-onnx ships a 1024-line tokens.txt (ids 0..1023) but the
model's vocab_size = 1025 — the CTC blank (id 1024) is omitted. sherpa-onnx
refuses to load such a tokens file:

    We expect that tokens.txt contains the symbol <blk> or <eps> or <blank>
    and its ID.

This tool appends `<blk> <next_id>` (next_id = max existing id + 1) IFF no blank
symbol is already present. It is IDEMPOTENT and edits the file in place,
preserving UTF-8 and the existing `token id` line format — safe to re-run after
re-downloading the model.

    python tools/asr/fix_tokens_blank.py assets/models/tarteel/tokens.txt

Use --blank-symbol to override the default (<blk>).
"""

from __future__ import annotations

import argparse
import sys

_BLANK_SYMBOLS = {"<blk>", "<eps>", "<blank>"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("tokens", help="path to tokens.txt")
    ap.add_argument("--blank-symbol", default="<blk>")
    args = ap.parse_args()

    with open(args.tokens, encoding="utf-8") as f:
        raw = f.read()

    lines = [ln for ln in raw.splitlines() if ln.strip() != ""]
    if not lines:
        print(f"✗ {args.tokens} is empty — nothing to do.", file=sys.stderr)
        return 1

    # Already has a blank symbol? Idempotent no-op.
    max_id = -1
    for ln in lines:
        parts = ln.split()
        sym = parts[0]
        try:
            tid = int(parts[-1])
        except ValueError:
            print(f"✗ malformed line (no trailing id): {ln!r}", file=sys.stderr)
            return 1
        max_id = max(max_id, tid)
        if sym in _BLANK_SYMBOLS:
            print(f"✓ blank symbol {sym!r} (id {tid}) already present — no change.")
            return 0

    blank_id = max_id + 1
    new_line = f"{args.blank_symbol} {blank_id}"

    # Append preserving exactly one trailing newline; keep original line endings
    # (splitlines already normalised, rejoin with '\n' which is what NeMo uses).
    out = "\n".join(lines + [new_line]) + "\n"
    with open(args.tokens, "w", encoding="utf-8") as f:
        f.write(out)

    print(f"✓ appended {new_line!r} to {args.tokens}")
    print(f"  ({len(lines)} → {len(lines) + 1} lines; blank id = {blank_id})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
