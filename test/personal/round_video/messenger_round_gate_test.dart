// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic room state only; no live account, bridge or Flutter.
// ignore_for_file: avoid_relative_lib_imports
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

import '../../../lib/personal/capabilities.dart';
import '../../../lib/personal/round_video/messenger_round_gate.dart';
import '../../../lib/personal/round_video/round_availability.dart';
import '../../../lib/personal/round_video/round_send_route.dart';
import '../../../lib/personal/round_video/telegram_room_binding.dart';

const _owner = '@fixture-owner:example.invalid';
const _bot = '@fixture-metabot:bridge.invalid';
const _roomId = '!fixture-messenger:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation _) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('synthetic messenger gate', database: _NoDatabase());
  bool e2ee = true, failConfig = false;
  int? uploadLimit = 8000000;
  @override
  bool get encryptionEnabled => e2ee;
  @override
  String? get userID => _owner;
  @override
  String? get deviceID => 'fixture-device';
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async {
    if (failConfig) throw StateError('Synthetic config failure');
    return MediaConfig(mUploadSize: uploadLimit);
  }
}

Map<String, dynamic> _features({
  Map<String, dynamic>? video = const {
    'mime_types': {'video/mp4': 2, 'video/quicktime': 2},
    'caption': 1,
    'max_size': 4000000,
  },
}) => {
  'id': 'fixture.meta.capabilities',
  'file': {'m.video': ?video},
};

Room _room({
  String protocol = 'facebook',
  String key = 'fixture-state',
  String? sender,
  String? missingType,
  bool joinedBot = true,
  bool encrypted = true,
  Membership membership = Membership.join,
  Map<String, dynamic>? features,
  Map<String, String> extraBridges = const {},
  List<String> joinedMembers = const [],
  String? receiver = 'fixture-login',
}) {
  final client = _Client();
  final room = Room(id: _roomId, client: client, membership: membership);
  client.rooms.add(room);
  void state(
    String type,
    Map<String, dynamic> content, {
    String stateKey = '',
    String? from,
  }) {
    if (type == missingType) return;
    room.setState(
      Event(
        room: room,
        type: type,
        stateKey: stateKey,
        content: content,
        senderId: from ?? sender ?? _bot,
        eventId: r'$fixture-state',
        originServerTs: DateTime.utc(2026),
      ),
    );
  }

  Map<String, dynamic> info(String protocolId, String bot) => {
    'bridgebot': bot,
    'creator': bot,
    'protocol': {'id': protocolId},
    'channel': {'id': 'fixture-thread', 'fi.mau.receiver': ?receiver},
  };
  state('m.bridge', info(protocol, _bot), stateKey: key);
  state('uk.half-shot.bridge', info(protocol, _bot), stateKey: key);
  state(bridgeFeaturesEventType, features ?? _features(), stateKey: key);
  extraBridges.forEach((extraKey, extraProtocol) {
    const otherBot = '@fixture-otherbot:bridge.invalid';
    state(
      'm.bridge',
      info(extraProtocol, otherBot),
      stateKey: extraKey,
      from: otherBot,
    );
    state(
      'uk.half-shot.bridge',
      info(extraProtocol, otherBot),
      stateKey: extraKey,
      from: otherBot,
    );
    state(
      bridgeFeaturesEventType,
      _features(),
      stateKey: extraKey,
      from: otherBot,
    );
  });
  state(
    EventTypes.RoomMember,
    {'membership': joinedBot ? 'join' : 'leave'},
    stateKey: _bot,
    from: _bot,
  );
  state(
    EventTypes.RoomMember,
    {'membership': 'join'},
    stateKey: _owner,
    from: _owner,
  );
  // A Messenger contact is a ghost of the bridge's own server.
  state(
    EventTypes.RoomMember,
    {'membership': 'join'},
    stateKey: '@fixture-meta_100:bridge.invalid',
    from: _bot,
  );
  for (final member in joinedMembers) {
    state(
      EventTypes.RoomMember,
      {'membership': 'join'},
      stateKey: member,
      from: member,
    );
  }
  if (encrypted) {
    state(EventTypes.Encryption, {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
    }, from: _owner);
  }
  return room;
}

void main() {
  RoundGateCode code(Room room, {bool silent = false, bool upload = false}) =>
      MessengerRoundGate.diagnose(
        room,
        silent: silent,
        requireUploadLimit: upload,
      ).code;

  test('own encrypted Messenger chat offers round video', () {
    final room = _room();
    expect(code(room), RoundGateCode.available);
    expect(MessengerRoundGate.of(room), isNotNull);
    expect(RoundSendRoute.forRoom(room), RoundSendRoute.messenger);
    final availability = RoundAvailability.of(room);
    expect(availability.canRecord, isTrue);
    expect(availability.reason, isNull);
    expect(MessengerRoundGate.isMessengerRoom(room), isTrue);
  });

  test('bridgev2 publishes the Beeper bridge type facebookgo', () {
    final room = _room(protocol: 'facebookgo');
    expect(code(room), RoundGateCode.available);
    expect(RoundSendRoute.diagnoseRoom(room).code, RoundGateCode.available);
    expect(RoundSendRoute.forRoom(room), RoundSendRoute.messenger);
    expect(RoundAvailability.of(room).canRecord, isTrue);
    expect(roundChatNetworks, contains('facebookgo'));
    expect(code(_room(protocol: 'instagramgo')), RoundGateCode.available);
  });

  test('gate matrix: network, bridges, ownership and encryption', () {
    expect(code(_room(protocol: 'instagram')), RoundGateCode.available);
    expect(code(_room(protocol: 'whatsapp')), RoundGateCode.unsupportedNetwork);
    expect(
      code(_room(extraBridges: const {'second': 'whatsapp'})),
      RoundGateCode.ambiguousBridges,
    );
    expect(
      code(_room(extraBridges: const {'second': 'facebook'})),
      RoundGateCode.ambiguousBridges,
    );
    expect(code(_room(encrypted: false)), RoundGateCode.notEncrypted);
    final noE2ee = _room();
    (noE2ee.client as _Client).e2ee = false;
    expect(code(noE2ee), RoundGateCode.fileEncryptionOff);
    expect(code(_room(membership: Membership.leave)), RoundGateCode.notJoined);
    expect(code(_room(missingType: 'm.bridge')), RoundGateCode.noBridgeInfo);
    expect(
      code(_room(missingType: 'uk.half-shot.bridge')),
      RoundGateCode.missingLegacyBridgeInfo,
    );
    expect(
      code(_room(missingType: bridgeFeaturesEventType)),
      RoundGateCode.missingRoomFeatures,
    );
    expect(
      code(_room(sender: '@forged:example.invalid')),
      RoundGateCode.senderMismatch,
    );
    expect(code(_room(joinedBot: false)), RoundGateCode.botNotJoined);
    expect(
      code(_room(joinedMembers: const ['@someone-else:example.invalid'])),
      RoundGateCode.foreignOwner,
      reason: 'Another Matrix user could make the bridge relay',
    );
    expect(code(_room(receiver: null)), RoundGateCode.available);
    for (final room in [
      _room(protocol: 'whatsapp'),
      _room(extraBridges: const {'second': 'facebook'}),
      _room(joinedMembers: const ['@someone-else:example.invalid']),
    ]) {
      expect(MessengerRoundGate.of(room), isNull);
      expect(RoundSendRoute.forRoom(room), isNull);
      expect(RoundAvailability.of(room).canRecord, isFalse);
    }
  });

  test('room features must accept MP4 video', () {
    expect(
      code(_room(features: _features(video: null))),
      RoundGateCode.videoNotAllowed,
    );
    expect(
      code(
        _room(
          features: _features(
            video: const {
              'mime_types': {'video/webm': 2},
            },
          ),
        ),
      ),
      RoundGateCode.videoNotAllowed,
    );
    expect(
      code(
        _room(
          features: _features(
            video: const {
              'mime_types': {'video/mp4': -2},
            },
          ),
        ),
      ),
      RoundGateCode.videoNotAllowed,
    );
    expect(
      roundGateMessage(RoundGateCode.videoNotAllowed),
      "This chat doesn't accept video messages.",
    );
  });

  test('no silent send on Messenger', () {
    expect(code(_room(), silent: true), RoundGateCode.silentUnsupported);
    expect(RoundSendRoute.messenger.needsTrust, isFalse);
    expect(RoundSendRoute.telegram.needsTrust, isTrue);
  });

  test('preflight measures the upload limit and derives the profile', () async {
    final room = _room();
    final binding = MessengerRoundGate.of(room)!;
    expect(
      binding.capabilities(room).allowed,
      isFalse,
      reason: 'No upload measurement yet',
    );
    expect(code(room, upload: true), RoundGateCode.uploadLimitUnknown);
    final caps = (await MessengerRoundGate.preflight(room))!;
    expect(caps.allowed, isTrue);
    expect(caps.silentAllowed, isFalse);
    final profile = caps.profile!;
    expect(profile.valid, isTrue);
    expect(profile.maxSizeBytes, 4000000, reason: 'Bridge max_size is lower');
    expect(profile.maxSide, 640);
    expect(profile.maxDurationMs, 60000);
    expect(code(room, upload: true), RoundGateCode.available);

    final client = room.client as _Client;
    client.uploadLimit = 2000000;
    expect(
      (await MessengerRoundGate.preflight(room))!.profile!.maxSizeBytes,
      2000000,
    );
    client.failConfig = true;
    final failed = (await MessengerRoundGate.preflight(room))!;
    expect(failed.allowed, isFalse);
    expect(MessengerRoundGate.uploadLimitUnreachable(client), isTrue);
  });

  test('round capability is the Messenger video declaration', () async {
    final room = _room();
    await MessengerRoundGate.preflight(room);
    BridgeCapabilityEvidence evidence(int size) =>
        RoomCapabilities.evidenceForFeature(
          BridgeFeature.roundVideo,
          room,
          media: BridgeMediaRequest(
            mimeType: 'video/mp4',
            sizeBytes: size,
            width: 384,
            height: 384,
            durationSeconds: 5,
          ),
        );
    expect(evidence(1000).result.allowed, isTrue);
    expect(evidence(5000000).result.allowed, isFalse);
    final unencrypted = RoomCapabilities.evidenceForFeature(
      BridgeFeature.roundVideo,
      _room(encrypted: false),
    );
    expect(unencrypted.result.allowed, isFalse);
    expect(unencrypted.reasonCode, 'round:notEncrypted');
    final instagram = RoomCapabilities.evidenceForFeature(
      BridgeFeature.roundVideo,
      _room(protocol: 'instagram'),
    );
    expect(instagram.result.allowed, isTrue);
  });

  test('outgoing content picks the route by its marker', () {
    const descriptor = RoundVideoDescriptor(
      sizeBytes: 1,
      width: 1,
      height: 1,
      durationMs: 1,
    );
    Map<String, dynamic> content(String network) => {
      'msgtype': 'm.video',
      'info': descriptor.matrixInfoFor(network),
    };
    expect(
      RoundSendRoute.forContent(content('telegram')),
      RoundSendRoute.telegram,
    );
    expect(
      RoundSendRoute.forContent(content('facebook')),
      RoundSendRoute.messenger,
    );
    expect(RoundSendRoute.forNetwork('facebook'), RoundSendRoute.messenger);
    expect(RoundSendRoute.forNetwork('instagram'), RoundSendRoute.instagram);
    expect(
      RoundSendRoute.forContent(content('instagram')),
      RoundSendRoute.instagram,
    );
    expect(
      RoundSendRoute.forContent({
        'msgtype': 'm.video',
        'info': {roundVideoDisplayMarker: true},
      }),
      RoundSendRoute.messenger,
      reason: 'Legacy Messenger rounds have no network marker',
    );
  });

  test('copy names all supported networks', () {
    expect(
      roundGateMessage(RoundGateCode.unsupportedNetwork),
      'Round videos are only available in Telegram, Messenger and Instagram chats.',
    );
    expect(
      roundGateMessage(RoundGateCode.notTelegram),
      'Round videos are only available in Telegram, Messenger and Instagram chats.',
    );
  });

  for (final protocol in instagramProtocolIds) {
    group(protocol, () {
      test(
        'offers the shared recorder through a distinct Instagram route',
        () async {
          final room = _room(protocol: protocol);
          final route = RoundSendRoute.forRoom(room)!;
          expect(route, RoundSendRoute.instagram);
          expect(route.network, 'instagram');
          expect(route.label, 'Instagram');
          expect(route.needsTrust, isFalse);
          expect(roundChatNetworks, contains(protocol));
          expect(RoundAvailability.of(room).canRecord, isTrue);
          expect(
            RoundSendRoute.diagnoseRoom(room).code,
            RoundGateCode.available,
          );
          expect(MessengerRoundGate.isMessengerRoom(room), isFalse);
          expect(MessengerRoundGate.of(room)!.network, 'instagram');
          expect(RoundSendRoute.messenger.bound(room), isNull);
          final caps = (await route.preflight(room))!;
          expect(caps.allowed, isTrue);
          expect(caps.profile!.maxSizeBytes, 4000000);
          expect(caps.profile!.maxSide, 640);
          expect(caps.profile!.maxDurationMs, 60000);
          expect(caps.silentAllowed, isFalse);
          expect(
            route.diagnose(room, silent: true).code,
            RoundGateCode.silentUnsupported,
          );
        },
      );

      test('keeps identity, ownership, encryption and MP4 checks', () {
        final denied = <(Room, RoundGateCode)>[
          (
            _room(protocol: protocol, encrypted: false),
            RoundGateCode.notEncrypted,
          ),
          (
            _room(protocol: protocol, joinedBot: false),
            RoundGateCode.botNotJoined,
          ),
          (
            _room(protocol: protocol, sender: '@forged:example.invalid'),
            RoundGateCode.senderMismatch,
          ),
          (
            _room(protocol: protocol, missingType: 'uk.half-shot.bridge'),
            RoundGateCode.missingLegacyBridgeInfo,
          ),
          (
            _room(protocol: protocol, missingType: bridgeFeaturesEventType),
            RoundGateCode.missingRoomFeatures,
          ),
          (
            _room(protocol: protocol, features: _features(video: null)),
            RoundGateCode.videoNotAllowed,
          ),
          (
            _room(
              protocol: protocol,
              joinedMembers: const ['@another:example.invalid'],
            ),
            RoundGateCode.foreignOwner,
          ),
          (
            _room(
              protocol: protocol,
              extraBridges: const {'second': 'facebook'},
            ),
            RoundGateCode.ambiguousBridges,
          ),
        ];
        for (final (room, expected) in denied) {
          expect(code(room), expected);
          expect(RoundAvailability.of(room).canRecord, isFalse);
          final evidence = RoomCapabilities.evidenceForFeature(
            BridgeFeature.roundVideo,
            room,
          );
          expect(evidence.result.allowed, isFalse);
          expect(evidence.reasonCode, 'round:${expected.name}');
        }
      });

      test(
        'MP4 limits remain current and an unreachable limit fails closed',
        () async {
          final room = _room(
            protocol: protocol,
            features: _features(
              video: const {
                'mime_types': {'video/mp4': 2},
                'max_size': 3000000,
                'max_width': 480,
                'max_height': 320,
                'max_duration': 15,
              },
            ),
          );
          final route = RoundSendRoute.instagram;
          final profile = (await route.preflight(room))!.profile!;
          expect(profile.maxSizeBytes, 3000000);
          expect(profile.maxSide, 320);
          expect(profile.recommendedSide, 320);
          expect(profile.maxDurationMs, 15000);
          expect(
            RoomCapabilities.forFeature(
              BridgeFeature.roundVideo,
              room,
              media: const BridgeMediaRequest(
                mimeType: 'video/mp4',
                sizeBytes: 4000000,
                width: 320,
                height: 320,
                durationSeconds: 10,
              ),
            ).allowed,
            isFalse,
          );
          (room.client as _Client).failConfig = true;
          expect((await route.preflight(room))!.allowed, isFalse);
          expect(route.uploadLimitUnreachable(room.client), isTrue);
          expect(
            route.diagnose(room, requireUploadLimit: true).code,
            RoundGateCode.uploadLimitUnknown,
          );
        },
      );

      test(
        'a frozen Instagram route cannot follow a protocol replacement',
        () async {
          final room = _room(protocol: protocol);
          final route = RoundSendRoute.forRoom(room)!;
          await route.preflight(room);
          final identity = route.bound(room)!;
          for (final type in ['m.bridge', 'uk.half-shot.bridge']) {
            final previous = room.getState(type, 'fixture-state')!;
            room.setState(
              Event(
                room: room,
                type: type,
                stateKey: previous.stateKey,
                content: {
                  ...previous.content,
                  'protocol': {'id': 'facebook'},
                },
                senderId: _bot,
                eventId: r'$changed',
                originServerTs: DateTime.utc(2026),
              ),
            );
          }
          expect(route.bound(room), isNull);
          expect(route.capabilities(room), isNull);
          expect(await route.preflight(room), isNull);
          expect(RoundSendRoute.forRoom(room), RoundSendRoute.messenger);
          expect(
            RoundSendRoute.messenger.bound(room)!.stateKey,
            identity.stateKey,
            reason:
                'Network binding matters even with the same bot, key and login',
          );
        },
      );
    });
  }

  test('report never carries identifiers or state contents', () {
    for (final room in [
      _room(),
      _room(joinedMembers: const ['@someone-else:example.invalid']),
      _room(protocol: 'instagram'),
    ]) {
      final text = MessengerRoundGate.diagnose(room).toString();
      for (final secret in [_owner, _bot, _roomId, 'fixture-state']) {
        expect(text, isNot(contains(secret)));
      }
    }
  });
}
