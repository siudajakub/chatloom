// SPDX-License-Identifier: AGPL-3.0-or-later
// The account's own sticker pack from the user's images (wave 11): checks,
// uploads with retries, duplicates, partial failure, cancel and edits.
// Fake upload and account data; synthetic images only.
import 'dart:typed_data';

import 'package:chatloom/personal/stickers/own_sticker_pack.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_pack_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

import 'sticker_test_support.dart';

class _Backend implements OwnPackBackend {
  String type = unstableUserImagePackType;
  Map<String, Object?>? content;
  final uploads = <String>[];
  final writes = <Map<String, Object?>>[];
  int failUploads = 0;
  bool failWrites = false;

  @override
  (String, Map<String, Object?>?) read() => (type, content);

  @override
  Future<void> write(String type, Map<String, Object?> content) async {
    if (failWrites) throw Exception('offline');
    this.type = type;
    this.content = content;
    writes.add(content);
  }

  @override
  Future<Uri> upload(Uint8List bytes, String filename, String mimetype) async {
    if (failUploads > 0) {
      failUploads--;
      throw Exception('offline');
    }
    uploads.add(filename);
    return Uri.parse('mxc://example.invalid/${uploads.length}');
  }
}

Uint8List _png(int seed, {int size = 64}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(seed % 255, 40, 200));
  return Uint8List.fromList(img.encodePng(image));
}

OwnStickerInput _input(int seed, {String? name, String? emoji}) =>
    OwnStickerInput(
      bytes: _png(seed),
      name: name ?? 'Cat $seed.png',
      emoji: emoji,
    );

void main() {
  late _Backend backend;
  late OwnStickerPackEditor editor;
  setUp(() {
    backend = _Backend();
    editor = OwnStickerPackEditor(backend, retryDelay: Duration.zero);
  });

  test('creates the pack from images in one write', () async {
    final progress = <(int, int)>[];
    final result = await editor.add(
      [_input(1, emoji: '😺'), _input(2)],
      packName: 'Fictional cats',
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(result.added, 2);
    expect(result.failed, isEmpty);
    expect(backend.writes, hasLength(1));
    expect(editor.name, 'Fictional cats');
    final images = editor.images;
    expect(images.map((e) => e.$1), ['cat_1', 'cat_2']);
    final first = images.first.$2;
    expect(first['body'], '😺');
    expect(first['usage'], ['sticker']);
    final info = first['info'] as Map;
    expect(info['mimetype'], 'image/png');
    expect(info['w'], 64);
    expect(info[ownStickerHashKey], isA<String>());
    expect(images.last.$2['body'], 'Cat 2', reason: 'no emoji: the name');
    expect(progress.last, (2, 2));
    // A pack the library reads as the account's own stickers.
    final pack = StickerPack.fromContent(
      ImagePackContent.fromJson(backend.content!),
      key: 'user|',
      source: StickerPackSource.user,
    );
    expect(pack.stickers, hasLength(2));
    expect(pack.title, 'Fictional cats');
  });

  test('skips duplicates and reports bad files; keeps the rest', () async {
    await editor.add([_input(1)]);
    final result = await editor.add([
      _input(1, name: 'again.png'),
      OwnStickerInput(bytes: Uint8List.fromList([1, 2, 3]), name: 'notes.txt'),
      OwnStickerInput(bytes: Uint8List(0), name: 'empty.png'),
      OwnStickerInput(
        bytes: Uint8List(OwnStickerPackEditor.maxBytes + 1),
        name: 'huge.png',
      ),
      _input(3),
    ]);
    expect(result.duplicates, 1);
    expect(result.added, 1);
    expect(result.failed.map((f) => f.$1.name), [
      'notes.txt',
      'empty.png',
      'huge.png',
    ]);
    expect(result.failed.first.$2, 'Use a PNG, WebP, GIF or JPEG image.');
    expect(result.failed.last.$2, 'Stickers can be up to 2 MB.');
    expect(editor.images, hasLength(2));
    expect(backend.uploads, hasLength(2));
  });

  test(
    'retries an upload, then reports it; other images still go in',
    () async {
      backend.failUploads = 2;
      var result = await editor.add([_input(1)]);
      expect(result.added, 1, reason: 'third attempt worked');
      backend.failUploads = OwnStickerPackEditor.uploadAttempts;
      result = await editor.add([_input(2), _input(3)]);
      expect(result.added, 1);
      expect(result.failed.single.$1.name, 'Cat 2.png');
      expect(result.failed.single.$2, contains('Upload failed'));
      expect(editor.images.map((e) => e.$1), ['cat_1', 'cat_3']);
    },
  );

  test(
    'cancel stops before the next upload and keeps what was uploaded',
    () async {
      final result = await editor.add([
        _input(1),
        _input(2),
        _input(3),
      ], cancelled: () => backend.uploads.isNotEmpty);
      expect(result.cancelled, isTrue);
      expect(result.added, 1);
      expect(editor.images, hasLength(1));
    },
  );

  test('edits re-read the newest pack and merge', () async {
    await editor.add([_input(1), _input(2), _input(3)]);
    // Another device added one meanwhile.
    final images = Map<String, Object?>.of(
      backend.content!['images'] as Map<String, Object?>,
    );
    images['remote'] = {'url': 'mxc://example.invalid/remote', 'body': '🌍'};
    backend.content = {...backend.content!, 'images': images};

    await editor.reorder(['cat_3', 'cat_1']);
    expect(editor.images.map((e) => e.$1), [
      'cat_3',
      'cat_1',
      'cat_2',
      'remote',
    ]);
    await editor.setEmoji('cat_2', '🐱');
    expect(editor.images[2].$2['body'], '🐱');
    final removed = editor.images.first.$2;
    final order = [for (final (key, _) in editor.images) key];
    await editor.remove(['cat_3']);
    expect(editor.images.map((e) => e.$1), ['cat_1', 'cat_2', 'remote']);
    await editor.restore('cat_3', removed, order: order);
    expect(editor.images.map((e) => e.$1), [
      'cat_3',
      'cat_1',
      'cat_2',
      'remote',
    ]);
    await editor.rename('  ');
    expect(editor.name, OwnStickerPackEditor.defaultName);
  });

  test('a failed write is a sentence and changes nothing', () async {
    await editor.add([_input(1)]);
    backend.failWrites = true;
    await expectLater(
      editor.remove(['cat_1']),
      throwsA(
        isA<StickerImportException>().having(
          (e) => e.message,
          'message',
          contains('couldn’t be saved'),
        ),
      ),
    );
    expect(editor.images, hasLength(1));
  });

  test('keeps the type the account already uses', () async {
    backend.type = userImagePackType;
    backend.content = {
      'images': <String, Object?>{},
      'pack': {'display_name': 'Older pack'},
    };
    await editor.add([_input(1)], packName: null);
    expect(backend.type, userImagePackType);
    expect(editor.name, 'Older pack');
  });

  test('the library shows the own pack after a refresh', () async {
    final fake = FakeStickerBackend();
    final library = fakeLibrary(fake);
    addTearDown(library.dispose);
    var notified = 0;
    library.addListener(() => notified++);
    expect(library.packs, isEmpty);
    await editor.add([_input(1)]);
    fake.user = ImagePackContent.fromJson(backend.content!);
    expect(library.packs, isEmpty, reason: 'cached until told');
    library.refresh();
    expect(notified, 1);
    expect(library.packs.single.source, StickerPackSource.user);
  });
}
