// SPDX-License-Identifier: AGPL-3.0-or-later
// Helpers for the idle-frame gate (test/perf/idle_frames_test.dart): the
// five main Notion screens built like test/notion/capture_production_test.dart
// (fictional data, no reference photos, no account), a host that can mute
// tickers or the whole app (NotionActivity), and fake-time probes that count
// the frames an idle screen still asks for and the timers it keeps armed.
import 'dart:async';

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
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void _noop() {}

/// How the host keeps (or stops) animation.
enum IdleMode {
  /// Foreground app: tickers on.
  active,

  /// `TickerMode(enabled: false)` around the app.
  tickersOff,

  /// `NotionActivity` with the app lifecycle set to inactive by the test.
  inactive,
}

/// The capture host: dark theme, phone insets, glass on.
Widget idleHost(Widget child, {IdleMode mode = IdleMode.active}) {
  Widget app = MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('en'),
    theme: NotionTheme.build(Brightness.dark),
    builder: (context, child) {
      Widget body = MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 44, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
        ),
        child: child!,
      );
      if (mode == IdleMode.inactive) body = NotionActivity(child: body);
      return NotionGlassScope(mode: NotionGlassMode.on, child: body);
    },
    home: child,
  );
  if (mode == IdleMode.tickersOff) {
    app = TickerMode(enabled: false, child: app);
  }
  return app;
}

/// The inbox: pinned shortcuts, unread and read rows, the network dock.
Widget idleInbox() {
  const names = ['Anna', 'Michael', 'Team', 'Ola', 'Family', 'Project', 'Kuba'];
  return Scaffold(
    body: NotionInboxPage(
      rows: [
        for (var i = 0; i < names.length; i++)
          NotionInboxRow(
            avatar: NotionInitialAvatar(
              name: names[i],
              size: NotionSize.avatarLg,
            ),
            name: names[i],
            preview: 'Fictional preview $i',
            time: '1$i:00',
            unreadCount: i == 0 ? 2 : 0,
            unread: i == 1,
            onTap: _noop,
          ),
      ],
      pins: [
        for (var i = 0; i < 3; i++)
          NotionPinnedShortcut(
            name: names[i],
            avatar: NotionInitialAvatar(
              name: names[i],
              size: notionPinnedAvatarSize,
            ),
            onTap: _noop,
            order: i,
            unreadCount: i == 1 ? 3 : 0,
          ),
      ],
      onSettings: _noop,
      onSearch: _noop,
      onNetworkSelected: (_) {},
      networks: const ['whatsapp', 'slack', 'messenger', 'instagram'],
    ),
  );
}

/// A conversation with the glass header, bubbles (one with a reply quote),
/// a voice note with the transcribe button and the shipped composer; the
/// merged variant shows source headings and the network chip.
Widget idleConversation({bool merged = false}) => Scaffold(
  extendBodyBehindAppBar: true,
  appBar: AppBar(
    backgroundColor: Colors.transparent,
    flexibleSpace: const NotionGlassBar(),
    leading: NotionIconButton(
      icon: Icons.chevron_left,
      label: 'Back',
      onPressed: _noop,
    ),
    titleSpacing: 0,
    title: NotionCompactChatHeader(
      avatar: const NotionInitialAvatar(name: 'Anna', size: 32),
      name: 'Anna',
      onDetails: _noop,
    ),
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
              for (var i = 0; i < 8; i++)
                _bubble(
                  context,
                  outgoing: i.isOdd,
                  time: '16:4$i',
                  source: merged ? 'WhatsApp' : null,
                  quote: i == 3 ? 'Fictional quoted message' : null,
                  body: Text('Fictional message $i'),
                ),
              _bubble(
                context,
                outgoing: false,
                time: '16:49',
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
              child: CompactComposer(
                input: const TextField(
                  maxLines: 4,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: 'Message…',
                    border: InputBorder.none,
                  ),
                ),
                source: ConversationSourceChip(
                  network: merged ? 'whatsapp' : 'instagram',
                  onPressed: merged ? _noop : null,
                ),
                addAction: const NotionIconButton(
                  icon: Icons.add,
                  label: 'Attach media or a file',
                  onPressed: _noop,
                ),
                fieldAction: const ComposerAction(
                  icon: Icons.sentiment_satisfied_alt_outlined,
                  label: 'Emoji picker',
                  onPressed: _noop,
                ),
                useCompactActionToolbar: true,
                primaryIsRecord: true,
                primaryAction: VoiceRecordButton(
                  hold: VoiceRecordHold(),
                  onStart: () async => false,
                  onSend: () async {},
                  onCancel: _noop,
                ),
                secondaryAction: merged
                    ? null
                    : const NotionIconButton(
                        icon: Icons.videocam_outlined,
                        label: 'Round video',
                        onPressed: _noop,
                      ),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);

Widget _bubble(
  BuildContext context, {
  required bool outgoing,
  required String time,
  required Widget body,
  String? source,
  String? quote,
}) {
  final colors = ConversationBubbleColors.of(context);
  final quoteColors = ConversationReplyQuote.colorsFor(
    side: colors.incoming,
    page: context.notion.colors.background,
    muted: colors.metadata,
  );
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: ConversationBubble(
      outgoing: outgoing,
      avatar: const NotionInitialAvatar(name: 'Anna', size: 28),
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

/// Chat details with shared content, a pending private change and its
/// status line.
Widget idleDetails() => NotionChatDetailsPage(
  data: NotionConversationDetailsData(
    name: 'Anna',
    network: 'WhatsApp',
    avatar: const NotionInitialAvatar(name: 'Anna', size: 64),
    label: 'Private',
    nickname: 'Anna',
    notifications: 'All messages',
    pinned: true,
    incognito: true,
    pending: true,
    status: 'Private changes awaiting synchronization.',
    sharedContent: Row(
      children: [
        NotionSharedContentBlock(
          label: 'Photo',
          thumbnail: const Icon(Icons.image_outlined),
          onTap: _noop,
        ),
        NotionSharedContentBlock(label: '0:18', audio: true, onTap: _noop),
      ],
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

/// The settings root.
Widget idleSettings() => NotionSettingsPage(
  data: const NotionSettingsData(
    name: 'Jan',
    avatar: NotionInitialAvatar(name: 'Jan', size: 44),
    summaries: {
      NotionSettingsCategory.account: 'Profile and sign out',
      NotionSettingsCategory.security: 'Incognito on',
      NotionSettingsCategory.appearance: 'Dark',
      NotionSettingsCategory.advanced: 'Private sync configured',
    },
  ),
  actions: NotionSettingsActions(back: _noop, open: (_) {}),
);

/// Every screen of the gate, by name.
final Map<String, Widget Function()> idleScreens = {
  'inbox': idleInbox,
  'conversation': idleConversation,
  'merged conversation': () => idleConversation(merged: true),
  'chat details': idleDetails,
  'settings': idleSettings,
};

/// Lets fake time pass in [step]s for [total] and draws a frame only when
/// one was asked for (a ticker, a `setState` from a timer or a stream).
/// Returns the moments (from the start) at which a frame was needed.
Future<List<Duration>> idleFrames(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  final frames = <Duration>[];
  for (var t = Duration.zero; t < total; t += step) {
    await tester.binding.delayed(step);
    if (tester.binding.hasScheduledFrame) {
      frames.add(t + step);
      await tester.pump();
    }
  }
  return frames;
}

/// Records the timers created while [run] executes code (widget lifecycles,
/// frame callbacks, the timers' own callbacks), so a test can see which of
/// them are still armed once the screen is idle.
class TimerSpy {
  final _timers =
      <({Timer timer, Duration duration, bool periodic, String origin})>[];

  late final ZoneSpecification _spec = ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      final timer = parent.createTimer(zone, duration, callback);
      _timers.add((
        timer: timer,
        duration: duration,
        periodic: false,
        origin: _origin(),
      ));
      return timer;
    },
    createPeriodicTimer: (self, parent, zone, duration, callback) {
      final timer = parent.createPeriodicTimer(zone, duration, callback);
      _timers.add((
        timer: timer,
        duration: duration,
        periodic: true,
        origin: _origin(),
      ));
      return timer;
    },
  );

  /// Runs [body] with timer recording.
  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneSpecification: _spec);

  /// Timers still armed, described with the app frame that created them.
  List<String> get armed => [
    for (final t in _timers)
      if (t.timer.isActive)
        '${t.periodic ? 'periodic' : 'one-shot'} ${t.duration} at ${t.origin}',
  ];

  /// Periodic timers still armed.
  List<String> get armedPeriodic => [
    for (final line in armed)
      if (line.startsWith('periodic')) line,
  ];

  /// The first app (`package:chatloom`) frame of the current stack, else
  /// the first SDK or plugin frame outside Dart and Flutter.
  static String _origin() {
    final lines = StackTrace.current.toString().split('\n');
    String? fallback;
    for (final line in lines.skip(1)) {
      if (line.contains('idle_support.dart')) continue;
      if (line.contains('package:chatloom/')) return line.trim();
      if (fallback == null &&
          line.startsWith('#') &&
          !line.contains('dart:') &&
          !line.contains('package:flutter/') &&
          !line.contains('package:flutter_test/') &&
          !line.contains('package:fake_async/') &&
          !line.contains('package:stack_trace/')) {
        fallback = line.trim();
      }
    }
    return fallback ?? '(no app frame)';
  }
}
