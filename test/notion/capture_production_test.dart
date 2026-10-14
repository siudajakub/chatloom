// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:fluffychat/personal/ui/notion_inbox_page.dart';
import 'package:fluffychat/personal/ui/notion_inbox_pins.dart';
import 'package:fluffychat/personal/ui/notion_inbox_row.dart';
import 'package:fluffychat/personal/ui/notion_settings_page.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/ui/notion/notion_theme.dart';
import 'package:fluffychat/widgets/layouts/two_column_layout.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _capture = Key('production-capture');
void _noop() {}
// Only the isolated visual test package contains the already-approved fictional
// portrait/photo reference. These pixels never seed the application or an account.
Widget _avatar(String name, [double size = 40]) {
  if (Platform.environment['NOTION_APPROVED_PHOTOS'] == '1' &&
      ['Anna', 'You', 'Jan'].contains(name)) {
    return _referencePhoto(
      name == 'Anna'
          ? const Rect.fromLTWH(101, 284, 68, 70)
          : const Rect.fromLTWH(102, 399, 67, 70),
      Size.square(size),
    );
  }
  return NotionInitialAvatar(name: name, size: size);
}

Widget _referencePhoto(Rect crop, Size size) {
  final scale = math.max(size.width / crop.width, size.height / crop.height);
  return ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: SizedBox.fromSize(
      size: size,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: -crop.left * scale,
            top: -crop.top * scale,
            width: 887 * scale,
            height: 1774 * scale,
            child: Image.asset('assets/reference/chat.png', fit: BoxFit.fill),
          ),
        ],
      ),
    ),
  );
}

Widget _host(Widget child, {double scale = 1, double keyboard = 0}) =>
    RepaintBoundary(
      key: _capture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        theme: NotionTheme.build(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            padding: const EdgeInsets.only(top: 44, bottom: 34),
            viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: child,
      ),
    );

Widget _inbox({bool empty = false, int extraPins = 0}) {
  const names = ['Anna', 'Michael', 'Team', 'Ola', 'Family', 'Project', 'Kuba'];
  const previews = [
    'Coffee tomorrow at 5?',
    'I’ll send the files tonight.',
    'Meeting tomorrow at 10:00',
    'Sent a photo',
    'Mom: Have a lovely day',
    'The new version is ready',
    'Thanks for your help!',
  ];
  const times = [
    '16:45',
    '15:20',
    '14:08',
    '12:31',
    '10:12',
    '09:40',
    'Yesterday',
  ];
  return Scaffold(
    body: NotionInboxPage(
      rows: empty
          ? []
          : [
              for (var i = 0; i < names.length; i++)
                NotionInboxRow(
                  avatar: _avatar(names[i]),
                  name: names[i],
                  preview: previews[i],
                  time: times[i],
                  unreadCount: i == 0
                      ? 2
                      : i == 2
                      ? 3
                      : 0,
                  onTap: _noop,
                ),
            ],
      pins: empty
          ? []
          : [
              NotionPinnedShortcut(
                name: 'Anna',
                avatar: _avatar('Anna', 28),
                onTap: _noop,
                order: 0,
              ),
              NotionPinnedShortcut(
                name: 'Team',
                avatar: _avatar('Team', 28),
                onTap: _noop,
                order: 1,
                isGroup: true,
              ),
              for (var i = 0; i < extraPins; i++)
                NotionPinnedShortcut(
                  name: 'Pinned $i',
                  avatar: _avatar('Pinned $i', 28),
                  onTap: _noop,
                  order: i + 2,
                ),
            ],
      onCompose: _noop,
      onSettings: _noop,
      onSearch: _noop,
      onNetworkSelected: (_) {},
      networks: const ['whatsapp', 'slack', 'messenger', 'instagram'],
    ),
  );
}

Widget _conversation({bool merged = false, bool error = false}) => Scaffold(
  appBar: AppBar(
    leading: NotionIconButton(
      icon: Icons.chevron_left,
      label: 'Back',
      onPressed: _noop,
    ),
    titleSpacing: 0,
    title: NotionCompactChatHeader(
      avatar: _avatar('Anna', 32),
      name: 'Anna',
      onDetails: _noop,
    ),
    actions: [
      NotionIconButton(
        icon: Icons.more_horiz,
        label: 'Conversation options',
        onPressed: _noop,
      ),
    ],
  ),
  body: Column(
    children: [
      Divider(height: 1, color: NotionTokens.border),
      if (error)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'History could not be loaded. Your loaded messages remain. Retry',
          ),
        ),
      Expanded(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'Today',
                style: TextStyle(fontSize: 13, color: NotionTokens.secondary),
              ),
            ),
            for (final item in const [
              ('Anna', '16:40', 'Are you free tomorrow?'),
              ('You', '16:41', 'Yes, after work.'),
              ('Anna', '16:42', 'Hey, coffee tomorrow at 5?'),
              ('You', '16:43', 'Sure. At the same café?'),
              ('Anna', '16:43', 'Yes, I’ll send you the location.'),
            ])
              NotionAuthoredMessageRow(
                avatar: _avatar(item.$1, 36),
                author: item.$1,
                time: item.$2,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.$3),
                    if (item.$2 == '16:43' &&
                        item.$1 == 'Anna' &&
                        Platform.environment['NOTION_APPROVED_PHOTOS'] ==
                            '1') ...[
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final width = math.min(constraints.maxWidth, 240.0);
                          return _referencePhoto(
                            const Rect.fromLTWH(203, 834, 448, 260),
                            Size(width, width * 260 / 448),
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Photo',
                        style: TextStyle(
                          fontSize: 12,
                          color: NotionTokens.secondary,
                        ),
                      ),
                    ],
                  ],
                ),
                source: merged ? 'WhatsApp' : null,
              ),
            NotionAuthoredMessageRow(
              avatar: _avatar('Anna', 36),
              author: 'Anna',
              time: '16:44',
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NotionAudioFileBlock(
                    duration: '0:18',
                    progress: .05,
                    onPlay: _noop,
                    onSeek: (_) {},
                    onDownload: _noop,
                  ),
                  const NotionTranscribeAction(onPressed: _noop),
                ],
              ),
            ),
            NotionAuthoredMessageRow(
              avatar: _avatar('You', 36),
              author: 'You',
              time: '16:45',
              body: const Text('Great, see you there!'),
            ),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: NotionComposer(
            input: const TextField(
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                hintText: 'Write a message…',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
              ),
            ),
            actions: [
              NotionIconButton(
                icon: Icons.attach_file,
                label: 'Attach a file',
                onPressed: _noop,
              ),
              NotionIconButton(
                icon: Icons.mic_none_outlined,
                label: 'Record voice message',
                onPressed: _noop,
              ),
            ],
            source: const Text(
              'WhatsApp',
              style: TextStyle(fontSize: 12, color: NotionTokens.secondary),
            ),
            sendAction: const NotionSendButton(),
          ),
        ),
      ),
    ],
  ),
);

Widget _details({
  bool pending = false,
  String notifications = 'All messages',
}) => NotionChatDetailsPage(
  data: NotionConversationDetailsData(
    name: 'Anna',
    network: 'WhatsApp',
    avatar: _avatar('Anna', 64),
    label: 'Private',
    nickname: 'Anna',
    notifications: notifications,
    pinned: true,
    incognito: true,
    pending: pending,
    status: pending ? 'Private changes awaiting synchronization.' : null,
    sharedContent: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          NotionSharedContentBlock(
            label: 'Photo',
            thumbnail: Platform.environment['NOTION_APPROVED_PHOTOS'] == '1'
                ? _referencePhoto(
                    const Rect.fromLTWH(203, 834, 448, 260),
                    const Size(144, 92),
                  )
                : const Icon(Icons.image_outlined),
            onTap: _noop,
          ),
          const SizedBox(width: 6),
          NotionSharedContentBlock(label: 'notes.pdf', onTap: _noop),
          const SizedBox(width: 6),
          NotionSharedContentBlock(label: '0:18', audio: true, onTap: _noop),
        ],
      ),
    ),
  ),
  actions: NotionConversationDetailsActions(
    search: _noop,
    mute: _noop,
    notifications: _noop,
    pin: (_) {},
    privacy: _noop,
    appearance: _noop,
    nickname: _noop,
    media: _noop,
    archive: _noop,
    contact: _noop,
    overflow: _noop,
  ),
);

Widget _settings() => NotionSettingsPage(
  data: NotionSettingsData(
    name: 'Jan',
    avatar: _avatar('Jan', 44),
    incognito: true,
    appLock: 'On',
    appearance: 'Dark',
    privateSync: 'Configured · awaiting worker',
  ),
  actions: NotionSettingsActions(
    back: _noop,
    overflow: _noop,
    editProfile: _noop,
    appLock: _noop,
    devices: _noop,
    notifications: _noop,
    appearance: _noop,
    transcriptions: _noop,
    privateSync: _noop,
    about: _noop,
    incognito: (_) {},
  ),
);

Future<void> _save(
  WidgetTester tester,
  String name, {
  bool scrollToTop = true,
}) async {
  await tester.pumpAndSettle();
  if (Platform.environment['NOTION_APPROVED_PHOTOS'] == '1') {
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/reference/chat.png'),
        tester.element(find.byKey(_capture)),
      ),
    );
    await tester.pumpAndSettle();
  }
  if (scrollToTop) {
    for (final state in tester.stateList<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    )) {
      if (state.position.hasContentDimensions) state.position.jumpTo(0);
    }
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull, reason: name);
  final directory = Platform.environment['NOTION_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  testWidgets('capture production five screens and adaptive states', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host(_inbox()));
    await _save(tester, 'inbox-390');
    await tester.tap(find.text('All chats'));
    await _save(tester, 'network-filter-390');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(_conversation()));
    await _save(tester, 'conversation-390');
    await tester.pumpWidget(_host(_details()));
    await _save(tester, 'chat-details-390');
    await tester.scrollUntilVisible(
      find.text('Incognito mode'),
      180,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.ensureVisible(find.text('Incognito mode'));
    await _save(tester, 'chat-details-390-privacy', scrollToTop: false);
    await tester.pumpWidget(_host(_settings()));
    await _save(tester, 'settings-390');
    await tester.scrollUntilVisible(
      find.text('About'),
      180,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.ensureVisible(find.text('About'));
    await _save(tester, 'settings-390-preferences', scrollToTop: false);
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpWidget(_host(_inbox(extraPins: 6), scale: 2));
    await _save(tester, 'inbox-320-large-text');
    await tester.pumpWidget(
      _host(_details(pending: true, notifications: 'Mentions only'), scale: 2),
    );
    await _save(tester, 'details-320-large-text-pending');
    tester.view.physicalSize = const Size(430, 932);
    await tester.pumpWidget(
      _host(_conversation(merged: true, error: true), keyboard: 300),
    );
    await _save(tester, 'merged-430-keyboard-error');
    await tester.pumpWidget(_host(_inbox(empty: true)));
    await _save(tester, 'inbox-430-empty');
    await tester.pumpWidget(_host(_settings(), scale: 2));
    await _save(tester, 'settings-430-large-text');
    for (final width in [360.0, 412.0]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpWidget(_host(_inbox()));
      await _save(tester, 'inbox-${width.toInt()}');
    }
    for (final width in [900.0, 1200.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        _host(
          TwoColumnLayout(
            mainView: _inbox(),
            sideView: _conversation(merged: true),
            hasNavigationRail: false,
          ),
        ),
      );
      await _save(tester, 'split-${width.toInt()}');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
