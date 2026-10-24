// SPDX-License-Identifier: AGPL-3.0-or-later
// A reply quote's thumbnail comes from the memory cache when the quote is
// mounted again (BP-05): no second read of the attachment store.
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/reply_content.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

class _FileDatabase implements DatabaseApi {
  int reads = 0;

  @override
  int get maxFileSize => 1 << 24;

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async {
    reads++;
    return _png;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('fixture must not access ${invocation.memberName}');
}

void main() {
  testWidgets('remounting a reply quote does not reload its thumbnail', (
    tester,
  ) async {
    final database = _FileDatabase();
    final client = Client('reply', database: database);
    final event = Event(
      room: Room(id: '!reply:example.invalid', client: client),
      eventId: r'$photo',
      senderId: '@fixture:example.invalid',
      type: EventTypes.Message,
      originServerTs: DateTime.utc(2026),
      content: {
        'msgtype': MessageTypes.Image,
        'body': 'photo.png',
        'url': 'mxc://example.invalid/photo',
        'info': {'mimetype': 'image/png', 'size': _png.length, 'w': 1, 'h': 1},
      },
    );
    Widget app(bool shown) => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: shown
            ? ReplyContent(
                event,
                fill: Colors.transparent,
                textColor: Colors.transparent,
              )
            : const SizedBox(),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(app(true));
    await settle();
    expect(find.byType(ReplyContent), findsOneWidget);
    expect(find.byType(MxcImage), findsOneWidget);
    final first = database.reads;
    expect(first, greaterThan(0));

    await tester.pumpWidget(app(false));
    await tester.pumpWidget(app(true));
    await settle();
    expect(database.reads, first);
  });
}
