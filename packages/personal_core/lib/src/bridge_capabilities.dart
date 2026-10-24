// SPDX-License-Identifier: AGPL-3.0-or-later
// Schema: https://github.com/mautrix/go/blob/754a8008cb027577ae0b20034878ea836ee9a212/event/capabilities.go
// State keys: same revision bridgev2/portal.go UpdateCapabilities.

import 'contracts.dart';
import 'round_video.dart';

/// Round dispatch requires both same-source states and measured runtime limits.
/// The caller establishes identity against own bridge login + m.bridge first.
class RoundBridgeCapabilities {
  final CapabilityResult result;
  final RoundEncodingProfile? profile;
  final TelegramMediaCapabilities extension;
  const RoundBridgeCapabilities._(this.result, this.profile, this.extension);
  factory RoundBridgeCapabilities.fromEvents({
    required RoundBridgeIdentity identity,
    RoundCapabilityEvent? featuresEvent,
    RoundCapabilityEvent? mediaEvent,
    required int? runtimeUploadLimitBytes,
  }) {
    final extension = TelegramMediaCapabilities.fromEvent(
      identity: identity,
      event: mediaEvent,
    );
    RoundBridgeCapabilities denied(CapabilityStatus status, String reason) =>
        RoundBridgeCapabilities._(
          CapabilityResult(status, reason),
          null,
          extension,
        );
    if (featuresEvent == null ||
        !featuresEvent.matches(identity) ||
        !extension.trusted) {
      return denied(
        CapabilityStatus.unverified,
        'No trusted bridge declaration.',
      );
    }
    final content = mediaEvent!.content;
    if (content['round_video'] == false ||
        content['round_video_permission'] == 'denied') {
      return denied(
        CapabilityStatus.unavailable,
        'The bridge blocks video messages.',
      );
    }
    if (content['round_video'] != true ||
        content['round_video_permission'] != 'allowed' ||
        runtimeUploadLimitBytes == null ||
        runtimeUploadLimitBytes <= 0) {
      return denied(
        CapabilityStatus.unverified,
        'Upload permission or size limit not confirmed.',
      );
    }
    final evidence = BridgeRoomCapabilities.fromState(
      featuresEvent.content,
    ).evidence(BridgeFeature.roundVideo);
    if (!evidence.result.allowed)
      return denied(evidence.result.status, evidence.result.reason);
    final files = featuresEvent.content['file'];
    final file = files is Map ? files[roundVideoCapabilityKey] : null;
    final profile = extension.encodingDeclaration;
    bool positive(Object? value) => value is int && value > 0;
    if (file is! Map ||
        file['mime_types'] is! Map ||
        (file['mime_types'] as Map)['video/mp4'] != 2 ||
        file['caption'] != -2 ||
        ![
          'max_size',
          'max_width',
          'max_height',
          'max_duration',
        ].every((key) => positive(file[key])) ||
        profile == null ||
        profile['id'] != 'pl.personal.chat.telegram.round_video.v1' ||
        profile['container'] != 'mp4' ||
        profile['video_codec'] != 'h264' ||
        profile['audio_codec'] != 'aac' ||
        profile['pixel_format'] != 'yuv420p' ||
        profile['square'] != true ||
        profile['sanitized_corners'] != true ||
        ![
          'max_size_bytes',
          'max_dimension_px',
          'max_duration_ms',
        ].every((key) => positive(profile[key]))) {
      return denied(
        CapabilityStatus.unverified,
        'Full round video profile not confirmed.',
      );
    }
    int minimum(List<int> values) => values.reduce((a, b) => a < b ? a : b);
    final side = minimum([
      640,
      file['max_width'] as int,
      file['max_height'] as int,
      profile['max_dimension_px'] as int,
    ]);
    final encoding = RoundEncodingProfile(
      maxSizeBytes: minimum([
        runtimeUploadLimitBytes,
        file['max_size'] as int,
        profile['max_size_bytes'] as int,
      ]),
      maxSide: side,
      recommendedSide: minimum([384, side]),
      maxDurationMs: minimum([
        60000,
        (file['max_duration'] as int) * 1000,
        profile['max_duration_ms'] as int,
      ]),
    );
    return RoundBridgeCapabilities._(
      const CapabilityResult(
        CapabilityStatus.available,
        'The bridge supports sending round videos.',
      ),
      encoding,
      extension,
    );
  }
}

const bridgeFeaturesEventType = 'com.beeper.room_features';

enum BridgeFeature {
  reply,
  reaction,
  edit,
  delete,
  audio,
  voice,
  upload,
  image,
  video,

  /// `m.video` marked `info["fi.mau.gif"]` (a looping GIF as MP4): bridgev2
  /// classifies it as its own message type and checks `file["fi.mau.gif"]`,
  /// which many networks restrict (Messenger, Instagram and Slack accept only
  /// `image/gif`), never `file["m.video"]`.
  gif,
  roundVideo,
  sticker,
  poll,
  thread,
  disappearing,
  location,
}

class BridgeCapabilityEvidence {
  final CapabilityResult result;
  final int? supportLevel;
  final Map<String, int> limits;
  final String source;
  final String? reasonCode;
  const BridgeCapabilityEvidence(
    this.result, {
    this.supportLevel,
    this.limits = const {},
    this.source = bridgeFeaturesEventType,
    this.reasonCode,
  });
  bool get partial => supportLevel == 1;
  @override
  String toString() => 'BridgeCapabilityEvidence(${result.status.name})';
}

class BridgeMediaRequest {
  final String mimeType;
  final int? sizeBytes;
  final int? width;
  final int? height;
  final double? durationSeconds;
  final String? caption;
  const BridgeMediaRequest({
    required this.mimeType,
    this.sizeBytes,
    this.width,
    this.height,
    this.durationSeconds,
    this.caption,
  });
}

/// Interprets declarations, not proof that a real bridged send succeeded.
/// An absent event is unknown; a valid file map's omitted message type or
/// unmatched MIME is explicitly rejected by the bridgev2 schema.
///
/// A declaration with an `id` is a complete bridgev2 `RoomFeatures` value:
/// every support level is `omitzero` (mautrix-go `event/capabilities.go`), so
/// an omitted level there is the bridge saying 0, "unsupported" (BR-02).
/// Only a state without `id` (absent, redacted, a hand-written fixture)
/// leaves omitted levels unknown.
class BridgeRoomCapabilities {
  final Map<String, Object?>? _state;
  final bool malformed;
  BridgeRoomCapabilities._(this._state, this.malformed);

  /// Whether the state is a complete bridgev2 declaration (has its `id`).
  bool get complete {
    final id = _state?['id'];
    return id is String && id.isNotEmpty;
  }

  /// The longest text message the network takes (`max_text_length`, in
  /// characters as the network counts them), or null when none is declared.
  int? get maxTextLength {
    final value = _state?['max_text_length'];
    return value is int && value > 0 ? value : null;
  }

  /// The declared level at [key] of the room-level features (for example
  /// `poll_hidden_votes`), with the omitted-means-unsupported rule.
  BridgeCapabilityEvidence level(String key) {
    if (_state == null) {
      return _unknown(malformed ? 'malformedState' : 'missingState');
    }
    return _declaredLevel(_state[key]);
  }

  /// Whether the bridge carries a change of the room state [eventType]
  /// (`m.room.name`, `m.room.topic`, `m.room.avatar`) to the network
  /// (`state[eventType].level`).
  BridgeCapabilityEvidence stateEvidence(String eventType) => _entryLevel(
    'state',
    eventType,
    (entry) => entry is Map ? entry['level'] : entry,
  );

  /// Whether the bridge carries the member action [action] (`invite`,
  /// `kick`, `ban`, `leave`, `revoke_invite`) to the network
  /// (`member_actions[action]`).
  BridgeCapabilityEvidence memberActionEvidence(String action) =>
      _entryLevel('member_actions', action, (entry) => entry);

  BridgeCapabilityEvidence _entryLevel(
    String mapKey,
    String key,
    Object? Function(Object? entry) levelOf,
  ) {
    if (_state == null) {
      return _unknown(malformed ? 'malformedState' : 'missingState');
    }
    final map = _state[mapKey];
    if (map == null) {
      return complete
          ? _blocked('unsupportedFallback', level: 0)
          : _unknown('missingOrMalformedLevel');
    }
    if (map is! Map) return _unknown('missingOrMalformedLevel');
    final entry = map[key];
    if (entry == null) {
      return complete
          ? _blocked('unsupportedFallback', level: 0)
          : _unknown('missingOrMalformedLevel');
    }
    if (entry is Map && !entry.containsKey('level')) {
      // `StateFeatures.level` has no omitzero: a level-less entry is malformed.
      return _unknown('missingOrMalformedLevel');
    }
    return _level(levelOf(entry));
  }

  /// [_level], reading an omitted level of a complete declaration as 0.
  BridgeCapabilityEvidence _declaredLevel(Object? level) =>
      level == null && complete ? _level(0) : _level(level);

  factory BridgeRoomCapabilities.fromState(Object? content) {
    if (content == null) return BridgeRoomCapabilities._(null, false);
    try {
      if (content is! Map || content.keys.any((key) => key is! String)) {
        return BridgeRoomCapabilities._(null, true);
      }
      return BridgeRoomCapabilities._(_snapshot(content), false);
    } catch (_) {
      return BridgeRoomCapabilities._(null, true);
    }
  }

  factory BridgeRoomCapabilities.fromStateEvents(
    Map<String, Object?> featuresByKey, {
    Iterable<String> bridgeStateKeys = const [],
    String? stateKey,
  }) {
    if (stateKey != null) {
      return BridgeRoomCapabilities.fromState(featuresByKey[stateKey]);
    }
    final matches = featuresByKey.keys.where(bridgeStateKeys.contains).toList();
    if (matches.length == 1) {
      return BridgeRoomCapabilities.fromState(featuresByKey[matches.single]);
    }
    if (matches.isEmpty && featuresByKey.length == 1) {
      return BridgeRoomCapabilities.fromState(featuresByKey.values.single);
    }
    return BridgeRoomCapabilities.fromState(null);
  }

  BridgeCapabilityEvidence evidence(
    BridgeFeature feature, {
    BridgeMediaRequest? media,
    Duration? messageAge,
    int? editCount,
    String? reaction,
    String? disappearingType,
    int? disappearingTimerMs,
    int? pollOptions,
    int? longestPollOption,
  }) {
    if (_state == null) {
      return _unknown(malformed ? 'malformedState' : 'missingState');
    }
    final mediaType = switch (feature) {
      BridgeFeature.audio => 'm.audio',
      BridgeFeature.voice => 'org.matrix.msc3245.voice',
      BridgeFeature.upload => 'm.file',
      BridgeFeature.image => 'm.image',
      BridgeFeature.video => 'm.video',
      BridgeFeature.gif => 'fi.mau.gif',
      BridgeFeature.roundVideo => roundVideoCapabilityKey,
      BridgeFeature.sticker => 'm.sticker',
      _ => null,
    };
    if (mediaType != null) {
      final result = _media(mediaType, media);
      // Partial/conversion support cannot preserve Telegram video-note semantics.
      if (feature == BridgeFeature.roundVideo && result.partial) {
        return _unknown('roundRequiresFullSupport');
      }
      return result;
    }
    if (feature == BridgeFeature.disappearing) {
      return _disappearing(disappearingType, disappearingTimerMs);
    }
    final key = feature == BridgeFeature.location
        ? 'location_message'
        : feature.name;
    var result = _declaredLevel(_state[key]);
    if (!result.result.allowed) {
      final reason = _featureUnsupported(feature);
      if (result.result.status != CapabilityStatus.unavailable ||
          reason == null) {
        return result;
      }
      return BridgeCapabilityEvidence(
        CapabilityResult(CapabilityStatus.unavailable, reason),
        supportLevel: result.supportLevel,
        reasonCode: result.reasonCode,
      );
    }
    final limits = <String, int>{};
    final keys = switch (feature) {
      BridgeFeature.edit => ['edit_max_age', 'edit_max_count'],
      BridgeFeature.delete => ['delete_max_age'],
      BridgeFeature.reaction => ['reaction_count'],
      BridgeFeature.poll => ['poll_max_options', 'poll_option_max_length'],
      _ => <String>[],
    };
    for (final name in keys) {
      if (!_state.containsKey(name)) continue;
      final value = _state[name];
      if (value is! int || value < 0) return _unknown('malformedLimit');
      if (value > 0) limits[name] = value;
    }
    final ageLimit =
        limits[feature == BridgeFeature.edit
            ? 'edit_max_age'
            : 'delete_max_age'];
    if (ageLimit != null &&
        messageAge != null &&
        messageAge.inMilliseconds > ageLimit * 1000) {
      return _blocked('messageTooOld', limits: limits);
    }
    if (feature == BridgeFeature.edit &&
        editCount != null &&
        (editCount < 0 ||
            (limits['edit_max_count'] != null &&
                editCount >= limits['edit_max_count']!))) {
      return _blocked('editLimit', limits: limits);
    }
    if (feature == BridgeFeature.reaction) {
      final allowed = _state['allowed_reactions'];
      if (allowed != null &&
          (allowed is! List || allowed.any((e) => e is! String))) {
        return _unknown('malformedReactions');
      }
      if (reaction != null && allowed is List && !allowed.contains(reaction)) {
        return _blocked('reactionNotAllowed', limits: limits);
      }
      // `reaction_count` is not a refusal: bridgev2 keeps the newest
      // `reaction_count - 1` earlier reactions of the sender and removes the
      // rest itself (`portal.go` `handleMatrixReaction`), the way WhatsApp,
      // Messenger and Telegram replace a reaction. The limit is exposed in
      // [BridgeCapabilityEvidence.limits] for the client to mirror (BR-01).
    }
    if (feature == BridgeFeature.poll &&
        ((pollOptions != null &&
                limits['poll_max_options'] != null &&
                pollOptions > limits['poll_max_options']!) ||
            (longestPollOption != null &&
                limits['poll_option_max_length'] != null &&
                longestPollOption > limits['poll_option_max_length']!))) {
      return _blocked('pollLimit', limits: limits);
    }
    result = BridgeCapabilityEvidence(
      result.result,
      supportLevel: result.supportLevel,
      limits: Map.unmodifiable(limits),
    );
    return result;
  }

  BridgeCapabilityEvidence _media(String type, BridgeMediaRequest? request) {
    final files = _state!['file'];
    if (files == null && complete) return _blocked('mediaTypeRejected');
    if (files is! Map) return _unknown('missingMediaDeclaration');
    if (!files.containsKey(type)) return _blocked('mediaTypeRejected');
    final config = files[type];
    if (config is! Map) return _unknown('malformedMediaDeclaration');
    final mimes = config['mime_types'];
    if (mimes is! Map || mimes.keys.any((k) => k is! String)) {
      return _unknown('malformedMimeDeclaration');
    }
    if (mimes.keys.any((key) => !_validMimePattern(key as String))) {
      return _unknown('malformedMimeDeclaration');
    }
    final limits = <String, int>{};
    for (final key in [
      'max_size',
      'max_width',
      'max_height',
      'max_duration',
      'max_caption_length',
    ]) {
      if (!config.containsKey(key)) continue;
      final value = config[key];
      if (value is! int || value < 0) return _unknown('malformedLimit');
      if (value > 0 || key == 'max_duration') limits[key] = value;
    }
    BridgeCapabilityEvidence result;
    if (request == null) {
      final levels = mimes.values.map(_level).toList();
      final supported = levels.where((l) => l.result.allowed).toList();
      if (supported.isEmpty) {
        return levels.any((l) => l.result.status == CapabilityStatus.unverified)
            ? _unknown('malformedMimeDeclaration')
            : _blocked('noSupportedMime');
      }
      final partialOnly = supported.every((l) => l.partial);
      result = _level(partialOnly ? 1 : 2);
    } else {
      final original = request.mimeType.trim();
      final base = original.split(';').first.trim();
      if (!RegExp(
        r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$',
      ).hasMatch(base)) {
        return _unknown('invalidMime');
      }
      // Matches bridgev2's precedence, including exact parameter-qualified MIME.
      Object? level;
      var found = false;
      for (final key in [original, base, '${base.split('/').first}/*', '*/*']) {
        if (mimes.containsKey(key)) {
          level = mimes[key];
          found = true;
          break;
        }
      }
      if (!found) return _blocked('mimeRejected');
      result = _level(level);
      if (!result.result.allowed) return result;
      final measurements = {
        'max_size': request.sizeBytes,
        'max_width': request.width,
        'max_height': request.height,
        'max_duration': request.durationSeconds,
      };
      for (final entry in measurements.entries) {
        if (entry.value != null &&
            (entry.value! < 0 || !entry.value!.isFinite)) {
          return _unknown('invalidMediaMeasurement');
        }
        final limit = limits[entry.key];
        if (limit != null && entry.value == null) {
          return _unknown('missingMediaMeasurement');
        }
        if (limit != null && entry.value != null && entry.value! > limit) {
          return _blocked('mediaLimit', limits: limits);
        }
      }
      if (request.caption != null && request.caption!.isNotEmpty) {
        final caption = _level(config['caption']);
        if (!caption.result.allowed) return caption;
        if (limits['max_caption_length'] != null &&
            request.caption!.runes.length > limits['max_caption_length']!) {
          return _blocked('captionLimit', limits: limits);
        }
        if (caption.partial) result = _level(1);
      }
    }
    return BridgeCapabilityEvidence(
      result.result,
      supportLevel: result.supportLevel,
      limits: Map.unmodifiable(limits),
    );
  }

  BridgeCapabilityEvidence _disappearing(String? type, int? timer) {
    final state = _state!['state'];
    final entry = state is Map ? state['com.beeper.disappearing_timer'] : null;
    if (entry == null && complete && (state == null || state is Map)) {
      return _blocked('timerUnsupported');
    }
    if (entry is! Map) return _unknown('missingTimerStatePermission');
    final level = _level(entry['level']);
    if (!level.result.allowed) return level;
    final config = _state['disappearing_timer'];
    if (config == null && complete) return _blocked('timerUnsupported');
    if (config is! Map) return _unknown('missingTimerDeclaration');
    final types = config['types'];
    if (types is! List ||
        types.any(
          (t) => t is! String || !{'', 'after_read', 'after_send'}.contains(t),
        )) {
      return _unknown('malformedTimerTypes');
    }
    if (!types.any((t) => t == 'after_read' || t == 'after_send')) {
      return _blocked('timerUnsupported');
    }
    if (type != null && !types.contains(type)) {
      return _blocked('timerTypeUnsupported');
    }
    final timers = config['timers'];
    if (timers != null &&
        (timers is! List || timers.any((t) => t is! int || t < 0))) {
      return _unknown('malformedTimers');
    }
    if (timers is List && timers.isEmpty) return _blocked('noAllowedTimers');
    if (timer != null &&
        (timer < 0 || (timers is List && !timers.contains(timer)))) {
      return _blocked('timerValueUnsupported');
    }
    return level;
  }

  static bool _validMimePattern(String value) {
    if (value == '*/*') return true;
    final base = value.split(';').first.trim();
    return RegExp(
      r'^[a-z0-9!#$&^_.+-]+/(?:\*|[a-z0-9!#$&^_.+-]+)$',
    ).hasMatch(base);
  }

  /// What the person reads when the network does not support [feature].
  static String? _featureUnsupported(BridgeFeature feature) =>
      switch (feature) {
        BridgeFeature.reply => "Replies aren't supported on this network.",
        BridgeFeature.reaction => "Reactions aren't supported on this network.",
        BridgeFeature.edit => "Editing isn't supported on this network.",
        BridgeFeature.delete => "Deleting isn't supported on this network.",
        BridgeFeature.poll => "Polls aren't supported on this network.",
        BridgeFeature.thread => "Threads aren't supported on this network.",
        BridgeFeature.location =>
          "Sharing a location isn't supported on this network.",
        _ => null,
      };

  static BridgeCapabilityEvidence _level(Object? level) {
    if (level is! int || level < -2 || level > 2) {
      return _unknown('missingOrMalformedLevel');
    }
    if (level <= 0) {
      return _blocked(switch (level) {
        -2 => 'rejected',
        -1 => 'dropped',
        _ => 'unsupportedFallback',
      }, level: level);
    }
    return BridgeCapabilityEvidence(
      CapabilityResult(
        CapabilityStatus.available,
        level == 1
            ? 'Partially supported by the bridge; may be converted.'
            : 'Supported by the bridge.',
      ),
      supportLevel: level,
    );
  }

  static BridgeCapabilityEvidence _unknown(String reason) =>
      BridgeCapabilityEvidence(
        CapabilityResult(CapabilityStatus.unverified, _reason(reason)),
        reasonCode: reason,
      );
  static BridgeCapabilityEvidence _blocked(
    String reason, {
    int? level,
    Map<String, int> limits = const {},
  }) => BridgeCapabilityEvidence(
    CapabilityResult(CapabilityStatus.unavailable, _reason(reason)),
    supportLevel: level,
    limits: Map.unmodifiable(limits),
    reasonCode: reason,
  );

  static String _reason(String code) => switch (code) {
    'missingState' => 'The bridge has not confirmed support for this feature.',
    'rejected' => 'The bridge rejects this feature.',
    'dropped' => 'The bridge drops this feature.',
    'unsupportedFallback' => "This isn't supported on this network.",
    'mediaTypeRejected' => "The bridge doesn't support this attachment type.",
    'mimeRejected' ||
    'noSupportedMime' => "The bridge doesn't support this file format.",
    'missingMediaDeclaration' =>
      "The bridge hasn't declared supported formats.",
    'missingMediaMeasurement' => "The selected file hasn't been checked yet.",
    'mediaLimit' => 'The file exceeds the size, dimension or duration limit.',
    'captionLimit' => 'The caption is too long.',
    'messageTooOld' => "It's too late to change this message.",
    'editLimit' => 'No more edits are allowed for this message.',
    'reactionNotAllowed' => "This reaction isn't supported in this chat.",
    'pollLimit' => 'The poll exceeds the option count or length limit.',
    'timerUnsupported' ||
    'noAllowedTimers' => "The bridge doesn't support disappearing messages.",
    'timerTypeUnsupported' => "This disappearing-message mode isn't supported.",
    'timerValueUnsupported' =>
      "This disappearing-message duration isn't supported.",
    'missingTimerStatePermission' ||
    'missingTimerDeclaration' => 'Disappearing-message support not confirmed.',
    _ => 'Could not confirm support for this feature.',
  };
  static Map<String, Object?> _snapshot(Map input) => Map.unmodifiable(
    input.map(
      (key, value) => MapEntry(
        key as String,
        value is Map
            ? _snapshot(value)
            : value is List
            ? List<Object?>.unmodifiable(
                value.map((v) => v is Map ? _snapshot(v) : v),
              )
            : value,
      ),
    ),
  );
}
