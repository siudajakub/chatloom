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
  /// [estimate] runs after the duration is measured and before any provider
  /// upload. Throwing from it (for example an automatic-job limit) aborts the
  /// job without a paid request; the plaintext work directory is still removed.
  Future<TranscriptionResult> transcribe(
    AudioSource audio,
    String? language,
    Cancellation cancel,
    void Function(double duration, double cost) estimate,
  );
}

/// A newly indexed incoming voice/round message reported by a read-only
/// source scan. Identifiers only: no sender, text, media or file paths.
class RecentSourceItem {
  final String roomId;
  final String eventId;
  final AutoTranscriptionKind kind;

  /// Source network label when the source can tell; otherwise 'unknown'.
  final String network;
  final int? durationMs;
  final DateTime? timestamp;
  const RecentSourceItem({
    required this.roomId,
    required this.eventId,
    required this.kind,
    this.network = 'unknown',
    this.durationMs,
    this.timestamp,
  });
  @override
  String toString() => 'RecentSourceItem(${kind.name}, redacted)';
}

class RecentSourcePage {
  /// Opaque, monotonic position after the examined rows.
  final int cursor;
  final List<RecentSourceItem> items;
  const RecentSourcePage(this.cursor, this.items);
}

abstract class RecentSourceScanner {
  /// A null [cursor] returns the current end position and no items, so the
  /// first scan never sweeps history. Returns null when the source is busy;
  /// the caller simply retries on its next interval.
  Future<RecentSourcePage?> recent({
    required int? cursor,
    DateTime? since,
    int limit = 100,
  });
}
