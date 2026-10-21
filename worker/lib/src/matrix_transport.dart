// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'ports.dart';
import 'reminder_reply.dart';

/// Streams one media download into memory, never buffering more than
/// [maxBytes]: a larger declared `Content-Length` is refused before the body
/// is read, and the stream is cancelled as soon as it passes the bound.
Future<Uint8List> boundedMediaDownload(
  http.Client httpClient,
  Uri uri, {
  required String? accessToken,
  required int maxBytes,
  required Cancellation cancel,
  Duration timeout = const Duration(minutes: 10),
}) async {
  cancel.check();
  final request = http.Request('GET', uri);
  if (accessToken != null) {
    request.headers['authorization'] = 'Bearer $accessToken';
  }
  final response = await httpClient
      .send(request)
      .timeout(const Duration(minutes: 2));
  final done = Completer<Uint8List>();
  final builder = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> subscription;
  void fail(String code) {
    unawaited(subscription.cancel());
    if (!done.isCompleted) done.completeError(WorkerFailure(code));
  }

  subscription = response.stream.listen(
    (chunk) {
      if (builder.length + chunk.length > maxBytes) {
        fail('source_too_large');
        return;
      }
      builder.add(chunk);
    },
    onError: (Object _) => fail('source_unavailable'),
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  if (response.statusCode >= 400) {
    fail('source_unavailable');
  } else if ((response.contentLength ?? 0) > maxBytes) {
    fail('source_too_large');
  }
  cancel.listen(() => fail('cancelled'));
  try {
    return await done.future.timeout(timeout);
  } on TimeoutException {
    fail('source_unavailable');
    throw const WorkerFailure('source_unavailable');
  }
}

/// An event the SDK stored before its room key arrived stays stored as it
/// came (encrypted): the SDK re-decrypts stored events only for a live
/// `Timeline` or for to-device keys within 5 minutes, never for keys from the
/// key backup or a later forward (the worker holds no timelines). Decrypt it
/// now with the keys the store holds; still encrypted when they are missing.
Future<Event> decryptStoredEvent(Client client, Event event) async {
  if (event.type != EventTypes.Encrypted || !client.encryptionEnabled) {
    return event;
  }
  try {
    return await client.encryption?.decryptRoomEvent(event) ?? event;
  } catch (_) {
    return event;
  }
}

class MatrixFeatureTransport
    implements FeatureTransport, MediaPreflight, BoundedAudioLoader {
  final Client client;
  final bool allowConversationSends;
  MatrixFeatureTransport(this.client, {this.allowConversationSends = true});
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
  Future<AudioSource> loadAudio(SourceEventRef source, Cancellation cancel) =>
      loadAudioBounded(
        source,
        cancel,
        maxBytes: transcriptionSourceMaxBytes,
        requireDeclaredSize: false,
      );

  @override
  Future<AudioSource> loadAudioBounded(
    SourceEventRef source,
    Cancellation cancel, {
    required int maxBytes,
    required bool requireDeclaredSize,
  }) async {
    final selected = await room(source.conversation);
    cancel.check();
    final stored = await selected.getEventById(source.eventId);
    if (stored == null) throw const WorkerFailure('source_unavailable');
    if (stored.redacted) throw const WorkerFailure('source_redacted');
    // Keys that arrived after the event (backup, forward) decrypt it now;
    // without this a job waited for keys it already had, forever.
    final event = await decryptStoredEvent(client, stored);
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
    final rejection = transcriptionSourceRejection(
      event,
      maxBytes: maxBytes,
      requireDeclaredSize: requireDeclaredSize,
    );
    if (rejection != null) throw WorkerFailure(rejection);
    cancel.check();
    // The SDK would buffer any size; the bounded callback aborts the
    // transfer at maxBytes (the decrypted copy is the same size).
    final file = await event.downloadAndDecryptAttachment(
      downloadCallback: (uri) => boundedMediaDownload(
        client.httpClient,
        uri,
        accessToken: client.accessToken,
        maxBytes: maxBytes,
        cancel: cancel,
      ),
    );
    cancel.check();
    // Redaction/protection may change while a download is in flight. Do not
    // send bytes to the decoder/provider after the source becomes unavailable.
    final afterDownload = transcriptionSourceRejection(
      event,
      maxBytes: maxBytes,
    );
    if (afterDownload != null) throw WorkerFailure(afterDownload);
    if (file.bytes.lengthInBytes > maxBytes) {
      throw const WorkerFailure('source_too_large');
    }
    // No defensive copy: the decrypted bytes are handed over as they are.
    return AudioSource(file.bytes, file.mimeType);
  }

  @override
  Future<MediaFacts?> mediaFacts(SourceEventRef source) async {
    try {
      final selected = await room(source.conversation);
      final stored = await selected
          .getEventById(source.eventId)
          .timeout(const Duration(seconds: 5));
      final event = stored == null
          ? null
          : await decryptStoredEvent(client, stored);
      if (event == null || event.redacted || event.type != EventTypes.Message) {
        return null;
      }
      final info = event.infoMap;
      int? positive(Object? value) => value is int && value >= 0 ? value : null;
      return MediaFacts(
        kind: transcribableMediaKind(event.content),
        durationMs: positive(info['duration']),
        sizeBytes: positive(info['size']),
      );
    } catch (_) {
      return null;
    }
  }

  /// Voice notes, other audio, rounds and videos (also `m.file` media) are
  /// accepted; GIF-style silent loops, images and protected media are not.
  /// The transcriber extracts only 0:a:0 into metadata-free MP3; the
  /// provider never receives video. A declared size above [maxBytes] is
  /// refused; automatic jobs ([requireDeclaredSize]) also refuse media whose
  /// size is not declared, since nothing would bound the download upfront.
  static String? transcriptionSourceRejection(
    Event event, {
    int maxBytes = transcriptionSourceMaxBytes,
    bool requireDeclaredSize = false,
  }) {
    if (event.redacted) return 'source_redacted';
    if (event.type != EventTypes.Message) return 'not_audio';
    if (!const {
      MessageTypes.Audio,
      MessageTypes.Video,
      MessageTypes.File,
    }.contains(event.messageType)) {
      return 'not_audio';
    }
    final round = RoundVideoDescriptor.fromContent(event.content);
    final policy = RoundMediaPolicy.fromContent(event.content);
    if (!policy.canTranscribe) return 'protected_media';
    if (transcribableMediaKind(event.content) == null) return 'not_audio';
    // The chat's disappearing-message setting (mautrix bridgev2 room state);
    // fail closed on anything but an explicit "off".
    if (disappearingTimerLimits(
      event.room.getState(beeperDisappearingTimerKey)?.content,
    )) {
      return 'protected_media';
    }
    if (round != null &&
        round.mimeType.isNotEmpty &&
        round.mimeType != 'video/mp4') {
      return 'invalid_round_format';
    }
    final size = event.infoMap['size'];
    if (size != null && (size is! int || size < 0)) {
      return 'invalid_media_metadata';
    }
    if (size is int && size > maxBytes) return 'source_too_large';
    if (size == null && requireDeclaredSize) {
      return 'auto_skipped_unknown_size';
    }
    return null;
  }

  @override
  Future<String> send(
    SendTarget target,
    Map<String, dynamic> content,
    String transactionId,
  ) async {
    if (!allowConversationSends) {
      throw const WorkerFailure('conversation_sends_disabled');
    }
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
    if (!allowConversationSends) {
      throw const WorkerFailure('conversation_sends_disabled');
    }
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
      final identity = ownRemoteIdentity(client);
      return await receivedReplySince(
        SdkReminderReplyHistory(timeline),
        client.userID!,
        since,
        // Weak (DM-structure) evidence is scoped to this room.
        isOwnSender: (senderId) =>
            identity.isOwn(senderId, roomId: selected.id),
        isBot: reminderBotSenders(selected).contains,
      );
    } finally {
      timeline.cancelSubscriptions();
    }
  }
}

/// Automated senders whose messages never count as a reply to a reminder:
/// the bridge bots [room] declares in its bridge state (`bridgebot`).
Set<String> reminderBotSenders(Room room) => {
  for (final type in ownIdentityBridgeStateTypes)
    for (final state in room.states[type]?.values ?? <StrippedStateEvent>[])
      if (state.content['bridgebot'] case final String bot when bot.isNotEmpty)
        bot,
};

/// Owner identity incl. own bridge ghosts, from already-loaded room state
/// (same snapshot rules as the app's `lib/personal/own_sender.dart`): only
/// joined rooms, each declaration with its sender and the declared bot's
/// membership, so personal_core ignores declarations not sent by a joined
/// bridge bot.
OwnRemoteIdentity ownRemoteIdentity(Client client) {
  final rooms = <BridgeRoomSnapshot>[];
  for (final room in client.rooms) {
    if (room.isSpace || room.membership != Membership.join) continue;
    bool joined(String userId) =>
        room.getState(EventTypes.RoomMember, userId)?.content['membership'] ==
        'join';
    final bridges = <BridgeInfoSnapshot>[
      for (final type in ownIdentityBridgeStateTypes)
        for (final state in room.states[type]?.values ?? <StrippedStateEvent>[])
          ?BridgeInfoSnapshot.fromContent(
            state.content,
            senderId: state.senderId,
            isJoined: joined,
          ),
    ];
    if (bridges.isEmpty) continue;
    final shape = BridgeRoomSnapshot(
      roomId: room.id,
      bridges: bridges,
      ownerJoined: true,
      directPartnerId: room.directChatMatrixID,
    );
    final memberStates = room.states[EventTypes.RoomMember];
    if (!shape.dmShaped || memberStates == null || memberStates.length > 12) {
      rooms.add(shape);
      continue;
    }
    rooms.add(
      BridgeRoomSnapshot(
        roomId: room.id,
        bridges: bridges,
        ownerJoined: true,
        directPartnerId: shape.directPartnerId,
        joinedMembers: {
          for (final entry in memberStates.entries)
            if (entry.value.content['membership'] == 'join')
              entry.key: entry.value.content['displayname'] is String
                  ? entry.value.content['displayname'] as String
                  : null,
        },
      ),
    );
  }
  return OwnRemoteIdentity.resolve(
    accountUserId: client.userID,
    rooms: rooms,
    displaynameOf: (id) {
      for (final room in client.rooms) {
        if (room.membership != Membership.join) continue;
        final content = room.getState(EventTypes.RoomMember, id)?.content;
        if (content?['membership'] != 'join') continue;
        final name = content?['displayname'];
        if (name is String && name.trim().isNotEmpty) return name;
      }
      return null;
    },
  );
}
