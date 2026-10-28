// SPDX-License-Identifier: AGPL-3.0-or-later
// Settings › Stickers › Your sticker pack (wave 11): pick, upload with a
// failure kept for retry, list. Fake picker, upload and account data.
import 'dart:typed_data';

import 'package:chatloom/personal/stickers/own_sticker_pack.dart';
import 'package:chatloom/personal/stickers/own_sticker_pack_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../notion/conversation_test_support.dart';
import 'sticker_test_support.dart';

class _Backend implements OwnPackBackend {
  Map<String, Object?>? content;
  int uploads = 0;

  @override
  (String, Map<String, Object?>?) read() =>
      (unstableUserImagePackType, content);

  @override
  Future<void> write(String type, Map<String, Object?> content) async =>
      this.content = content;

  @override
  Future<Uri> upload(Uint8List bytes, String filename, String mimetype) async =>
      Uri.parse('mxc://example.invalid/${++uploads}');
}

Uint8List _png(int seed) {
  final image = img.Image(width: 32, height: 32);
  img.fill(image, color: img.ColorRgb8(seed, 10, 10));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  testWidgets('empty → pick → upload; a bad file stays with its reason', (
    tester,
  ) async {
    final backend = _Backend();
    final library = fakeLibrary(FakeStickerBackend());
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: OwnStickerPackPage(
            client: ConversationClient(),
            library: library,
            editor: OwnStickerPackEditor(backend, retryDelay: Duration.zero),
            picker: (_) async => [
              OwnStickerInput(bytes: _png(1), name: 'wave.png'),
              OwnStickerInput(
                bytes: Uint8List.fromList([1, 2]),
                name: 'notes.txt',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Make your own stickers'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('own-pack-choose')));
    await tester.pumpAndSettle();
    expect(find.text('2 new images'), findsOneWidget);
    expect(find.text('Add 2 stickers'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('own-pack-upload')));
    await tester.pumpAndSettle();
    expect(backend.uploads, 1);
    expect(find.text('1 new image'), findsOneWidget);
    expect(find.text('Use a PNG, WebP, GIF or JPEG image.'), findsOneWidget);
    expect(find.text('1 sticker'), findsOneWidget);
    expect(find.text(OwnStickerPackEditor.defaultName), findsOneWidget);
    expect(find.byType(NotionListRow), findsWidgets);
  });
}
