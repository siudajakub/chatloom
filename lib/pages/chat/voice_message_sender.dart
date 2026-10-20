// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:cross_file/cross_file.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

/// One live recorder draft owns one SDK transaction, including an unknown ACK.
/// Retain only routing and a digest; audio bytes remain in the stopped draft.
class _VoiceMessageSendAttempt {
  final String path, transactionId, digest, fileName;
  final String? mimeType, owner, device, thread, lastThreadEvent;
  final Room target;
  final Client activeClient;
  final Event? reply;
  final int duration;
  final List<int> waveform;
  bool inFlight = false, accepted = false;

  _VoiceMessageSendAttempt({
    required this.path,
    required this.transactionId,
    required this.digest,
    required this.fileName,
    required this.mimeType,
    required this.target,
    required this.activeClient,
    required this.owner,
    required this.device,
    required this.reply,
    required this.thread,
    required this.lastThreadEvent,
    required this.duration,
    required List<int> waveform,
  }) : waveform = List.unmodifiable(waveform);

  bool matches({
    required Room room,
    required Client activeClient,
    required Event? reply,
    required String? thread,
  }) =>
      identical(room.client, target.client) &&
      room.id == target.id &&
      room.client.userID == owner &&
      room.client.deviceID == device &&
      identical(activeClient, this.activeClient) &&
      reply?.eventId == this.reply?.eventId &&
      thread == this.thread;
}

/// Sends stopped voice recordings for one composer. A lost response is not
/// permission to create a second event in another room, reply or thread: the
/// same stopped draft can only retry its first intent, with its original SDK
/// transaction. Shared by the ordinary chat and the merged person chat.
class VoiceMessageSender {
  _VoiceMessageSendAttempt? _attempt;

  /// Sends [path] to [target]. [composerUnchanged] is the caller's own check
  /// that the composer still targets the same room/reply/thread (and is
  /// mounted); it is re-evaluated after every wait. [onAccepted] runs when
  /// the event was accepted while the composer is still unchanged.
  Future<bool> send({
    required BuildContext context,
    required Room target,
    required Event? reply,
    required String? thread,
    required String? lastThreadEvent,
    required bool Function() composerUnchanged,
    required String path,
    required int duration,
    required List<int> waveform,
    required String fileName,
    Future<bool> Function(Room)? confirmTrust,
    Future<Uint8List?> Function(String)? readRecording,
    VoidCallback? onAccepted,
  }) async {
    final client = target.client;
    final owner = client.userID;
    final device = client.deviceID;
    final matrix = Matrix.of(context);
    final activeClient = matrix.client;
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;
    final previous = _attempt;
    if (previous?.inFlight == true) return false;
    var attempt = previous?.path == path ? previous : null;
    if (attempt != null) {
      if (attempt.accepted) return true;
      if (attempt.inFlight ||
          !attempt.matches(
            room: target,
            activeClient: activeClient,
            reply: reply,
            thread: thread,
          )) {
        return false;
      }
    }
    bool current() =>
        composerUnchanged() &&
        PersonalPrivacy.surfaceUnlocked &&
        privacyGeneration == PersonalPrivacy.surfaceGeneration &&
        identical(matrix.client, activeClient) &&
        matrix.widget.clients.contains(client) &&
        client.userID == owner &&
        client.deviceID == device &&
        target.canSendDefaultMessages;
    if (!current()) return false;
    final proceed =
        await (confirmTrust?.call(target) ??
            showTrustUserInRoomDialog(context, target));
    if (!proceed || !current() || !context.mounted) return false;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final bytes = readRecording != null
        ? await readRecording(path)
        : (await showFutureLoadingDialog(
            context: context,
            future: XFile(path).readAsBytes,
          )).result;
    if (bytes == null || !current()) return false;

    final mimeType = lookupMimeType(fileName, headerBytes: bytes);
    final extension = mimeType == null ? null : extensionFromMime(mimeType);
    if (extension != null) {
      fileName =
          'voice_message_${DateTime.now().millisecondsSinceEpoch}.$extension';
    }

    // Another callback may have reached dispatch while trust/file I/O waited.
    final latest = _attempt;
    if (latest != null && !identical(latest, previous)) {
      if (latest.inFlight) return false;
      if (latest.path == path) {
        if (latest.accepted) return true;
        if (!latest.matches(
          room: target,
          activeClient: activeClient,
          reply: reply,
          thread: thread,
        )) {
          return false;
        }
        attempt = latest;
      }
    }
    final digest = sha256.convert(bytes).toString();
    if (attempt != null &&
        (attempt.digest != digest ||
            attempt.duration != duration ||
            !listEquals(attempt.waveform, waveform))) {
      return false;
    }
    attempt ??= _VoiceMessageSendAttempt(
      path: path,
      transactionId: client.generateUniqueTransactionId(),
      digest: digest,
      fileName: fileName,
      mimeType: mimeType,
      target: target,
      activeClient: activeClient,
      owner: owner,
      device: device,
      reply: reply,
      thread: thread,
      lastThreadEvent: lastThreadEvent,
      duration: duration,
      waveform: waveform,
    );
    _attempt = attempt;

    final file = MatrixAudioFile(
      bytes: bytes,
      name: attempt.fileName,
      mimeType: attempt.mimeType,
    );

    attempt.inFlight = true;
    try {
      final eventId = await attempt.target.sendFileEvent(
        file,
        txid: attempt.transactionId,
        inReplyTo: attempt.reply,
        threadRootEventId: attempt.thread,
        threadLastEventId: attempt.lastThreadEvent,
        extraContent: {
          'info': {...file.info, 'duration': attempt.duration},
          'org.matrix.msc3245.voice': {},
          'org.matrix.msc1767.audio': {
            'duration': attempt.duration,
            'waveform': attempt.waveform,
          },
        },
      );
      if (eventId == null || !eventId.startsWith(r'$')) return false;
      attempt.accepted = true;
    } catch (e) {
      if (current() && context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(e.toLocalizedString(context))),
        );
      }
      return false;
    } finally {
      attempt.inFlight = false;
    }
    if (current()) onAccepted?.call();
    return true;
  }
}
