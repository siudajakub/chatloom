// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';

class WorkerFailure implements Exception {
  final String code;
  const WorkerFailure(this.code);
  @override
  String toString() => 'WorkerFailure($code)';
}

class PaidRequestUnknown extends WorkerFailure {
  const PaidRequestUnknown() : super('paid_request_unknown');
}

class Cancellation {
  bool cancelled = false;
  final List<void Function()> _listeners = [];
  void check() {
    if (cancelled) throw const WorkerFailure('cancelled');
  }

  void listen(void Function() listener) {
    if (cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void cancel() {
    cancelled = true;
    for (final f in _listeners) {
      f();
    }
    _listeners.clear();
  }
}

class AudioSource {
  final Uint8List bytes;
  final String mimeType;
  AudioSource(this.bytes, this.mimeType);
}

class TranscriptionResult {
  final String text;
  final double durationSeconds;
  final double estimatedCostUsd;
  const TranscriptionResult(
    this.text,
    this.durationSeconds,
    this.estimatedCostUsd,
  );
}

abstract class FeatureTransport {
  String get accountId;
  String get deviceId;
  bool get verified;

  /// Fresh source metadata only: null means unavailable or undeciphered.
  Future<bool?> sourceRedacted(SourceEventRef source);
  Future<AudioSource> loadAudio(SourceEventRef source, Cancellation cancel);
  Future<String> send(
    SendTarget target,
    Map<String, dynamic> content,
    String transactionId,
  );
  Future<void> readAfterAcceptedReply(SendTarget target);
  Future<bool> hasRepliedSince(ConversationRef conversation, DateTime since);
}

abstract class Transcriber {
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double duration, double cost) estimate,
  );
}
