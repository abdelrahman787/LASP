import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

// ignore_for_file: avoid_print
void main() {
  sherpa.initBindings();

  const encoder = 'assets/models/tarteel/encoder.onnx';
  const decoder = 'assets/models/tarteel/decoder.onnx';
  const tokens = 'assets/models/tarteel/tokens.txt';
  const audioFile = 'assets/test_audio/ayah16k.wav';

  print('[CMP] Initializing Tarteel Whisper model...');
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      decodingMethod: 'greedy_search',
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: encoder,
          decoder: decoder,
          language: 'ar',
          task: 'transcribe',
        ),
        tokens: tokens,
        numThreads: 4,
        provider: 'cpu',
        modelType: 'whisper',
      ),
    ),
  );

  print('[CMP] Reading audio $audioFile...');
  final wave = sherpa.readWave(audioFile);
  final audioSec = wave.samples.length / wave.sampleRate;
  print('[CMP] Audio length: ${audioSec.toStringAsFixed(2)}s');

  print('[CMP] Starting decode...');
  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
  
  final sw = Stopwatch()..start();
  recognizer.decode(stream);
  final text = recognizer.getResult(stream).text;
  sw.stop();

  stream.free();
  recognizer.free();

  final inferMs = sw.elapsedMilliseconds;
  final rtf = audioSec > 0 ? inferMs / 1000.0 / audioSec : 0.0;

  print('[CMP] Output: "$text"');
  print('[CMP] Total infer time: ${inferMs}ms');
  print('[CMP] RTF: ${rtf.toStringAsFixed(3)}');
  print('[CMP] Incremental: NO. Result only available after decode() returns for the entire waveform.');
}
