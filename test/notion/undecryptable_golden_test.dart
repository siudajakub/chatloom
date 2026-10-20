// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden references for undecryptable messages and the inbox encryption
// notice (fictional data). Run and update through scripts/verify-notion-ui.py.
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_grouping.dart';
import 'package:chatloom/pages/chat/events/waiting_message_view.dart';
import 'package:chatloom/pages/chat/undecryptable_chat_hint.dart';
import 'package:chatloom/personal/encryption/key_recovery_stage.dart';
import 'package:chatloom/personal/ui/inbox_health_notice.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _boundary = Key('golden');
void _noop() {}

Future<void> _golden(
  WidgetTester tester,
  String name,
  Widget child, {
  Size size = const Size(390, 760),
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        theme: NotionTheme.build(brightness),
        home: child,
      ),
    ),
  );
  // Fixed frames: in-flight stages spin forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull, reason: name);
  await expectLater(
    find.byKey(_boundary),
    matchesGoldenFile('goldens/screens/$name.png'),
  );
}

Widget _bubble(
  KeyRecoveryStage? stage, {
  bool outgoing = false,
  ConversationGroupPosition position = ConversationGroupPosition.single,
  String? heading,
}) => Builder(
  builder: (context) => ConversationBubble(
    outgoing: outgoing,
    groupPosition: position,
    heading: heading == null
        ? null
        : Text(heading, style: context.notion.typography.captionMuted),
    body: WaitingMessageView(
      stage: stage,
      textColor: ConversationBubbleColors.of(context).text,
      onRetry: _noop,
      onVerify: _noop,
    ),
    footer: Text('09:41', style: context.notion.typography.captionMuted),
  ),
);

Widget _conversation() => Builder(
  builder: (context) => Scaffold(
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: NotionSize.headerHeight,
            child: Padding(
              padding: NotionSpace.page,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Anna Nowak', style: NotionType.headline),
              ),
            ),
          ),
          UndecryptableChatHint(count: 3, onFix: _noop),
          Divider(height: 1, color: context.notion.colors.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: NotionSpace.sm,
                vertical: NotionSpace.xs,
              ),
              children: [
                _bubble(
                  KeyRecoveryStage.backup,
                  position: ConversationGroupPosition.first,
                  heading: 'Anna',
                ),
                _bubble(
                  KeyRecoveryStage.devices,
                  position: ConversationGroupPosition.middle,
                ),
                _bubble(
                  KeyRecoveryStage.failed,
                  position: ConversationGroupPosition.last,
                ),
                _bubble(KeyRecoveryStage.verifySession, outgoing: true),
                _bubble(KeyRecoveryStage.permanent),
              ],
            ),
          ),
        ],
      ),
    ),
  ),
);

const _items = [
  InboxHealthItem(
    icon: Icons.key_outlined,
    title: 'Connect this device to key backup',
    message:
        'Enter your recovery key to unlock older messages and verify this '
        'session.',
    actionLabel: 'Connect',
  ),
  InboxHealthItem(
    icon: Icons.lock_clock_outlined,
    title: '2 chats have messages that couldn’t be decrypted',
    message: 'Ask your key backup and other devices for the keys again.',
    actionLabel: 'Try again',
    tone: NotionCalloutTone.neutral,
  ),
  InboxHealthItem(
    icon: Icons.devices_other_outlined,
    title: '1 of your sessions isn’t verified',
    message: 'Verify the ones you use and sign out of any you don’t recognise.',
    actionLabel: 'Review',
    tone: NotionCalloutTone.neutral,
  ),
];

Widget _inbox() => Scaffold(
  body: SafeArea(
    child: ListView(
      padding: NotionSpace.page,
      children: [
        const SizedBox(height: NotionSpace.xs),
        const Text('Chats', style: NotionType.title),
        InboxHealthNotice(
          items: _items,
          onFix: (_) {},
          onDismiss: _noop,
          onDetails: _noop,
        ),
        const SizedBox(height: NotionSpace.xl),
        const NotionSectionHeader(title: 'Encryption and sync'),
        InboxHealthDetails(items: _items, onFix: (_) {}, busy: 1),
      ],
    ),
  ),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets(
    'waiting for this message: every key stage and the header hint',
    (tester) => _golden(tester, 'undecryptable-390', _conversation()),
  );
  testWidgets(
    'inbox encryption notice and its details',
    (tester) => _golden(
      tester,
      'inbox-health-390',
      _inbox(),
      size: const Size(390, 900),
    ),
  );
}
