// SPDX-License-Identifier: AGPL-3.0-or-later

/// Automatic prefetch of voice notes, round videos and round thumbnails.
///
/// The prefetcher downloads **ciphertext only** into the encrypted media cache
/// (the same bytes and key the Matrix SDK stores in
/// `downloadAndDecryptAttachment(cacheAttachment: true)`), so a later tap on
/// play is a cache hit. It never decrypts, never writes plaintext files and
/// never sends read/played receipts.
///
/// ## Attaching from a timeline list (owner: ChatEventList / merged page)
///
/// ```dart
/// RoomPrefetchScope? _prefetch;
/// List<Event> _prefetchEvents = const [];
///
/// // Once the timeline exists (idempotent; one scope per open list):
/// _prefetch ??= MediaPrefetcher.of(room.client).attach(
///   roomIds: {room.id},                 // merged page: all member room ids
///   events: () => _prefetchEvents,      // newest first, same list as rows
/// );
///
/// // In build, after computing the visible events:
/// _prefetchEvents = events;
///
/// // In the itemBuilder, for an event row, with its index into events():
/// _prefetch?.noteBuilt(eventIndex);     // O(1): two ints + idle timer
///
/// // In dispose:
/// _prefetch?.dispose();                 // aborts this scope's downloads
/// ```
///
/// Policy: at open the newest [MediaPrefetcher.initialCount] qualifying events;
/// while scrolling, after [MediaPrefetcher.idleDelay] without builds, the
/// built range ± [MediaPrefetcher.windowMargin] (nearest the centre first);
/// new arrivals in attached rooms first. At most [MediaPrefetcher.maxConcurrent]
/// downloads, deduplicated by `mxc://`, each capped at
/// [MediaPrefetcher.maxItemBytes] (under the cache `maxFileSize`), and at most
/// [MediaPrefetcher.scopeBudgetBytes] of network per open chat. Limited or
/// protected media, unknown sizes, unsent/redacted events and rounds whose
/// verified media state is not loaded or expired are never fetched. Work stops
/// when the scope is disposed, the app is not resumed, the privacy lock engages
/// (`PersonalPrivacy.surfaceGeneration` changes), the account logs out, the
/// setting `personalAutoDownloadVoiceRounds` is off, or (with
/// `personalAutoDownloadWifiOnly`) the device is not on Wi-Fi/Ethernet.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'media_inflight.dart';
import 'protected_matrix_database.dart';

/// Thrown inside a download to stop it (cancellation, cap, idle timeout).
class MediaPrefetchAborted implements Exception {
  final String reason;
  const MediaPrefetchAborted(this.reason);
  @override
  String toString() => 'MediaPrefetchAborted($reason)';
}

/// Cooperative cancellation for one download. [onAbort] doubles as the
/// `http.AbortableRequest.abortTrigger`.
class MediaPrefetchCancellation {
  final bool Function() _stillWanted;
  final _abort = Completer<void>();
  MediaPrefetchCancellation(this._stillWanted);

  bool get valid => !_abort.isCompleted && _stillWanted();
  Future<void> get onAbort => _abort.future;
  void cancel() {
    if (!_abort.isCompleted) _abort.complete();
  }
}

/// Side effects of the prefetcher, injectable for tests.
abstract class MediaPrefetchPorts {
  /// `AppSettings.personalAutoDownloadVoiceRounds`.
  bool get enabled;

  /// Wi-Fi-only policy; true when downloads may use the current network.
  Future<bool> networkAllowed();

  /// App resumed, privacy surface unlocked/foreground, account logged in.
  bool get surfaceActive;

  /// Changes whenever the privacy surface locks/unlocks or backgrounds.
  int get surfaceGeneration;

  /// Largest ciphertext the SDK cache stores (exclusive); 0 = no file cache.
  int get maxCacheableBytes;

  bool isRoundStateKnown(Event event);
  bool isRoundExpired(Event event);
  Future<void> preloadRoundStates(Room room, Iterable<String> eventIds);

  /// Same gate the SDK runs before every attachment access; throws to deny.
  Future<void> authorize(Event event, bool thumbnail);
  Future<bool> isCached(Uri mxc);
  Future<void> store(Uri mxc, Uint8List ciphertext);

  /// Returns ciphertext to store, or null when nothing should be stored
  /// (e.g. the content-scanner fallback already stored it through the SDK).
  Future<Uint8List?> download(
    Event event,
    Uri mxc, {
    required bool thumbnail,
    required int maxBytes,
    required MediaPrefetchCancellation cancellation,
  });
}

class _Job {
  final Uri mxc;
  final Event event;
  final bool thumbnail;
  final int size;
  int priority;
  int sequence;
  final RoomPrefetchScope charged;
  final owners = <RoomPrefetchScope>{};
  MediaPrefetchCancellation? cancellation;
  bool cancelled = false;
  _Job(
    this.mxc,
    this.event,
    this.thumbnail,
    this.size,
    this.priority,
    this.sequence,
    this.charged,
  ) {
    owners.add(charged);
  }

  void cancel() {
    cancelled = true;
    cancellation?.cancel();
  }
}

class _Candidate {
  final Event event;
  final bool round;
  final Uri mxc;
  final int size;
  final Uri? thumbnail;
  final int? thumbnailSize;
  const _Candidate(
    this.event,
    this.round,
    this.mxc,
    this.size,
    this.thumbnail,
    this.thumbnailSize,
  );
}

/// Per-client prefetch queue. Use [MediaPrefetcher.of] and [attach].
class MediaPrefetcher {
  static const maxConcurrent = 2;
  static const maxItemBytes = 8 * 1024 * 1024;
  static const maxThumbnailBytes = 2 * 1024 * 1024;
  static const scopeBudgetBytes = 48 * 1024 * 1024;
  static const initialCount = 20;
  static const initialScanLimit = 200;
  static const windowMargin = 10;
  static const idleDelay = Duration(milliseconds: 300);

  static const _arrival = 0, _initial = 1, _window = 2;

  static final _instances = <Client, MediaPrefetcher>{};

  static MediaPrefetcher of(Client client) => _instances.putIfAbsent(
    client,
    () => MediaPrefetcher._(client, ClientMediaPrefetchPorts(client)),
  );

  /// In-flight prefetch of [mxc] (any account); play paths may await it and
  /// then read the cache. Never completes with an error.
  static Future<void>? inflight(Uri mxc) => MediaInflight.of(mxc);

  /// Aborts everything for [client] (logout / account removal).
  static void closeFor(Client client) => _instances.remove(client)?._close();

  final Client client;
  final MediaPrefetchPorts ports;
  final Duration idle;
  final _scopes = <RoomPrefetchScope>{};
  final _queue = <_Job>[];
  final _running = <String, _Job>{};
  final _known = <String, _Job>{};
  StreamSubscription<Event>? _arrivals;
  StreamSubscription<LoginState>? _login;
  int _sequence = 0;
  bool _closed = false;
  int? _generation;

  MediaPrefetcher._(this.client, this.ports, {this.idle = idleDelay}) {
    _login = client.onLoginStateChanged.stream.listen((state) {
      if (state == LoginState.loggedOut &&
          identical(_instances[client], this)) {
        closeFor(client);
      }
    });
  }

  @visibleForTesting
  factory MediaPrefetcher.test(
    Client client,
    MediaPrefetchPorts ports, {
    Duration idle = Duration.zero,
  }) => _instances[client] = MediaPrefetcher._(client, ports, idle: idle);

  @visibleForTesting
  int get queuedCount => _queue.length;
  @visibleForTesting
  int get runningCount => _running.length;

  RoomPrefetchScope attach({
    required Set<String> roomIds,
    required List<Event> Function() events,
  }) {
    final scope = RoomPrefetchScope._(this, Set.unmodifiable(roomIds), events);
    if (_closed) {
      scope._disposed = true;
      return scope;
    }
    _scopes.add(scope);
    _arrivals ??= client.onTimelineEvent.stream.listen(_arrived);
    scope._schedule();
    return scope;
  }

  void _arrived(Event event) {
    if (_closed) return;
    for (final scope in _scopes) {
      if (scope.roomIds.contains(event.room.id)) {
        unawaited(scope._enqueue([event], _arrival));
      }
    }
  }

  void _detach(RoomPrefetchScope scope) {
    _scopes.remove(scope);
    _queue.removeWhere((job) {
      job.owners.remove(scope);
      if (job.owners.isNotEmpty) return false;
      _known.remove(job.mxc.toString());
      return true;
    });
    for (final job in _running.values.toList()) {
      job.owners.remove(scope);
      if (job.owners.isEmpty) job.cancel();
    }
    if (_scopes.isEmpty) {
      unawaited(_arrivals?.cancel());
      _arrivals = null;
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    for (final scope in _scopes.toList()) {
      scope._disposed = true;
      scope._timer?.cancel();
    }
    _scopes.clear();
    _queue.clear();
    _known.clear();
    for (final job in _running.values) {
      job.cancel();
    }
    unawaited(_arrivals?.cancel());
    unawaited(_login?.cancel());
  }

  /// Privacy lock / backgrounding drops queued work; it is rebuilt from the
  /// next scroll or arrival once the surface is active again.
  bool _surfaceUsable() {
    if (_closed || !ports.enabled || !ports.surfaceActive) {
      _dropAll();
      return false;
    }
    final generation = ports.surfaceGeneration;
    if (_generation != null && _generation != generation) {
      _generation = generation;
      _dropAll();
      return false;
    }
    _generation = generation;
    return true;
  }

  void _dropAll() {
    for (final job in _queue) {
      _known.remove(job.mxc.toString());
    }
    _queue.clear();
    for (final job in _running.values) {
      job.cancel();
    }
    for (final scope in _scopes) {
      scope._initialDone = false;
    }
  }

  _Candidate? _candidate(Event event) {
    if (event.type != EventTypes.Message ||
        event.redacted ||
        !event.status.isSent ||
        !event.eventId.startsWith(r'$') ||
        !identical(event.room.client, client)) {
      return null;
    }
    final type = event.messageType;
    final round =
        type == MessageTypes.Video &&
        RoundVideoDescriptor.fromContent(event.content) != null;
    if (!round && type != MessageTypes.Audio) return null;
    if (!RoundMediaPolicy.fromContent(event.content).canPersist) return null;
    // Chats with a disappearing-message timer (mautrix bridgev2 room state)
    // are never prefetched; anything but an explicit "off" counts as on.
    if (disappearingTimerLimits(
      event.room.getState(beeperDisappearingTimerKey)?.content,
    )) {
      return null;
    }
    final mxc = event.attachmentMxcUrl;
    final size = event.infoMap['size'];
    final storable = ports.maxCacheableBytes;
    // Unknown size: the SDK would neither read nor write the cache for it.
    if (mxc == null ||
        !mxc.isScheme('mxc') ||
        size is! int ||
        size <= 0 ||
        size > maxItemBytes ||
        size >= storable) {
      return null;
    }
    Uri? thumbnail;
    int? thumbnailSize;
    if (round && event.hasThumbnail) {
      final value = event.thumbnailInfoMap['size'];
      final uri = event.thumbnailMxcUrl;
      if (uri != null &&
          uri.isScheme('mxc') &&
          value is int &&
          value > 0 &&
          value <= maxThumbnailBytes &&
          value < storable) {
        thumbnail = uri;
        thumbnailSize = value;
      }
    }
    return _Candidate(event, round, mxc, size, thumbnail, thumbnailSize);
  }

  bool _roundAllowed(Event event) =>
      ports.isRoundStateKnown(event) && !ports.isRoundExpired(event);

  void _add(
    RoomPrefetchScope scope,
    Event event,
    Uri mxc,
    int size,
    bool thumbnail,
    int priority,
  ) {
    final key = mxc.toString();
    final existing = _known[key];
    final sequence = _sequence++;
    if (existing != null) {
      existing.owners.add(scope);
      // Better (or refreshed same-tier) priority moves it up the queue.
      if (priority <= existing.priority) {
        existing
          ..priority = priority
          ..sequence = sequence;
      }
      return;
    }
    if (MediaInflight.contains(mxc)) return;
    final job = _Job(mxc, event, thumbnail, size, priority, sequence, scope);
    _known[key] = job;
    _queue.add(job);
  }

  void _pump() {
    if (_queue.isEmpty || !_surfaceUsable()) return;
    while (_running.length < maxConcurrent && _queue.isNotEmpty) {
      var best = 0;
      for (var i = 1; i < _queue.length; i++) {
        final a = _queue[i], b = _queue[best];
        if (a.priority < b.priority ||
            (a.priority == b.priority && a.sequence < b.sequence)) {
          best = i;
        }
      }
      final job = _queue.removeAt(best);
      final key = job.mxc.toString();
      _running[key] = job;
      unawaited(
        MediaInflight.track(job.mxc, _run(job)).whenComplete(() {
          _running.remove(key);
          if (identical(_known[key], job)) _known.remove(key);
          _pump();
        }),
      );
    }
  }

  Future<void> _run(_Job job) async {
    final generation = ports.surfaceGeneration;
    bool wanted() =>
        !job.cancelled &&
        !_closed &&
        job.owners.isNotEmpty &&
        ports.enabled &&
        ports.surfaceActive &&
        ports.surfaceGeneration == generation;
    final cancellation = job.cancellation = MediaPrefetchCancellation(wanted);
    final scope = job.charged;
    var reserved = 0;
    try {
      if (!cancellation.valid) return;
      if (!await ports.networkAllowed() || !cancellation.valid) return;
      if (job.event.messageType == MessageTypes.Video &&
          !_roundAllowed(job.event)) {
        return;
      }
      await ports.authorize(job.event, job.thumbnail);
      if (!cancellation.valid) return;
      if (await ports.isCached(job.mxc) || !cancellation.valid) return;
      if (scope._spent + job.size > scopeBudgetBytes) return;
      reserved = job.size;
      scope._spent += reserved;
      final limit = job.thumbnail ? maxThumbnailBytes : maxItemBytes;
      final bytes = await ports.download(
        job.event,
        job.mxc,
        thumbnail: job.thumbnail,
        maxBytes: limit,
        cancellation: cancellation,
      );
      if (bytes == null) {
        scope._spent -= reserved;
        return;
      }
      // Charge what actually crossed the network.
      scope._spent += bytes.length - reserved;
      reserved = 0;
      if (!cancellation.valid ||
          bytes.isEmpty ||
          bytes.length > limit ||
          bytes.length >= ports.maxCacheableBytes) {
        return;
      }
      await ports.store(job.mxc, bytes);
    } catch (_) {
      // Best effort: the play path downloads on demand. Release the budget
      // reserved for a download that did not produce bytes.
      scope._spent -= reserved;
    }
  }
}

/// One open chat (or merged conversation). Cheap to feed from `itemBuilder`.
class RoomPrefetchScope {
  final MediaPrefetcher _owner;
  final Set<String> roomIds;
  final List<Event> Function() _events;
  bool _disposed = false;
  bool _initialDone = false;
  int _spent = 0;
  int? _min, _max;
  Timer? _timer;
  final _clock = Stopwatch()..start();
  Duration _lastBuilt = Duration.zero;

  RoomPrefetchScope._(this._owner, this.roomIds, this._events);

  bool get disposed => _disposed;

  /// Network bytes charged to this scope (cache hits are free).
  int get spentBytes => _spent;

  /// Call from the list's itemBuilder with the row's index into `events()`.
  /// Records the built range; work starts after the list is idle.
  void noteBuilt(int index) {
    if (_disposed || index < 0) return;
    if (_min == null || index < _min!) _min = index;
    if (_max == null || index > _max!) _max = index;
    _lastBuilt = _clock.elapsed;
    _schedule();
  }

  /// Re-scan without a scroll (e.g. after the timeline finished loading).
  void refresh() => _schedule();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _owner._detach(this);
  }

  void _schedule() {
    if (_disposed || _timer != null) return;
    _timer = Timer(_owner.idle, _tick);
  }

  void _tick() {
    _timer = null;
    if (_disposed) return;
    final quiet = _clock.elapsed - _lastBuilt;
    if (_owner.idle > Duration.zero && quiet < _owner.idle) {
      _timer = Timer(_owner.idle - quiet, _tick);
      return;
    }
    unawaited(_flush());
  }

  Future<void> _flush() async {
    if (_disposed || !_owner._surfaceUsable()) return;
    final events = _events();
    if (events.isEmpty) return;
    if (!_initialDone) {
      _initialDone = true;
      // Newest-first prefix holding the first [initialCount] candidates; its
      // rounds also get their media states preloaded in one batch.
      final scan = math.min(events.length, MediaPrefetcher.initialScanLimit);
      var end = 0, found = 0;
      while (end < scan && found < MediaPrefetcher.initialCount) {
        if (_owner._candidate(events[end++]) != null) found++;
      }
      await _enqueue(events.sublist(0, end), MediaPrefetcher._initial);
    }
    final min = _min, max = _max;
    _min = _max = null;
    if (min == null || max == null || _disposed) return;
    final from = math.max(0, min - MediaPrefetcher.windowMargin);
    final to = math.min(events.length - 1, max + MediaPrefetcher.windowMargin);
    if (from > to) return;
    final centre = (min + max) / 2;
    final order = [for (var i = from; i <= to; i++) i]
      ..sort((a, b) => (a - centre).abs().compareTo((b - centre).abs()));
    // Far-away window work from the previous position is no longer wanted.
    _owner._queue.removeWhere((job) {
      if (job.priority != MediaPrefetcher._window ||
          !job.owners.contains(this)) {
        return false;
      }
      job.owners.remove(this);
      if (job.owners.isNotEmpty) return false;
      _owner._known.remove(job.mxc.toString());
      return true;
    });
    await _enqueue([for (final i in order) events[i]], MediaPrefetcher._window);
  }

  Future<void> _enqueue(Iterable<Event> events, int priority) async {
    final owner = _owner;
    if (_disposed ||
        owner._closed ||
        !owner.ports.enabled ||
        !owner.ports.surfaceActive) {
      return;
    }
    final candidates = <_Candidate>[];
    final unknown = <Room, List<String>>{};
    for (final event in events) {
      if (!roomIds.contains(event.room.id) ||
          !identical(event.room.client, owner.client)) {
        continue;
      }
      // Batch-load reverse states for every visible round (also ones too big
      // to prefetch) so rows do not query them one by one.
      if (!event.redacted &&
          event.eventId.startsWith(r'$') &&
          RoundVideoDescriptor.fromContent(event.content) != null &&
          !owner.ports.isRoundStateKnown(event)) {
        (unknown[event.room] ??= []).add(event.eventId);
      }
      final candidate = owner._candidate(event);
      if (candidate != null) candidates.add(candidate);
    }
    for (final entry in unknown.entries) {
      try {
        await owner.ports.preloadRoundStates(entry.key, entry.value);
      } catch (_) {
        // Unknown state stays unknown: those rounds are skipped below.
      }
      if (_disposed) return;
    }
    for (final c in candidates) {
      if (c.round && !owner._roundAllowed(c.event)) continue;
      final thumbnail = c.thumbnail, thumbnailSize = c.thumbnailSize;
      if (thumbnail != null && thumbnailSize != null) {
        owner._add(this, c.event, thumbnail, thumbnailSize, true, priority);
      }
      owner._add(this, c.event, c.mxc, c.size, false, priority);
    }
    owner._pump();
  }
}

/// Production ports: AppSettings, connectivity_plus, PersonalPrivacy,
/// TelegramRoundService, the SDK attachment gate and the encrypted cache.
class ClientMediaPrefetchPorts implements MediaPrefetchPorts {
  final Client client;
  static const idleTimeout = Duration(seconds: 20);
  ClientMediaPrefetchPorts(this.client);

  @override
  bool get enabled => AppSettings.personalAutoDownloadVoiceRounds.value;

  @override
  Future<bool> networkAllowed() async {
    if (!AppSettings.personalAutoDownloadWifiOnly.value) return true;
    try {
      final networks = await Connectivity().checkConnectivity();
      return networks.contains(ConnectivityResult.wifi) ||
          networks.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  @override
  bool get surfaceActive {
    final state = WidgetsBinding.instance.lifecycleState;
    return PersonalPrivacy.surfaceUnlocked &&
        PersonalPrivacy.surfaceForeground &&
        (state == null || state == AppLifecycleState.resumed) &&
        client.isLogged();
  }

  @override
  int get surfaceGeneration => PersonalPrivacy.surfaceGeneration;

  @override
  int get maxCacheableBytes {
    final database = client.database;
    return database.supportsFileStoring ? database.maxFileSize : 0;
  }

  TelegramRoundService get _rounds => TelegramRoundService.of(client);

  @override
  bool isRoundStateKnown(Event event) => _rounds.isMediaStateKnown(event);

  @override
  bool isRoundExpired(Event event) =>
      _rounds.verifiedMediaStateSnapshot(event)?['expired'] == true;

  @override
  Future<void> preloadRoundStates(Room room, Iterable<String> eventIds) =>
      _rounds.preloadMediaStates(room, eventIds);

  @override
  Future<void> authorize(Event event, bool thumbnail) async {
    // No installed attachment gate means privacy wiring is missing: deny
    // rather than download unchecked.
    final gate = client.authorizeAttachmentAccess;
    if (gate == null) throw const MediaPrefetchAborted('no_gate');
    await gate(event, thumbnail);
  }

  @override
  Future<bool> isCached(Uri mxc) async {
    final database = client.database;
    if (database is ProtectedMatrixDatabase) return database.hasFile(mxc);
    return await database.getFile(mxc) != null;
  }

  @override
  Future<void> store(Uri mxc, Uint8List ciphertext) => client.database
      .storeFile(mxc, ciphertext, DateTime.now().millisecondsSinceEpoch);

  @override
  Future<Uint8List?> download(
    Event event,
    Uri mxc, {
    required bool thumbnail,
    required int maxBytes,
    required MediaPrefetchCancellation cancellation,
  }) async {
    if (client.contentScannerConfig != null) {
      // Scanner flow is SDK-only; it stores the ciphertext itself.
      await event.downloadAndDecryptAttachment(
        getThumbnail: thumbnail,
        cacheAttachment: true,
        onDownloadProgress: (bytes) {
          if (!cancellation.valid) throw const MediaPrefetchAborted('cancel');
          if (bytes > maxBytes) throw const MediaPrefetchAborted('cap');
        },
      );
      return null;
    }
    final uri = await mxc.getDownloadUri(client);
    final token = client.accessToken;
    if (!uri.hasScheme || token == null || !cancellation.valid) return null;
    // Same request as the SDK's _downloadAttachmentBytes (no scanner).
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: cancellation.onAbort,
    )..headers['authorization'] = 'Bearer $token';
    final response = await client.httpClient.send(request);
    return readBoundedBody(
      response,
      maxBytes: maxBytes,
      cancellation: cancellation,
      idleTimeout: idleTimeout,
    );
  }
}

/// Reads a media response, aborting on non-2xx, oversize (declared or
/// streamed), cancellation, or [idleTimeout] without data. Null = discard.
@visibleForTesting
Future<Uint8List?> readBoundedBody(
  http.StreamedResponse response, {
  required int maxBytes,
  required MediaPrefetchCancellation cancellation,
  Duration idleTimeout = ClientMediaPrefetchPorts.idleTimeout,
}) {
  final declared = response.contentLength;
  if (response.statusCode < 200 ||
      response.statusCode >= 300 ||
      (declared != null && declared > maxBytes) ||
      !cancellation.valid) {
    cancellation.cancel();
    unawaited(response.stream.listen(null, onError: (Object _) {}).cancel());
    return Future.value();
  }
  final done = Completer<Uint8List?>();
  final builder = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> subscription;
  Timer? idle;
  void finish(Uint8List? value) {
    idle?.cancel();
    if (done.isCompleted) return;
    if (value == null) {
      cancellation.cancel();
      unawaited(subscription.cancel());
    }
    done.complete(value);
  }

  void armIdle() {
    idle?.cancel();
    idle = Timer(idleTimeout, () => finish(null));
  }

  subscription = response.stream.listen(
    (chunk) {
      if (done.isCompleted) return;
      if (!cancellation.valid) return finish(null);
      builder.add(chunk);
      if (builder.length > maxBytes) return finish(null);
      armIdle();
    },
    onError: (Object _) => finish(null),
    onDone: () => finish(builder.takeBytes()),
    cancelOnError: true,
  );
  unawaited(cancellation.onAbort.then((_) => finish(null)));
  armIdle();
  return done.future;
}
