// SPDX-License-Identifier: AGPL-3.0-or-later

/// Transcription languages and the synced automatic-transcription policy,
/// shared by the app and the worker. Pure Dart: no Flutter, Matrix or crypto
/// package, so the worker and the app evaluate exactly the same rules.
library;

import 'dart:convert';

import 'contracts.dart';
import 'round_video.dart';

/// ISO-639-1 codes offered for transcription; null means automatic detection.
/// The worker rejects every other value with `invalid_language`.
const transcriptionLanguages = <String, String>{
  'pl': 'Polish',
  'en': 'English',
  'hy': 'Armenian',
};

bool validTranscriptionLanguage(Object? code) =>
    code == null ||
    (code is String && transcriptionLanguages.containsKey(code));

/// Private journal metadata entity holding [TranscriptionPolicy] JSON.
const transcriptionPolicyEntity = 'transcription-policy';
const transcriptionPolicyVersion = 1;

/// Automatic work never reaches further back than this, whatever the policy
/// says: no history sweep after a long worker outage or a fresh install.
const autoTranscriptionMaxAge = Duration(hours: 24);

/// Choices offered by Settings; the policy accepts any value in its bounds.
const transcriptionMaxSecondsChoices = <int>[60, 180, 300, 600];
const transcriptionDailyBudgetChoices = <double>[0.25, 0.5, 1.0, 2.0, 5.0];

/// Deterministic journal entity of a source message's transcript. The app and
/// the worker must derive the same id, so a worker-created automatic job and a
/// later request from any device address one entity.
String transcriptEntityId(SourceEventRef source) =>
    'transcript:${sha256Hex(utf8.encode(source.key))}';

/// Synced, account-wide automatic transcription rules (journal metadata).
///
/// Absent policy = [TranscriptionPolicy.defaults]: J asked for automatic
/// transcription of incoming voice and round messages in every network.
/// The worker additionally requires its private `autoTranscription` operator
/// switch before it scans local sources (double opt-in).
class TranscriptionPolicy {
  static const defaultMaxSeconds = 300;
  static const defaultDailyBudgetUsd = 1.0;
  static const minMaxSeconds = 10;
  static const maxMaxSeconds = 3600;
  static const maxDailyBudgetUsd = 100.0;

  final bool auto;

  /// Automatic work only considers messages sent at or after this moment.
  final DateTime? enabledAt;

  /// ISO-639-1 code from [transcriptionLanguages]; null = automatic.
  final String? defaultLanguage;

  /// Explicit per-network switches; absent networks follow [auto].
  final Map<String, bool> networks;

  /// Per-room overrides: true = always, false = never.
  final Map<String, bool> chatOverrides;

  /// Explicit per-kind switches (`voice`, `round`, `video`, `audio`,
  /// `reel`); an absent kind takes its default ([kindEnabled]): on, except
  /// Instagram reels, which are transcribed only on demand. Older apps drop
  /// this field (or the `reel` key) when they save the policy, which returns
  /// every kind to that default, never to automatic reels.
  final Map<String, bool> kinds;
  final int maxSeconds;
  final double dailyBudgetUsd;

  const TranscriptionPolicy({
    this.auto = true,
    this.enabledAt,
    this.defaultLanguage,
    this.networks = const {},
    this.chatOverrides = const {},
    this.kinds = const {},
    this.maxSeconds = defaultMaxSeconds,
    this.dailyBudgetUsd = defaultDailyBudgetUsd,
  });

  static const defaults = TranscriptionPolicy();

  /// Unreadable or newer-version policies fail closed: nothing automatic.
  static const disabled = TranscriptionPolicy(auto: false);

  /// Reads a metadata value; null (never saved or deleted) yields [defaults].
  factory TranscriptionPolicy.fromValue(Object? value) {
    if (value == null) return defaults;
    if (value is! Map) return disabled;
    try {
      return TranscriptionPolicy.fromJson(Map<String, dynamic>.from(value));
    } catch (_) {
      return disabled;
    }
  }

  factory TranscriptionPolicy.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != null && version != transcriptionPolicyVersion) {
      return disabled;
    }
    Map<String, bool> switches(Object? value) => value is Map
        ? {
            for (final entry in value.entries)
              if (entry.key is String &&
                  (entry.key as String).isNotEmpty &&
                  entry.value is bool)
                entry.key as String: entry.value as bool,
          }
        : const {};
    final enabled = json['enabledAt'];
    final language = json['defaultLanguage'];
    final seconds = json['maxSeconds'];
    final budget = json['dailyBudgetUsd'];
    return TranscriptionPolicy(
      // A malformed switch never turns paid background work on.
      auto: !json.containsKey('auto') || json['auto'] == true,
      enabledAt: enabled is String ? DateTime.tryParse(enabled)?.toUtc() : null,
      defaultLanguage:
          language is String && transcriptionLanguages.containsKey(language)
          ? language
          : null,
      networks: Map.unmodifiable(switches(json['networks'])),
      chatOverrides: Map.unmodifiable(switches(json['chatOverrides'])),
      kinds: Map.unmodifiable({
        for (final entry in switches(json['kinds']).entries)
          if (_kindNames.contains(entry.key)) entry.key: entry.value,
      }),
      maxSeconds: seconds is int
          ? seconds.clamp(minMaxSeconds, maxMaxSeconds)
          : defaultMaxSeconds,
      dailyBudgetUsd: budget is num && budget.isFinite
          ? budget.toDouble().clamp(0.0, maxDailyBudgetUsd)
          : defaultDailyBudgetUsd,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': transcriptionPolicyVersion,
    'auto': auto,
    'enabledAt': enabledAt?.toUtc().toIso8601String(),
    'defaultLanguage': defaultLanguage,
    'networks': {
      for (final key in networks.keys.toList()..sort()) key: networks[key],
    },
    'chatOverrides': {
      for (final key in chatOverrides.keys.toList()..sort())
        key: chatOverrides[key],
    },
    'kinds': {for (final key in kinds.keys.toList()..sort()) key: kinds[key]},
    'maxSeconds': maxSeconds,
    'dailyBudgetUsd': dailyBudgetUsd,
  };

  TranscriptionPolicy copyWith({
    bool? auto,
    DateTime? Function()? enabledAt,
    String? Function()? defaultLanguage,
    Map<String, bool>? networks,
    Map<String, bool>? chatOverrides,
    Map<String, bool>? kinds,
    int? maxSeconds,
    double? dailyBudgetUsd,
  }) => TranscriptionPolicy(
    auto: auto ?? this.auto,
    enabledAt: enabledAt == null ? this.enabledAt : enabledAt(),
    defaultLanguage: defaultLanguage == null
        ? this.defaultLanguage
        : defaultLanguage(),
    networks: Map.unmodifiable(networks ?? this.networks),
    chatOverrides: Map.unmodifiable(chatOverrides ?? this.chatOverrides),
    kinds: Map.unmodifiable(kinds ?? this.kinds),
    maxSeconds: (maxSeconds ?? this.maxSeconds).clamp(
      minMaxSeconds,
      maxMaxSeconds,
    ),
    dailyBudgetUsd: (dailyBudgetUsd ?? this.dailyBudgetUsd).clamp(
      0.0,
      maxDailyBudgetUsd,
    ),
  );

  /// Turning automatic work on restarts its time window, so messages received
  /// while it was off are never swept up later.
  TranscriptionPolicy withAuto(bool enabled, DateTime now) => copyWith(
    auto: enabled,
    enabledAt: enabled && !auto ? () => now.toUtc() : null,
  );

  TranscriptionPolicy withNetwork(String network, bool enabled) =>
      copyWith(networks: {...networks, network: enabled});

  TranscriptionPolicy withKind(AutoTranscriptionKind kind, bool enabled) =>
      copyWith(kinds: {...kinds, kind.name: enabled});

  /// Kinds without an explicit switch follow their default
  /// ([AutoTranscriptionKind.automaticByDefault]): J asked (2026-10-19) for
  /// voice, rounds and videos alike, and (2026-10-20) for Instagram reels
  /// only on demand. An absent `kinds` field (never saved, or saved by an
  /// older app) therefore means every kind except reels.
  /// The worker re-checks this at job start and again before upload.
  bool kindEnabled(AutoTranscriptionKind kind) =>
      kinds[kind.name] ?? kind.automaticByDefault;

  /// null removes the override (Default).
  TranscriptionPolicy withChatOverride(String roomId, bool? value) {
    final updated = Map<String, bool>.from(chatOverrides);
    if (value == null) {
      updated.remove(roomId);
    } else {
      updated[roomId] = value;
    }
    return copyWith(chatOverrides: updated);
  }

  /// Networks without an explicit switch follow [auto]. If any network was
  /// switched off, a message whose network cannot be determined is skipped.
  bool networkEnabled(String network) {
    final explicit = networks[network];
    if (explicit != null) return explicit;
    if (network == 'unknown' || network.isEmpty) {
      return !networks.values.contains(false);
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is TranscriptionPolicy &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'TranscriptionPolicy(auto: $auto, redacted)';
}

/// Media that carries speech and can be transcribed.
///
/// * `voice`: an `m.audio` voice note (MSC3245).
/// * `round`: a Telegram round video (`fi.mau.telegram.round_message`).
/// * `video`: any other video, also an `m.file` with a `video/*` type.
/// * `audio`: any other audio, also an `m.file` with an `audio/*` type.
/// * `reel`: a video shared from Instagram (a reel, post or story share, see
///   [isInstagramShare]); transcribed only on demand unless switched on.
///
/// Workers and apps that predate a kind ignore its switch and classify such
/// media by the older rules (a reel is then an ordinary `video`).
enum AutoTranscriptionKind {
  voice,
  round,
  video,
  audio,
  reel;

  /// Whether a policy without an explicit switch transcribes this kind
  /// automatically. J (2026-10-20): Instagram reels only when asked.
  bool get automaticByDefault => this != AutoTranscriptionKind.reel;
}

final _kindNames = {for (final kind in AutoTranscriptionKind.values) kind.name};

/// Hosts of shared Instagram posts, reels and stories.
bool _instagramHost(String host) {
  final value = host.toLowerCase();
  return value == 'instagram.com' ||
      value.endsWith('.instagram.com') ||
      value == 'instagr.am' ||
      value.endsWith('.instagr.am');
}

/// True for media the Instagram bridge delivered as a share of someone's
/// post, reel or story rather than as a recording sent by the sender.
///
/// mautrix-meta converts a shared post (an XMA attachment) into the post's
/// own media and always adds the post's link as the top-level `external_url`
/// (`igconv/xma.go` `fetchXMA`/`wrapXMAItem`; the older Messenger path in
/// `msgconv/from-meta.go` does the same from the share's action URL). A video
/// recorded and sent directly in the chat has no `external_url`.
bool isInstagramShare(Map<String, dynamic> content) {
  final url = content['external_url'];
  if (url is! String || url.length > 2048) return false;
  final parsed = Uri.tryParse(url.trim());
  return parsed != null &&
      (parsed.scheme == 'https' || parsed.scheme == 'http') &&
      _instagramHost(parsed.host);
}

/// Containers and audio formats the worker's FFmpeg input whitelist reads.
/// Used only where a file has no usable MIME type.
const _videoExtensions = {
  'mp4', 'm4v', 'mov', 'webm', 'mkv', '3gp', '3g2', 'avi', //
};
const _audioExtensions = {
  'ogg', 'oga', 'opus', 'mp3', 'm4a', 'aac', 'wav', 'flac', 'amr', 'weba', //
};

/// The transcribable kind of a decrypted `m.room.message` [content], or null
/// for text, images, stickers, GIF-style silent loops, playlists and media
/// whose protective metadata forbids transcription (view-once, protected,
/// disappearing). Shared by the app and the worker so both classify alike.
/// Room-level disappearing settings are checked separately by the callers.
/// A video shared from Instagram is a `reel`, not a `video`.
AutoTranscriptionKind? transcribableMediaKind(Map<String, dynamic> content) {
  final msgtype = content['msgtype'];
  if (msgtype is! String) return null;
  if (!const {'m.audio', 'm.video', 'm.file'}.contains(msgtype)) return null;
  if (!RoundMediaPolicy.fromContent(content).canTranscribe) return null;
  final info = content['info'] is Map ? content['info'] as Map : const {};
  if (RoundVideoDescriptor.fromContent(content) != null) {
    return AutoTranscriptionKind.round;
  }
  if (msgtype == 'm.audio') {
    return content.containsKey('org.matrix.msc3245.voice')
        ? AutoTranscriptionKind.voice
        : AutoTranscriptionKind.audio;
  }
  // mautrix marks GIF-style clips (Telegram animations, WhatsApp GIFs):
  // silent loops never carry speech, so nothing is downloaded for them.
  if (info['fi.mau.gif'] == true ||
      info['fi.mau.no_audio'] == true ||
      (info['fi.mau.loop'] == true && info['fi.mau.autoplay'] == true)) {
    return null;
  }
  final rawMime = info['mimetype'];
  var mime = rawMime is String ? rawMime.toLowerCase().trim() : '';
  if (mime.contains('mpegurl') || mime.contains('scpls')) return null;
  if (mime.isEmpty || mime == 'application/octet-stream') {
    final name = content['filename'] is String
        ? content['filename'] as String
        : content['body'] is String
        ? content['body'] as String
        : '';
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    mime = _videoExtensions.contains(extension)
        ? 'video/$extension'
        : _audioExtensions.contains(extension)
        ? 'audio/$extension'
        : msgtype == 'm.video'
        ? 'video/unknown'
        : '';
  }
  if (msgtype == 'm.video') {
    if (mime.startsWith('image/')) return null;
    return isInstagramShare(content)
        ? AutoTranscriptionKind.reel
        : AutoTranscriptionKind.video;
  }
  if (mime.startsWith('video/')) {
    return isInstagramShare(content)
        ? AutoTranscriptionKind.reel
        : AutoTranscriptionKind.video;
  }
  if (mime.startsWith('audio/')) return AutoTranscriptionKind.audio;
  return null;
}

/// Everything needed to decide automatic eligibility, without content.
class AutoTranscriptionCandidate {
  /// null = no transcribable speech media (see [transcribableMediaKind]).
  final AutoTranscriptionKind? kind;
  final String network;
  final String roomId;
  final bool outgoing;

  /// null when the source cannot tell; such a candidate is `too_old` (an
  /// unknown age never starts paid background work).
  final DateTime? timestamp;
  final int? durationMs;

  /// `org:<roomId>`, `org:person:<groupId>` and `network-policy:<network>`.
  final Map<String, dynamic>? chatMetadata;
  final Map<String, dynamic>? personMetadata;
  final Map<String, dynamic>? networkMetadata;

  const AutoTranscriptionCandidate({
    required this.kind,
    required this.network,
    required this.roomId,
    required this.outgoing,
    this.timestamp,
    this.durationMs,
    this.chatMetadata,
    this.personMetadata,
    this.networkMetadata,
  });

  @override
  String toString() => 'AutoTranscriptionCandidate(redacted)';
}

/// Why a message is not transcribed automatically; null = eligible.
///
/// Codes: disabled, unsupported, kind_disabled, outgoing, before_enabled,
/// too_old, chat_disabled, network_disabled, ignored, muted, duration_limit,
/// budget. A per-kind switch applies in every chat, also with "Always".
/// `duration_limit` and `budget` mean "eligible, but over a limit": the worker
/// records them as `auto_skipped_duration` / `auto_skipped_budget` so the
/// client can explain why no transcript appeared.
String? autoTranscriptionBlock(
  TranscriptionPolicy policy,
  AutoTranscriptionCandidate candidate, {
  required DateTime now,
}) {
  if (!policy.auto) return 'disabled';
  final kind = candidate.kind;
  if (kind == null) return 'unsupported';
  if (!policy.kindEnabled(kind)) return 'kind_disabled';
  if (candidate.outgoing) return 'outgoing';
  final timestamp = candidate.timestamp;
  if (timestamp == null) return 'too_old';
  final enabledAt = policy.enabledAt;
  if (enabledAt != null && timestamp.isBefore(enabledAt)) {
    return 'before_enabled';
  }
  if (now.difference(timestamp) > autoTranscriptionMaxAge) return 'too_old';
  final override = policy.chatOverrides[candidate.roomId];
  if (override == false) return 'chat_disabled';
  // "Always" is an explicit per-chat choice; it outranks network, mute and
  // ignore rules, but never own messages, time windows or cost limits.
  if (override != true) {
    if (!policy.networkEnabled(candidate.network)) return 'network_disabled';
    if (_ignored(candidate.chatMetadata) ||
        _ignored(candidate.personMetadata)) {
      return 'ignored';
    }
    if (_muted(
      candidate.chatMetadata,
      candidate.personMetadata,
      candidate.networkMetadata,
    )) {
      return 'muted';
    }
  }
  final duration = candidate.durationMs;
  if (duration != null && duration > policy.maxSeconds * 1000) {
    return 'duration_limit';
  }
  if (policy.dailyBudgetUsd <= 0) return 'budget';
  return null;
}

bool autoEligible(
  TranscriptionPolicy policy,
  AutoTranscriptionCandidate candidate, {
  required DateTime now,
}) => autoTranscriptionBlock(policy, candidate, now: now) == null;

bool _ignored(Map<String, dynamic>? metadata) =>
    metadata != null &&
    (metadata['ignored'] == true || metadata['placement'] == 'ignored');

/// Mirrors ConversationMetadata.shouldNotify precedence: an explicit chat
/// notification mode wins, then chat/person mute, then the network default.
bool _muted(
  Map<String, dynamic>? chat,
  Map<String, dynamic>? person,
  Map<String, dynamic>? network,
) {
  const modes = {'all', 'mentionsOnly', 'muted'};
  final chatMode = chat?['notificationMode'];
  if (modes.contains(chatMode)) return chatMode == 'muted';
  if (chat?['muted'] == true || person?['muted'] == true) return true;
  if (person?['notificationMode'] == 'muted') return true;
  return network?['notifications'] == 'muted';
}

/// FIPS 180-4 SHA-256 as lowercase hex. personal_core has no runtime
/// dependencies; tests pin it against the NIST vectors and package:crypto.
/// Every intermediate value stays within 32 bits, also on the web.
String sha256Hex(List<int> data) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & mask;
  final message = <int>[for (final byte in data) byte & 0xff, 0x80];
  while (message.length % 64 != 56) {
    message.add(0);
  }
  // Bit length as two 32-bit words without 64-bit shifts.
  final high = data.length ~/ 0x20000000;
  final low = (data.length % 0x20000000) * 8;
  for (final word in [high, low]) {
    message.addAll([
      (word >> 24) & 0xff,
      (word >> 16) & 0xff,
      (word >> 8) & 0xff,
      word & 0xff,
    ]);
  }
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < message.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] =
          ((message[j] << 24) |
              (message[j + 1] << 16) |
              (message[j + 2] << 8) |
              message[j + 3]) &
          mask;
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final choice = (e & f) ^ ((~e & mask) & g);
      final t1 = (hh + s1 + choice + k[i] + w[i]) & mask;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + majority) & mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & mask;
    }
    h[0] = (h[0] + a) & mask;
    h[1] = (h[1] + b) & mask;
    h[2] = (h[2] + c) & mask;
    h[3] = (h[3] + d) & mask;
    h[4] = (h[4] + e) & mask;
    h[5] = (h[5] + f) & mask;
    h[6] = (h[6] + g) & mask;
    h[7] = (h[7] + hh) & mask;
  }
  return h.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}
