// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: avoid_relative_lib_imports
import 'dart:io';
import '../../../packages/personal_core/lib/src/bridge_capabilities.dart';
import '../../../packages/personal_core/lib/src/contracts.dart';
import '../../../packages/personal_core/lib/src/round_video.dart';

void check(bool value, String description) {
  if (!value) throw StateError(description);
}

void main() {
  final legacyTarget = <String, dynamic>{
    'accountId': 'a',
    'deviceId': 'd',
    'roomId': 'r',
    'network': 'telegram',
  };
  check(
    !RoundSendTarget.fromJson(legacyTarget).silent,
    'Legacy send became silent',
  );
  check(
    RoundSendTarget.fromJson({...legacyTarget, 'silent': true}).silent,
    'Silent bool lost',
  );
  for (final invalid in ['true', 1, null]) {
    try {
      RoundSendTarget.fromJson({...legacyTarget, 'silent': invalid});
      throw StateError('Malformed silent flag accepted');
    } on FormatException {
      /* bool strict */
    }
  }
  const frozenTarget = RoundSendTarget(
    accountId: 'matrix-account',
    deviceId: 'matrix-device',
    roomId: 'room',
    network: 'telegram',
    bridgeAccountId: 'bridge-login',
    bridgeStateKey: '',
    bridgeSenderId: '@bridge:invalid',
    replyEventId: r'$reply',
    threadEventId: r'$thread',
    readUpToEventId: r'$cutoff',
  );
  final restoredTarget = RoundSendTarget.fromJson(frozenTarget.toJson());
  check(
    restoredTarget.bridgeAccountId == 'bridge-login' &&
        restoredTarget.bridgeStateKey == '' &&
        restoredTarget.bridgeSenderId == '@bridge:invalid' &&
        restoredTarget.replyEventId == r'$reply' &&
        restoredTarget.threadEventId == r'$thread',
    'Frozen bridge identity/relations lost on restart',
  );
  Map<String, dynamic> content(Object? marker, {String type = 'm.video'}) => {
    'msgtype': type,
    'info': {roundMessageMarker: marker, 'w': 384, 'h': 384},
  };
  for (final marker in [false, null, 1, 'true', '1']) {
    check(
      RoundVideoDescriptor.fromContent(content(marker)) == null,
      'Non-bool marker inferred round',
    );
  }
  check(
    RoundVideoDescriptor.fromContent(content(true)) != null,
    'Round marker lost',
  );
  check(
    RoundVideoDescriptor.fromContent(content(true), redacted: true) == null,
    'Redaction ignored',
  );
  check(
    RoundVideoDescriptor.fromContent(content(true, type: 'm.audio')) == null,
    'Wrong msgtype inferred round',
  );
  check(
    RoundVideoDescriptor.fromContent({
          'msgtype': 'm.video',
          'info': {roundMessageMarker: true},
        }) !=
        null,
    'Incomplete incoming discarded',
  );
  check(
    RoundVideoDescriptor.fromContent({'msgtype': 'm.video', 'info': []}) ==
        null,
    'Malformed info inferred round',
  );
  const good = RoundVideoDescriptor(
    sizeBytes: 42,
    width: 384,
    height: 384,
    durationMs: 60000,
    videoCodec: 'h264',
    audioCodec: 'aac',
    cornersSanitized: true,
  );
  check(
    good.outgoingError(const RoundEncodingProfile(maxSizeBytes: 42)) == null,
    'Exact duration/size ceiling rejected',
  );
  check(
    good.outgoingError(const RoundEncodingProfile(maxSizeBytes: 41)) != null,
    'Size ceiling ignored',
  );
  const identity = RoundBridgeIdentity(
    accountId: 'fixture-login',
    roomId: '!fixture:invalid',
    stateKey: '',
    senderId: '@bot:invalid',
  );
  final features = <String, dynamic>{
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
  };
  final extension = <String, dynamic>{
    'version': 1,
    'account_id': identity.accountId,
    'room_id': identity.roomId,
    'bridge_state_key': identity.stateKey,
    'round_video': true,
    'round_video_permission': 'allowed',
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
  };
  RoundCapabilityEvent event(Map<String, dynamic> c, {String? sender}) =>
      RoundCapabilityEvent(
        accountId: identity.accountId,
        roomId: identity.roomId,
        stateKey: identity.stateKey,
        senderId: sender ?? identity.senderId,
        content: c,
      );
  RoundBridgeCapabilities parse({
    Map<String, dynamic>? media,
    String? sender,
    int? uploadLimit = 8000000,
  }) => RoundBridgeCapabilities.fromEvents(
    identity: identity,
    featuresEvent: event(features),
    mediaEvent: event(media ?? extension, sender: sender),
    runtimeUploadLimitBytes: uploadLimit,
  );
  check(
    parse().result.allowed && parse().profile!.maxSizeBytes == 8000000,
    'Trusted v1/minimum runtime limit failed',
  );
  check(
    !parse(uploadLimit: null).result.allowed,
    'Unknown runtime upload limit allowed',
  );
  check(
    !parse(sender: '@forged:invalid').result.allowed,
    'Forged sender allowed',
  );
  for (final key in ['account_id', 'room_id', 'bridge_state_key']) {
    check(
      !parse(media: {...extension, key: 'foreign'}).result.allowed,
      'Foreign content identity allowed',
    );
  }
  check(
    !parse(media: {...extension, 'version': 2}).result.allowed,
    'Unknown extension version allowed',
  );
  check(
    !parse(media: {...extension, 'round_video': null}).result.allowed,
    'Unknown round support allowed',
  );
  check(
    parse(
          media: {...extension, 'round_video_permission': 'denied'},
        ).result.status ==
        CapabilityStatus.unavailable,
    'Denied permission lost',
  );
  check(
    !BridgeRoomCapabilities.fromState({
      'file': {
        'm.video': {
          'mime_types': {'video/mp4': 2},
        },
      },
    }).evidence(BridgeFeature.roundVideo).result.allowed,
    'Ordinary m.video inferred round',
  );
  check(
    !BridgeRoomCapabilities.fromState({
      'file': {
        roundVideoCapabilityKey: {
          'mime_types': {'video/mp4': 1},
        },
      },
    }).evidence(BridgeFeature.roundVideo).result.allowed,
    'Partial round support allowed',
  );
  final policy = {
    'version': 1,
    'transfer_allowed': false,
    'ttl_seconds': null,
    'view_once': false,
    'protected_content': null,
    'lazy_supported': false,
  };
  check(
    !RoundMediaPolicy.fromContent({
      'pl.personal.chat.telegram.media_policy': policy,
    }).canPlay,
    'Canonical protected placeholder downloaded',
  );
  for (final v in [true, 9, '60']) {
    final p = RoundMediaPolicy.fromContent({
      'info': {'fi.mau.telegram.ttl_seconds': v},
    });
    check(
      !p.canPlay && !p.canPersist && !p.canTranscribe,
      'TTL/malformed bypass',
    );
  }
  final protected = RoundMediaPolicy.fromContent({
    'info': {'fi.mau.telegram.protected_content': true},
  });
  check(
    protected.canPlay && !protected.canPersist && !protected.canForward,
    'Protected media export/caching bypass',
  );
  stdout.writeln(
    'PASS round strict marker, incoming gaps, profile, trusted identity, '
    'runtime limits, partial/fallback denial and TTL/protected guards',
  );
}
