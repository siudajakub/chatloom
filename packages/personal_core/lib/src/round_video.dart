// SPDX-License-Identifier: AGPL-3.0-or-later
import 'contracts.dart';

const roundMessageMarker = 'fi.mau.telegram.round_message';

/// Network-neutral display marker for a round sent where the network has no
/// native round type (Messenger): an ordinary `m.video` that ChatLoom shows
/// as a round. Bridges ignore unknown `info` keys; Telegram sends never
/// carry it (they keep [roundMessageMarker], understood by the fork).
const roundVideoDisplayMarker = 'pl.personal.chat.round_video';

/// Networks a round can be sent to: `telegram` (native video note through
/// the ChatLoom fork) and `facebook` (Messenger: a square video).
const roundSendNetworks = {'telegram', 'facebook'};
const roundVideoCapabilityKey = 'pl.personal.chat.telegram.round_video';
const telegramMediaCapabilitiesEventType =
    'pl.personal.chat.telegram.media_capabilities';
const telegramMediaPlayedEventType = 'pl.personal.chat.telegram.media_played';
const telegramMediaForwardEventType = 'pl.personal.chat.telegram.media_forward';
const telegramMediaStateEventType = 'pl.personal.chat.telegram.media_state';
const telegramSendOptionsKey = 'pl.personal.chat.telegram.send_options';

/// A capture's destination is fixed before permissions or camera access.
class RoundSendTarget {
  final String accountId, deviceId, roomId, network;
  final String? replyEventId, threadEventId, readUpToEventId;
  final String? bridgeAccountId, bridgeStateKey, bridgeSenderId;
  final bool silent;
  const RoundSendTarget({
    required this.accountId,
    required this.deviceId,
    required this.roomId,
    required this.network,
    this.replyEventId,
    this.threadEventId,
    this.readUpToEventId,
    this.bridgeAccountId,
    this.bridgeStateKey,
    this.bridgeSenderId,
    this.silent = false,
  });
  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'deviceId': deviceId,
    'roomId': roomId,
    'network': network,
    'replyEventId': replyEventId,
    'threadEventId': threadEventId,
    'readUpToEventId': readUpToEventId,
    'bridgeAccountId': bridgeAccountId,
    'bridgeStateKey': bridgeStateKey,
    'bridgeSenderId': bridgeSenderId,
    'silent': silent,
  };
  factory RoundSendTarget.fromJson(Map<String, dynamic> j) => RoundSendTarget(
    accountId: j['accountId'] as String,
    deviceId: j['deviceId'] as String,
    roomId: j['roomId'] as String,
    network: j['network'] as String,
    replyEventId: j['replyEventId'] as String?,
    threadEventId: j['threadEventId'] as String?,
    readUpToEventId: j['readUpToEventId'] as String?,
    bridgeAccountId: j['bridgeAccountId'] as String?,
    bridgeStateKey: j['bridgeStateKey'] as String?,
    bridgeSenderId: j['bridgeSenderId'] as String?,
    silent: _silentFromJson(j),
  );
  static bool _silentFromJson(Map<String, dynamic> json) {
    if (!json.containsKey('silent')) return false;
    final value = json['silent'];
    if (value is! bool)
      throw const FormatException('Invalid round silent option');
    return value;
  }

  bool get valid =>
      accountId.isNotEmpty &&
      deviceId.isNotEmpty &&
      roomId.isNotEmpty &&
      (network == 'telegram' || (network == 'facebook' && !silent));
  @override
  String toString() => 'RoundSendTarget(redacted)';
}

class RoundEncodingProfile {
  final int maxDurationMs, maxSide, maxSizeBytes;
  final int recommendedSide, videoBitrate, audioBitrate;
  const RoundEncodingProfile({
    required this.maxSizeBytes,
    this.maxDurationMs = 60000,
    this.maxSide = 640,
    this.recommendedSide = 384,
    this.videoBitrate = 1000000,
    this.audioBitrate = 64000,
  });
  bool get valid =>
      maxDurationMs > 0 &&
      maxDurationMs <= 60000 &&
      maxSide > 0 &&
      maxSide <= 640 &&
      maxSizeBytes > 0 &&
      recommendedSide > 0 &&
      recommendedSide <= maxSide &&
      videoBitrate > 0 &&
      audioBitrate > 0;
}

/// Incoming metadata may be incomplete. Outgoing metadata must be measured.
class RoundVideoDescriptor {
  final int? sizeBytes, width, height, durationMs;
  final String mimeType;
  final String? videoCodec, audioCodec;
  final bool cornersSanitized;
  const RoundVideoDescriptor({
    this.sizeBytes,
    this.width,
    this.height,
    this.durationMs,
    this.mimeType = 'video/mp4',
    this.videoCodec,
    this.audioCodec,
    this.cornersSanitized = false,
  });
  static RoundVideoDescriptor? fromContent(
    Map<String, dynamic> content, {
    bool redacted = false,
  }) {
    final info = content['info'];
    if (redacted ||
        content['msgtype'] != 'm.video' ||
        info is! Map ||
        (info[roundMessageMarker] != true &&
            info[roundVideoDisplayMarker] != true)) {
      return null;
    }
    int? positive(Object? v) => v is int && v >= 0 ? v : null;
    return RoundVideoDescriptor(
      sizeBytes: positive(info['size']),
      width: positive(info['w']),
      height: positive(info['h']),
      durationMs: positive(info['duration']),
      mimeType: info['mimetype'] is String ? info['mimetype'] as String : '',
    );
  }

  String? outgoingError(RoundEncodingProfile profile) {
    if (!profile.valid) return 'invalidEncodingProfile';
    if (mimeType != 'video/mp4' ||
        videoCodec != 'h264' ||
        audioCodec != 'aac') {
      return 'invalidRoundFormat';
    }
    if (!cornersSanitized) return 'unsanitizedCorners';
    if (width == null ||
        height == null ||
        width! <= 0 ||
        width != height ||
        width! > profile.maxSide)
      return 'invalidRoundDimensions';
    if (durationMs == null ||
        durationMs! <= 0 ||
        durationMs! > profile.maxDurationMs)
      return 'invalidRoundDuration';
    if (sizeBytes == null ||
        sizeBytes! <= 0 ||
        sizeBytes! > profile.maxSizeBytes)
      return 'roundSizeLimit';
    return null;
  }

  Map<String, dynamic> toJson() => {
    'sizeBytes': sizeBytes,
    'width': width,
    'height': height,
    'durationMs': durationMs,
    'mimeType': mimeType,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'cornersSanitized': cornersSanitized,
  };
  factory RoundVideoDescriptor.fromJson(Map<String, dynamic> j) =>
      RoundVideoDescriptor(
        sizeBytes: j['sizeBytes'] as int?,
        width: j['width'] as int?,
        height: j['height'] as int?,
        durationMs: j['durationMs'] as int?,
        mimeType: j['mimeType'] as String,
        videoCodec: j['videoCodec'] as String?,
        audioCodec: j['audioCodec'] as String?,
        cornersSanitized: j['cornersSanitized'] == true,
      );
  Map<String, dynamic> get matrixInfo => {
    'mimetype': mimeType,
    'size': sizeBytes,
    'w': width,
    'h': height,
    'duration': durationMs,
    roundMessageMarker: true,
  };

  /// [matrixInfo] for a send to [network]: Telegram keeps its fork marker
  /// unchanged; every other network gets only [roundVideoDisplayMarker].
  Map<String, dynamic> matrixInfoFor(String network) => network == 'telegram'
      ? matrixInfo
      : {
          'mimetype': mimeType,
          'size': sizeBytes,
          'w': width,
          'h': height,
          'duration': durationMs,
          roundVideoDisplayMarker: true,
        };

  /// Whether [content] is marked as a native Telegram round (the fork's
  /// marker), as opposed to a round shown as one by ChatLoom only.
  static bool isTelegramRound(Map<String, dynamic> content) {
    final info = content['info'];
    return info is Map && info[roundMessageMarker] == true;
  }

  @override
  String toString() => 'RoundVideoDescriptor(redacted)';
}

/// Matrix key used by mautrix bridgev2 for disappearing messages, both in
/// message content (`{type, timer}` per message) and as room state (the
/// chat's current setting). `timer` is in milliseconds.
const beeperDisappearingTimerKey = 'com.beeper.disappearing_timer';

enum DisappearingTimerState { off, active, malformed }

/// Classifies a `com.beeper.disappearing_timer` value. `null` and `{}` (or a
/// type of `''`/`none` without a positive timer) are off; mautrix writes `{}`
/// when the timer is disabled. Any other value is active, and an unexpected
/// shape is malformed, which callers treat as active (fail closed).
DisappearingTimerState disappearingTimerState(Object? value) {
  if (value == null) return DisappearingTimerState.off;
  if (value is! Map) return DisappearingTimerState.malformed;
  final type = value['type'];
  final timer = value['timer'];
  if ((type != null && type is! String) ||
      (timer != null && (timer is! num || timer < 0 || timer.isNaN))) {
    return DisappearingTimerState.malformed;
  }
  final typed = type is String && type.isNotEmpty && type != 'none';
  final timed = timer is num && timer > 0;
  return typed || timed
      ? DisappearingTimerState.active
      : DisappearingTimerState.off;
}

/// True unless [value] (message content entry or room state content) says
/// the disappearing timer is off. Malformed values count as disappearing.
bool disappearingTimerLimits(Object? value) =>
    disappearingTimerState(value) != DisappearingTimerState.off;

/// mautrix bridgev2's view-limited media (`event.BeeperViewLimitedMedia`):
/// `{"type": "...", "count": n, "time": ms}`, every field optional.
const beeperViewLimitedKey = 'com.beeper.view_limited';

/// ChatLoom's Instagram bridge fork marks the view-once ("raven") photos and
/// videos it bridges: `{"version": 1, "view_mode": 0|1}`. The media itself is
/// ordinary `m.image`/`m.video`; nothing is ever reported back to Instagram,
/// so the sender is never told it was opened. Deliberately not
/// [beeperViewLimitedKey], which opts into bridgev2's view-limited flows.
const instagramRavenKey = 'pl.personal.chat.instagram.raven';

/// How an Instagram sender limited a view-once photo or video
/// (`view_mode` 0 and 1; 2, "keep in chat", is never marked).
enum InstagramRavenMode { viewOnce, allowReplay }

/// The [instagramRavenKey] marker of [content]: `present` is false without
/// the key; `mode` is null when the key is there but malformed.
({bool present, InstagramRavenMode? mode}) instagramRavenOf(Map content) {
  if (!content.containsKey(instagramRavenKey)) {
    return (present: false, mode: null);
  }
  final value = content[instagramRavenKey];
  final mode = value is Map && value['version'] == 1
      ? switch (value['view_mode']) {
          0 => InstagramRavenMode.viewOnce,
          1 => InstagramRavenMode.allowReplay,
          _ => null,
        }
      : null;
  return (present: true, mode: mode);
}

/// True when [value] has the shape of bridgev2's `com.beeper.view_limited`
/// object (a string type, non-negative integer count and time).
bool _beeperViewLimitedShape(Object? value) {
  if (value is! Map) return false;
  final type = value['type'], count = value['count'], time = value['time'];
  return (type == null || type is String) &&
      (count == null || (count is int && count >= 0)) &&
      (time == null || (time is int && time >= 0));
}

/// Guard before SDK download/decrypt, preload, thumbnail or cache access.
/// Limited media stays a placeholder until a proven lazy-consumption transport.
class RoundMediaPolicy {
  final bool isTimeLimited, protectedContent, malformed, transferAllowed;

  /// Instagram view-once media (see [instagramRavenKey]): downloaded, cached
  /// and shown like other media, but never saved, shared, forwarded or
  /// transcribed from ChatLoom.
  final InstagramRavenMode? viewOnceMode;
  const RoundMediaPolicy({
    this.isTimeLimited = false,
    this.protectedContent = false,
    this.malformed = false,
    this.transferAllowed = true,
    this.viewOnceMode,
  });
  bool get canPlay => transferAllowed && !isTimeLimited && !malformed;
  bool get canPersist => canPlay && !protectedContent;
  bool get canExport => canPersist && viewOnceMode == null;
  bool get canForward => canExport;
  bool get canTranscribe => canExport;
  String? get placeholderReason => malformed
      ? 'invalidProtectiveMetadata'
      : !transferAllowed || isTimeLimited
      ? 'limitedMediaUnavailable'
      : null;
  static RoundMediaPolicy fromContent(Map<String, dynamic> content) {
    var limited = false, protected = false, malformed = false, allowed = true;
    final raven = instagramRavenOf(content);
    if (raven.present && raven.mode == null) {
      limited = true;
      malformed = true;
    }
    final maps = <Map>[content];
    if (content['info'] is Map) maps.add(content['info'] as Map);
    for (final root in List<Map>.from(maps)) {
      for (final key in [
        'pl.personal.chat.telegram.media_policy',
        'pl.personal.chat.telegram.media',
        'fi.mau.telegram.media',
      ]) {
        if (!root.containsKey(key)) continue;
        final value = root[key];
        if (value is! Map || value['version'] != 1)
          malformed = true;
        else {
          maps.add(value);
          if (key == 'pl.personal.chat.telegram.media_policy') {
            allowed &= value['transfer_allowed'] == true;
            if (value['transfer_allowed'] is! bool) malformed = true;
            if (value['protected_content'] == null) protected = true;
          }
        }
      }
    }
    for (final map in maps) {
      for (final key in [
        'view_once',
        'fi.mau.telegram.view_once',
        'com.beeper.view_once',
        beeperViewLimitedKey,
      ]) {
        if (!map.containsKey(key)) continue;
        if (map[key] is bool) {
          limited |= map[key] == true;
        } else if (key == beeperViewLimitedKey &&
            _beeperViewLimitedShape(map[key])) {
          // bridgev2 sends an object, not a flag: limited, not malformed.
          limited = true;
        } else {
          limited = true;
          malformed = true;
        }
      }
      for (final key in [
        'ttl_seconds',
        'ttl',
        'fi.mau.telegram.ttl',
        'fi.mau.telegram.ttl_seconds',
      ]) {
        if (!map.containsKey(key)) continue;
        final v = map[key];
        if (v == null && key == 'ttl_seconds') continue;
        if (v is int && v >= 0)
          limited |= v > 0;
        else {
          limited = true;
          malformed = true;
        }
      }
      if (map.containsKey('com.beeper.disappearing')) {
        final v = map['com.beeper.disappearing'];
        if (v is! Map || v['timer'] is! int || (v['timer'] as int) < 0) {
          limited = true;
          malformed = true;
        } else {
          limited |= (v['timer'] as int) > 0;
        }
      }
      // mautrix bridgev2 marks each disappearing message in its content.
      if (map.containsKey(beeperDisappearingTimerKey)) {
        switch (disappearingTimerState(map[beeperDisappearingTimerKey])) {
          case DisappearingTimerState.off:
            break;
          case DisappearingTimerState.active:
            limited = true;
          case DisappearingTimerState.malformed:
            limited = true;
            malformed = true;
        }
      }
      for (final key in [
        'protected',
        'protected_content',
        'fi.mau.telegram.protected',
        'fi.mau.telegram.protected_content',
        'fi.mau.telegram.no_forward',
      ]) {
        if (!map.containsKey(key)) continue;
        if (map[key] == null && key == 'protected_content') {
          protected = true;
          continue;
        }
        if (map[key] is bool)
          protected |= map[key] == true;
        else {
          protected = true;
          malformed = true;
        }
      }
    }
    return RoundMediaPolicy(
      isTimeLimited: limited,
      protectedContent: protected,
      malformed: malformed,
      transferAllowed: allowed,
      viewOnceMode: raven.mode,
    );
  }
}

class RoundBridgeIdentity {
  final String accountId, roomId, stateKey, senderId;
  const RoundBridgeIdentity({
    required this.accountId,
    required this.roomId,
    required this.stateKey,
    required this.senderId,
  });
  bool get valid =>
      accountId.isNotEmpty && roomId.isNotEmpty && senderId.isNotEmpty;
  @override
  String toString() => 'RoundBridgeIdentity(redacted)';
}

/// Caller binds these fields to authenticated Matrix state, never content claims.
class RoundCapabilityEvent {
  final String accountId, roomId, stateKey, senderId;
  final Map<String, dynamic> content;
  RoundCapabilityEvent({
    required this.accountId,
    required this.roomId,
    required this.stateKey,
    required this.senderId,
    required Map<String, dynamic> content,
  }) : content = Map.unmodifiable(content);
  bool matches(RoundBridgeIdentity identity) =>
      identity.valid &&
      accountId == identity.accountId &&
      roomId == identity.roomId &&
      stateKey == identity.stateKey &&
      senderId == identity.senderId;
}

/// Extension operations must be positively declared by the same trusted source.
class TelegramMediaCapabilities {
  final Map<String, dynamic>? _content;
  final bool trusted;
  const TelegramMediaCapabilities._(this._content, this.trusted);
  factory TelegramMediaCapabilities.fromEvent({
    required RoundBridgeIdentity identity,
    RoundCapabilityEvent? event,
  }) {
    if (event == null ||
        !event.matches(identity) ||
        event.content['version'] != 1 ||
        event.content['account_id'] != identity.accountId ||
        event.content['room_id'] != identity.roomId ||
        event.content['bridge_state_key'] != identity.stateKey) {
      return const TelegramMediaCapabilities._(null, false);
    }
    return TelegramMediaCapabilities._(event.content, true);
  }
  CapabilityResult operation(String name) {
    final value = _content?[name];
    if (!trusted || value is! bool)
      return const CapabilityResult(
        CapabilityStatus.unverified,
        "The bridge hasn't confirmed this operation.",
      );
    return CapabilityResult(
      value ? CapabilityStatus.available : CapabilityStatus.unavailable,
      value
          ? 'The bridge supports this operation.'
          : "The bridge doesn't support this operation.",
    );
  }

  Map<String, dynamic>? get encodingDeclaration {
    final value = _content?['profile'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
}
