// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/personal/ui/notion_chat_details_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/personal/ui/notion_transcribe_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/layouts/two_column_layout.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _capture = Key('production-capture');
const _screenGoldens = {
  'inbox-390',
  'inbox-390-scrolled',
  'conversation-390',
  'conversation-390-scrolled',
  'merged-430-keyboard-error',
  'chat-details-390',
  'settings-390',
};
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
      borderRadius: NotionRadius.avatarAll,
    );
  }
  return NotionInitialAvatar(name: name, size: size);
}

Widget _referencePhoto(
  Rect crop,
  Size size, {
  BorderRadius borderRadius = NotionRadius.smAll,
}) {
  final scale = math.max(size.width / crop.width, size.height / crop.height);
  return ClipRRect(
    borderRadius: borderRadius,
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
        // Captures show the Impeller look; flutter_tester has no Impeller.
        home: NotionGlassScope(mode: NotionGlassMode.on, child: child),
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
                  avatar: _avatar(names[i], NotionSize.avatarLg),
                  name: names[i],
                  preview: previews[i],
                  time: times[i],
                  unreadCount: i == 0
                      ? 2
                      : i == 2
                      ? 3
                      : 0,
                  // Marked unread by hand: three highlighted rows in a row
                  // show the gap that keeps their highlights apart.
                  unread: i == 1,
                  onTap: _noop,
                ),
            ],
      pins: empty
          ? []
          : [
              NotionPinnedShortcut(
                name: 'Anna',
                avatar: _avatar('Anna', notionPinnedAvatarSize),
                onTap: _noop,
                order: 0,
              ),
              NotionPinnedShortcut(
                name: 'Team',
                avatar: _avatar('Team', notionPinnedAvatarSize),
                onTap: _noop,
                order: 1,
                unreadCount: 3,
                isGroup: true,
              ),
              for (var i = 0; i < extraPins; i++)
                NotionPinnedShortcut(
                  name: 'Pinned $i',
                  avatar: _avatar('Pinned $i', notionPinnedAvatarSize),
                  onTap: _noop,
                  order: i + 2,
                ),
            ],
      onSettings: _noop,
      onSearch: _noop,
      onNetworkSelected: (_) {},
      networks: const ['whatsapp', 'slack', 'messenger', 'instagram'],
    ),
  );
}

// Mirrors ChatView/MergedChatPage chrome: glass header and composer drawn
// over the timeline (DESIGN.md "Glass").
Widget _conversation({bool merged = false, bool error = false}) => Scaffold(
  extendBodyBehindAppBar: true,
  appBar: AppBar(
    backgroundColor: Colors.transparent,
    flexibleSpace: const NotionGlassBar(),
    shape: const Border(bottom: BorderSide(color: NotionTokens.border)),
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
  body: Builder(
    builder: (context) => Stack(
      children: [
        Positioned.fill(
          child: ListView(
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top,
              bottom: 160,
            ),
            children: [
              if (error)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'History could not be loaded. Your loaded messages remain. Retry',
                  ),
                ),
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
                _bubble(
                  context,
                  outgoing: item.$1 == 'You',
                  time: item.$2,
                  source: merged ? 'WhatsApp' : null,
                  quote: item.$2 == '16:43' && item.$1 == 'You'
                      ? 'Hey, coffee tomorrow at 5?'
                      : null,
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
                            return ClipRRect(
                              borderRadius: NotionRadius.lgAll,
                              child: _referencePhoto(
                                const Rect.fromLTWH(203, 834, 448, 260),
                                Size(width, width * 260 / 448),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              _bubble(
                context,
                outgoing: false,
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
                    const NotionTranscribeSplitButton(onTranscribe: _noop),
                  ],
                ),
              ),
              _bubble(
                context,
                outgoing: true,
                time: '16:45',
                body: const Text('Great, see you there!'),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: NotionGlassBar(
            child: SafeArea(
              top: false,
              // The shipped composer, configured like ChatInputRow (ordinary)
              // and the merged chat composer.
              child: CompactComposer(
                input: const TextField(
                  maxLines: 4,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: 'Message…',
                    hintMaxLines: 1,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                  ),
                ),
                source: ConversationSourceChip(
                  network: 'whatsapp',
                  onPressed: merged ? _noop : null,
                ),
                actions: [
                  const ComposerAction(
                    icon: Icons.attach_file_outlined,
                    label: 'Attach media or a file',
                    onPressed: _noop,
                  ),
                  if (!merged)
                    const ComposerAction(
                      icon: Icons.add_reaction_outlined,
                      label: 'Emoji picker',
                      onPressed: _noop,
                    ),
                ],
                primaryAction: merged
                    ? IconButton(
                        icon: const Icon(Icons.mic_none_outlined),
                        tooltip: 'Record in source conversation',
                        onPressed: _noop,
                      )
                    : VoiceRecordButton(
                        hold: VoiceRecordHold(),
                        onStart: () async => false,
                        onSend: () async {},
                        onCancel: _noop,
                      ),
              ),
            ),
          ),
        ),
      ],
    ),
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
    summaries: const {
      NotionSettingsCategory.account: 'Profile and sign out',
      NotionSettingsCategory.security:
          'Incognito on · App lock, devices and recovery',
      NotionSettingsCategory.appearance: 'Dark · Colours and wallpaper',
      NotionSettingsCategory.advanced: 'Private sync configured',
    },
  ),
  actions: NotionSettingsActions(back: _noop, open: (_) {}),
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
  // Screen goldens need the approved reference photos, which only the
  // isolated harness (scripts/verify-notion-ui.py) provides.
  if (_screenGoldens.contains(name) &&
      Platform.environment['NOTION_APPROVED_PHOTOS'] == '1') {
    await expectLater(
      find.byKey(_capture),
      matchesGoldenFile('goldens/screens/$name.png'),
    );
  }
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

/// Moves content under the glass header so captures show the blur.
Future<void> _scrollUnderChrome(WidgetTester tester) async {
  await tester.drag(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .first,
    const Offset(0, -220),
  );
  await tester.pumpAndSettle();
}

/// A production message bubble as `Message` builds it, without the SDK.
Widget _bubble(
  BuildContext context, {
  required bool outgoing,
  required String time,
  required Widget body,
  String? source,
  String? quote,
}) {
  final colors = ConversationBubbleColors.of(context);
  final page = context.notion.colors.background;
  final quoteColors = ConversationReplyQuote.colorsFor(
    side: colors.incoming,
    page: page,
    muted: colors.metadata,
  );
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: ConversationBubble(
      outgoing: outgoing,
      avatar: _avatar('Anna', 28),
      heading: source == null
          ? null
          : Text(
              source,
              style: NotionType.caption.copyWith(color: colors.metadata),
            ),
      quote: quote == null
          ? null
          : ConversationReplyQuote(
              text: quote,
              fill: quoteColors.fill,
              textColor: quoteColors.text,
              outgoing: outgoing,
              caption: ConversationReplyCaption(
                label: 'Replied to Anna',
                color: colors.metadata,
              ),
              onTap: _noop,
            ),
      footer: Text(
        time,
        style: NotionType.micro.copyWith(color: colors.metadata),
      ),
      body: body,
    ),
  );
}

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
  testWidgets('capture production five screens and adaptive states', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host(_inbox()));
    await _save(tester, 'inbox-390');
    await _scrollUnderChrome(tester);
    await _save(tester, 'inbox-390-scrolled', scrollToTop: false);
    await tester.tap(find.text('All networks'));
    await _save(tester, 'network-filter-390');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(_conversation()));
    await _save(tester, 'conversation-390');
    await _scrollUnderChrome(tester);
    await _save(tester, 'conversation-390-scrolled', scrollToTop: false);
    await tester.pumpWidget(_host(_details()));
    await _save(tester, 'chat-details-390');
    await tester.scrollUntilVisible(
      find.text('Incognito'),
      180,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.ensureVisible(find.text('Incognito'));
    await _save(tester, 'chat-details-390-privacy', scrollToTop: false);
    await tester.pumpWidget(_host(_settings()));
    await _save(tester, 'settings-390');
    await tester.scrollUntilVisible(
      find.text('Scheduled messages'),
      180,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.ensureVisible(find.text('Scheduled messages'));
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
          ),
        ),
      );
      await _save(tester, 'split-${width.toInt()}');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
