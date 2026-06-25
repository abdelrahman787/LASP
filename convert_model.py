import ctranslate2

converter = ctranslate2.converters.TransformersConverter(
    "tarteel-ai/whisper-base-ar-quran"
)
converter.convert("D:/lasp/tarteel_ct2", quantization="int8", force=True)
print("Done! Model saved to D:/lasp/tarteel_ct2")