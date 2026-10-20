// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chatloom/personal/media/media_inflight.dart';
import 'package:chatloom/personal/media/media_prefetcher.dart';
import 'package:chatloom/personal/round_video/round_media_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

const _mb = 1024 * 1024;

class _Database implements DatabaseApi {
  final files = <String, Uint8List>{};
  final stored = <String>[];
  @override
  bool get supportsFileStoring => true;
  @override
  int get maxFileSize => 10 * 1000 * 1000;
  @override
  Future<Uint8List?> getFile(Uri mxcUri) async => files[mxcUri.toString()];
  @override
  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) async {
    stored.add(mxcUri.toString());
    files[mxcUri.toString()] = bytes;
  }

  // Versions cache used by getDownloadUri when logged in.
  @override
  Future<({Map<String, Object?> content, DateTime savedAt})?>
  getCustomCacheObject(String cacheKey) async => null;
  @override
  Future<void> cacheCustomObject(
    String cacheKey,
    Map<String, Object?> object,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access account storage');
}

class _Ports implements MediaPrefetchPorts {
  @override
  bool enabled = true;
  @override
  bool surfaceActive = true;
  @override
  int surfaceGeneration = 0;
  bool network = true;
  @override
  int maxCacheableBytes = 10 * 1000 * 1000;

  /// eventId → state; a missing key means "not loaded".
  final states = <String, Map<String, dynamic>?>{};

  /// What a batched preload finds (eventId → state, null = known absence).
  final preloadable = <String, Map<String, dynamic>?>{};
  final preloadCalls = <List<String>>[];
  final authorized = <String>[];
  final cached = <String>{};
  final stored = <String, Uint8List>{};
  final downloads = <String>[];
  final maxBytes = <String, int>{};
  final cancellations = <String, MediaPrefetchCancellation>{};
  final sizes = <String, int>{};
  Completer<void>? gate;
  int active = 0, maxActive = 0;
  int returnExtra = 0;

  @override
  Future<bool> networkAllowed() async => network;

  @override
  bool isRoundStateKnown(Event event) => states.containsKey(event.eventId);
  @override
  bool isRoundExpired(Event event) => states[event.eventId]?['expired'] == true;
  @override
  Future<void> preloadRoundStates(Room room, Iterable<String> ids) async {
    preloadCalls.add(ids.toList());
    for (final id in ids) {
      if (preloadable.containsKey(id)) states[id] = preloadable[id];
    }
  }

  @override
  Future<void> authorize(Event event, bool thumbnail) async {
    authorized.add('${event.eventId}:$thumbnail');
  }

  @override
  Future<bool> isCached(Uri mxc) async => cached.contains(mxc.toString());

  @override
  Future<void> store(Uri mxc, Uint8List ciphertext) async {
    stored[mxc.toString()] = ciphertext;
  }

  @override
  Future<Uint8List?> download(
    Event event,
    Uri mxc, {
    required bool thumbnail,
    required int maxBytes,
    required MediaPrefetchCancellation cancellation,
  }) async {
    final key = mxc.toString();
    downloads.add(key);
    this.maxBytes[key] = maxBytes;
    cancellations[key] = cancellation;
    active++;
    maxActive = math.max(maxActive, active);
    try {
      final gate = this.gate;
      if (gate != null) {
        await Future.any([gate.future, cancellation.onAbort]);
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      if (!cancellation.valid && gate == null) return null;
      final size = thumbnail
          ? event.thumbnailInfoMap['size'] as int
          : event.infoMap['size'] as int;
      return Uint8List(size + returnExtra);
    } finally {
      active--;
    }
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Event _voice(
  Room room,
  String id, {
  Object? size = 1000,
  String? mxc,
  Map<String, dynamic> extra = const {},
  EventStatus status = EventStatus.synced,
}) => Event(
  room: room,
  eventId: '\$$id',
  senderId: '@peer:example.invalid',
  type: EventTypes.Message,
  status: status,
  originServerTs: DateTime.utc(2026),
  content: {
    'msgtype': 'm.audio',
    'body': 'voice.ogg',
    'url': mxc ?? 'mxc://example.invalid/$id',
    'info': {'size': ?size, 'mimetype': 'audio/ogg'},
    'org.matrix.msc3245.voice': <String, dynamic>{},
    ...extra,
  },
);

Event _round(Room room, String id, {int size = 2000, int? thumbnailSize}) =>
    Event(
      room: room,
      eventId: '\$$id',
      senderId: '@peer:example.invalid',
      type: EventTypes.Message,
      originServerTs: DateTime.utc(2026),
      content: {
        'msgtype': 'm.video',
        'body': 'round.mp4',
        'url': 'mxc://example.invalid/$id',
        'info': {
          'fi.mau.telegram.round_message': true,
          'duration': 10000,
          'size': size,
          'mimetype': 'video/mp4',
          if (thumbnailSize != null) ...{
            'thumbnail_url': 'mxc://example.invalid/$id-thumb',
            'thumbnail_info': {'size': thumbnailSize, 'mimetype': 'image/jpeg'},
          },
        },
      },
    );

void main() {
  late Client client;
  late Room room;
  late _Ports ports;
  late MediaPrefetcher prefetcher;
  final requests = <http.BaseRequest>[];

  setUp(() {
    requests.clear();
    client = Client(
      'prefetch fixture',
      database: _Database(),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 404);
      }),
    );
    room = Room(id: '!room:example.invalid', client: client);
    ports = _Ports();
    prefetcher = MediaPrefetcher.test(client, ports);
  });

  tearDown(() {
    MediaPrefetcher.closeFor(client);
  });

  test('open chat prefetches the newest 20 qualifying voice notes, '
      'two at a time, without receipts', () async {
    final events = [for (var i = 0; i < 25; i++) _voice(room, 'v$i')];
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads.length, 20);
    expect(ports.downloads.first, 'mxc://example.invalid/v0');
    expect(ports.stored.length, 20);
    expect(ports.maxActive, lessThanOrEqualTo(MediaPrefetcher.maxConcurrent));
    expect(ports.maxBytes.values.toSet(), {MediaPrefetcher.maxItemBytes});
    expect(ports.authorized.first, r'$v0:false');
    // The prefetcher only reaches the network through the download port: no
    // receipt, read marker, typing or event send ever leaves the client.
    expect(requests, isEmpty);
    scope.dispose();
  });

  test('scroll window, cache hits, size caps and limited media', () async {
    final events = [
      _voice(room, 'big', size: 9 * _mb),
      _voice(room, 'unknown', size: null),
      _voice(room, 'sending', status: EventStatus.sending),
      _voice(
        room,
        'limited',
        extra: {
          'info': {'size': 1000, 'com.beeper.view_once': true},
        },
      ),
      _voice(room, 'cached'),
      for (var i = 0; i < 40; i++) _voice(room, 'w$i'),
    ];
    ports.cached.add('mxc://example.invalid/cached');
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    final initial = ports.downloads.toSet();
    expect(initial, isNot(contains('mxc://example.invalid/big')));
    expect(initial, isNot(contains('mxc://example.invalid/unknown')));
    expect(initial, isNot(contains('mxc://example.invalid/sending')));
    expect(initial, isNot(contains('mxc://example.invalid/limited')));
    expect(initial, isNot(contains('mxc://example.invalid/cached')));
    // Newest 20 candidates include the cached one, which costs no download.
    expect(initial.length, 19);
    // Scrolled to rows 35–37: window 25..47 (clamped), nearest centre first.
    scope.noteBuilt(35);
    scope.noteBuilt(37);
    await _settle();
    final later = ports.downloads.skip(initial.length).toList();
    expect(later.first, 'mxc://example.invalid/w31'); // index 36
    expect(later, contains('mxc://example.invalid/w39')); // index 44
    expect(later, isNot(contains('mxc://example.invalid/w0')));
    scope.dispose();
  });

  test('per-chat budget stops at 48 MB of network', () async {
    final events = [
      for (var i = 0; i < 10; i++) _voice(room, 'b$i', size: 7 * _mb),
    ];
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads.length, 6); // 6 × 7 MB = 42 MB; the 7th exceeds 48
    expect(scope.spentBytes, 42 * _mb);
    scope.dispose();
  });

  test('duplicates by mxc download once across events and scopes', () async {
    final events = [
      _voice(room, 'a', mxc: 'mxc://example.invalid/same'),
      _voice(room, 'b', mxc: 'mxc://example.invalid/same'),
    ];
    ports.gate = Completer<void>();
    final first = prefetcher.attach(roomIds: {room.id}, events: () => events);
    final second = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads, ['mxc://example.invalid/same']);
    expect(
      MediaPrefetcher.inflight(Uri.parse('mxc://example.invalid/same')),
      isNotNull,
    );
    // One owner leaving does not cancel the shared download.
    first.dispose();
    ports.gate!.complete();
    await _settle();
    expect(ports.stored.keys, ['mxc://example.invalid/same']);
    expect(
      MediaPrefetcher.inflight(Uri.parse('mxc://example.invalid/same')),
      isNull,
    );
    second.dispose();
  });

  test('disposing the scope aborts the download and stores nothing', () async {
    final events = [for (var i = 0; i < 4; i++) _voice(room, 'd$i')];
    ports.gate = Completer<void>();
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads.length, 2);
    final cancellation = ports.cancellations.values.first;
    scope.dispose();
    await _settle();
    expect(cancellation.valid, isFalse);
    expect(prefetcher.queuedCount, 0);
    expect(prefetcher.runningCount, 0);
    expect(ports.stored, isEmpty);
    expect(ports.downloads.length, 2);
  });

  test('privacy lock aborts in-flight work and drops the queue', () async {
    final events = [for (var i = 0; i < 6; i++) _voice(room, 'l$i')];
    ports.gate = Completer<void>();
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads.length, 2);
    ports
      ..surfaceGeneration += 1
      ..surfaceActive = false;
    ports.gate!.complete();
    await _settle();
    expect(ports.cancellations.values.every((c) => !c.valid), isTrue);
    expect(ports.stored, isEmpty);
    expect(ports.downloads.length, 2);
    expect(prefetcher.queuedCount, 0);
    scope.dispose();
  });

  test('disappearing messages and chats are never prefetched', () async {
    final events = [
      _voice(
        room,
        'timed',
        extra: {
          beeperDisappearingTimerKey: {'type': 'after_read', 'timer': 60000},
        },
      ),
      _voice(room, 'garbled', extra: {beeperDisappearingTimerKey: 'soon'}),
      _voice(
        room,
        'off',
        extra: {beeperDisappearingTimerKey: <String, dynamic>{}},
      ),
    ];
    var scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads, ['mxc://example.invalid/off']);
    scope.dispose();

    // The chat's own setting (mautrix bridgev2 room state) blocks every
    // message in it; a malformed value fails closed.
    for (final content in <Map<String, dynamic>>[
      {'type': 'after_send', 'timer': 3600000},
      {'type': 7},
    ]) {
      final timedRoom = Room(id: '!timed:example.invalid', client: client)
        ..setState(
          StrippedStateEvent(
            type: beeperDisappearingTimerKey,
            content: content,
            senderId: '@bridge:example.invalid',
            stateKey: '',
          ),
        );
      final timed = [_voice(timedRoom, 'in-${content['type']}')];
      scope = prefetcher.attach(roomIds: {timedRoom.id}, events: () => timed);
      scope.noteBuilt(0);
      await _settle();
      expect(ports.downloads, ['mxc://example.invalid/off']);
      expect(ports.authorized, isNot(contains(r'$in-after_send:false')));
      scope.dispose();
    }
  });

  test('production attachment gate denies when none is installed', () async {
    final ports = ClientMediaPrefetchPorts(client);
    final event = _voice(room, 'gate');
    expect(client.authorizeAttachmentAccess, isNull);
    await expectLater(
      ports.authorize(event, false),
      throwsA(isA<MediaPrefetchAborted>()),
    );
    final seen = <String>[];
    client.authorizeAttachmentAccess = (event, thumbnail) async {
      seen.add('${event.eventId}:$thumbnail');
    };
    await ports.authorize(event, true);
    expect(seen, [r'$gate:true']);
  });

  test('backgrounded app does not start work', () async {
    ports.surfaceActive = false;
    final events = [_voice(room, 'bg')];
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads, isEmpty);
    scope.dispose();
  });

  test('setting off means no work at all', () async {
    ports.enabled = false;
    final events = [_voice(room, 'off'), _round(room, 'r-off')];
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    scope.noteBuilt(0);
    await _settle();
    expect(ports.downloads, isEmpty);
    expect(ports.authorized, isEmpty);
    expect(ports.preloadCalls, isEmpty);
    scope.dispose();
  });

  test('Wi-Fi-only policy blocks downloads on other networks', () async {
    ports.network = false;
    final events = [_voice(room, 'cell')];
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads, isEmpty);
    scope.dispose();
  });

  test(
    'rounds need a loaded, unexpired media state; thumbnails first',
    () async {
      final events = [
        _round(room, 'ok', thumbnailSize: 300),
        _round(room, 'expired'),
        _round(room, 'unknown'),
        _round(room, 'huge-thumb', thumbnailSize: 3 * _mb),
      ];
      ports.preloadable
        ..[r'$ok'] =
            null // known absence of reverse state
        ..[r'$expired'] = {'expired': true}
        ..[r'$huge-thumb'] = {'expired': false};
      final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
      await _settle();
      expect(ports.preloadCalls.single.toSet(), {
        r'$ok',
        r'$expired',
        r'$unknown',
        r'$huge-thumb',
      });
      expect(ports.downloads, [
        'mxc://example.invalid/ok-thumb',
        'mxc://example.invalid/ok',
        'mxc://example.invalid/huge-thumb',
      ]);
      expect(
        ports.maxBytes['mxc://example.invalid/ok-thumb'],
        MediaPrefetcher.maxThumbnailBytes,
      );
      scope.dispose();
    },
  );

  test('new arrivals in attached rooms are fetched first', () async {
    final events = <Event>[];
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    final other = Room(id: '!other:example.invalid', client: client);
    client.onTimelineEvent.add(_voice(other, 'elsewhere'));
    client.onTimelineEvent.add(_voice(room, 'arrived'));
    await _settle();
    expect(ports.downloads, ['mxc://example.invalid/arrived']);
    scope.dispose();
  });

  test('oversize download result is not stored', () async {
    ports.returnExtra = MediaPrefetcher.maxItemBytes;
    final events = [_voice(room, 'liar', size: 1000)];
    final scope = prefetcher.attach(roomIds: {room.id}, events: () => events);
    await _settle();
    expect(ports.downloads.length, 1);
    expect(ports.stored, isEmpty);
    scope.dispose();
  });

  group('readBoundedBody', () {
    test('returns ciphertext unchanged', () async {
      final bytes = await readBoundedBody(
        http.StreamedResponse(
          Stream.fromIterable([
            [1, 2],
            [3],
          ]),
          200,
        ),
        maxBytes: 3,
        cancellation: MediaPrefetchCancellation(() => true),
      );
      expect(bytes, [1, 2, 3]);
    });

    test('rejects errors, declared and streamed oversize', () async {
      Future<Uint8List?> read(http.StreamedResponse response) =>
          readBoundedBody(
            response,
            maxBytes: 3,
            cancellation: MediaPrefetchCancellation(() => true),
          );
      expect(await read(http.StreamedResponse(Stream.value([1]), 404)), isNull);
      expect(
        await read(
          http.StreamedResponse(Stream.value([1]), 200, contentLength: 4),
        ),
        isNull,
      );
      expect(
        await read(
          http.StreamedResponse(
            Stream.fromIterable([
              [1, 2],
              [3, 4],
            ]),
            200,
          ),
        ),
        isNull,
      );
    });

    test('cancellation and idle timeout abort the stream', () async {
      final controller = StreamController<List<int>>();
      final cancellation = MediaPrefetchCancellation(() => true);
      final pending = readBoundedBody(
        http.StreamedResponse(controller.stream, 200),
        maxBytes: 10,
        cancellation: cancellation,
      );
      controller.add([1]);
      await _settle();
      cancellation.cancel();
      expect(await pending, isNull);
      await controller.close();

      final stalled = StreamController<List<int>>();
      final idle = MediaPrefetchCancellation(() => true);
      expect(
        await readBoundedBody(
          http.StreamedResponse(stalled.stream, 200),
          maxBytes: 10,
          cancellation: idle,
          idleTimeout: const Duration(milliseconds: 10),
        ),
        isNull,
      );
      expect(idle.valid, isFalse);
      await stalled.close();
    });
  });

  test('production download sends only an authenticated media GET and '
      'stores the ciphertext the SDK would cache', () async {
    final seen = <http.BaseRequest>[];
    final ciphertext = utf8.encode('opaque-ciphertext');
    final database = _Database();
    final networkClient = Client(
      'prefetch network fixture',
      database: database,
      httpClient: MockClient((request) async {
        seen.add(request);
        if (request.url.path == '/_matrix/client/versions') {
          return http.Response(
            jsonEncode({
              'versions': ['v1.11'],
            }),
            200,
          );
        }
        return http.Response.bytes(ciphertext, 200);
      }),
    );
    networkClient
      ..homeserver = Uri.parse('https://hs.example.invalid')
      ..accessToken = 'fixture-token';
    final networkRoom = Room(
      id: '!room:example.invalid',
      client: networkClient,
    );
    final ports = _NetworkPorts(networkClient);
    final networkPrefetcher = MediaPrefetcher.test(networkClient, ports);
    final events = [_voice(networkRoom, 'net', size: ciphertext.length)];
    final scope = networkPrefetcher.attach(
      roomIds: {networkRoom.id},
      events: () => events,
    );
    for (var i = 0; i < 20 && database.stored.isEmpty; i++) {
      await _settle();
    }
    expect(database.files['mxc://example.invalid/net'], ciphertext);
    final media = seen.where((r) => r.url.path.contains('/media/')).single;
    expect(media.method, 'GET');
    expect(
      media.url.path,
      '/_matrix/client/v1/media/download/example.invalid/net',
    );
    expect(media.headers['authorization'], 'Bearer fixture-token');
    expect(
      seen.every(
        (r) =>
            r.method == 'GET' &&
            !r.url.path.contains('/receipt') &&
            !r.url.path.contains('/read_markers') &&
            !r.url.path.contains('/send/'),
      ),
      isTrue,
    );
    scope.dispose();
    MediaPrefetcher.closeFor(networkClient);
  });

  group('play paths', () {
    test('round loader waits for an in-flight prefetch first', () async {
      final event = _round(room, 'await');
      final prefetch = Completer<void>();
      MediaInflight.track(event.attachmentMxcUrl!, prefetch.future);
      var downloads = 0;
      final loader = RoundMediaLoader(
        download:
            (event, {required cacheAttachment, onDownloadProgress}) async {
              downloads++;
              throw const RoundMediaUnavailable('fixture');
            },
      );
      final load = loader.load(event);
      await _settle();
      expect(downloads, 0);
      prefetch.complete();
      await expectLater(load, throwsA(isA<RoundMediaUnavailable>()));
      expect(downloads, 1);
    });

    test('round thumbnails are read from the encrypted cache', () async {
      final database = _Database();
      final cachedClient = Client(
        'thumbnail cache fixture',
        database: database,
        httpClient: MockClient(
          (request) async => throw StateError('thumbnail hit the network'),
        ),
      );
      final cachedRoom = Room(
        id: '!room:example.invalid',
        client: cachedClient,
      );
      final thumbnail = Uint8List.fromList([7, 7, 7]);
      database.files['mxc://example.invalid/cached-thumb'] = thumbnail;
      final bytes = await RoundMediaLoader().thumbnail(
        _round(cachedRoom, 'cached', thumbnailSize: thumbnail.length),
      );
      expect(bytes, thumbnail);
    });
  });
}

class _NetworkPorts extends ClientMediaPrefetchPorts {
  _NetworkPorts(super.client);
  @override
  bool get enabled => true;
  @override
  Future<bool> networkAllowed() async => true;
  @override
  bool get surfaceActive => true;
  @override
  int get surfaceGeneration => 0;
  @override
  Future<void> authorize(Event event, bool thumbnail) async {}
  @override
  Future<bool> isCached(Uri mxc) async =>
      await client.database.getFile(mxc) != null;
}
