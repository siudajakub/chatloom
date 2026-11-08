// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic pixels and transport only; no account or real network.
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4nGP4z8DwHwohFABFzAf5Zsv/OQAAAABJRU5ErkJggg==',
);

class _Database implements DatabaseApi {
  final files = <Uri, Uint8List>{};
  @override
  int get maxFileSize => 10 * 1000 * 1000;
  @override
  Future<Uint8List?> getFile(Uri uri) async => files[uri];
  @override
  Future<void> storeFile(Uri uri, Uint8List bytes, int time) async {
    files[uri] = bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected storage');
}

class _Client extends Client {
  _Client(_Database database, http.Client transport)
    : super(
        'image data saver fixture',
        database: database,
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://example.invalid');
  }
  @override
  Future<bool> authenticatedMediaSupported() async => true;
}

Event _event(Client client, {int? size, bool thumbnail = false}) => Event(
  room: Room(id: '!fixture:example.invalid', client: client),
  eventId: r'$image',
  type: EventTypes.Message,
  senderId: '@fixture:example.invalid',
  originServerTs: DateTime.utc(2026),
  content: {
    'msgtype': MessageTypes.Image,
    'body': 'fixture.png',
    'url': 'mxc://example.invalid/image',
    'info': {
      'mimetype': 'image/png',
      'size': ?size,
      if (thumbnail) 'thumbnail_url': 'mxc://example.invalid/thumbnail',
      if (thumbnail)
        'thumbnail_info': {'size': _pixel.length, 'mimetype': 'image/png'},
    },
  },
);

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(body: Center(child: child)),
);

Future<void> _settleNetwork(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(pumpEventQueue);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() async => AppSettings.personalDataSaver.setItem(true));

  for (final size in [null, 4 * 1024 * 1024]) {
    testWidgets('original size $size waits for tap, then loads once', (
      tester,
    ) async {
      var requests = 0;
      final client = _Client(
        _Database(),
        MockClient((_) async {
          requests++;
          return http.Response.bytes(_pixel, 200);
        }),
      );
      final event = _event(client, size: size);
      await tester.pumpWidget(
        _app(MxcImage(event: event, width: 250, height: 200)),
      );
      await _settleNetwork(tester);
      expect(requests, 0);
      expect(find.text('Load image'), findsOneWidget);
      await tester.tap(find.text('Load image'));
      await _settleNetwork(tester);
      expect(requests, 1);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Load image'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('cached original remains instant in data saver', (tester) async {
    var requests = 0;
    final database = _Database()
      ..files[Uri.parse('mxc://example.invalid/image')] = (Uint8List(
        4 * 1024 * 1024,
      )..setRange(0, _pixel.length, _pixel));
    final client = _Client(
      database,
      MockClient((_) async {
        requests++;
        return http.Response.bytes(_pixel, 200);
      }),
    );
    await tester.pumpWidget(
      _app(
        MxcImage(event: _event(client, size: 4000000), width: 250, height: 200),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Load image'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small original and thumbnail keep automatic previews', (
    tester,
  ) async {
    for (final thumbnail in [false, true]) {
      var requests = 0;
      final client = _Client(
        _Database(),
        MockClient((_) async {
          requests++;
          return http.Response.bytes(_pixel, 200);
        }),
      );
      await tester.pumpWidget(
        _app(
          MxcImage(
            event: _event(
              client,
              size: thumbnail ? 4000000 : _pixel.length,
              thumbnail: thumbnail,
            ),
            width: 250,
            height: 200,
          ),
        ),
      );
      await _settleNetwork(tester);
      expect(requests, 1);
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('neighboring URI preview widths share a server rendition', (
    tester,
  ) async {
    final uris = <Uri>[];
    final client = _Client(
      _Database(),
      MockClient((request) async {
        uris.add(request.url);
        return http.Response.bytes(_pixel, 200);
      }),
    );
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            for (final width in [101.0, 102.0])
              MxcImage(
                uri: Uri.parse('mxc://example.invalid/image'),
                client: client,
                width: width,
                height: 50,
              ),
          ],
        ),
      ),
    );
    await _settleNetwork(tester);
    expect(uris, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unknown encrypted URI preview does not fetch original', (
    tester,
  ) async {
    var requests = 0;
    final client = _Client(
      _Database(),
      MockClient((_) async {
        requests++;
        return http.Response.bytes(_pixel, 200);
      }),
    );
    await tester.pumpWidget(
      _app(
        MxcImage(
          uri: Uri.parse('mxc://example.invalid/encrypted'),
          encryption: const {},
          client: client,
          width: 250,
          height: 200,
        ),
      ),
    );
    await _settleNetwork(tester);
    expect(requests, 0);
    expect(find.text('Load image'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('oversized thumbnail also waits for explicit transfer', (
    tester,
  ) async {
    var requests = 0;
    final oversized = Uint8List(4 * 1024 * 1024)
      ..setRange(0, _pixel.length, _pixel);
    final database = _Database();
    final client = _Client(
      database,
      MockClient((_) async {
        requests++;
        return http.Response.bytes(oversized, 200);
      }),
    );
    await tester.pumpWidget(
      _app(
        MxcImage(
          event: _event(client, size: 5000000, thumbnail: true),
          width: 250,
          height: 200,
        ),
      ),
    );
    await _settleNetwork(tester);
    expect(requests, 1);
    expect(database.files, isEmpty);
    expect(find.text('Load image'), findsOneWidget);
    await tester.tap(find.text('Load image'));
    await _settleNetwork(tester);
    expect(requests, 2);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small quote and large text deferred previews do not overflow', (
    tester,
  ) async {
    final client = _Client(
      _Database(),
      MockClient((_) async => throw StateError('No download')),
    );
    for (final size in [34.0, 180.0]) {
      await tester.pumpWidget(
        _app(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: MxcImage(event: _event(client), width: size, height: size),
          ),
        ),
      );
      await _settleNetwork(tester);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
