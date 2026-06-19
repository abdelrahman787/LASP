#!/usr/bin/env python3
"""Export the Tarteel Whisper fine-tune to ONNX for Sherpa-ONNX (on-device ASR).

Sherpa-ONNX's Whisper runtime needs ONNX produced by ITS OWN exporter
(scripts/whisper/export-onnx.py in k2-fsa/sherpa-onnx) — NOT optimum (whose
encoder_model/decoder_model_merged tensor names are incompatible).

That exporter only accepts a fixed set of `--model` names and loads via
`whisper.load_model(name)`. `tarteel-ai/whisper-base-ar-quran` is a HuggingFace
*transformers* checkpoint, so we:
  1. Convert it to the OpenAI-Whisper `.pt` layout (dims + remapped state_dict).
  2. Relax the exporter's argparse `choices` so a local `.pt` path is accepted
     (whisper.load_model loads a file path directly, no checksum).
  3. Run the exporter, then collect/rename outputs into assets/models/tarteel/:
       encoder.onnx (int8), decoder.onnx (int8), tokens.txt, silero_vad.onnx

Produces ~75 MB total. Outputs sizes at the end.

NOT run/verified in the dev sandbox. The HF→OpenAI key remap follows the
canonical Whisper mapping; if a key mismatch occurs it is printed explicitly.
Refs:
  https://k2-fsa.github.io/sherpa/onnx/pretrained_models/whisper/export-onnx.html
  https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/whisper/export-onnx.py

Usage (venv with torch/transformers/openai-whisper/onnx/onnxruntime installed):
  cd <repo root>
  python tools/asr/export_onnx.py
"""

import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

HF_MODEL = "tarteel-ai/whisper-base-ar-quran"
OUT = Path("assets/models/tarteel")
WORK = Path("tools/asr/_work")
EXPORT_URL = (
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/"
    "scripts/whisper/export-onnx.py"
)
SILERO_VAD_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "asr-models/silero_vad.onnx"
)
CKPT = "tarteel.pt"  # OpenAI-format checkpoint name (passed to the exporter)


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, **kw)


def convert_hf_to_openai(hf_id: str, out_path: Path) -> None:
    """HF transformers Whisper → OpenAI-Whisper checkpoint ({dims, state_dict})."""
    import torch
    import whisper  # noqa: F401  (ensures openai-whisper is installed)
    from transformers import WhisperForConditionalGeneration

    print(f"Loading HF model {hf_id} ...")
    hf = WhisperForConditionalGeneration.from_pretrained(hf_id)
    cfg = hf.config
    dims = dict(
        n_mels=cfg.num_mel_bins,
        n_vocab=cfg.vocab_size,
        n_audio_ctx=cfg.max_source_positions,
        n_audio_state=cfg.d_model,
        n_audio_head=cfg.encoder_attention_heads,
        n_audio_layer=cfg.encoder_layers,
        n_text_ctx=cfg.max_target_positions,
        n_text_state=cfg.d_model,
        n_text_head=cfg.decoder_attention_heads,
        n_text_layer=cfg.decoder_layers,
    )

    def rename(k: str) -> str:
        k = k.replace("encoder.layers", "encoder.blocks")
        k = k.replace("decoder.layers", "decoder.blocks")
        # cross-attn first (more specific than self_attn replacements)
        k = k.replace("encoder_attn.q_proj", "cross_attn.query")
        k = k.replace("encoder_attn.k_proj", "cross_attn.key")
        k = k.replace("encoder_attn.v_proj", "cross_attn.value")
        k = k.replace("encoder_attn.out_proj", "cross_attn.out")
        k = k.replace("encoder_attn_layer_norm", "cross_attn_ln")
        k = k.replace("self_attn.q_proj", "attn.query")
        k = k.replace("self_attn.k_proj", "attn.key")
        k = k.replace("self_attn.v_proj", "attn.value")
        k = k.replace("self_attn.out_proj", "attn.out")
        k = k.replace("self_attn_layer_norm", "attn_ln")
        k = k.replace("fc1", "mlp.0")
        k = k.replace("fc2", "mlp.2")
        k = k.replace("final_layer_norm", "mlp_ln")
        # token embedding before the generic positional rename
        k = k.replace("decoder.embed_tokens.weight", "decoder.token_embedding.weight")
        k = k.replace("embed_positions.weight", "positional_embedding")
        k = k.replace("encoder.layer_norm", "encoder.ln_post")
        k = k.replace("decoder.layer_norm", "decoder.ln")
        return k

    hf_sd = hf.model.state_dict()  # inner model only (no proj_out/lm_head)
    new_sd = {rename(k): v for k, v in hf_sd.items()}

    # Sanity-check the remap by loading into a fresh OpenAI Whisper of these dims.
    from whisper.model import ModelDimensions, Whisper

    model = Whisper(ModelDimensions(**dims))
    missing, unexpected = model.load_state_dict(new_sd, strict=False)
    if missing:
        print(f"  WARNING missing keys ({len(missing)}): {missing[:8]} ...")
    if unexpected:
        print(f"  WARNING unexpected keys ({len(unexpected)}): {unexpected[:8]} ...")
    if not missing and not unexpected:
        print("  state_dict mapped cleanly ✓")

    torch.save({"dims": dims, "model_state_dict": new_sd}, out_path)
    print(f"  wrote {out_path}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)

    # 1) Download the current exporter (tokens are generated by it now — no
    #    separate tokens.py needed).
    script = WORK / "export-onnx.py"
    print(f"Downloading {EXPORT_URL}")
    urllib.request.urlretrieve(EXPORT_URL, script)

    # 2) Relax the argparse `choices=[...]` so a local .pt path is accepted.
    src = script.read_text(encoding="utf-8")
    patched = re.sub(r"choices=\[.*?\],", "", src, count=1, flags=re.DOTALL)
    if patched != src:
        script.write_text(patched, encoding="utf-8")
        print("  patched export-onnx.py (removed --model choices restriction)")
    else:
        print("  NOTE: could not find choices=[...] to patch — check script version")

    # 3) Convert HF fine-tune → OpenAI checkpoint inside WORK.
    convert_hf_to_openai(HF_MODEL, WORK / CKPT)

    # 4) Run the exporter from WORK (outputs land there). Absolute script path
    #    avoids the cwd path-duplication bug.
    run([sys.executable, str(script.resolve()), "--model", CKPT], cwd=str(WORK))

    # 5) Collect + rename outputs (prefer int8) into OUT.
    def find(*suffixes):
        for p in WORK.rglob("*"):
            if any(p.name.endswith(s) for s in suffixes):
                return p
        return None

    enc = find("encoder.int8.onnx") or find("encoder.onnx")
    dec = find("decoder.int8.onnx") or find("decoder.onnx")
    tok = find("tokens.txt")
    for src_f, dst in [(enc, "encoder.onnx"), (dec, "decoder.onnx"), (tok, "tokens.txt")]:
        if src_f and src_f.exists():
            shutil.copy(src_f, OUT / dst)
            print(f"  -> {OUT / dst}  (from {src_f.name})")
        else:
            print(f"  !! missing output for {dst} — exporter step incomplete")

    # 6) Silero VAD v5 (for the on-device VAD gate).
    vad_out = OUT / "silero_vad.onnx"
    if not vad_out.exists():
        print("Downloading Silero VAD ...")
        try:
            urllib.request.urlretrieve(SILERO_VAD_URL, vad_out)
        except Exception as e:  # noqa: BLE001
            print(f"  !! could not fetch silero_vad.onnx: {e}")

    # 7) Sizes.
    print("\n==================== EXPORT SIZES ====================")
    total = 0.0
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
