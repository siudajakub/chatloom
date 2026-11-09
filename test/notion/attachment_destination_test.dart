// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_attachment_destination.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
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
  for (final brightness in Brightness.values) {
    testWidgets('attachment destination in ${brightness.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(brightness),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('capture'),
              child: NotionGlassBar(
                child: Padding(
                  padding: const EdgeInsets.all(NotionSpace.sm),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConversationAttachmentDestination(
                        network: 'messenger',
                        recipient: 'Alex',
                        onPressed: () {},
                      ),
                      const ConversationAttachmentDestination(
                        network: 'telegram',
                        recipient: 'Alex',
                        replyLocked: true,
                      ),
                      const ConversationAttachmentDestination(
                        network: 'instagram',
                        recipient: 'Alex',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('capture')),
        matchesGoldenFile(
          'goldens/attachment-destination-${brightness.name}.png',
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reply destination explains its lock and cannot change source', (
    tester,
  ) async {
    var selections = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationAttachmentDestination(
            network: 'telegram',
            recipient: 'Alex',
            replyLocked: true,
            onPressed: () => selections++,
          ),
        ),
      ),
    );
    expect(find.text('Reply stays on this network'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    await tester.tap(find.text('Send via Telegram'));
    await tester.pumpAndSettle();
    expect(selections, 0);
    final node = tester.getSemantics(
      find.byType(ConversationAttachmentDestination),
    );
    expect(node.label, 'Send via Telegram, Alex');
    expect(node.hint, 'Reply stays on this network');
    semantics.dispose();
  });

  testWidgets('reduced motion changes the destination without a transition', (
    tester,
  ) async {
    final network = ValueNotifier('messenger');
    addTearDown(network.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: network,
              builder: (context, value, _) => ConversationAttachmentDestination(
                network: value,
                recipient: 'Alex',
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    network.value = 'telegram';
    await tester.pump();
    expect(find.text('Send via Telegram'), findsOneWidget);
    expect(find.text('Send via Messenger'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
