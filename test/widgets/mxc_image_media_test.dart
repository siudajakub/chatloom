// SPDX-License-Identifier: AGPL-3.0-or-later
// MxcImage: TGS / Lottie-JSON stickers render (ST-01, ST-14), failures end in
// a static fallback instead of an endless spinner (PF-02).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/lottie_sticker_data.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Media comes from the client's file cache; anything else is not expected.
class _FileDatabase implements DatabaseApi {
  _FileDatabase(this.file);

  Uint8List? Function() file;
  Object? error;

  @override
  int get maxFileSize => 1 << 24;

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async {
    final error = this.error;
    if (error != null) throw error;
    return file();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access ${invocation.memberName}');
}

class _RemoteClient extends Client {
  _RemoteClient(http.Client transport)
    : super(
        'throttled media fixture',
        database: _FileDatabase(() => null),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://example.invalid');
  }

  @override
  Future<bool> authenticatedMediaSupported() {
    discoveryCalls++;
    return discovery?.future ?? Future.value(true);
  }

  Completer<bool>? discovery;
  int discoveryCalls = 0;
}

class _StalledMediaTransport extends http.BaseClient {
  int requests = 0, aborts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    if (requests > 1) {
      return Future.value(
        http.StreamedResponse(
          Stream.value(utf8.encode('{"errcode":"M_NOT_FOUND"}')),
          404,
        ),
      );
    }
    final response = Completer<http.StreamedResponse>();
    unawaited(
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborts++;
        response.completeError(http.RequestAbortedException(request.url));
      }),
    );
    return response.future;
  }
}

class _StatusMediaTransport extends http.BaseClient {
  _StatusMediaTransport(this.status);
  final int status;
  final requests = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"errcode":"M_UNKNOWN"}')),
      status,
    );
  }
}

const _lottie =
    '{"v":"5.5.2","fr":30,"ip":0,"op":30,"w":64,"h":64,"nm":"t",'
    '"ddd":0,"assets":[],"layers":[]}';

Uint8List _tgs() =>
    Uint8List.fromList(GZipEncoder().encodeBytes(utf8.encode(_lottie)));

Event _sticker(Client client, {required String mimetype, int size = 100}) =>
    Event(
      room: Room(id: '!stickers:example.invalid', client: client),
      eventId: r'$sticker',
      senderId: '@fixture:example.invalid',
      type: EventTypes.Sticker,
      originServerTs: DateTime.utc(2026),
      content: {
        'body': 'sticker',
        'url': 'mxc://example.invalid/sticker',
        'info': {'mimetype': mimetype, 'size': size, 'w': 64, 'h': 64},
      },
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool reducedMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: NotionTheme.build(Brightness.dark),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: app!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(MxcImage.clearLottieCache);

  testWidgets(
    'shared event download aborts only after its last widget leaves',
    (tester) async {
      final transport = _StalledMediaTransport();
      final client = _RemoteClient(transport);
      final event = _sticker(client, mimetype: 'image/png');
      Widget image(String key) =>
          MxcImage(key: ValueKey(key), event: event, width: 64, height: 64);
      await _pump(tester, Column(children: [image('first'), image('second')]));
      await tester.pump();
      expect(transport.requests, 1);
      await _pump(tester, Column(children: [image('second')]));
      await tester.pump();
      expect(
        transport.aborts,
        0,
        reason: 'one visible consumer still needs the file',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(transport.aborts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scanner reopen retries once and an old reply cannot remove its flight',
    (tester) async {
      final responses = <Completer<http.Response>>[];
      final client =
          _RemoteClient(
              MockClient((_) {
                final response = Completer<http.Response>();
                responses.add(response);
                return response.future;
              }),
            )
            ..contentScannerConfig = MatrixContentScannerConfig(
              downloadUri: Uri.parse('https://scanner.invalid/download/'),
              downloadThumbnailUri: Uri.parse(
                'https://scanner.invalid/thumbnail/',
              ),
              downloadEncryptedUri: Uri.parse(
                'https://scanner.invalid/download_encrypted',
              ),
            );
      final event = _sticker(client, mimetype: 'image/png');
      Widget images(List<String> keys) => Column(
        children: [
          for (final key in keys)
            MxcImage(key: ValueKey(key), event: event, width: 64, height: 64),
        ],
      );
      await _pump(tester, images(['first']));
      await tester.pump();
      expect(responses, hasLength(1));
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, images(['second']));
      await tester.pump();
      expect(
        responses,
        hasLength(2),
        reason: 'reopening retries the stalled scan',
      );
      responses.first.complete(http.Response('{"errcode":"M_NOT_FOUND"}', 404));
      await tester.pump(const Duration(milliseconds: 1));
      await _pump(tester, images(['second', 'third']));
      await tester.pump();
      expect(
        responses,
        hasLength(2),
        reason: 'old completion preserves the newer shared flight',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      responses.last.complete(http.Response('{"errcode":"M_NOT_FOUND"}', 404));
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SDK event header stall aborts and releases the download for retry',
    (tester) async {
      final transport = _StalledMediaTransport();
      final client = _RemoteClient(transport);
      final states = <MxcImageLoad>[];
      await _pump(
        tester,
        MxcImage(
          event: _sticker(client, mimetype: 'image/png'),
          width: 64,
          height: 64,
          onLoadStateChanged: states.add,
        ),
      );
      await tester.pump();
      expect(transport.requests, 1);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(transport.aborts, 1);
      expect(states, contains(MxcImageLoad.failed));
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(transport.requests, 2);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stalled SDK URI discovery is shared after its UI deadline', (
    tester,
  ) async {
    var requests = 0;
    final client = _RemoteClient(
      MockClient((_) async {
        requests++;
        return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
      }),
    )..discovery = Completer<bool>();
    final states = <MxcImageLoad>[];
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'image/png'),
        width: 64,
        height: 64,
        onLoadStateChanged: states.add,
      ),
    );
    await tester.pump();
    expect(client.discoveryCalls, 1);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(states, contains(MxcImageLoad.failed));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(
      client.discoveryCalls,
      1,
      reason: 'retry shares the stalled SDK work',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    client.discovery!.complete(true);
    await tester.pump();
    expect(
      requests,
      0,
      reason: 'late discovery must not start expired transfer',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scanner deadline keeps SDK path and never duplicates a stalled scan',
    (tester) async {
      final response = Completer<http.Response>();
      final paths = <Uri>[];
      final client =
          _RemoteClient(
              MockClient((request) {
                paths.add(request.url);
                return response.future;
              }),
            )
            ..contentScannerConfig = MatrixContentScannerConfig(
              downloadUri: Uri.parse('https://scanner.invalid/download/'),
              downloadThumbnailUri: Uri.parse(
                'https://scanner.invalid/thumbnail/',
              ),
              downloadEncryptedUri: Uri.parse(
                'https://scanner.invalid/download_encrypted',
              ),
            );
      final states = <MxcImageLoad>[];
      await _pump(
        tester,
        MxcImage(
          event: _sticker(client, mimetype: 'image/png'),
          width: 64,
          height: 64,
          onLoadStateChanged: states.add,
        ),
      );
      await tester.pump();
      expect(paths.single.host, 'scanner.invalid');
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(states, contains(MxcImageLoad.failed));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(paths, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      response.complete(http.Response('{"errcode":"M_NOT_FOUND"}', 404));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final status in [429, 503]) {
    testWidgets('thumbnail $status backs off without fetching the original', (
      tester,
    ) async {
      final transport = _StatusMediaTransport(status);
      final requests = transport.requests;
      final states = <MxcImageLoad>[];
      final client = _RemoteClient(transport);
      await _pump(
        tester,
        MxcImage(
          client: client,
          uri: Uri.parse('mxc://example.invalid/photo'),
          width: 64,
          height: 64,
          onLoadStateChanged: states.add,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      for (
        var frame = 0;
        frame < 10 && !states.contains(MxcImageLoad.failed);
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(states, contains(MxcImageLoad.failed));
      expect(requests, hasLength(1));
      expect(requests.single.path, contains('/thumbnail/'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(requests, hasLength(2));
      expect(requests.last.path, contains('/thumbnail/'));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  group('LottieStickerData', () {
    test('reads TGS and Lottie JSON, nothing else', () {
      expect(LottieStickerData.jsonBytes(_tgs()), isNotNull);
      expect(
        LottieStickerData.jsonBytes(Uint8List.fromList(utf8.encode(_lottie))),
        isNotNull,
      );
      expect(
        LottieStickerData.jsonBytes(
          Uint8List.fromList(utf8.encode('{"name":"not lottie"}')),
        ),
        isNull,
      );
      // A PNG signature.
      expect(
        LottieStickerData.jsonBytes(
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]),
        ),
        isNull,
      );
      expect(LottieStickerData.parse(_tgs()), isNotNull);
      expect(LottieStickerData.isLottieMime('application/x-tgsticker'), isTrue);
      expect(LottieStickerData.isLottieMime('image/webp'), isFalse);
    });

    test('the composition cache is bounded', () {
      final cache = LottieCompositionCache<int>(capacity: 2);
      final composition = LottieStickerData.parse(_tgs())!;
      for (var i = 0; i < 5; i++) {
        cache.put(i, composition);
      }
      expect(cache.length, 2);
      expect(cache.get(0), isNull);
      expect(cache.get(4), same(composition));
    });
  });

  testWidgets('a TGS sticker renders as Lottie, not a spinner', (tester) async {
    final client = Client('tgs', database: _FileDatabase(_tgs));
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'application/x-tgsticker'),
        width: 128,
        height: 128,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Lottie), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a Lottie JSON sticker renders; reduced motion is still', (
    tester,
  ) async {
    final json = Uint8List.fromList(utf8.encode(_lottie));
    final client = Client('json', database: _FileDatabase(() => json));
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'video/lottie+json'),
        width: 128,
        height: 128,
      ),
      reducedMotion: true,
    );
    await tester.pump();
    await tester.pump();
    final lottie = tester.widget<Lottie>(find.byType(Lottie));
    expect(lottie.animate, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('unavailable media ends in a static fallback', (tester) async {
    final database = _FileDatabase(() => null)
      ..error = MatrixException.fromJson({'errcode': 'M_NOT_FOUND'});
    final client = Client('missing', database: database);
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'image/webp'),
        width: 128,
        height: 128,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('unsupported bytes end in a static fallback', (tester) async {
    final client = Client(
      'unsupported',
      database: _FileDatabase(() => Uint8List.fromList(List.filled(64, 7))),
    );
    await _pump(
      tester,
      MxcImage(
        event: _sticker(client, mimetype: 'application/octet-stream'),
        width: 128,
        height: 128,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
