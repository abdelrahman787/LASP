/// Local runtime switches for debugging the ASR backend.
///
/// NOTE: committed with defaults rather than gitignored — gitignoring a source
/// file that `providers.dart` imports would break every fresh clone / CI build.
/// Edit locally to toggle; flip back to the Cloudflare Worker for debugging.
library;

/// When true, use the on-device Tarteel Whisper model (Sherpa-ONNX) for ASR.
/// When false, fall back to the Cloudflare Worker (GroqAsrService) — controlled
/// by `kUseRealAsr` in providers.dart.
const bool kUseOnDeviceAsr = true;
