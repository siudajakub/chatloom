// SPDX-License-Identifier: AGPL-3.0-or-later
// Small robustness and cost guards from review R12, R18, R20, R22 and R24.
// Fictional offline fixtures only.
import 'dart:async';
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/utils/flutter_error_routing.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/cover_resize_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

void main() {
  group('framework errors', () {
    FlutterErrorDetails details({required bool silent}) => FlutterErrorDetails(
      exception: StateError('fictional codec failure'),
      stack: StackTrace.empty,
      library: 'image resource service',
      silent: silent,
    );

    test('silent errors are logged, never reported to the dialog', () {
      final reported = <Object>[];
      routeFlutterError(details(silent: true), (e, _) => reported.add(e));
      expect(reported, isEmpty);
    });

    test('other errors still reach the reporter with their stack', () {
      final reported = <(Object, StackTrace)>[];
      final error = details(silent: false);
      routeFlutterError(error, (e, s) => reported.add((e, s)));
      expect(reported.single.$1, same(error.exception));
      expect(reported.single.$2, same(StackTrace.empty));
    });
  });

  group('url launcher', () {
    test('punycode encodes unicode labels and keeps ASCII hosts', () {
      expect(UrlLauncher.punycodeHost('example.invalid'), 'example.invalid');
      // Hosts arrive percent-encoded from Uri.parse.
      expect(
        UrlLauncher.punycodeHost(Uri.parse('https://bücher.example').host),
        'xn--bcher-kva.example',
      );
    });

    test('a malformed percent escape falls back to the raw host', () {
      expect(UrlLauncher.punycodeHost('a%E2.example'), 'a%E2.example');
      expect(UrlLauncher.punycodeHost('%zz.example'), '%zz.example');
    });

    testWidgets('an empty link shows a notice instead of throwing', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final url in ['', '   ']) {
        await UrlLauncher(context, url).launchUrl();
        await tester.pump();
        expect(find.byType(SnackBar), findsOneWidget);
        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('blur hash placeholder', () {
    setUp(BlurHash.clearCache);
    tearDown(() => BlurHash.decoder = BlurHash.decodeInline);

    testWidgets('decodes once across mounts and shows a cached one at once', (
      tester,
    ) async {
      var decodes = 0;
      BlurHash.decoder = (data) {
        decodes++;
        return BlurHash.decodeInline(data);
      };
      Future<void> show(bool visible) => tester.pumpWidget(
        MaterialApp(
          home: visible
              ? const BlurHash(width: 64, height: 32)
              : const SizedBox(),
        ),
      );
      await show(true);
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await show(false);
        await show(true);
        // Already decoded: the image is there on the first frame.
        expect(find.byType(Image), findsOneWidget);
      }
      expect(decodes, 1);
      expect(BlurHash.cachedCount, 1);
    });

    testWidgets('the cache is bounded and drops failed decodes', (
      tester,
    ) async {
      BlurHash.decoder = (_) => Future.error(StateError('fictional'));
      await tester.pumpWidget(
        const MaterialApp(home: BlurHash(width: 10, height: 10)),
      );
      await tester.pump();
      expect(BlurHash.cachedCount, 0);
      BlurHash.decoder = (_) => Completer<Uint8List>().future;
      for (var i = 0; i < 80; i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: BlurHash(blurhash: 'fixture-$i', width: 10, height: 10),
          ),
        );
      }
      expect(BlurHash.cachedCount, lessThanOrEqualTo(64));
    });
  });

  group('cover decode size', () {
    test('covers the box with the aspect ratio kept, never upscaling', () {
      // Landscape photo on a portrait phone: height decides.
      final landscape = CoverResizeImage.coverSize(4000, 3000, 1080, 2400);
      expect(landscape.height, 2400);
      expect(landscape.width, 3200);
      // Tall image: width decides.
      final tall = CoverResizeImage.coverSize(1000, 8000, 500, 1000);
      expect(tall.width, 500);
      expect(tall.height, 4000);
      // Smaller than the box: decoded as is.
      final small = CoverResizeImage.coverSize(300, 200, 1080, 2400);
      expect((small.width, small.height), (null, null));
    });
  });

  group('bookmarks refresh', () {
    test('only timeline changes and left rooms invalidate saved messages', () {
      final quiet = SyncUpdate.fromJson({
        'next_batch': 'fixture',
        'rooms': {
          'join': {
            '!receipts:example.invalid': {
              'ephemeral': {
                'events': [
                  {
                    'type': 'm.typing',
                    'content': {'user_ids': <String>[]},
                  },
                ],
              },
              'timeline': {'events': <Object>[]},
            },
          },
        },
      });
      expect(bookmarkRoomsChangedBy(quiet), isEmpty);
      final changed = SyncUpdate.fromJson({
        'next_batch': 'fixture',
        'rooms': {
          'join': {
            '!edited:example.invalid': {
              'timeline': {
                'events': [
                  {
                    'type': 'm.room.redaction',
                    'event_id': r'$fixture-redaction',
                    'sender': '@anna:example.invalid',
                    'origin_server_ts': 0,
                    'redacts': r'$fixture-saved',
                    'content': <String, Object?>{},
                  },
                ],
              },
            },
          },
          'leave': {'!left:example.invalid': <String, Object?>{}},
        },
      });
      expect(bookmarkRoomsChangedBy(changed), {
        '!edited:example.invalid',
        '!left:example.invalid',
      });
    });
  });
}
