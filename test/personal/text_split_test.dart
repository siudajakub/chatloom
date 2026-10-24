// SPDX-License-Identifier: AGPL-3.0-or-later
// BR-05: long texts split at natural breaks and sent as consecutive parts
// once the user agrees. Fictional offline fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/input_bar.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/text_split.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

void _expectParts(String text, int limit, List<String> parts) {
  final split = splitLongText(text, limit);
  expect(split, parts);
  for (final part in split) {
    expect(part.length, lessThanOrEqualTo(limit), reason: part);
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('splitLongText', () {
    test('a text that fits is one part', () {
      _expectParts('Short message', 4096, ['Short message']);
      expect(firstTextPartEnd('Short', 5), 5);
    });

    test('paragraphs first, then lines, sentences and words', () {
      final paragraph = '${'a' * 30}\n\n${'b' * 30}';
      _expectParts(paragraph, 40, ['a' * 30, 'b' * 30]);
      final lines = '${'a' * 30}\n${'b' * 30}';
      _expectParts(lines, 40, ['a' * 30, 'b' * 30]);
      _expectParts('One sentence here. Another sentence follows it.', 30, [
        'One sentence here.',
        'Another sentence follows it.',
      ]);
      _expectParts('alpha beta gamma delta epsilon', 12, [
        'alpha beta',
        'gamma delta',
        'epsilon',
      ]);
    });

    test('a 4096 limit (Telegram) keeps every part within it', () {
      final text = List.filled(900, 'Fictional words here.').join(' ');
      final parts = splitLongText(text, 4096);
      expect(parts.length, greaterThan(1));
      for (final part in parts) {
        expect(part.length, lessThanOrEqualTo(4096));
        expect(part.endsWith('.'), isTrue, reason: 'split mid-sentence');
      }
      expect(parts.join(' '), text);
    });

    test('never cuts an emoji or a grapheme in half', () {
      const family = '👨‍👩‍👧';
      final text = List.filled(10, family).join();
      final parts = splitLongText(text, 17);
      expect(parts.join(), text);
      for (final part in parts) {
        expect(part.characters.every((c) => c == family), isTrue);
        expect(part.length, lessThanOrEqualTo(17));
      }
    });

    test('a break inside a code block is avoided when possible', () {
      const text = 'Intro line\n```\ncode one\ncode two\n```\nOutro';
      // The window ends inside the fence: the break before it wins.
      expect(splitLongText(text, 30).first, 'Intro line');
    });

    test('a code block longer than the limit still breaks between lines', () {
      final code = List.filled(8, 'line of code').join('\n');
      final parts = splitLongText('```\n$code\n```', 40);
      for (final part in parts) {
        expect(part.length, lessThanOrEqualTo(40));
        expect(part.contains('line of c\n'), isFalse);
      }
    });

    test('a word longer than the limit is cut', () {
      _expectParts('x' * 25, 10, ['x' * 10, 'x' * 10, 'x' * 5]);
    });
  });

  testWidgets(
    'merged chat: an over-long text is offered as parts and sent in order',
    (tester) async {
      final client = ConversationClient();
      final a = ConversationRoom(
        client,
        '!split-a:example.invalid',
        network: 'telegram',
      );
      final b = ConversationRoom(client, '!split-b:example.invalid');
      a.state(bridgeFeaturesEventType, {
        'id': 'fixture.capabilities',
        'reply': 2,
        'max_text_length': 24,
      }, key: 'fixture');
      a.message(r'$a', 'Earlier message');
      b.message(r'$b', 'Other source', minute: 39);
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      final matrix = ConversationMatrix(
        client,
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: MergedChatPage(
              personal: personal,
              group: PersonGroup(
                id: 'split-person',
                name: 'Anna',
                members: [personal.ref(a), personal.ref(b)],
                defaultRoomId: a.id,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = find.descendant(
        of: find.byType(InputBar),
        matching: find.byType(TextField),
      );
      const text = 'First fictional part. Second fictional part.';
      await tester.enterText(editor, text);
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_button')));
      await tester.pumpAndSettle();
      // Nothing is sent before the user agrees; the draft is untouched.
      expect(personal.sends, isEmpty);
      expect(tester.widget<TextField>(editor).controller!.text, text);
      expect(find.textContaining('allows 24 characters'), findsOneWidget);
      await tester.tap(find.text('Send as 2'));
      await tester.pumpAndSettle();
      expect(personal.sends.map((s) => s.text), [
        'First fictional part.',
        'Second fictional part.',
      ]);
      expect(personal.sends.every((s) => s.room == a), isTrue);
      expect(tester.widget<TextField>(editor).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
