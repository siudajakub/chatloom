// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/journal_replay_batch.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/utils/bounded_byte_cache.dart';
import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

class _Database implements DatabaseApi {
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  Future<void> deleteOldFiles(int savedAt) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OfflineClient extends Client {
  _OfflineClient() : super('synthetic-offline', database: _Database()) {
    syncErrorMaxTimeoutSec = 60;
  }
  int attempts = 0;
  int? successAt;
  @override
  bool isLogged() => true;
  @override
  String get syncFilterId => 'synthetic-filter';
  @override
  String get prevBatch => 'synthetic-batch';
  @override
  Future<SyncUpdate> sync({
    String? filter,
    String? since,
    bool? fullState,
    PresenceType? setPresence,
    int? timeout,
    bool? useStateAfter,
  }) async {
    attempts++;
    if (attempts == successAt) return SyncUpdate(nextBatch: 'synthetic-batch');
    throw const SocketException('synthetic offline');
  }

  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {}
  @override
  Future<void> processToDeviceQueue() async {}
}

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);

final _widePixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAZAAAADICAYAAADGFbfiAAAC2ElEQVR4nO3VMQ0AMAzAsPInvXLIM1WyEeTLPAAI5ncAADcZCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAYCACJgQCQGAgAiYEAkBgIAImBAJAsGlFm9Hbl+6IAAAAASUVORK5CYII=',
);

class _ImageEvent extends Event {
  _ImageEvent(Room room, String id)
    : super(
        room: room,
        eventId: id,
        type: EventTypes.Message,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
        content: {'msgtype': MessageTypes.Image},
      );
  int requests = 0;
  Uint8List imageBytes = _pixel;
  Future<MatrixFile> Function()? loader;
  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    bool cacheAttachment = true,
    void Function(int)? onDownloadProgress,
  }) {
    requests++;
    return loader?.call() ??
        Future<MatrixFile>.value(
          MatrixImageFile(bytes: imageBytes, name: 'fixture.png'),
        );
  }
}

Widget _image(Event event, {String? cacheKey}) => MaterialApp(
  home: MxcImage(event: event, cacheKey: cacheKey, width: 48, height: 48),
);

void main() {
  test(
    'encoded cache evicts least recently used bytes and bounds entry count',
    () {
      final cache = BoundedByteCache<String>(maxBytes: 5, maxEntries: 2);
      cache.put('a', Uint8List(2));
      cache.put('b', Uint8List(2));
      cache.get('a');
      cache.put('c', Uint8List(2));
      expect(cache.get('b'), isNull);
      expect(cache.get('a'), isNotNull);
      expect(cache.retainedBytes, 4);
      cache.put('a', Uint8List(6));
      expect(cache.get('a'), isNull);
      expect(cache.retainedBytes, 2);
      cache.removeWhere((_) => true);
      expect(cache.retainedBytes, 0);
      expect(cache.length, 0);
    },
  );

  test('automatic sync backs off; push and network wakes bypass its timer', () {
    fakeAsync((clock) {
      final client = _OfflineClient();
      unawaited(client.oneShotSync());
      clock.flushMicrotasks();
      expect(client.attempts, 1);
      clock.elapse(const Duration(seconds: 3));
      expect(client.attempts, 2);
      clock.elapse(const Duration(seconds: 3));
      expect(client.attempts, 2);
      unawaited(wakeSyncOnNetworkRecovery([client], [ConnectivityResult.none]));
      clock.flushMicrotasks();
      expect(client.attempts, 2);
      unawaited(client.oneShotSync(timeout: Duration.zero));
      clock.flushMicrotasks();
      expect(
        client.attempts,
        3,
        reason: 'Push bypasses the offline retry timer',
      );
      unawaited(wakeSyncOnNetworkRecovery([client], [ConnectivityResult.wifi]));
      clock.flushMicrotasks();
      expect(client.attempts, 4, reason: 'Network recovery wakes desktop sync');
      client.backgroundSync = false;
      clock.elapse(const Duration(minutes: 2));
      expect(client.attempts, 4);
      unawaited(client.oneShotSync());
      clock.flushMicrotasks();
      expect(client.attempts, 5, reason: 'Push works with looping disabled');
      unawaited(client.dispose(closeDatabase: false));
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test(
    'automatic retries cap at a minute and SDK defaults retain worker cadence',
    () {
      for (final cap in [3, 60]) {
        fakeAsync((clock) {
          final client = _OfflineClient()..syncErrorMaxTimeoutSec = cap;
          unawaited(client.oneShotSync());
          clock.flushMicrotasks();
          final delays = cap == 3 ? [3, 3, 3] : [3, 6, 12, 24, 48, 60, 60];
          for (final delay in delays) {
            final before = client.attempts;
            clock.elapse(Duration(seconds: delay - 1));
            expect(client.attempts, before);
            clock.elapse(const Duration(seconds: 1));
            expect(client.attempts, before + 1);
          }
          client.backgroundSync = false;
          unawaited(client.dispose(closeDatabase: false));
          clock.flushMicrotasks();
          expect(clock.pendingTimers, isEmpty);
        });
      }
    },
  );

  test('successful automatic sync delivers an update and resets backoff', () {
    fakeAsync((clock) {
      final client = _OfflineClient()..successAt = 3;
      var delivered = 0;
      final subscription = client.onSync.stream.listen((_) => delivered++);
      unawaited(client.oneShotSync());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 3));
      expect(client.attempts, 2);
      clock.elapse(const Duration(seconds: 6));
      expect(client.attempts, 4);
      expect(delivered, 1);
      clock.elapse(const Duration(seconds: 2));
      expect(client.attempts, 4);
      clock.elapse(const Duration(seconds: 1));
      expect(
        client.attempts,
        5,
        reason: 'Success restores the three-second base delay',
      );
      client.backgroundSync = false;
      unawaited(subscription.cancel());
      unawaited(client.dispose(closeDatabase: false));
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test(
    'journal batches keep source order, latest trusted heartbeat and late results',
    () {
      final room = Room(
        id: '!fixture:example.invalid',
        client: Client('batch', database: _Database()),
      );
      Event event(String id, int time, String kind) => Event(
        room: room,
        eventId: id,
        type: personalEventType,
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026).add(Duration(seconds: time)),
        content: Map<String, dynamic>.from(
          PersonalOperation(
            opId: id,
            kind: kind,
            entityId: 'fixture',
            createdAt: DateTime.utc(2026),
            payload: {},
          ).toJson(),
        ),
      );
      final events = [
        event('b', 2, 'draft.result'),
        event('old-heartbeat', 1, 'worker.heartbeat'),
        event('a', 2, 'draft.result'),
        event('heartbeat', 3, 'worker.heartbeat'),
        event('untrusted', 4, 'worker.heartbeat'),
        event('seen', 0, 'draft.result'),
      ];
      final batch = JournalReplayBatch(
        events,
        acceptedEventIds: {'seen'},
        trusted: (e) => e.eventId != 'untrusted',
      );
      expect(batch.results.map((r) => r.$1.eventId), ['a', 'b']);
      expect(batch.heartbeat?.$1.eventId, 'heartbeat');
      events.add(event('late', -1, 'draft.result'));
      expect(
        JournalReplayBatch(
          events,
          acceptedEventIds: {'seen', 'a', 'b'},
          trusted: (e) => e.eventId != 'untrusted',
        ).results.single.$1.eventId,
        'late',
      );
      events.removeWhere((e) => e.eventId == 'heartbeat');
      expect(
        JournalReplayBatch(
          events,
          acceptedEventIds: {},
          trusted: (e) => e.eventId != 'untrusted',
        ).heartbeat?.$1.eventId,
        'old-heartbeat',
      );
    },
  );

  test(
    'live projections stay fresh; render caches expire with their snapshot',
    () {
      final client = Client('projection', database: _Database());
      final personal = PersonalClient.of(client);
      addTearDown(personal.dispose);
      final room = Room(id: '!fixture:example.invalid', client: client);
      final live = InboxProjection(personal);
      personal.values['org:${room.id}'] = {'nickname': 'Before'};
      final snapshot = InboxProjection.snapshot(personal);
      expect(snapshot.displayName(room), 'Before');
      personal.values['org:${room.id}'] = {'nickname': 'After'};
      expect(live.displayName(room), 'After');
      expect(snapshot.displayName(room), 'Before');
      expect(InboxProjection.snapshot(personal).displayName(room), 'After');
    },
  );

  testWidgets('image retries back off and stop in background/dispose', (
    tester,
  ) async {
    final room = Room(
      id: '!fixture:example.invalid',
      client: Client('images', database: _Database()),
    );
    final event = _ImageEvent(room, 'offline')
      ..loader = () async => throw const SocketException('synthetic');
    await tester.pumpWidget(_image(event));
    await tester.pump();
    expect(event.requests, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(event.requests, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(event.requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 2));
    expect(event.requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(event.requests, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
    expect(event.requests, 3);
  });

  testWidgets(
    'thumbnail decoding reduces pixels without stretching the source',
    (tester) async {
      final room = Room(
        id: '!fixture:example.invalid',
        client: Client('aspect-ratio', database: _Database()),
      );
      final event = _ImageEvent(room, 'wide')..imageBytes = _widePixel;
      await tester.pumpWidget(_image(event));
      await tester.pump();
      final image = tester.widget<Image>(find.byType(Image));
      final dimensions = await tester.runAsync(() async {
        final done = Completer<(int, int)>();
        final stream = image.image.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            final size = (info.image.width, info.image.height);
            info.dispose();
            stream.removeListener(listener);
            done.complete(size);
          },
          onError: (Object error, StackTrace? stack) {
            stream.removeListener(listener);
            done.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        return done.future;
      });
      expect(dimensions!.$1, lessThan(400));
      expect(dimensions.$1, dimensions.$2 * 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late image response cannot replace a changed source', (
    tester,
  ) async {
    final room = Room(
      id: '!fixture:example.invalid',
      client: Client('image-switch', database: _Database()),
    );
    final gate = Completer<MatrixFile>();
    final old = _ImageEvent(room, 'old')..loader = () => gate.future;
    final next = _ImageEvent(room, 'next');
    await tester.pumpWidget(_image(old));
    await tester.pump();
    await tester.pumpWidget(_image(next));
    await tester.pump();
    gate.completeError(const SocketException('synthetic stale result'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(old.requests, 1);
    expect(next.requests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
