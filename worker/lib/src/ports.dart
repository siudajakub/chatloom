// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';

/// Largest media the worker downloads for transcription (declared and
/// actual size). Automatic jobs use the tighter [autoMediaMaxBytes].
const transcriptionSourceMaxBytes = 250000000;

/// Automatic jobs skip larger media before downloading: the audio of a
/// five-minute clip is a few MB, but its video can be hundreds.
const autoMediaMaxBytes = 150 * 1024 * 1024;

/// Media above this (declared, or unknown for manual jobs) is "large": only
/// one large job holds media in memory and in the tmpfs work directory at a
/// time. Worst case one large job (download + decrypted copy, then bytes +
/// temp file, about 2 x 250 MB) plus a small one stays well below the
/// unit's MemoryMax of 1536 MiB.
const largeMediaBytes = 32 * 1024 * 1024;

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
  Uint8List _bytes;
  final String mimeType;
  AudioSource(Uint8List bytes, this.mimeType) : _bytes = bytes;

  Uint8List get bytes => _bytes;

  /// Hands the media over and drops this reference, so a large video is not
  /// held in memory while its extracted audio is uploaded.
  Uint8List takeBytes() {
    final taken = _bytes;
    _bytes = Uint8List(0);
    return taken;
  }
}

/// Declared (not measured) facts about a source message's media, read from
/// metadata before anything is downloaded. Every field may be unknown.
class MediaFacts {
  final AutoTranscriptionKind? kind;
  final int? durationMs;
  final int? sizeBytes;
  const MediaFacts({this.kind, this.durationMs, this.sizeBytes});
  @override
  String toString() => 'MediaFacts(${kind?.name}, redacted)';
}

/// Optional transport capability: cheap metadata lookup before a download,
/// so automatic limits can skip oversized media without fetching it.
abstract class MediaPreflight {
  /// null when the metadata is unavailable (the job then downloads and
  /// measures as before).
  Future<MediaFacts?> mediaFacts(SourceEventRef source);
}

/// Optional transport capability: a download that never buffers more than
/// [maxBytes] (refused from declared metadata first, then aborted while
/// streaming). With [requireDeclaredSize] media without a declared size is
/// refused before any byte is fetched (automatic jobs).
abstract class BoundedAudioLoader {
  Future<AudioSource> loadAudioBounded(
    SourceEventRef source,
    Cancellation cancel, {
    required int maxBytes,
    required bool requireDeclaredSize,
  });
}

/// Push feed of newly received messages, e.g. from the worker's own Matrix
/// sync. Identifiers only, like [RecentSourceScanner].
abstract class LiveSourceFeed {
  /// Removes and returns the messages received since the previous call.
  Future<List<RecentSourceItem>> drain();

  /// Completes when new items are available (or after a resolution attempt
  /// is due), so the daemon wakes immediately instead of polling.
  Future<void> get wakeup;

  /// Starts or stops collecting; inactive feeds drop what they receive.
  set active(bool value);
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
