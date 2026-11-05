// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/personal/media/voice_format.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:cross_file/cross_file.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

export 'package:personal_core/personal_core.dart' show DictationLimits;

class DictationException implements Exception {
  final String code;
  const DictationException(this.code);
  @override
  String toString() => 'DictationException($code)';
}

/// One in-flight private draft per account. Audio is encrypted and published
/// only in the self-only journal; this service has no recipient/send API.
class DictationService {
  static final _instances = Expando<DictationService>('dictation');
  static DictationService of(Client client) =>
      _instances[client] ??= DictationService._(client);
  DictationService._(this.client);
  final Client client;
  PersonalClient get _personal => PersonalClient.of(client);
  _Attempt? _attempt;
  int _generation = 0;
  bool get busy => _attempt != null;
  bool get available {
    final personal = _personal;
    final heartbeat = personal.workerReadiness;
    return personal.workerOnline &&
        heartbeat?.healthy == true &&
        heartbeat?.verified == true &&
        heartbeat?.dictation == 'ready' &&
        heartbeat?.dictationVersion == 1;
  }

  String? get unavailableReason =>
      available ? null : 'dictation_not_configured';

  Future<String> transcribeFile({
    required String path,
    required int durationMs,
    required String fileName,
  }) async {
    if (durationMs <= 0 ||
        durationMs > DictationLimits.maxDuration.inMilliseconds) {
      throw const DictationException('dictation_duration_limit');
    }
    final generation = _generation;
    final account = client.userID;
    final lock = PersonalPrivacy.surfaceLockGeneration;
    final file = XFile(path);
    if (await file.length() > DictationLimits.maxBytes) {
      throw const DictationException('source_too_large');
    }
    final bytes = await file.readAsBytes();
    if (generation != _generation ||
        client.userID != account ||
        !PersonalPrivacy.surfaceUnlocked ||
        lock != PersonalPrivacy.surfaceLockGeneration) {
      throw const DictationException('cancelled');
    }
    final recordingDuration = Duration(milliseconds: durationMs);
    return transcribe(
      bytes: bytes,
      mimeType: voiceRecordingMime(
        bytes,
        fileName.endsWith('.ogg')
            ? 'audio/ogg'
            : fileName.endsWith('.webm')
            ? 'audio/webm'
            : 'audio/mp4',
      ),
      duration: recordingDuration,
    );
  }

  Future<String> transcribe({
    required Uint8List bytes,
    required String mimeType,
    required Duration duration,
  }) async {
    if (busy) throw const DictationException('dictation_busy');
    if (!available) throw const DictationException('dictation_not_configured');
    if (bytes.isEmpty || bytes.length > DictationLimits.maxBytes) {
      throw const DictationException('source_too_large');
    }
    if (duration <= Duration.zero || duration > DictationLimits.maxDuration) {
      throw const DictationException('dictation_duration_limit');
    }
    if (!mimeType.startsWith('audio/')) {
      throw const DictationException('not_audio');
    }
    final attempt = _Attempt('dictation-${const Uuid().v4()}', client);
    _attempt = attempt;
    Room? journal;
    String? completedText;
    try {
      void check() {
        if (attempt.cancelled ||
            client.userID != attempt.account ||
            client.deviceID != attempt.device ||
            !PersonalPrivacy.surfaceUnlocked ||
            PersonalPrivacy.surfaceLockGeneration != attempt.lockGeneration) {
          throw const DictationException('cancelled');
        }
      }

      check();
      journal = await _personal.dictationJournal();
      check();
      if (!journal.encrypted || !client.fileEncryptionEnabled) {
        throw const DictationException('encryption_unavailable');
      }
      final encrypted = await MatrixFile(
        bytes: bytes,
        name: 'dictation',
        mimeType: mimeType,
      ).encrypt();
      check();
      final uri = await client.uploadContent(
        encrypted.data,
        filename: 'dictation.bin',
        contentType: 'application/octet-stream',
      );
      check();
      await _personal.dictationJournal();
      check();
      final eventId = await journal.sendEvent(
        {
          'msgtype': MessageTypes.Audio,
          'body': 'Private dictation',
          DictationLimits.sourceMarker: attempt.id,
          'info': {
            'mimetype': mimeType,
            'size': bytes.length,
            'duration': duration.inMilliseconds,
          },
          'file': {
            'url': uri.toString(),
            'v': 'v2',
            'iv': encrypted.iv,
            'hashes': {'sha256': encrypted.sha256},
            'key': {
              'alg': 'A256CTR',
              'ext': true,
              'k': encrypted.k,
              'key_ops': ['encrypt', 'decrypt'],
              'kty': 'oct',
            },
          },
        },
        txid: '${attempt.id}-audio',
        displayPendingEvent: false,
        retryOnTransportFailure: false,
      );
      attempt.eventId = eventId;
      check();
      if (eventId == null || !eventId.startsWith(r'$')) {
        throw const DictationException('source_unavailable');
      }
      await _personal.command(
        'dictation.request',
        attempt.id,
        {
          'id': attempt.id,
          'eventId': eventId,
          'durationMs': duration.inMilliseconds,
          'sizeBytes': bytes.length,
        },
        optimisticJob: {'id': attempt.id, 'state': 'waitingSync'},
      );
      attempt.requested = true;
      check();
      void changed() {
        try {
          check();
          final job = _personal.dictations[attempt.id];
          if (job == null || attempt.result.isCompleted) return;
          final state = job['state'];
          if (state == 'done') {
            final text = job['text'];
            if (text is! String || text.trim().isEmpty) {
              attempt.result.completeError(
                const DictationException('empty_transcript'),
              );
            } else {
              attempt.result.complete(text);
            }
          } else if (const {
            'failed',
            'unknown',
            'cancelled',
            'conflict',
          }.contains(state)) {
            attempt.result.completeError(
              DictationException(
                job['errorCode'] as String? ?? 'transcription_failed',
              ),
            );
          }
        } catch (error, stack) {
          if (!attempt.result.isCompleted) {
            attempt.result.completeError(error, stack);
          }
        }
      }

      _personal.addListener(changed);
      try {
        changed();
        final text = await attempt.result.future.timeout(
          const Duration(minutes: 7),
          onTimeout: () => throw const DictationException('dictation_timeout'),
        );
        check();
        completedText = text;
      } finally {
        _personal.removeListener(changed);
      }
    } finally {
      if (attempt.requested &&
          _personal.dictations[attempt.id]?['state'] != 'done') {
        await _cancelRemote(attempt);
      }
      final eventId = attempt.eventId;
      if (journal != null &&
          eventId != null &&
          client.userID == attempt.account &&
          client.deviceID == attempt.device) {
        try {
          await journal
              .redactEvent(eventId)
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          /* Retry on next explicit action only. */
        }
      }
      if (identical(_attempt, attempt)) _attempt = null;
    }
    // Cleanup may await the homeserver. A lock/cancel during that wait must
    // still prevent returning a transcript to a now stale composer.
    if (attempt.cancelled ||
        client.userID != attempt.account ||
        client.deviceID != attempt.device ||
        !PersonalPrivacy.surfaceUnlocked ||
        PersonalPrivacy.surfaceLockGeneration != attempt.lockGeneration) {
      throw const DictationException('cancelled');
    }
    return completedText;
  }

  Future<void> _cancelRemote(_Attempt attempt) async {
    if (client.userID != attempt.account || client.deviceID != attempt.device) {
      return;
    }
    try {
      await _personal.cancelDictation(attempt.id);
    } catch (_) {
      /* Source redaction also prevents a later paid request. */
    }
  }

  Future<void> cancel() async {
    _generation++;
    final attempt = _attempt;
    if (attempt == null) return;
    attempt.cancelled = true;
    // Wake the result waiter. Before a waiter exists, check() observes the flag.
    if (attempt.requested && !attempt.result.isCompleted) {
      attempt.result.completeError(const DictationException('cancelled'));
    }
    if (attempt.requested) await _cancelRemote(attempt);
  }
}

class _Attempt {
  _Attempt(this.id, Client client)
    : account = client.userID,
      device = client.deviceID,
      lockGeneration = PersonalPrivacy.surfaceLockGeneration {
    // Cancellation may win the command ACK before the result waiter attaches.
    unawaited(
      result.future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      ),
    );
  }
  final String id;
  final String? account, device;
  final int lockGeneration;
  bool cancelled = false, requested = false;
  String? eventId;
  final result = Completer<String>();
}
