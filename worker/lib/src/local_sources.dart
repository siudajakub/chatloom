// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:personal_core/personal_core.dart';
import 'ports.dart';

/// Upper bound for a Telegram round video exported by the local adapter.
const localRoundMaxBytes = 64 * 1024 * 1024;
const localAudioMaxBytes = 250000000;

/// Video containers the adapter may export (FFmpeg whitelist: mov,
/// matroska/webm, avi). The worker keeps only the first audio stream.
const localVideoMimeTypes = {
  'video/mp4',
  'video/webm',
  'video/quicktime',
  'video/3gpp',
  'video/3gpp2',
  'video/x-matroska',
  'video/x-m4v',
  'video/x-msvideo',
};

/// Kinds this worker asks the adapter for. Adapters that predate video
/// support ignore the field and keep returning voice/round only. Reels are
/// asked for only while the policy transcribes them automatically; a current
/// adapter then lists them as `reel`, and never as `video` otherwise.
const localRecentKinds = ['voice', 'round', 'video', 'audio'];
const localReelKind = 'reel';
const _metadataMaxBytes = 65536;
const _recentMaxBytes = 262144;
const _recentMaxLimit = 200;

/// The adapter hung up without answering (see [LocalSourceTransport]); the
/// request was not processed. Escapes as `local_source_unavailable`.
class _AdapterRefused extends WorkerFailure {
  const _AdapterRefused() : super('local_source_unavailable');
}

/// Explicit local-source adapter. Journal/crypto, identity and all conversation
/// writes remain with Matrix; this socket never receives a provider/API key.
///
/// The adapter serves one request at a time and refuses the rest immediately.
/// Requests from this process are therefore serialized here: a background
/// source scan or deletion audit must never make a paid job's media export
/// fail with `local_source_unavailable`.
///
/// Serializing is not enough on its own: the adapter frees its slot only
/// after it closed the previous connection, a moment after this side has
/// read the whole answer. A request sent in that moment (the next step of
/// the same job, or the next job of a burst waiting here) is accepted and
/// dropped without any HTTP answer. Such a refusal is retried after a short
/// pause ([refusalRetryDelays]); any other I/O failure is reported as
/// `local_source_unavailable`, which the engine retries with backoff,
/// instead of escaping as a raw exception that failed the job for good.
class LocalSourceTransport
    implements
        FeatureTransport,
        RecentSourceScanner,
        MediaPreflight,
        BoundedAudioLoader {
  final FeatureTransport matrix;
  final String socketPath;

  /// Pauses before resending a request the adapter dropped unanswered; one
  /// retry per entry. The adapter's slot is normally free again within
  /// milliseconds.
  final List<Duration> refusalRetryDelays;
  final _clients = <HttpClient>{};
  bool _closed = false;
  Future<void>? _active;
  LocalSourceTransport(
    this.matrix,
    this.socketPath, {
    this.refusalRetryDelays = const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 250),
      Duration(seconds: 1),
    ],
  });

  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  bool local(SourceEventRef source) =>
      source.conversation.roomId.endsWith(':beeper.local');
  @override
  String get accountId => matrix.accountId;
  @override
  String get deviceId => matrix.deviceId;
  @override
  bool get verified => matrix.verified;

  /// Waits for the previous request unless [wait] elapses first.
  Future<T> _exclusive<T>(Future<T> Function() action, {Duration? wait}) async {
    final deadline = wait == null ? null : DateTime.now().add(wait);
    while (_active != null) {
      final active = _active!;
      if (deadline == null) {
        await active;
        continue;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw const WorkerFailure('local_source_busy');
      }
      try {
        await active.timeout(remaining);
      } on TimeoutException {
        throw const WorkerFailure('local_source_busy');
      }
    }
    final done = Completer<void>();
    _active = done.future;
    try {
      return await action();
    } finally {
      _active = null;
      done.complete();
    }
  }

  Future<Uint8List> _post(
    String path,
    Map<String, Object?> payload,
    int limit,
    Cancellation cancel,
  ) async {
    cancel.check();
    if (_closed) throw const WorkerFailure('cancelled');
    final client = HttpClient();
    _clients.add(client);
    client.connectionFactory = (_, _, _) => Socket.startConnect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    cancel.listen(() => client.close(force: true));
    var answered = false;
    try {
      final req = await client
          .postUrl(Uri.parse('http://localhost$path'))
          .timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      final body = utf8.encode(jsonEncode(payload));
      req.contentLength = body.length;
      req.add(body);
      final response = await req.close().timeout(const Duration(minutes: 3));
      answered = true;
      if (response.statusCode != 200) {
        throw const WorkerFailure('local_source_unavailable');
      }
      if (response.contentLength < 0 || response.contentLength > limit) {
        throw const WorkerFailure('source_too_large');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(minutes: 3))) {
        cancel.check();
        if (bytes.length + chunk.length > limit) {
          throw const WorkerFailure('source_too_large');
        }
        bytes.add(chunk);
      }
      cancel.check();
      return bytes.takeBytes();
    } on WorkerFailure {
      rethrow;
    } on Exception catch (e) {
      cancel.check();
      if (_closed) throw const WorkerFailure('cancelled');
      // Refused or closed before any answer: nothing was processed.
      if (!answered && e is IOException) throw const _AdapterRefused();
      throw const WorkerFailure('local_source_unavailable');
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  /// [_post], resending a request the adapter dropped unanswered.
  Future<Uint8List> _send(
    String path,
    Map<String, Object?> payload,
    int limit,
    Cancellation cancel,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _post(path, payload, limit, cancel);
      } on _AdapterRefused {
        if (attempt >= refusalRetryDelays.length) rethrow;
        await Future<void>.delayed(refusalRetryDelays[attempt]);
        cancel.check();
        if (_closed) throw const WorkerFailure('cancelled');
      }
    }
  }

  Future<Uint8List> request(
    SourceEventRef source,
    String mode,
    Cancellation cancel, {
    int? limit,
    Duration? wait,
  }) async {
    if (!verified ||
        source.conversation.accountId != accountId ||
        !local(source)) {
      throw const WorkerFailure('invalid_local_source_account');
    }
    return _exclusive(
      () => _send(
        '/source',
        {'source': source.toJson(), 'mode': mode},
        limit ?? (mode == 'metadata' ? _metadataMaxBytes : localAudioMaxBytes),
        cancel,
      ),
      wait: wait,
    );
  }

  Future<Map<String, dynamic>> metadata(
    SourceEventRef source,
    Cancellation cancel, {
    Duration? wait,
  }) async {
    final data =
        jsonDecode(
              utf8.decode(
                await request(source, 'metadata', cancel, wait: wait),
              ),
            )
            as Map<String, dynamic>;
    if (data['sourceKey'] != source.key || data['redacted'] is! bool) {
      throw const WorkerFailure('local_source_binding_mismatch');
    }
    return data;
  }

  @override
  Future<bool?> sourceRedacted(SourceEventRef source) async {
    if (!local(source)) return matrix.sourceRedacted(source);
    try {
      // Status probes are advisory: never queue behind a long media export.
      return (await metadata(
            source,
            Cancellation(),
            wait: const Duration(seconds: 4),
          ))['redacted']
          as bool;
    } catch (_) {
      return null;
    }
  }

  /// Media kind and byte bound approved by fresh adapter metadata. Voice notes
  /// and other audio must be audio; round videos must be exactly video/mp4;
  /// other videos one of [localVideoMimeTypes].
  static int _exportLimit(Map<String, dynamic> metadata) {
    final mime = metadata['mimeType'];
    final kind = metadata['kind'] ?? 'voice';
    if (mime is! String) throw const WorkerFailure('protected_media');
    if ((kind == 'voice' || kind == 'audio') && mime.startsWith('audio/')) {
      return localAudioMaxBytes;
    }
    if (kind == 'round' && mime == 'video/mp4') return localRoundMaxBytes;
    if ((kind == 'video' || kind == localReelKind) &&
        localVideoMimeTypes.contains(mime)) {
      return localAudioMaxBytes;
    }
    if (mime.startsWith('video/')) {
      throw WorkerFailure(
        kind == 'video' ? 'invalid_media_format' : 'invalid_round_format',
      );
    }
    throw const WorkerFailure('protected_media');
  }

  static AutoTranscriptionKind? _kind(Object? value) => switch (value) {
    'voice' => AutoTranscriptionKind.voice,
    'round' => AutoTranscriptionKind.round,
    'video' => AutoTranscriptionKind.video,
    'audio' => AutoTranscriptionKind.audio,
    localReelKind => AutoTranscriptionKind.reel,
    _ => null,
  };

  /// The adapter answers a reel as `kind: video` plus `reel: true`, which
  /// older workers ignore.
  static AutoTranscriptionKind? _metadataKind(Map<String, dynamic> data) {
    final kind = _kind(data['kind'] ?? 'voice');
    return kind == AutoTranscriptionKind.video && data['reel'] == true
        ? AutoTranscriptionKind.reel
        : kind;
  }

  /// Set once an adapter refused the `reel` kind (it predates reels): later
  /// scans of this process do not ask again, and reels stay on demand.
  bool _reelKindRefused = false;

  @override
  Future<MediaFacts?> mediaFacts(SourceEventRef source) async {
    if (!local(source)) {
      final Object matrix = this.matrix;
      return matrix is MediaPreflight ? matrix.mediaFacts(source) : null;
    }
    try {
      // Advisory like status probes: never queue behind a long export.
      final data = await metadata(
        source,
        Cancellation(),
        wait: const Duration(seconds: 4),
      );
      if (data['redacted'] == true || data['transcriptionAllowed'] != true) {
        return null;
      }
      int? positive(Object? value) => value is int && value >= 0 ? value : null;
      return MediaFacts(
        kind: _metadataKind(data),
        durationMs: positive(data['durationMs']),
        sizeBytes: positive(data['fileSize']),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AudioSource> loadAudio(SourceEventRef source, Cancellation cancel) =>
      loadAudioBounded(
        source,
        cancel,
        maxBytes: localAudioMaxBytes,
        requireDeclaredSize: false,
      );

  @override
  Future<AudioSource> loadAudioBounded(
    SourceEventRef source,
    Cancellation cancel, {
    required int maxBytes,
    required bool requireDeclaredSize,
  }) async {
    if (!local(source)) {
      final Object matrix = this.matrix;
      return matrix is BoundedAudioLoader
          ? matrix.loadAudioBounded(
              source,
              cancel,
              maxBytes: maxBytes,
              requireDeclaredSize: requireDeclaredSize,
            )
          : this.matrix.loadAudio(source, cancel);
    }
    final before = await metadata(source, cancel);
    if (before['redacted'] == true) {
      throw const WorkerFailure('source_redacted');
    }
    if (before['transcriptionAllowed'] != true) {
      throw const WorkerFailure('protected_media');
    }
    final declared = before['fileSize'];
    if (declared is int && declared > maxBytes) {
      throw const WorkerFailure('source_too_large');
    }
    // Older adapters do not declare the size: automatic jobs refuse them.
    if (declared is! int && requireDeclaredSize) {
      throw const WorkerFailure('auto_skipped_unknown_size');
    }
    final kindLimit = _exportLimit(before);
    // The adapter response is refused above this before buffering (declared
    // Content-Length) and aborted while streaming.
    final limit = kindLimit < maxBytes ? kindLimit : maxBytes;
    // Wire mode stays 'audio' for compatibility; it means "approved media
    // bytes". The transcriber keeps only the first audio stream.
    final bytes = await request(source, 'audio', cancel, limit: limit);
    final after = await metadata(source, cancel);
    if (after['redacted'] == true) throw const WorkerFailure('source_redacted');
    if (after['transcriptionAllowed'] != true ||
        after['mimeType'] != before['mimeType'] ||
        (after['kind'] ?? 'voice') != (before['kind'] ?? 'voice')) {
      throw const WorkerFailure('protected_media');
    }
    return AudioSource(bytes, before['mimeType'] as String);
  }

  static final _network = RegExp(r'^[a-z0-9_.-]{1,64}$');

  @override
  Future<RecentSourcePage?> recent({
    required int? cursor,
    DateTime? since,
    int limit = 100,
    bool reels = false,
  }) async {
    if (!verified) throw const WorkerFailure('device_verification_required');
    if (limit < 1 ||
        limit > _recentMaxLimit ||
        (cursor != null && cursor < 0)) {
      throw ArgumentError('Invalid recent source page');
    }
    // A scan is optional work: skip this interval instead of waiting.
    if (_active != null) return null;
    final askReels = reels && !_reelKindRefused;
    Future<Uint8List> page(bool withReels) => _exclusive(
      () => _send(
        '/recent',
        {
          'accountId': accountId,
          'cursor': cursor,
          'sinceMs': since?.toUtc().millisecondsSinceEpoch,
          'limit': limit,
          'kinds': [...localRecentKinds, if (withReels) localReelKind],
        },
        _recentMaxBytes,
        Cancellation(),
      ),
      wait: Duration.zero,
    );
    Uint8List bytes;
    try {
      try {
        bytes = await page(askReels);
      } on WorkerFailure catch (e) {
        // A dropped connection says nothing about the kinds it knows.
        if (!askReels ||
            e.code == 'local_source_busy' ||
            e is _AdapterRefused) {
          rethrow;
        }
        // An adapter that predates reels refuses the unknown kind. Scan
        // without it: reels then stay on demand rather than every
        // automatic transcription stopping.
        _reelKindRefused = true;
        bytes = await page(false);
      }
    } on WorkerFailure catch (e) {
      if (e.code == 'local_source_busy') return null;
      rethrow;
    }
    final Object? data;
    try {
      data = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const WorkerFailure('invalid_recent_response');
    }
    if (data is! Map ||
        data['cursor'] is! int ||
        (data['cursor'] as int) < (cursor ?? 0) ||
        data['items'] is! List ||
        (data['items'] as List).length > limit) {
      throw const WorkerFailure('invalid_recent_response');
    }
    // One bad item no longer rejects the page: before, the cursor never
    // moved past it and the same page was refused every 3 s, forever.
    final items = <RecentSourceItem>[];
    for (final raw in data['items'] as List) {
      final room = raw is Map ? raw['roomId'] : null;
      final event = raw is Map ? raw['eventId'] : null;
      final kind = raw is Map ? _kind(raw['kind']) : null;
      if (room is! String ||
          !room.startsWith('!') ||
          !room.endsWith(':beeper.local') ||
          room.length > 255 ||
          event is! String ||
          !event.startsWith(r'$') ||
          event.length > 255 ||
          kind == null) {
        skippedRecentItems++;
        continue;
      }
      raw as Map;
      // Implausible metadata is dropped, not the message: an unknown
      // duration is measured before any upload, an unknown time is too old.
      final duration = raw['durationMs'];
      final timestamp = raw['timestampMs'];
      final network = raw['network'];
      items.add(
        RecentSourceItem(
          roomId: room,
          eventId: event,
          kind: kind,
          network: network is String && _network.hasMatch(network)
              ? network
              : 'unknown',
          durationMs: duration is int && duration >= 0 && duration <= 86400000
              ? duration
              : null,
          timestamp: timestamp is int && timestamp > 0
              ? DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true)
              : null,
        ),
      );
    }
    return RecentSourcePage(data['cursor'] as int, items);
  }

  /// Items of recent pages skipped as malformed (diagnostics and tests).
  int skippedRecentItems = 0;

  @override
  Future<String> send(
    SendTarget target,
    Map<String, dynamic> content,
    String transactionId,
  ) => matrix.send(target, content, transactionId);
  @override
  Future<void> readAfterAcceptedReply(SendTarget target) =>
      matrix.readAfterAcceptedReply(target);
  @override
  Future<bool> hasRepliedSince(ConversationRef conversation, DateTime since) =>
      matrix.hasRepliedSince(conversation, since);
}
