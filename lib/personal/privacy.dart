// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/media/media_prefetcher.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'capabilities.dart';
import 'journal_trust.dart';
import 'privacy_transport.dart';
import 'round_video/telegram_media_protocol.dart';
import 'round_video/telegram_room_binding.dart';
import 'round_video/telegram_round_service.dart';

final _roundReadCutoffKey = Object();

abstract final class PersonalPrivacy {
  static bool _surfaceUnlocked = true;
  static bool _surfaceForeground = true;
  static int surfaceGeneration = 0;
  // External pickers intentionally background the app. A lock still invalidates
  // their captured composer even when the user unlocks before returning.
  static int surfaceLockGeneration = 0;
  static bool get surfaceUnlocked => _surfaceUnlocked;
  static set surfaceUnlocked(bool value) {
    if (_surfaceUnlocked != value) {
      surfaceGeneration++;
      surfaceLockGeneration++;
    }
    _surfaceUnlocked = value;
  }

  static bool get surfaceForeground => _surfaceForeground;
  static set surfaceForeground(bool value) {
    if (_surfaceForeground != value) surfaceGeneration++;
    _surfaceForeground = value;
  }

  static void invalidatePlayedIntents() => surfaceGeneration++;
  static PrivacyPolicy get policy => PrivacyPolicy(
    incognito: AppSettings.personalIncognito.value,
    typingEnabled: AppSettings.sendTypingNotifications.value,
  );
  static Future<void> markRead(
    Room room,
    String eventId, {
    bool manual = false,
    bool acceptedReply = false,
    // Only an explicit manual action can override the automatic receipt
    // preference. It still uses the exact room/event transport grant.
    bool publicReceipt = false,
  }) async {
    if (!policy.allowRead(manual: manual, acceptedReply: acceptedReply)) return;
    if (!eventId.startsWith(r'$')) return;
    final server = room.client.baseUri;
    if (server == null) return;
    await withReadGrant(
      room.id,
      eventId,
      server,
      () => room.setReadMarker(
        eventId,
        mRead: eventId,
        public:
            (manual && publicReceipt) ||
            AppSettings.sendPublicReadReceipts.value,
      ),
    );
  }

  static final _observed = <Room, String>{};
  static String? frozenReadCutoff(Room room) => _observed[room];
  static Future<T> withFrozenRoundReadCutoff<T>(
    Room room,
    String? cutoff,
    Future<T> Function() action, {
    bool Function()? stillCurrent,
  }) => runZoned(
    action,
    zoneValues: {_roundReadCutoffKey: (room, cutoff, stillCurrent)},
  );
  static bool frozenRoundTargetCurrent(Room room) {
    final frozen = Zone.current[_roundReadCutoffKey];
    return frozen is! (Room, String?, bool Function()?) ||
        !identical(frozen.$1, room) ||
        frozen.$3?.call() != false;
  }

  static void observe(Room room, String eventId) {
    if (!surfaceUnlocked) return;
    if (eventId.startsWith(r'$')) _observed[room] = eventId;
  }

  static void forgetObservedControl(Event event) {
    if (isTelegramMediaControl(event.type) &&
        _observed[event.room] == event.eventId) {
      _observed.remove(event.room);
    }
  }

  static void forget(Client client) {
    MediaPrefetcher.closeFor(client);
    unawaited(TelegramRoundService.closeFor(client));
    TelegramRoomBinding.forget(client);
    _observed.removeWhere((room, _) => identical(room.client, client));
    _typingRooms.removeWhere((room) => identical(room.client, client));
  }

  static void bind(Client client) {
    TelegramRoundService.of(client);
    client.wrapOutgoingRequest = (room, type, content, txid, send) async {
      final server = client.baseUri;
      if (server == null) throw const PrivacySuppressed();
      if (isTelegramMediaControl(type) ||
          RoundVideoDescriptor.fromContent(content) != null) {
        await client.authorizeOutgoingEvent?.call(room, type, content);
      }
      return withOutgoingPrivacyContext(
        roomId: room.id,
        type: type,
        transactionId: txid,
        server: server,
        content: content,
        isCurrent: () => frozenRoundTargetCurrent(room),
        requireEncrypted:
            isTelegramMediaControl(type) ||
            RoundVideoDescriptor.fromContent(content) != null,
        action: send,
      );
    };
    client.authorizeAttachmentAccess = (event, thumbnail) async {
      if (!RoundMediaPolicy.fromContent(event.content).canPlay) {
        throw const PersonalCapabilityUnavailable(
          'To medium wymaga bezpiecznego otwarcia w Telegramie.',
        );
      }
      if (RoundVideoDescriptor.fromContent(event.content) != null &&
          (await TelegramRoundService.of(
                client,
              ).mediaState(event))?['expired'] ==
              true) {
        throw const PersonalCapabilityUnavailable(
          'This video message has expired.',
        );
      }
    };
    client.authorizeOutgoingEvent = (room, type, content) async {
      if (isJournal(room)) return;
      if (content['msgtype'] is String &&
          isTelegramMediaControl(content['msgtype'] as String)) {
        throw const PrivacySuppressed();
      }
      if (type == telegramMediaStateType) throw const PrivacySuppressed();
      if (type == telegramMediaPlayedType || type == telegramMediaForwardType) {
        if (!surfaceUnlocked ||
            !surfaceForeground ||
            !room.encrypted ||
            !client.encryptionEnabled) {
          throw const PrivacySuppressed();
        }
        final destination = TelegramRoomBinding.of(room);
        final source = content['source'];
        if (destination == null ||
            source is! Map ||
            content['version'] != 1 ||
            source['account_id'] != destination.identity.accountId ||
            source['room_id'] is! String ||
            source['event_id'] is! String) {
          throw const PrivacySuppressed();
        }
        final sourceRoom = client.getRoomById(source['room_id'] as String);
        final binding = sourceRoom == null
            ? null
            : TelegramRoomBinding.of(sourceRoom);
        final sourceEvent = sourceRoom == null
            ? null
            : await sourceRoom.getEventById(source['event_id'] as String);
        if (binding == null ||
            sourceEvent == null ||
            sourceEvent.redacted ||
            RoundVideoDescriptor.fromContent(sourceEvent.content) == null ||
            binding.identity.accountId != destination.identity.accountId) {
          throw const PrivacySuppressed();
        }
        final extension = destination.capabilities(room).extension;
        if (type == telegramMediaPlayedType) {
          if (sourceRoom != room ||
              !extension.operation('playback_receipts').allowed ||
              !RoundMediaPolicy.fromContent(sourceEvent.content).canPlay) {
            throw const PrivacySuppressed();
          }
          authorizeMediaPlayed(content, policy.incognito);
        } else {
          final target = content['destination'];
          if (!extension.operation('native_forward').allowed ||
              target is! Map ||
              target['room_id'] != room.id ||
              target['account_id'] != destination.identity.accountId ||
              !RoundMediaPolicy.fromContent(sourceEvent.content).canForward ||
              (content['silent'] == true &&
                  !extension.operation('silent_send').allowed) ||
              ((content['schedule_date'] as num? ?? 0) != 0 &&
                  !extension.operation('scheduled_send').allowed)) {
            throw const PrivacySuppressed();
          }
        }
        return;
      }
      final round = RoundVideoDescriptor.fromContent(content);
      final options = content[telegramSendOptionsKey];
      if (options != null &&
          (round == null ||
              options is! Map ||
              options.length != 3 ||
              options['version'] != 1 ||
              options['silent'] != true ||
              options['schedule_date'] != 0 ||
              TelegramRoomBinding.of(room)
                      ?.capabilities(room)
                      .extension
                      .operation('silent_send')
                      .allowed !=
                  true)) {
        throw const PrivacySuppressed();
      }
      if (round != null) {
        final preflight = await TelegramRoomBinding.preflight(room);
        final profile = preflight?.profile;
        if (!surfaceUnlocked ||
            !room.encrypted ||
            !client.encryptionEnabled ||
            !client.fileEncryptionEnabled ||
            !frozenRoundTargetCurrent(room) ||
            preflight?.result.allowed != true ||
            profile == null ||
            !RoundMediaPolicy.fromContent(content).canPersist ||
            round.width == null ||
            round.width != round.height ||
            round.width! <= 0 ||
            round.width! > profile.maxSide ||
            round.durationMs == null ||
            round.durationMs! <= 0 ||
            round.durationMs! > profile.maxDurationMs ||
            round.sizeBytes == null ||
            round.sizeBytes! <= 0 ||
            round.sizeBytes! > profile.maxSizeBytes ||
            content['file'] is! Map ||
            content.containsKey('url')) {
          throw const PersonalCapabilityUnavailable(
            'The bridge, permissions or round video format are unverified. The recording remains in the queue.',
          );
        }
      }
      final relation = content['m.relates_to'];
      final reply = relation is Map ? relation['m.in_reply_to'] : null;
      final sourceId =
          content['redacts'] ??
          (relation is Map ? relation['event_id'] : null) ??
          (reply is Map ? reply['event_id'] : null);
      final event = sourceId is String
          ? await room.getEventById(sourceId)
          : null;
      if (relation is Map &&
          relation['rel_type'] == RelationshipTypes.edit &&
          (round != null ||
              (event != null &&
                  RoundVideoDescriptor.fromContent(event.content) != null))) {
        throw const PersonalCapabilityUnavailable(
          'Telegram does not support editing sent round videos.',
        );
      }
      final fileInfo = content['info'];
      final mime = fileInfo is Map ? fileInfo['mimetype'] as String? : null;
      final features = <BridgeFeature>{
        if (type == EventTypes.Redaction)
          event?.type == EventTypes.Reaction
              ? BridgeFeature.reaction
              : BridgeFeature.delete,
        if (type == EventTypes.Reaction) BridgeFeature.reaction,
        if (type == EventTypes.Sticker) BridgeFeature.sticker,
        if (type.contains('poll')) BridgeFeature.poll,
        if (relation is Map && relation['rel_type'] == RelationshipTypes.edit)
          BridgeFeature.edit,
        if (reply is Map) BridgeFeature.reply,
        if (relation is Map && relation['rel_type'] == RelationshipTypes.thread)
          BridgeFeature.thread,
        ...switch (content['msgtype']) {
          'm.image' => {BridgeFeature.image},
          'm.video' => {
            round == null ? BridgeFeature.video : BridgeFeature.roundVideo,
          },
          'm.audio' => {
            content.containsKey('org.matrix.msc3245.voice')
                ? BridgeFeature.voice
                : BridgeFeature.audio,
          },
          'm.file' => {BridgeFeature.upload},
          'm.location' => {BridgeFeature.location},
          _ => <BridgeFeature>{},
        },
      };
      for (final feature in features) {
        final capability = RoomCapabilities.forFeature(
          feature,
          room,
          event: event,
          media: mime == null
              ? null
              : BridgeMediaRequest(
                  mimeType: mime,
                  sizeBytes: fileInfo['size'] as int?,
                  width: fileInfo['w'] as int?,
                  height: fileInfo['h'] as int?,
                  durationSeconds: fileInfo['duration'] is num
                      ? (fileInfo['duration'] as num).toDouble() / 1000
                      : null,
                ),
        );
        if (capability.status == CapabilityStatus.unavailable ||
            (round != null &&
                capability.status != CapabilityStatus.available)) {
          throw PersonalCapabilityUnavailable(capability.reason);
        }
      }
    };

    client.captureOutgoingContext = (room, type) {
      if (!policy.incognito ||
          isJournal(room) ||
          !{EventTypes.Message, EventTypes.Sticker}.contains(type)) {
        return null;
      }
      final frozen = Zone.current[_roundReadCutoffKey];
      if (frozen is (Room, String?, bool Function()?) &&
          identical(frozen.$1, room)) {
        return frozen.$2;
      }
      return _observed[room];
    };
    client.onOutgoingAccepted = (room, eventId, context) async {
      if (context is String) await markRead(room, context, acceptedReply: true);
    };
  }

  static final _typingRooms = <Room>{};
  static Future<void> setTyping(Room room, bool typing, {int? timeout}) async {
    if (typing && !policy.allowTyping) return;
    if (typing) {
      _typingRooms.add(room);
    } else {
      _typingRooms.remove(room);
    }
    await room.setTyping(typing, timeout: timeout);
  }

  static Future<void> setIncognito(bool enabled, List<Client> clients) async {
    await AppSettings.personalIncognito.setItem(enabled);
    if (enabled) {
      for (final room in List<Room>.from(_typingRooms)) {
        await setTyping(room, false);
      }
    }
    for (final client in clients) {
      client.syncPresence = enabled
          ? PresenceType.offline
          : PresenceType.unavailable;
    }
  }

  static bool isJournal(Room room) =>
      room.getState(personalRoomMarker)?.content['schema'] ==
      personalSchemaVersion;

  /// Decryption/authentication precede interpreting the public wake hint.
  static Future<Room?> reminderTarget(Event event) async {
    if (!isJournal(event.room) ||
        event.redacted ||
        event.type != personalEventType ||
        event.senderId != event.room.client.userID ||
        event.originalSource?.type != EventTypes.Encrypted) {
      return null;
    }
    final client = event.room.client;
    // Authenticated by the megolm session that decrypted it, not by the
    // unauthenticated envelope sender_key.
    if (!await MegolmTrustSnapshot.verify(event)) return null;
    final members = await event.room.requestParticipants([
      Membership.join,
      Membership.invite,
    ]);
    if (members.isEmpty || members.any((u) => u.id != client.userID)) {
      return null;
    }
    final op = PersonalOperation.fromJson(event.content);
    if (op.kind != 'reminder.result' ||
        op.payload['state'] != 'done' ||
        op.payload['due'] != true) {
      return null;
    }
    final conversation = op.payload['conversation'];
    if (conversation is! Map || conversation['accountId'] != client.userID) {
      return null;
    }
    return client.getRoomById(conversation['roomId'] as String? ?? '');
  }

  static void installLogging() {
    Logs().sanitize = (event) => LogEvent(
      'diagnostic: ${event.level.name}',
      exception: event.exception?.runtimeType.toString(),
      level: event.level,
    );
    Logs().level = Level.warning;
  }
}
