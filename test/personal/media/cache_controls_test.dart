// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatloom/pages/settings_chat/settings_storage_view.dart';
import 'package:chatloom/personal/media/cache_budget.dart';
import 'package:chatloom/personal/media/cache_controls.dart';
import 'package:chatloom/personal/media/protected_matrix_database.dart';
import 'package:chatloom/personal/media/video_file_cache.dart';
import 'package:chatloom/personal/stickers/sticker_media_cache.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PreviewControls extends MediaCacheControls {
  _PreviewControls() : super(databases: []);
  final values = {
    MediaCacheCategory.media: 24 * 1024 * 1024,
    MediaCacheCategory.video: 128 * 1024 * 1024,
    MediaCacheCategory.avatar: 3 * 1024 * 1024,
    MediaCacheCategory.sticker: 14 * 1024 * 1024,
  };
  @override
  Future<MediaCacheUsage> usage() async =>
      MediaCacheUsage(values, outgoingBytes: 120 * 1024);
  @override
  Future<void> clear(MediaCacheCategory category) async {
    values[category] = 0;
  }

  @override
  Future<void> applyBudget(MediaCacheBudget budget) => budget.save();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
    }
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'unknown and missing limits keep existing standard allowances',
    () async {
      expect(MediaCacheBudget.parse(null), MediaCacheBudget.standard);
      expect(MediaCacheBudget.parse('unexpected'), MediaCacheBudget.standard);
      expect(MediaCacheBudget.standard.singleAccountMiB, 992);
      expect(MediaCacheBudget.compact.singleAccountMiB, 256);
      await MediaCacheBudget.compact.save();
      expect(await MediaCacheBudget.read(), MediaCacheBudget.compact);
    },
  );

  test(
    'usage and selective clear preserve pending files and account data',
    () async {
      final root = await Directory.systemTemp.createTemp('cache-controls-');
      final factory = createDatabaseFactoryFfi(noIsolate: true);
      final raw = await factory.openDatabase(
        '${root.path}/fixture.sqlite',
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute(
            "PRAGMA key = '${base64UrlEncode(List<int>.filled(32, 11))}'",
          ),
        ),
      );
      final database = ProtectedMatrixDatabase(
        'fixture',
        database: raw,
        factory: factory,
      );
      try {
        await database.open();
        await raw.execute('CREATE TABLE account_fixture (value TEXT)');
        await raw.insert('account_fixture', {
          'value': 'history and keys fixture',
        });
        final pending = Uri.parse('cache://file/pending-fixture');
        final photo = Uri.parse('mxc://fixture/photo');
        await database.storeFile(pending, Uint8List(120), 0);
        await database.storeFile(photo, Uint8List(300), 0);
        final video = await VideoFileCache.open(
          Directory('${root.path}/video'),
        );
        final avatar = await StickerMediaCache.open(
          Directory('${root.path}/avatar'),
          key: List.filled(32, 7),
        );
        final sticker = await StickerMediaCache.open(
          Directory('${root.path}/sticker'),
          key: List.filled(32, 8),
        );
        final key = 'a' * 64;
        await video.write(key, Uint8List(500), reel: true);
        await avatar.write(key, Uint8List(100));
        await sticker.write(key, Uint8List(200));
        final controls = MediaCacheControls(
          databases: [database, database],
          video: () async => video,
          avatar: () async => avatar,
          sticker: () async => sticker,
        );
        final usage = await controls.usage();
        expect(usage.complete, isTrue);
        expect(
          usage.bytes[MediaCacheCategory.media],
          300,
          reason: 'same account is counted once',
        );
        expect(usage.outgoingBytes, 120);
        expect(usage.bytes[MediaCacheCategory.video], 500);
        expect(
          usage.bytes[MediaCacheCategory.avatar],
          132,
          reason: 'includes AES-GCM header and tag',
        );
        expect(usage.bytes[MediaCacheCategory.sticker], 232);
        final generation = database.mediaCacheGeneration;
        await controls.clear(MediaCacheCategory.media);
        expect(database.mediaCacheGeneration, generation + 1);
        expect(await database.getFile(pending), hasLength(120));
        expect(await database.getFile(photo), isNull);
        expect(
          (await raw.query('account_fixture')).single['value'],
          'history and keys fixture',
        );
        expect(await avatar.read(key), hasLength(100));
        await controls.clear(MediaCacheCategory.video);
        expect(await video.read(key, reel: true), isNull);
        expect(await sticker.read(key), hasLength(200));
        await controls.applyBudget(MediaCacheBudget.compact);
        expect(video.maxBytes, MediaCacheBudget.compact.videoBytes);
        expect(avatar.maxBytes, MediaCacheBudget.compact.avatarBytes);
        expect(sticker.maxBytes, MediaCacheBudget.compact.stickerBytes);
        expect(await MediaCacheBudget.read(), MediaCacheBudget.compact);
      } finally {
        await raw.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('missing file caches stay unknown instead of reporting zero', () async {
    final controls = MediaCacheControls(
      databases: [],
      video: () async => null,
      avatar: () async => null,
      sticker: () async => null,
    );
    final usage = await controls.usage();
    expect(usage.complete, isFalse);
    expect(usage.bytes[MediaCacheCategory.video], isNull);
    await expectLater(
      controls.clear(MediaCacheCategory.video),
      throwsStateError,
    );
  });

  testWidgets('storage controls fit narrow screens at large text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SettingsStoragePage(
            controls: MediaCacheControls(
              databases: [],
              video: () async => null,
              avatar: () async => null,
              sticker: () async => null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Storage & cache'), findsOneWidget);
    expect(find.text('Known cache usage'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in [
    (
      name: 'storage-narrow-large-text',
      width: 320.0,
      scale: 2.0,
      brightness: Brightness.dark,
    ),
    (
      name: 'storage-dark',
      width: 390.0,
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      name: 'storage-light',
      width: 390.0,
      scale: 1.0,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets('storage controls synthetic capture ${scenario.name}', (
      tester,
    ) async {
      tester.view.physicalSize = Size(scenario.width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controls = _PreviewControls();
      const boundaryKey = ValueKey('storage-capture-boundary');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: NotionTheme.build(scenario.brightness),
            home: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(scenario.scale),
              ),
              child: SettingsStoragePage(controls: controls),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      Future<void> capture(String suffix) async {
        final output = Platform.environment['NOTION_CAPTURE_DIR'];
        if (output == null) return;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File(
              '$output/${scenario.name}$suffix.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      await capture('');
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -2400),
      );
      await tester.pump(const Duration(seconds: 1));
      await capture('-scrolled');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
