// SPDX-License-Identifier: AGPL-3.0-or-later
// Run through worker's pure-Dart package config; no live account or Flutter.
// ignore_for_file: avoid_relative_lib_imports
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

import '../../../lib/personal/capabilities.dart';
import '../../../lib/personal/round_video/round_availability.dart';
import '../../../lib/personal/round_video/telegram_room_binding.dart';

const _owner = '@fixture-owner:example.invalid';
const _bot = '@fixture-bridge:example.invalid';
const _login = 'fixture-own-login';
const _roomId = '!fixture-round:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation _) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('synthetic binding', database: _NoDatabase());
  final configRefresh = <(Duration, bool)>[];
  bool failConfigRefresh = false;
  String owner = _owner, device = 'fixture-device';
  bool e2ee = true;
  @override
  bool get encryptionEnabled => e2ee;
  @override
  String? get userID => owner;
  @override
  String? get deviceID => device;
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async {
    configRefresh.add((cacheLifetime, throwOnUpdateFailure));
    if (failConfigRefresh && throwOnUpdateFailure) {
      throw StateError('Synthetic config refresh failure');
    }
    return MediaConfig(mUploadSize: 8000000);
  }
}

Room _fixture({
  String key = 'fixture-state',
  String? receiver = _login,
  String owner = _owner,
  String? sender,
  String bot = _bot,
  bool pinned = true,
  String protocol = 'telegram',
  String? missingType,
  String? foreignKeyType,
  String contentRoom = _roomId,
  bool joinedBot = true,
  Membership membership = Membership.join,
  bool encrypted = true,
  Map<String, dynamic> mediaOverrides = const {},
}) {
  final client = _Client();
  final room = Room(id: _roomId, client: client, membership: membership);
  client.rooms.add(room);
  void state(
    String type,
    Map<String, dynamic> content, {
    String? stateKey,
    String? stateSender,
  }) {
    if (type == missingType) return;
    room.setState(
      Event(
        room: room,
        type: type,
        stateKey: stateKey ?? (foreignKeyType == type ? 'foreign-key' : key),
        content: content,
        senderId: stateSender ?? sender ?? bot,
        eventId: r'$fixture-state',
        originServerTs: DateTime.utc(2026),
      ),
    );
  }

  final info = <String, dynamic>{
    'bridgebot': bot,
    'creator': bot,
    'protocol': {'id': protocol},
    'channel': {'fi.mau.receiver': receiver},
  };
  state('m.bridge', info);
  state('uk.half-shot.bridge', info);
  state(bridgeFeaturesEventType, {
    'id': 'fi.mau.telegram.capabilities.round.v1+fixture',
    'file': {
      roundVideoCapabilityKey: {
        'mime_types': {'video/mp4': 2},
        'caption': -2,
        'max_size': 16000000,
        'max_width': 640,
        'max_height': 640,
        'max_duration': 60,
      },
    },
  });
  state(telegramMediaCapabilitiesEventType, {
    'version': 1,
    'matrix_user_id': owner,
    'account_id': _login,
    'room_id': contentRoom,
    'bridge_state_key': key,
    'round_video': true,
    'round_video_permission': 'allowed',
    ...mediaOverrides,
    if (!mediaOverrides.containsKey('profile'))
      'profile': {
        'id': 'pl.personal.chat.telegram.round_video.v1',
        'container': 'mp4',
        'video_codec': 'h264',
        'audio_codec': 'aac',
        'pixel_format': 'yuv420p',
        'square': true,
        'sanitized_corners': true,
        'max_duration_ms': 60000,
        'max_dimension_px': 640,
        'max_size_bytes': 16000000,
      },
  });
  state(
    EventTypes.RoomMember,
    {'membership': joinedBot ? 'join' : 'leave'},
    stateKey: bot,
    stateSender: bot,
  );
  if (encrypted) {
    state(
      EventTypes.Encryption,
      {'algorithm': AlgorithmTypes.megolmV1AesSha2},
      stateKey: '',
      stateSender: owner,
    );
  }
  if (pinned)
    TelegramRoomBinding.installTrustedIdentity(
      client,
      RoundBridgeIdentity(
        accountId: _login,
        roomId: _roomId,
        stateKey: key,
        senderId: bot,
      ),
    );
  return room;
}

void main() {
  test(
    'trusted portal requires same state source, own Matrix owner + bridge login',
    () async {
      final room = _fixture();
      final binding = TelegramRoomBinding.of(room);
      expect(binding, isNotNull);
      expect(binding!.identity.accountId, _login);
      expect(binding.identity.senderId, _bot);
      expect(
        binding.capabilities(room).result.allowed,
        isFalse,
        reason: 'No runtime upload measurement yet',
      );
      final caps = await TelegramRoomBinding.preflight(room);
      expect(caps!.result.allowed, isTrue);
      expect(caps.profile!.maxSizeBytes, 8000000);
      expect(
        RoomCapabilities.forFeature(
          BridgeFeature.roundVideo,
          room,
          media: const BridgeMediaRequest(
            mimeType: 'video/mp4',
            sizeBytes: 1000,
            width: 384,
            height: 384,
            durationSeconds: 5,
          ),
        ).allowed,
        isTrue,
      );
      expect(
        RoomCapabilities.forFeature(
          BridgeFeature.roundVideo,
          room,
          media: const BridgeMediaRequest(
            mimeType: 'video/mp4',
            sizeBytes: 1000,
            durationSeconds: 5,
          ),
        ).allowed,
        isFalse,
        reason: 'Round measurement guard must not invent missing dimensions',
      );
      expect(TelegramRoomBinding.of(room, stateKey: 'foreign'), isNull);
      expect(
        TelegramRoomBinding.of(_fixture(owner: '@foreign:invalid')),
        isNull,
      );
      expect(
        TelegramRoomBinding.of(_fixture(receiver: 'foreign-login')),
        isNull,
      );
      expect(
        TelegramRoomBinding.of(_fixture(sender: '@forged:invalid')),
        isNull,
      );
      expect(TelegramRoomBinding.of(_fixture(protocol: 'whatsapp')), isNull);
      expect(
        TelegramRoomBinding.of(_fixture(contentRoom: '!foreign:invalid')),
        isNull,
      );
      expect(TelegramRoomBinding.of(_fixture(joinedBot: false)), isNull);
      expect(
        TelegramRoomBinding.of(_fixture(membership: Membership.leave)),
        isNull,
      );
      for (final type in [
        'm.bridge',
        'uk.half-shot.bridge',
        bridgeFeaturesEventType,
        telegramMediaCapabilitiesEventType,
      ]) {
        expect(TelegramRoomBinding.of(_fixture(missingType: type)), isNull);
        expect(TelegramRoomBinding.of(_fixture(foreignKeyType: type)), isNull);
      }
    },
  );
  test(
    'trusted empty state key and shared portal still require exact owner',
    () {
      expect(
        TelegramRoomBinding.of(_fixture(key: '', receiver: null)),
        isNotNull,
      );
      expect(
        TelegramRoomBinding.of(
          _fixture(key: '', receiver: null, owner: '@foreign:invalid'),
        ),
        isNull,
      );
    },
  );
  test(
    'final preflight refreshes runtime limit and rejects failed refresh',
    () async {
      final room = _fixture();
      final client = room.client as _Client;
      expect(
        (await TelegramRoomBinding.preflight(room))!.result.allowed,
        isTrue,
      );
      expect(client.configRefresh.single, (Duration.zero, true));
      client.failConfigRefresh = true;
      expect(
        (await TelegramRoomBinding.preflight(room))!.result.allowed,
        isFalse,
        reason:
            'Expired runtime limit must not survive a failed server refresh',
      );
    },
  );
  test(
    'multiple independently valid bridge sources are ambiguous without selected key',
    () {
      final room = _fixture();
      final second = _fixture(key: 'second');
      for (final type in [
        'm.bridge',
        'uk.half-shot.bridge',
        bridgeFeaturesEventType,
        telegramMediaCapabilitiesEventType,
      ]) {
        final e = second.getState(type, 'second')!;
        room.setState(
          Event(
            room: room,
            type: type,
            stateKey: 'second',
            content: e.content,
            senderId: e.senderId,
            eventId: r'$second',
            originServerTs: DateTime.utc(2026),
          ),
        );
      }
      TelegramRoomBinding.installTrustedIdentity(
        room.client,
        const RoundBridgeIdentity(
          accountId: _login,
          roomId: _roomId,
          stateKey: 'second',
          senderId: _bot,
        ),
      );
      expect(TelegramRoomBinding.of(room), isNull);
      expect(
        TelegramRoomBinding.of(room, stateKey: 'fixture-state'),
        isNotNull,
      );
      expect(TelegramRoomBinding.of(room, stateKey: 'second'), isNotNull);
    },
  );
  test(
    'coherent forged claims never auto-pin trusted bridge identity',
    () async {
      final known = _fixture(pinned: false);
      expect(TelegramRoomBinding.unverifiedCandidate(known), isNotNull);
      expect(TelegramRoomBinding.of(known), isNull);
      expect(await TelegramRoomBinding.preflight(known), isNull);
      final forged = _fixture(
        bot: '@coherent-attacker:example.invalid',
        pinned: false,
      );
      expect(TelegramRoomBinding.unverifiedCandidate(forged), isNotNull);
      expect(TelegramRoomBinding.of(forged), isNull);
      TelegramRoomBinding.installTrustedIdentity(
        forged.client,
        const RoundBridgeIdentity(
          accountId: _login,
          roomId: _roomId,
          stateKey: 'fixture-state',
          senderId: _bot,
        ),
      );
      expect(TelegramRoomBinding.of(forged), isNull);
      expect(await TelegramRoomBinding.preflight(forged), isNull);
    },
  );
  test(
    'pins remain bound to own Matrix account/device if Client object is reused',
    () {
      final room = _fixture();
      final client = room.client as _Client;
      expect(TelegramRoomBinding.of(room), isNotNull);
      client.device = 'replacement-device';
      expect(TelegramRoomBinding.of(room), isNull);
      client.device = 'fixture-device';
      client.owner = '@replacement-owner:example.invalid';
      final media = room.getState(
        telegramMediaCapabilitiesEventType,
        'fixture-state',
      )!;
      room.setState(
        Event(
          room: room,
          type: media.type,
          stateKey: media.stateKey,
          content: {...media.content, 'matrix_user_id': client.owner},
          senderId: media.senderId,
          eventId: r'$owner-changed',
          originServerTs: DateTime.utc(2026),
        ),
      );
      expect(TelegramRoomBinding.of(room), isNull);
      expect(
        TelegramRoomBinding.of(_fixture(pinned: false)),
        isNull,
        reason: 'Another Client must not inherit pins',
      );
    },
  );

  group('diagnose', () {
    RoundGateCode code(Room room, {bool silent = false, bool upload = false}) =>
        TelegramRoomBinding.diagnose(
          room,
          silent: silent,
          requireUploadLimit: upload,
        ).code;

    test('stock bridge without the round extension lacks round support', () {
      final room = _fixture(missingType: telegramMediaCapabilitiesEventType);
      final report = TelegramRoomBinding.diagnose(room);
      expect(report.code, RoundGateCode.bridgeLacksRoundSupport);
      expect(report.terminal, isTrue);
      expect(report.checks['roomFeatures'], isTrue);
      expect(report.checks['roundExtension'], isFalse);
      final availability = RoundAvailability.of(room);
      expect(availability.canRecord, isFalse);
      expect(
        availability.reason,
        "This Telegram bridge doesn't support round video messages yet.",
      );
      expect(availability.hint, contains('ChatLoom round bridge'));
      final evidence = RoomCapabilities.evidenceForFeature(
        BridgeFeature.roundVideo,
        room,
      );
      expect(evidence.result.status, CapabilityStatus.unavailable);
      expect(evidence.result.reason, startsWith('This Telegram bridge'));
      expect(evidence.reasonCode, 'round:bridgeLacksRoundSupport');
    });

    test('valid trusted bridge is available, untrusted one needs trust', () {
      expect(code(_fixture()), RoundGateCode.available);
      final untrusted = _fixture(pinned: false);
      expect(code(untrusted), RoundGateCode.needsTrust);
      expect(RoundAvailability.of(untrusted).canRecord, isTrue);
      expect(
        RoundAvailability.of(untrusted).kind,
        RoundAvailabilityKind.needsTrust,
      );
      expect(
        TelegramRoomBinding.of(untrusted),
        isNull,
        reason: 'Diagnosis never authorizes',
      );
      final capability = RoomCapabilities.evidenceForFeature(
        BridgeFeature.roundVideo,
        untrusted,
      );
      expect(capability.result.status, CapabilityStatus.unverified);
      expect(capability.reasonCode, 'round:needsTrust');
    });

    test('availability cache follows trust changes', () {
      final room = _fixture(pinned: false);
      expect(RoundAvailability.of(room).code, RoundGateCode.needsTrust);
      TelegramRoomBinding.installTrustedIdentity(
        room.client,
        const RoundBridgeIdentity(
          accountId: _login,
          roomId: _roomId,
          stateKey: 'fixture-state',
          senderId: _bot,
        ),
      );
      expect(RoundAvailability.of(room).code, RoundGateCode.available);
    });

    test('resolution failures map to precise codes in check order', () {
      expect(
        code(_fixture(membership: Membership.leave)),
        RoundGateCode.notJoined,
      );
      expect(
        code(_fixture(missingType: 'm.bridge')),
        RoundGateCode.noBridgeInfo,
      );
      expect(code(_fixture(protocol: 'whatsapp')), RoundGateCode.notTelegram);
      expect(
        code(_fixture(missingType: 'uk.half-shot.bridge')),
        RoundGateCode.missingLegacyBridgeInfo,
      );
      expect(
        code(_fixture(missingType: bridgeFeaturesEventType)),
        RoundGateCode.missingRoomFeatures,
      );
      expect(
        code(_fixture(mediaOverrides: const {'version': 2})),
        RoundGateCode.extensionVersion,
      );
      expect(
        code(_fixture(owner: '@foreign:example.invalid')),
        RoundGateCode.foreignOwner,
      );
      expect(
        code(_fixture(contentRoom: '!foreign:example.invalid')),
        RoundGateCode.roomMismatch,
      );
      expect(
        code(_fixture(sender: '@forged:example.invalid')),
        RoundGateCode.senderMismatch,
      );
      expect(code(_fixture(joinedBot: false)), RoundGateCode.botNotJoined);
      expect(
        code(_fixture(receiver: 'foreign-login')),
        RoundGateCode.receiverMismatch,
      );
      expect(
        code(_fixture(foreignKeyType: telegramMediaCapabilitiesEventType)),
        RoundGateCode.bridgeLacksRoundSupport,
      );
    });

    test('declaration, profile, encryption and silent checks', () {
      expect(
        code(_fixture(mediaOverrides: const {'round_video': false})),
        RoundGateCode.roundDenied,
      );
      expect(
        code(
          _fixture(mediaOverrides: const {'round_video_permission': 'unknown'}),
        ),
        RoundGateCode.roundNotDeclared,
      );
      expect(
        code(_fixture(mediaOverrides: const {'profile': null})),
        RoundGateCode.profileIncomplete,
      );
      expect(code(_fixture(encrypted: false)), RoundGateCode.notEncrypted);
      final noE2ee = _fixture();
      (noE2ee.client as _Client).e2ee = false;
      expect(code(noE2ee), RoundGateCode.fileEncryptionOff);
      expect(code(_fixture(), silent: true), RoundGateCode.silentUnsupported);
      expect(
        code(
          _fixture(mediaOverrides: const {'silent_send': true}),
          silent: true,
        ),
        RoundGateCode.available,
      );
    });

    test('upload limit is required only right after preflight', () async {
      final room = _fixture();
      expect(code(room, upload: true), RoundGateCode.uploadLimitUnknown);
      expect(RoundGateCode.uploadLimitUnknown.terminal, isFalse);
      await TelegramRoomBinding.preflight(room);
      expect(code(room, upload: true), RoundGateCode.available);
    });

    test('multiple valid sources are ambiguous unless one is selected', () {
      final room = _fixture();
      final second = _fixture(key: 'second');
      for (final type in [
        'm.bridge',
        'uk.half-shot.bridge',
        bridgeFeaturesEventType,
        telegramMediaCapabilitiesEventType,
      ]) {
        final e = second.getState(type, 'second')!;
        room.setState(
          Event(
            room: room,
            type: type,
            stateKey: 'second',
            content: e.content,
            senderId: e.senderId,
            eventId: r'$second',
            originServerTs: DateTime.utc(2026),
          ),
        );
      }
      expect(code(room), RoundGateCode.ambiguousBridges);
      expect(
        TelegramRoomBinding.diagnose(room, stateKey: 'fixture-state').code,
        RoundGateCode.available,
      );
    });

    test('report never carries identifiers or state contents', () {
      for (final room in [
        _fixture(),
        _fixture(missingType: telegramMediaCapabilitiesEventType),
        _fixture(receiver: 'foreign-login'),
      ]) {
        final text = TelegramRoomBinding.diagnose(room).toString();
        for (final secret in [_owner, _bot, _login, _roomId, 'fixture-state']) {
          expect(text, isNot(contains(secret)));
        }
      }
    });
  });
}
