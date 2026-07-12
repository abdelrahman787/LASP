/// GATE 2 — live-mic streaming ASR check for the FastConformer-Transducer model.
///
/// What this tests:
///  1. StreamingAsrService loads the Transducer model and Silero VAD cleanly.
///  2. Partial results appear in real-time while reciting.
///  3. Endpoint detection fires at natural pauses → final result emitted.
///  4. NO hallucination: silence between words should NOT produce random text.
///  5. RTF stays < 0.1 (ideally ≈ 0.032 as in Gate-1).
///
/// How to use:
///  1. Place model files in assets/models/streaming/ (see gate2_main.dart).
///  2. flutter run -t lib/dev/gate2_main.dart
///  3. Tap "Start Recording" and recite an ayah or two.
///  4. Tap "Stop" — the final accumulated text appears.
///  5. Compare against what you recited. No garbage in the silence gaps = pass.
///
/// Hallucination verdict:
///  • PASS: text matches recitation; no random words during pauses.
///  • FAIL: random garbage appears during or after silence. Check VAD thresholds
///          (_kVadThreshold / _kVadMinSilence in streaming_asr_service.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';

import '../app/data/streaming_asr_service.dart';

class GateTwoScreen extends StatefulWidget {
  const GateTwoScreen({super.key});

  @override
  State<GateTwoScreen> createState() => _GateTwoScreenState();
}

class _GateTwoScreenState extends State<GateTwoScreen> {
  final StreamingAsrService _svc = StreamingAsrService();

  bool _recording = false;
  bool _loading = false;
  String _partialText = '';
  final List<_Utterance> _utterances = [];
  int _totalInferMs = 0;
  double _totalAudioSec = 0;
  String? _error;

  @override
  void dispose() {
    _svc.stop();
    super.dispose();
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.status;
    if (!status.isGranted) {
      final result = await Permission.microphone.request();
      if (!result.isGranted) {
        setState(() => _error = 'Mic permission denied.');
        return;
      }
    }
    setState(() {
      _loading = true;
      _error = null;
      _partialText = '';
      _utterances.clear();
      _totalInferMs = 0;
      _totalAudioSec = 0;
    });

    final sw = Stopwatch()..start();
    await _svc.start((AsrResult result) {
      if (!mounted) return;
      setState(() {
        _partialText = result.text;
        _loading = false;
      });
    });
    sw.stop();

    if (mounted) {
      setState(() {
        _recording = true;
        _loading = false;
        if (_error == null && sw.elapsedMilliseconds > 10000) {
          _error = 'Model load took ${sw.elapsedMilliseconds}ms — check assets.';
        }
      });
    }
  }

  Future<void> _stopRecording() async {
    await _svc.stop();
    if (mounted) {
      setState(() {
        _recording = false;
        if (_partialText.isNotEmpty) {
          _utterances.add(_Utterance(_partialText, isFinal: true));
          _partialText = '';
        }
      });
    }
  }

  double get _aggRtf =>
      _totalAudioSec > 0 ? _totalInferMs / 1000.0 / _totalAudioSec : 0.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gate 2 — Streaming ASR (Transducer)'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status chips row.
            Wrap(
              spacing: 8,
              children: [
                if (_recording)
                  const Chip(
                    label: Text('● RECORDING'),
                    backgroundColor: Colors.red,
                    labelStyle: TextStyle(color: Colors.white),
                  )
                else if (_loading)
                  const Chip(label: Text('Loading model…'))
                else
                  const Chip(label: Text('Stopped')),
                if (_totalAudioSec > 0)
                  Chip(label: Text('RTF ${_aggRtf.toStringAsFixed(3)}')),
                if (_utterances.isNotEmpty)
                  Chip(label: Text('${_utterances.length} utterances')),
              ],
            ),
            const SizedBox(height: 12),

            // Control buttons.
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_recording || _loading) ? null : _startRecording,
                    icon: const Icon(Icons.mic),
                    label: const Text('Start Recording'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _recording ? _stopRecording : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Error banner.
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_error!,
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer)),
                ),
              ),

            // Live partial text.
            if (_partialText.isNotEmpty || _recording) ...[
              const Text('Live partial:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _partialText.isEmpty ? '(waiting for speech…)' : _partialText,
                      style: const TextStyle(fontSize: 16),
                      textDirection: TextDirection.rtl,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Gate-2 checklist.
            const Text('Gate-2 checklist:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const _CheckItem(
                text: 'Model loads without error (no init_failed in log)'),
            const _CheckItem(
                text: 'Partial text updates while reciting (not only at stop)'),
            const _CheckItem(
                text: 'No hallucination during silence (no random words)'),
            const _CheckItem(text: 'RTF < 0.1 (ideally ≈ 0.032)'),
            const SizedBox(height: 16),

            // Final utterances log.
            const Text('Utterances (on endpoint / stop):',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Expanded(
              child: _utterances.isEmpty
                  ? const Center(
                      child: Text(
                          'No utterances yet.\nRecite an ayah and tap Stop.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: _utterances.length,
                      itemBuilder: (ctx, i) {
                        final u = _utterances[i];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Chip(
                                      label: Text(
                                          u.isFinal ? 'FINAL' : 'ENDPOINT'),
                                      padding: EdgeInsets.zero,
                                    ),
                                    const Spacer(),
                                    Text('#${i + 1}',
                                        style: const TextStyle(
                                            color: Colors.grey)),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                SelectableText(
                                  u.text.isEmpty ? '(empty)' : u.text,
                                  style: const TextStyle(fontSize: 15),
                                  textDirection: TextDirection.rtl,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Utterance {
  final String text;
  final bool isFinal;
  const _Utterance(this.text, {required this.isFinal});
}

class _CheckItem extends StatelessWidget {
  final String text;
  const _CheckItem({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_box_outline_blank, size: 18, color: Colors.grey),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
