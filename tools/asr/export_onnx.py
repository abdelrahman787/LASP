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


def _shrink_decoder(work: Path, fp32: "Path|None", exporter_int8: "Path|None"):
    """Try to shrink the decoder by ALSO quantizing the token-embedding (Gather),
    not just MatMul. Runs onnxruntime's quant_pre_process first (also silences
    the pre-processing warning). Self-validates the result loads in an
    InferenceSession; on any failure or if not smaller, returns the exporter's
    int8 file. Set SKIP_EMBED_QUANT=1 to skip and just use the exporter's int8.
    """
    import os

    if os.environ.get("SKIP_EMBED_QUANT") == "1" or fp32 is None:
        return exporter_int8 or fp32
    try:
        from onnxruntime.quantization import QuantType, quantize_dynamic
        from onnxruntime.quantization.shape_inference import quant_pre_process
        import onnxruntime as ort

        pre = work / "decoder.pre.onnx"
        out = work / "decoder.embq.int8.onnx"
        print("Re-quantizing decoder (pre-process + embedding/Gather) ...")
        quant_pre_process(str(fp32), str(pre), skip_symbolic_shape=False)
        quantize_dynamic(
            str(pre),
            str(out),
            weight_type=QuantType.QInt8,
            op_types_to_quantize=["MatMul", "Gather"],
        )
        # Validate it actually loads (structure is sound).
        ort.InferenceSession(str(out), providers=["CPUExecutionProvider"])
        new_mb = out.stat().st_size / 1e6
        old_mb = (exporter_int8.stat().st_size / 1e6) if exporter_int8 else 1e9
        print(f"  embedding-quantized decoder: {new_mb:.2f} MB "
              f"(exporter int8: {old_mb:.2f} MB)")
        if exporter_int8 is None or new_mb < old_mb:
            return out
        return exporter_int8
    except Exception as e:  # noqa: BLE001
        print(f"  embedding quantization skipped ({e}) — using exporter int8")
        return exporter_int8 or fp32


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)

    # 1) Download the current exporter (tokens are generated by it now — no
    #    separate tokens.py needed).
    script = WORK / "export-onnx.py"
    print(f"Downloading {EXPORT_URL}")
    urllib.request.urlretrieve(EXPORT_URL, script)

    # 2) Patch the downloaded exporter:
    #    (a) relax the argparse `choices=[...]` so a local .pt path is accepted;
    #    (b) force the legacy TorchScript ONNX exporter (`dynamo=False`) on both
    #        torch.onnx.export() calls — torch>=2.x defaults to the dynamo/
    #        torch.export path, which chokes on the decoder's data-dependent
    #        positional_embedding[offset:offset+T] slice
    #        (GuardOnDataDependentSymNode). The anchor `opset_version=opset_version,`
    #        appears once inside each export() call's kwargs (a valid place to add
    #        another kwarg, unlike right after the positional args).
    src = script.read_text(encoding="utf-8")
    patched = re.sub(r"choices=\[.*?\],", "", src, count=1, flags=re.DOTALL)
    if patched != src:
        print("  patched export-onnx.py (removed --model choices restriction)")
    else:
        print("  NOTE: could not find choices=[...] to patch — check script version")

    anchor = "opset_version=opset_version,"
    n = patched.count(anchor)
    if n > 0:
        patched = patched.replace(anchor, f"{anchor}\n        dynamo=False,")
        print(f"  patched export-onnx.py (forced dynamo=False on {n} export call(s))")
    else:
        print("  NOTE: could not find opset_version anchor — check torch.onnx.export "
              "calls; you may need to add dynamo=False manually")

    if patched != src:
        script.write_text(patched, encoding="utf-8")

    # 3) Convert HF fine-tune → OpenAI checkpoint inside WORK.
    convert_hf_to_openai(HF_MODEL, WORK / CKPT)

    # 4) Run the exporter from WORK (outputs land there). Absolute script path
    #    avoids the cwd path-duplication bug.
    run([sys.executable, str(script.resolve()), "--model", CKPT], cwd=str(WORK))

    # 5) Collect outputs into OUT.
    #    - encoder: the exporter's int8 (already small, ~28 MB).
    #    - decoder: the exporter's int8 leaves the huge token-embedding (Gather)
    #      in fp32 (vocab*d_model*4 ≈ 106 MB), so it stays ~124 MB. Try to also
    #      quantize the embedding (quant_pre_process + Gather) from the fp32
    #      decoder; self-validate it loads; fall back to the exporter's int8.
    def find(*suffixes):
        for p in WORK.rglob("*"):
            if any(p.name.endswith(s) for s in suffixes):
                return p
        return None

    print("\n=== intermediate files in _work ===")
    for p in sorted(WORK.glob("*.onnx")):
        print(f"  {p.name:34s} {p.stat().st_size / 1e6:7.2f} MB")

    enc = find("encoder.int8.onnx") or find("encoder.onnx")
    if enc:
        shutil.copy(enc, OUT / "encoder.onnx")
        print(f"  -> {OUT / 'encoder.onnx'}  (from {enc.name})")

    # Resolve fp32 vs int8 decoder explicitly (suffix match alone is ambiguous).
    dec_int8 = find("decoder.int8.onnx")
    dec_fp32 = None
    for p in WORK.rglob("*decoder.onnx"):
        if not p.name.endswith(".int8.onnx"):
            dec_fp32 = p
            break

    chosen = _shrink_decoder(WORK, dec_fp32, dec_int8)
    tok = find("tokens.txt")
    if chosen:
        shutil.copy(chosen, OUT / "decoder.onnx")
        print(f"  -> {OUT / 'decoder.onnx'}  (from {chosen.name})")
    else:
        print("  !! no decoder produced — exporter step incomplete")
    if tok:
        shutil.copy(tok, OUT / "tokens.txt")
        print(f"  -> {OUT / 'tokens.txt'}  (from {tok.name})")

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
