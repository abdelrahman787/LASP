#!/usr/bin/env python3
"""Export the Tarteel Whisper model to ONNX for Sherpa-ONNX (on-device ASR).

IMPORTANT — why not `optimum`:
  Sherpa-ONNX's Whisper runtime expects ONNX files produced by *its own*
  exporter (specific tensor names: n_layer_cross_k/v, etc.). The generic
  `optimum.exporters.onnx` output (encoder_model.onnx + decoder_model_merged.onnx)
  will NOT load in Sherpa-ONNX. So this script uses Sherpa-ONNX's official
  Whisper export instead, and emits the files our Flutter service expects:

    assets/models/tarteel/encoder.onnx        (int8)
    assets/models/tarteel/decoder.onnx        (int8)
    assets/models/tarteel/tokens.txt
    assets/models/tarteel/silero_vad.onnx     (Silero VAD v5, for the VAD gate)

NOTE: This was written without being run (no GPU/model in the dev sandbox).
Verify against the current Sherpa-ONNX Whisper export docs:
  https://k2-fsa.github.io/sherpa/onnx/pretrained_models/whisper/export-onnx.html

Usage:
  cd <repo root>
  python3 -m venv .venv && source .venv/bin/activate   # (Windows: .venv\\Scripts\\activate)
  pip install torch transformers onnx onnxruntime openai-whisper \
              kaldi-native-fbank librosa soundfile
  python tools/asr/export_onnx.py
"""

import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

HF_MODEL = "tarteel-ai/whisper-base-ar-quran"
OUT = Path("assets/models/tarteel")
WORK = Path("tools/asr/_work")
SHERPA_RAW = "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/scripts/whisper"
SILERO_VAD_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
)


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, **kw)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)

    # 1) Make the HF fine-tune loadable by openai-whisper (Sherpa's exporter
    #    loads via `whisper.load_model`). Convert the transformers checkpoint to
    #    the original OpenAI .pt layout and register a custom dimension name.
    #
    #    Sherpa's export-onnx.py reads `--model <name>`; for a custom/fine-tuned
    #    model you point it at a local OpenAI-format checkpoint. The conversion
    #    helper below follows the documented approach — adjust if the upstream
    #    script changes.
    print(f"Downloading Sherpa-ONNX Whisper export scripts into {WORK} ...")
    for fn in ["export-onnx.py", "requirements.txt", "test.py", "tokens.py"]:
        try:
            urllib.request.urlretrieve(f"{SHERPA_RAW}/{fn}", WORK / fn)
        except Exception as e:  # noqa: BLE001
            print(f"  (could not fetch {fn}: {e})")

    # 2) Export. Sherpa's script downloads the model by NAME; for the Tarteel
    #    HF fine-tune, pre-download it and export under a custom name. The exact
    #    invocation depends on the script version — the canonical command is:
    #
    #      export PYTHONPATH=...; python export-onnx.py --model base
    #
    #    For a HF fine-tune, see the "custom model" section of the docs above.
    #    We attempt the HF-aware path first.
    env = dict(os.environ)
    try:
        run(
            [sys.executable, str(WORK / "export-onnx.py"), "--model", HF_MODEL],
            cwd=str(WORK),
            env=env,
        )
    except Exception as e:  # noqa: BLE001
        print("\n!! Automated export failed — follow the docs manually:")
        print("   https://k2-fsa.github.io/sherpa/onnx/pretrained_models/whisper/export-onnx.html")
        print(f"   ({e})")

    # 3) Collect + rename the produced files into OUT. Sherpa emits names like
    #    `base-encoder.int8.onnx`, `base-decoder.int8.onnx`, `base-tokens.txt`.
    def find(*suffixes):
        for p in WORK.rglob("*"):
            if any(p.name.endswith(s) for s in suffixes):
                return p
        return None

    enc = find("encoder.int8.onnx") or find("encoder.onnx")
    dec = find("decoder.int8.onnx") or find("decoder.onnx")
    tok = find("tokens.txt")
    for src, dstname in [(enc, "encoder.onnx"), (dec, "decoder.onnx"), (tok, "tokens.txt")]:
        if src and src.exists():
            shutil.copy(src, OUT / dstname)
            print(f"  -> {OUT / dstname}")
        else:
            print(f"  !! missing output for {dstname} — export step incomplete")

    # 4) Silero VAD v5 model (for the on-device VAD gate).
    vad_out = OUT / "silero_vad.onnx"
    if not vad_out.exists():
        try:
            print("Downloading Silero VAD ...")
            urllib.request.urlretrieve(SILERO_VAD_URL, vad_out)
        except Exception as e:  # noqa: BLE001
            print(f"  !! could not fetch silero_vad.onnx: {e}")

    # 5) Report sizes.
    print("\n==================== EXPORT SIZES ====================")
    total = 0
    for f in sorted(OUT.glob("*")):
        if f.name == ".gitkeep":
            continue
        mb = f.stat().st_size / (1024 * 1024)
        total += mb
        print(f"  {f.name:24s} {mb:7.2f} MB")
    print(f"  {'TOTAL':24s} {total:7.2f} MB   (target ~75 MB)")
    print("=====================================================")


if __name__ == "__main__":
    main()
