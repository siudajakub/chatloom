// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'ports.dart';
import 'reminder_reply.dart';

class MatrixFeatureTransport implements FeatureTransport {
  final Client client;
  MatrixFeatureTransport(this.client);
  @override
  String get accountId => client.userID!;
  @override
  String get deviceId => client.deviceID!;
  @override
  bool get verified =>
      client
          .userDeviceKeys[client.userID]
          ?.deviceKeys[client.deviceID]
          ?.verified ==
      true;
  Future<Room> room(ConversationRef ref) async {
    if (ref.accountId != accountId || !ref.roomId.startsWith('!')) {
      throw const WorkerFailure('invalid_account_or_room');
    }
    await client.roomsLoading;
    final room = client.getRoomById(ref.roomId);
    if (room == null || room.membership != Membership.join) {
      throw const WorkerFailure('room_unavailable');
    }
    return room;
  }

  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async {
    try {
      final selected = await room(source.conversation);
      // Bypass the SDK's cached event, which may predate the redaction.
      final raw = await client
          .getOneRoomEvent(selected.id, source.eventId)
          .timeout(const Duration(seconds: 5));
      var event = Event.fromMatrixEvent(raw, selected);
      if (event.redacted) return true;
      if (event.type == EventTypes.Encrypted) {
        event = await client.encryption?.decryptRoomEvent(event) ?? event;
        if (event.type == EventTypes.Encrypted) return null;
      }
      return event.redacted;
    } catch (_) {
      return null; // 404, missing keys, transport failures are not deletion proof.
    }
  }

  @override
  Future<AudioSource> loadAudio(
    SourceEventRef source,
    Cancellation cancel,
  ) async {
    final selected = await room(source.conversation);
    cancel.check();
    final event = await selected.getEventById(source.eventId);
    if (event == null) throw const WorkerFailure('source_unavailable');
    if (event.redacted) throw const WorkerFailure('source_redacted');
    if (event.type == EventTypes.Encrypted) {
      try {
        await event.requestKey();
      } catch (_) {}
      final timeline = await selected.getTimeline();
      try {
        timeline.requestKeys(onlineKeyBackupOnly: false);
      } finally {
        timeline.cancelSubscriptions();
      }
      throw const WorkerFailure('waiting_keys');
    }
    final rejection = transcriptionSourceRejection(event);
    if (rejection != null) throw WorkerFailure(rejection);
    cancel.check();
    final file = await event.downloadAndDecryptAttachment();
    cancel.check();
    // Redaction/protection may change while a download is in flight. Do not
    // send bytes to the decoder/provider after the source becomes unavailable.
    final afterDownload = transcriptionSourceRejection(event);
    if (afterDownload != null) throw WorkerFailure(afterDownload);
    if (file.bytes.lengthInBytes > 250000000) {
      throw const WorkerFailure('source_too_large');
    }
    return AudioSource(Uint8List.fromList(file.bytes), file.mimeType);
  }

  /// Video is permitted only for strict ordinary round notes. The transcriber
  /// extracts 0:a:0 into metadata-free MP3; the provider never receives MP4.
  static String? transcriptionSourceRejection(Event event) {
    if (event.redacted) return 'source_redacted';
    if (event.type != EventTypes.Message) return 'not_audio';
    final round = RoundVideoDescriptor.fromContent(event.content);
    if (event.messageType != MessageTypes.Audio && round == null) {
      return 'not_audio';
    }
    final policy = RoundMediaPolicy.fromContent(event.content);
    if (!policy.canTranscribe) return 'protected_media';
    if (round != null &&
        round.mimeType.isNotEmpty &&
        round.mimeType != 'video/mp4') {
      return 'invalid_round_format';
    }
    final size = event.infoMap['size'];
    if (size != null && (size is! int || size < 0)) {
      return 'invalid_media_metadata';
    }
    if (size is int && size > 250000000) return 'source_too_large';
    return null;
  }

  @override
  Future<String> send(
    SendTarget target,
    Map<String, dynamic> content,
    String transactionId,
  ) async {
    if (!verified) throw const WorkerFailure('device_verification_required');
    final selected = await room(target.conversation);
    if (selected.encrypted && !client.encryptionEnabled) {
      throw const WorkerFailure('encryption_unavailable');
    }
    try {
      final result = await selected.sendEvent(
        Map<String, dynamic>.from(content),
        txid: transactionId,
        type: EventTypes.Message,
        displayPendingEvent: false,
      );
      if (result == null) throw const WorkerFailure('send_unknown');
      return result;
    } on MatrixException catch (e) {
      if (e.errcode == 'M_FORBIDDEN') {
        throw const WorkerFailure('send_forbidden');
      }
      if (e.errcode == 'M_UNKNOWN_TOKEN') {
        throw const WorkerFailure('session_lost');
      }
      throw const WorkerFailure('send_unknown');
    }
  }

  @override
  Future<void> readAfterAcceptedReply(SendTarget target) async {
    final bound = target.readUpToEventId;
    if (bound == null) return;
    final selected = await room(target.conversation);
    if (!bound.startsWith(r'$') || await selected.getEventById(bound) == null) {
      throw const WorkerFailure('invalid_read_bound');
    }
    await selected.setReadMarker(bound, mRead: bound, public: true);
  }

  @override
  Future<bool> hasRepliedSince(
    ConversationRef conversation,
    DateTime since,
  ) async {
    final selected = await room(conversation);
    final timeline = await selected.getTimeline();
    try {
      return await receivedReplySince(
        SdkReminderReplyHistory(timeline),
        client.userID!,
        since,
      );
    } finally {
      timeline.cancelSubscriptions();
    }
  }
}
