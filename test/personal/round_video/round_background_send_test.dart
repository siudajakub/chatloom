// SPDX-License-Identifier: AGPL-3.0-or-later
// A committed round finishes sending after the app is left or locked (J,
// 2026-10-27), still bound to its bridge, and holds the send lease only
// while it is queued or sending. Synthetic room state; no live account.
import 'dart:async';

import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/media/immediate_media_outbox.dart';
import 'package:chatloom/personal/media/pending_media_store.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/telegram_room_binding.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/utils/foreground_service_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

const _owner = '@fixture-owner:example.invalid';
const _device = 'fixture-device';
const _bot = '@fixture-bridge:example.invalid';
const _login = 'fixture-own-login';
const _roomId = '!fixture-round-send:example.invalid';
const _key = 'fixture-state';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation _) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('synthetic round send', database: _NoDatabase());
  @override
  bool get encryptionEnabled => true;
  @override
  String? get userID => _owner;
  @override
  String? get deviceID => _device;
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => MediaConfig(mUploadSize: 8000000);
}

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String stateKey = _key,
  String sender = _bot,
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: stateKey,
    content: content,
    senderId: sender,
    eventId: r'$fixture-state',
    originServerTs: DateTime.utc(2026),
  ),
);

void _mediaCapabilities(Room room, {String permission = 'allowed'}) =>
    _state(room, telegramMediaCapabilitiesEventType, {
      'version': 1,
      'matrix_user_id': _owner,
      'account_id': _login,
      'room_id': _roomId,
      'bridge_state_key': _key,
      'round_video': true,
      'round_video_permission': permission,
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

/// A trusted Telegram portal with the round extension, encrypted.
Room _room() {
  final client = _Client();
  final room = Room(id: _roomId, client: client, membership: Membership.join);
  client.rooms.add(room);
  final info = <String, dynamic>{
    'bridgebot': _bot,
    'creator': _bot,
    'protocol': {'id': 'telegram'},
    'channel': {'fi.mau.receiver': _login},
  };
  _state(room, 'm.bridge', info);
  _state(room, 'uk.half-shot.bridge', info);
  _state(room, bridgeFeaturesEventType, {
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
  _mediaCapabilities(room);
  _state(room, EventTypes.RoomMember, {'membership': 'join'}, stateKey: _bot);
  _state(
    room,
    EventTypes.Encryption,
    {'algorithm': AlgorithmTypes.megolmV1AesSha2},
    stateKey: '',
    sender: _owner,
  );
  TelegramRoomBinding.installTrustedIdentity(
    client,
    const RoundBridgeIdentity(
      accountId: _login,
      roomId: _roomId,
      stateKey: _key,
      senderId: _bot,
    ),
  );
  return room;
}

const _target = RoundSendTarget(
  accountId: _owner,
  deviceId: _device,
  roomId: _roomId,
  network: 'telegram',
  bridgeAccountId: _login,
  bridgeStateKey: _key,
  bridgeSenderId: _bot,
);

const _descriptor = RoundVideoDescriptor(
  sizeBytes: 1024,
  width: 384,
  height: 384,
  durationMs: 5000,
  videoCodec: 'h264',
  audioCodec: 'aac',
  cornersSanitized: true,
);

/// The final event the outbox sends (content shape of
/// [ImmediateMediaOutbox.dispatch]).
Map<String, dynamic> _finalContent() => {
  'msgtype': 'm.video',
  'body': 'video_message.mp4',
  'filename': 'video_message.mp4',
  'info': _descriptor.matrixInfoFor('telegram'),
  'file': {
    'v': 'v2',
    'iv': 'fixture-iv',
    'key': {'kty': 'oct', 'alg': 'A256CTR', 'k': 'fixture-key'},
    'hashes': {'sha256': 'fixture-digest'},
    'url': 'mxc://fixture.invalid/round',
  },
};

/// Holds `get` (the first step of a dispatch) until [release] completes.
class _HeldStore implements PendingMediaRepository {
  final release = Completer<void>();
  int reads = 0;
  @override
  Future<PendingMediaRecord?> get(String actionId) async {
    reads++;
    await release.future;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected store access');
}

ImmediateMediaOutbox _outbox(PendingMediaRepository store) =>
    ImmediateMediaOutbox(
      accountId: _owner,
      deviceId: _device,
      store: store,
      guard: (_, _) async {},
      encrypt: (_, _) async => throw StateError('not reached'),
      upload: (_, _, _) async => throw StateError('not reached'),
      sendEvent: (_, _, _) async => throw StateError('not reached'),
    );

void main() {
  setUp(() {
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
  });
  tearDown(() {
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
  });

  test('a committed round passes the checks before and after the upload '
      'while the app is in the background and locked', () async {
    final room = _room();
    final service = TelegramRoundService.of(room.client);
    addTearDown(() => TelegramRoundService.closeFor(room.client));
    PersonalPrivacy.surfaceForeground = false;
    PersonalPrivacy.surfaceUnlocked = false;
    await service.debugGuard(_target, _descriptor);
    expect(service.debugTargetStillBound(_target, _descriptor), isTrue);
  });

  test('a bridge revoked while the app is hidden still stops the send '
      'before and after the upload', () async {
    final room = _room();
    final service = TelegramRoundService.of(room.client);
    addTearDown(() => TelegramRoundService.closeFor(room.client));
    PersonalPrivacy.surfaceForeground = false;
    PersonalPrivacy.surfaceUnlocked = false;
    await service.debugGuard(_target, _descriptor);
    _mediaCapabilities(room, permission: 'denied');
    await expectLater(
      service.debugGuard(_target, _descriptor),
      throwsA(
        isA<ImmediateMediaRejected>().having(
          (e) => e.code,
          'code',
          'roundCapabilityUnavailable',
        ),
      ),
    );
    expect(service.debugTargetStillBound(_target, _descriptor), isFalse);
    _mediaCapabilities(room);
    // Another bridge login than the one the round was recorded for.
    const changed = RoundSendTarget(
      accountId: _owner,
      deviceId: _device,
      roomId: _roomId,
      network: 'telegram',
      bridgeAccountId: 'another-login',
      bridgeStateKey: _key,
      bridgeSenderId: _bot,
    );
    await expectLater(
      service.debugGuard(changed, _descriptor),
      throwsA(
        isA<ImmediateMediaRejected>().having(
          (e) => e.code,
          'code',
          'frozenBridgeIdentityChanged',
        ),
      ),
    );
    expect(service.debugTargetStillBound(changed, _descriptor), isFalse);
  });

  test('the final event of a committed round is authorised while locked; '
      'any other round event still needs the app unlocked', () async {
    final room = _room();
    final client = room.client;
    PersonalPrivacy.bind(client);
    final service = TelegramRoundService.of(client);
    addTearDown(() => PersonalPrivacy.forget(client));
    final authorize = client.authorizeOutgoingEvent!;
    Future<void> send({required bool committed}) =>
        PersonalPrivacy.withFrozenRoundReadCutoff(
          room,
          null,
          () async => authorize(room, EventTypes.Message, _finalContent()),
          committedRound: committed,
          stillCurrent: () =>
              service.debugTargetStillBound(_target, _descriptor),
        );

    await send(committed: false);
    PersonalPrivacy.surfaceForeground = false;
    PersonalPrivacy.surfaceUnlocked = false;
    await send(committed: true);
    await expectLater(
      send(committed: false),
      throwsA(isA<PersonalCapabilityUnavailable>()),
    );
    // Outside a committed send's own zone nothing is relaxed.
    expect(PersonalPrivacy.committedRoundSend(room), isFalse);
    // A revoked bridge refuses even the committed round.
    _mediaCapabilities(room, permission: 'denied');
    await expectLater(
      send(committed: true),
      throwsA(isA<PersonalCapabilityUnavailable>()),
    );
  });

  test('Retry holds the send lease until its dispatch ends, also when the '
      'round is already sending (early return)', () async {
    final calls = <String>[];
    final previous = TelegramRoundService.sendLease;
    final lease = ForegroundLease(
      start: () async {
        calls.add('start');
        return true;
      },
      stop: () async => calls.add('stop'),
    );
    TelegramRoundService.sendLease = lease;
    addTearDown(() => TelegramRoundService.sendLease = previous);
    final room = _room();
    final service = TelegramRoundService.of(room.client);
    addTearDown(() => TelegramRoundService.closeFor(room.client));
    final store = _HeldStore();
    service.debugUseOutbox(_outbox(store));
    // Hidden and locked: a tapped Retry still dispatches.
    PersonalPrivacy.surfaceForeground = false;
    PersonalPrivacy.surfaceUnlocked = false;

    final first = service.retry('fixture-action', room: room);
    await pumpEventQueue();
    expect(store.reads, 1, reason: 'dispatch started while hidden and locked');
    expect(lease.holds, 1);
    // A second tap while it sends: nothing new starts, its hold is released.
    final second = await service.retry('fixture-action', room: room);
    expect(second, isNull);
    expect(lease.holds, 1);
    store.release.complete();
    final result = await first;
    expect(result?.state, ImmediateMediaState.failed);
    expect(result?.errorCode, 'actionUnavailable');
    expect(lease.holds, 0);
    await pumpEventQueue();
    expect(calls, ['start', 'stop']);
  });
}
