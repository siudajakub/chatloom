// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: a mocked method channel stands in for MediaStorePlugin.kt; no
// device storage, no account data.
import 'dart:io';

import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/media/media_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(MediaStore.channel, null));

  group('collectionFor', () {
    test('photos, stickers and GIFs go to Pictures', () {
      for (final mime in [
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/gif',
      ]) {
        expect(
          MediaStore.collectionFor(mimeType: mime),
          MediaStoreCollection.images,
          reason: mime,
        );
      }
    });

    test('videos (also GIF videos) go to Movies', () {
      expect(
        MediaStore.collectionFor(mimeType: 'video/mp4'),
        MediaStoreCollection.video,
      );
      expect(
        MediaStore.collectionFor(mimeType: 'video/quicktime'),
        MediaStoreCollection.video,
      );
    });

    test('everything else goes to Downloads', () {
      for (final mime in [
        'application/pdf',
        'audio/ogg',
        'application/json',
        'application/octet-stream',
      ]) {
        expect(
          MediaStore.collectionFor(mimeType: mime),
          MediaStoreCollection.downloads,
          reason: mime,
        );
      }
    });

    test('a missing or generic type is sniffed from the name', () {
      expect(
        MediaStore.collectionFor(
          mimeType: 'application/octet-stream',
          name: 'shot.PNG',
        ),
        MediaStoreCollection.images,
      );
      expect(
        MediaStore.collectionFor(mimeType: null, name: 'clip.mp4'),
        MediaStoreCollection.video,
      );
      expect(
        MediaStore.collectionFor(mimeType: '', name: 'notes'),
        MediaStoreCollection.downloads,
      );
    });

    test('labels and confirmations', () {
      expect(MediaStoreCollection.images.actionLabel, 'Save to gallery');
      expect(MediaStoreCollection.video.savedMessage, 'Saved to gallery');
      expect(MediaStoreCollection.downloads.actionLabel, 'Save to Downloads');
      expect(MediaStoreCollection.downloads.savedMessage, 'Saved to Downloads');
      expect(MediaStoreCollection.images.relativePath, 'Pictures/ChatLoom');
      expect(MediaStoreCollection.video.relativePath, 'Movies/ChatLoom');
      expect(MediaStoreCollection.downloads.relativePath, 'Download/ChatLoom');
    });
  });

  group('file names', () {
    test('adds the extension of the type when the name has none', () {
      expect(exportFileName('photo', 'image/jpeg'), 'photo.jpg');
      expect(exportFileName('clip', 'video/mp4'), 'clip.mp4');
      expect(exportFileName('report.pdf', 'application/pdf'), 'report.pdf');
      expect(exportFileName('', 'image/png'), 'file.png');
      expect(exportFileName(null, null), 'file');
    });

    test('keeps only the last path segment and drops unsafe characters', () {
      expect(exportFileName('../../etc/a.png', 'image/png'), 'a.png');
      expect(exportFileName(r'C:\x\b.gif', 'image/gif'), 'b.gif');
      expect(exportFileName('a:b*c?.jpg', 'image/jpeg'), 'a_b_c_.jpg');
    });

    test('lease extensions follow the name', () {
      expect(fileExtension('a.PNG'), '.png');
      expect(fileExtension('a.gif'), '.gif');
      expect(fileExtension('noext'), '.bin');
      expect(fileExtension('weird.ex-t'), '.bin');
    });

    test('macOS save panel opens in the real Downloads', () {
      expect(
        macDownloadsDirectory(
          '/Users/example/Library/Containers/pl.personal.chatloom/Data',
        ),
        '/Users/example/Downloads',
      );
      expect(macDownloadsDirectory('/Users/example'), '/Users/example/Downloads');
      expect(macDownloadsDirectory(null), isNull);
    });
  });

  group('save', () {
    test('sends small files inline and reports the collection', () async {
      MethodCall? call;
      messenger.setMockMethodCallHandler(MediaStore.channel, (c) async {
        call = c;
        return true;
      });
      final bytes = Uint8List.fromList([1, 2, 3]);
      final saved = await MediaStore.save(
        MatrixFile(bytes: bytes, name: 'photo', mimeType: 'image/jpeg'),
      );
      expect(saved, MediaStoreCollection.images);
      expect(call!.method, 'saveToCollection');
      final args = Map<String, Object?>.from(call!.arguments as Map);
      expect(args['displayName'], 'photo.jpg');
      expect(args['mimeType'], 'image/jpeg');
      expect(args['collection'], 'images');
      expect(args['bytes'], bytes);
      expect(args.containsKey('path'), isFalse);
    });

    test('a file goes to Downloads with its own type', () async {
      MethodCall? call;
      messenger.setMockMethodCallHandler(MediaStore.channel, (c) async {
        call = c;
        return true;
      });
      final saved = await MediaStore.save(
        MatrixFile(
          bytes: Uint8List(4),
          name: 'report.pdf',
          mimeType: 'application/pdf',
        ),
      );
      expect(saved, MediaStoreCollection.downloads);
      final args = Map<String, Object?>.from(call!.arguments as Map);
      expect(args['collection'], 'downloads');
      expect(args['mimeType'], 'application/pdf');
      expect(args['displayName'], 'report.pdf');
    });

    test('old Android (false) and a missing plugin fall back', () async {
      messenger.setMockMethodCallHandler(
        MediaStore.channel,
        (_) async => false,
      );
      final file = MatrixFile(
        bytes: Uint8List(1),
        name: 'a.png',
        mimeType: 'image/png',
      );
      expect(await MediaStore.save(file), isNull);
      messenger.setMockMethodCallHandler(MediaStore.channel, null);
      expect(await MediaStore.save(file), isNull);
    });

    test('a native failure surfaces as an error', () async {
      messenger.setMockMethodCallHandler(
        MediaStore.channel,
        (_) async => throw PlatformException(code: 'save_failed'),
      );
      await expectLater(
        MediaStore.save(
          MatrixFile(bytes: Uint8List(1), name: 'a.png', mimeType: 'image/png'),
        ),
        throwsA(isA<PlatformException>()),
      );
    });

    test('large files pass through a private lease that is deleted', () async {
      final temp = await Directory.systemTemp.createTemp('media_store_test');
      addTearDown(() => temp.delete(recursive: true));
      final access = await MediaAccess.open(
        directory: Directory('${temp.path}/personal_media'),
      );
      String? path;
      var existedDuringCall = false;
      messenger.setMockMethodCallHandler(MediaStore.channel, (c) async {
        final args = Map<String, Object?>.from(c.arguments as Map);
        path = args['path'] as String?;
        existedDuringCall = path != null && File(path!).existsSync();
        expect(args.containsKey('bytes'), isFalse);
        return true;
      });
      final bytes = Uint8List(MediaStore.inlineBytesLimit + 1);
      final saved = await MediaStore.save(
        MatrixFile(bytes: bytes, name: 'movie', mimeType: 'video/mp4'),
        lease: (data, extension) => access.create(data, extension: extension),
      );
      expect(saved, MediaStoreCollection.video);
      expect(path, endsWith('.mp4'));
      expect(existedDuringCall, isTrue);
      expect(File(path!).existsSync(), isFalse);
    });
  });
}
