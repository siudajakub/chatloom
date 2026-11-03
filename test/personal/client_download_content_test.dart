// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline media fixtures: no account credentials or real network.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  final files = <Uri, Uint8List>{};
  int reads = 0, writes = 0;

  @override
  Future<Uint8List?> getFile(Uri uri) async {
    reads++;
    return files[uri];
  }

  @override
  Future<void> storeFile(Uri uri, Uint8List bytes, int time) async {
    writes++;
    files[uri] = bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client(DatabaseApi database, http.Client transport)
    : super('media fixture', database: database, httpClient: transport) {
    homeserver = Uri.parse('https://example.invalid');
  }

  @override
  Future<bool> authenticatedMediaSupported() =>
      discovery?.future ?? Future.value(true);

  Completer<bool>? discovery;

  String? account = '@fixture:example.invalid';
  DatabaseApi? currentDatabase;

  @override
  String? get userID => account;

  @override
  DatabaseApi get database => currentDatabase ?? super.database;
}

class _HangingTransport extends http.BaseClient {
  int requests = 0, aborts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    if (requests > 1) {
      return Future.value(http.StreamedResponse(Stream.value(_pixel), 200));
    }
    final response = Completer<http.StreamedResponse>();
    final abort = (request as http.AbortableRequest).abortTrigger!;
    unawaited(
      abort.then((_) {
        aborts++;
        response.completeError(http.RequestAbortedException(request.url));
      }),
    );
    return response.future;
  }
}

final _uri = Uri.parse('mxc://example.invalid/photo');
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4nGP4z8DwHwohFABFzAf5Zsv/OQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SDK callback adapter rejects late bytes after an account switch',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final client = _Client(
        _Database(),
        MockClient((_) {
          started.complete();
          return response.future;
        }),
      );
      final abort = Completer<void>();
      final load = client.downloadMediaBytes(
        Uri.parse('https://example.invalid/media'),
        abortTrigger: abort.future,
        cancelled: () => abort.isCompleted,
      );
      final rejected = expectLater(load, throwsStateError);
      await started.future;
      client.account = '@new:example.invalid';
      response.complete(http.Response.bytes(_pixel, 200));
      await rejected;
    },
  );

  test(
    'cold URI discovery has a deadline and never downloads after expiry',
    () async {
      late _Client client;
      var requests = 0;
      fakeAsync((async) {
        client = _Client(
          _Database(),
          MockClient((_) async {
            requests++;
            return http.Response.bytes(_pixel, 200);
          }),
        )..discovery = Completer<bool>();
        Object? failure;
        client
            .downloadMxcCached(_uri)
            .then<void>(
              (_) => fail('cold discovery must time out'),
              onError: (Object error) => failure = error,
            );
        async.flushMicrotasks();
        expect(requests, 0);
        async.elapse(const Duration(seconds: 30));
        expect(failure, isA<TimeoutException>());
        client.discovery!.complete(true);
        async.flushMicrotasks();
        expect(
          requests,
          0,
          reason: 'late discovery cannot start an expired flight',
        );
        expect(async.pendingTimers, isEmpty);
      });
      // Discovery was constructed in the fake zone; use the fixture's known
      // capability for the real async HTTP retry after leaving that zone.
      client.discovery = null;
      expect(await client.downloadMxcCached(_uri), _pixel);
      expect(requests, 1);
    },
  );

  test(
    'a header stall times out, aborts and releases the flight for retry',
    () async {
      final database = _Database();
      final transport = _HangingTransport();
      final client = _Client(database, transport);
      const deadline = Duration(seconds: 30);
      fakeAsync((async) {
        final failures = <Object>[];
        for (var i = 0; i < 2; i++) {
          client
              .downloadMxcCached(_uri, timeout: deadline)
              .then<void>(
                (_) => fail('stalled transfer must time out'),
                onError: failures.add,
              );
        }
        async.flushMicrotasks();
        expect(transport.requests, 1);
        async.elapse(deadline);
        expect(failures, everyElement(isA<TimeoutException>()));
        expect(failures, hasLength(2));
        expect(transport.aborts, 1);
        expect(database.writes, 0);
        expect(async.pendingTimers, isEmpty);
      });
      expect(await client.downloadMxcCached(_uri, timeout: deadline), _pixel);
      expect(transport.requests, 2);
      expect(database.writes, 1);
    },
  );

  test(
    'an account switch on the same Client cannot reuse or store old work',
    () async {
      final oldDatabase = _Database();
      final newDatabase = _Database();
      final oldResponse = Completer<http.Response>();
      final oldStarted = Completer<void>();
      var requests = 0;
      final client = _Client(
        oldDatabase,
        MockClient((_) async {
          requests++;
          if (requests == 1) {
            oldStarted.complete();
            return oldResponse.future;
          }
          return http.Response.bytes([2], 200);
        }),
      );
      final old = client.downloadMxcCached(_uri);
      final oldRejected = expectLater(old, throwsStateError);
      await oldStarted.future;
      client.account = '@new:example.invalid';
      client.currentDatabase = newDatabase;
      final current = client.downloadMxcCached(_uri);
      oldResponse.complete(http.Response.bytes([1], 200));
      await oldRejected;
      expect(await current, [2]);
      expect(requests, 2);
      expect(oldDatabase.writes, 0);
      expect(newDatabase.files[_uri], [2]);
    },
  );

  test(
    'ten concurrent copies share one SQL read, download and store',
    () async {
      final database = _Database();
      final response = Completer<http.Response>();
      var requests = 0;
      final client = _Client(
        database,
        MockClient((_) {
          requests++;
          return response.future;
        }),
      );
      final copies = List.generate(10, (_) => client.downloadMxcCached(_uri));
      response.complete(http.Response.bytes(_pixel, 200));
      for (final bytes in await Future.wait(copies)) {
        expect(bytes, _pixel);
      }
      expect(database.reads, 1);
      expect(requests, 1);
      expect(database.writes, 1);
      await client.downloadMxcCached(_uri);
      expect(database.reads, 2, reason: 'finished work leaves the registry');
      expect(requests, 1);
    },
  );

  test(
    'failed work is shared and released so an explicit retry works',
    () async {
      final database = _Database();
      var requests = 0;
      final client = _Client(
        database,
        MockClient((_) async {
          requests++;
          if (requests == 1) throw http.ClientException('offline fixture');
          return http.Response.bytes(_pixel, 200);
        }),
      );
      final first = client.downloadMxcCached(_uri);
      final second = client.downloadMxcCached(_uri);
      await Future.wait([
        expectLater(first, throwsA(isA<http.ClientException>())),
        expectLater(second, throwsA(isA<http.ClientException>())),
      ]);
      expect(requests, 1);
      expect(await client.downloadMxcCached(_uri), _pixel);
      expect(requests, 2);
    },
  );

  test(
    'account, rendition and storage policy never share in-flight work',
    () async {
      final response = Completer<http.Response>();
      var requests = 0;
      final transport = MockClient((_) {
        requests++;
        return response.future;
      });
      final client = _Client(_Database(), transport);
      final other = _Client(_Database(), transport);
      final copies = [
        client.downloadMxcCached(_uri),
        other.downloadMxcCached(_uri),
        client.downloadMxcCached(_uri, databaseCache: false),
        client.downloadMxcCached(
          _uri,
          isThumbnail: true,
          width: 64,
          height: 64,
          thumbnailMethod: ThumbnailMethod.crop,
        ),
        client.downloadMxcCached(
          _uri,
          isThumbnail: true,
          width: 64,
          height: 64,
          thumbnailMethod: ThumbnailMethod.scale,
        ),
      ];
      response.complete(http.Response.bytes(_pixel, 200));
      await Future.wait(copies);
      expect(requests, 5);
    },
  );

  test(
    'rounding applies on cache hits and never overwrites source bytes',
    () async {
      final database = _Database();
      var requests = 0;
      final client = _Client(
        database,
        MockClient((_) async {
          requests++;
          return http.Response.bytes(_pixel, 200);
        }),
      );
      for (var i = 0; i < 2; i++) {
        final rounded = await client.downloadMxcCached(
          _uri,
          rounded: true,
          width: 32,
          height: 32,
        );
        final codec = await ui.instantiateImageCodec(rounded);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 32);
        expect(frame.image.height, 32);
        frame.image.dispose();
        codec.dispose();
        expect(database.files[_uri], _pixel);
        expect(await client.downloadMxcCached(_uri), _pixel);
      }
      expect(requests, 1);
      expect(database.writes, 1);
    },
  );
}
