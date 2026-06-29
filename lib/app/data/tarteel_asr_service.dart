// sherpa_onnx removed from pubspec.yaml (libonnxruntime.so conflict with
// onnxruntime package). TarteelOnDeviceAsrService kept as a stub so
// providers.dart compiles; it throws at runtime (production code uses
// StreamingAsrService instead).
import 'package:quran_tasmee3_core/recitation/asr_service.dart';

class TarteelOnDeviceAsrService implements AsrService {
  @override
  Future<void> start(void Function(AsrResult) onResult) =>
      throw UnsupportedError('TarteelOnDeviceAsrService: sherpa_onnx package removed');

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> stop() async {}
}
