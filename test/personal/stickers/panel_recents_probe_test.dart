// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/stickers/notion_emoji_picker.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('probe emoji recents', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final picked = <String>[];
    Widget picker() => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Scaffold(
        body: SizedBox(
          height: 320,
          child: Builder(
            builder: (context) => EmojiPicker(
              onEmojiSelected: (_, e) => picked.add(e.emoji),
              config: notionEmojiPickerConfig(context),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(picker());
    await tester.pumpAndSettle();
    expect(find.text('Emoji you use show up here.'), findsOneWidget);
    // Second category tab (smileys).
    final tabs = find.byType(Tab);
    debugPrint('tabs: ${tabs.evaluate().length}');
    await tester.tap(tabs.at(1));
    await tester.pumpAndSettle();
    final grin = find.text('😀');
    debugPrint('grin: ${grin.evaluate().length}');
    await tester.tap(grin.first);
    await tester.pumpAndSettle();
    debugPrint('picked $picked');
    await tester.tap(tabs.at(0));
    await tester.pumpAndSettle();
    debugPrint('recents now: ${find.text('😀').evaluate().length} noRecents: ${find.text('Emoji you use show up here.').evaluate().length}');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(picker());
    await tester.pumpAndSettle();
    debugPrint('after reopen: ${find.text('😀').evaluate().length} noRecents: ${find.text('Emoji you use show up here.').evaluate().length}');
  });
}
