// SPDX-License-Identifier: AGPL-3.0-or-later
// README media: frame sequences of the app's own widgets (inbox page and
// dock, swipe actions, the merged conversation page with its real message
// rows, long-press menu, composer and sticker panel, the Appearance page and
// the privacy settings) driven through real gestures and real animation
// timelines.
//
// Everything shown is fictional: offline fixtures, made-up people and
// messages, a photo and stickers drawn in code. No account, network or
// storage is touched.
//
//   README_CAPTURE_DIR=/abs/dir flutter test test/readme/readme_capture_test.dart
//   python3 scripts/readme/make-media.py --frames /abs/dir
//
// Without README_CAPTURE_DIR the scenes still run (a smoke test of the
// choreography) but nothing is written. See docs/readme/README.md.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/compact_composer.dart';
import 'package:chatloom/pages/settings_style/settings_style.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/stickers/sticker_library.dart';
import 'package:chatloom/personal/stickers/sticker_media_cache.dart';
import 'package:chatloom/personal/stickers/sticker_models.dart';
import 'package:chatloom/personal/stickers/sticker_panel.dart';
import 'package:chatloom/personal/stickers/sticker_tab.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/personal/ui/notion_privacy_preferences.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';
import '../personal/stickers/sticker_test_support.dart';

/// One recorded frame step (25 fps; GIF delays are whole centiseconds).
const _frame = Duration(milliseconds: 40);

/// Phone viewport in logical pixels (Pixel 7/8 class).
const _phoneSize = Size(412, 915);

/// Captures are rendered at this pixel ratio, then scaled down by the
/// assembler, so text and glyph edges stay smooth.
const double _pixelRatio = 2;

final String? _out = Platform.environment['README_CAPTURE_DIR'];

const _screen = Key('readme-screen');

/// Emoji fall back to a colour emoji font when the machine has one.
const _emojiFamily = 'Noto Color Emoji';
const _emojiFonts = [
  '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
  '/usr/share/fonts/noto/NotoColorEmoji.ttf',
  '/System/Library/Fonts/Apple Color Emoji.ttc',
];
bool _emojiLoaded = false;

// ---------------------------------------------------------------------------
// Recording

/// Where a finger touches the glass, drawn over the screen so a viewer can
/// follow the gesture. Null: no finger.
final _finger = ValueNotifier<({Offset at, bool down})?>(null);

/// A frame sequence of one scene. Identical consecutive frames are merged
/// into one longer frame, so holds cost nothing.
class _Reel {
  _Reel(this.tester, this.name);

  final WidgetTester tester;
  final String name;
  final frames = <Map<String, Object>>[];
  Uint8List? _last;

  /// Named frames (the hero image picks settled states by name).
  final marks = <String, int>{};

  void mark(String name) => marks[name] = frames.length - 1;

  Future<void> shot([Duration length = _frame]) async {
    final out = _out;
    if (out == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_screen),
    );
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: _pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final last = _last;
    if (last != null && listEquals(last, bytes)) {
      frames.last['ms'] = (frames.last['ms']! as int) + length.inMilliseconds;
      return;
    }
    final file = '$name/${frames.length.toString().padLeft(4, '0')}.png';
    await tester.runAsync(() async {
      final target = File('$out/$file');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes!);
    });
    frames.add({'file': file, 'ms': length.inMilliseconds});
    _last = bytes;
  }

  /// Runs the clock for [length] in frame steps, recording every frame.
  Future<void> play(Duration length) async {
    for (var t = Duration.zero; t < length; t += _frame) {
      await tester.pump(_frame);
      await shot();
    }
  }

  /// Lets every animation finish, then shows the result for [length].
  Future<void> hold(Duration length) async {
    await tester.pumpAndSettle(_frame);
    await shot(length);
  }

  /// A tap with a visible finger: down for a few frames, then up.
  Future<void> tap(Finder target, {int down = 3, Offset? at}) async {
    final point = at ?? tester.getCenter(target.first);
    _finger.value = (at: point, down: true);
    final gesture = await tester.startGesture(point);
    for (var i = 0; i < down; i++) {
      await tester.pump(_frame);
      await shot();
    }
    await gesture.up();
    _finger.value = (at: point, down: false);
    await tester.pump(_frame);
    await shot();
    _finger.value = null;
  }

  /// Two quick taps (inside the double-tap window).
  Future<void> doubleTap(Finder target) async {
    final point = tester.getCenter(target.first);
    for (var i = 0; i < 2; i++) {
      _finger.value = (at: point, down: true);
      final gesture = await tester.startGesture(point);
      await tester.pump(_frame);
      await shot();
      await gesture.up();
      _finger.value = (at: point, down: false);
      await tester.pump(_frame);
      await shot();
    }
    _finger.value = null;
  }

  /// A long press held for [held] (past the recogniser's timeout) and
  /// released, recording the whole time.
  Future<void> longPress(
    Finder target, {
    Duration held = const Duration(milliseconds: 900),
  }) async {
    final at = tester.getCenter(target.first);
    _finger.value = (at: at, down: true);
    final gesture = await tester.startGesture(at);
    for (var t = Duration.zero; t < held; t += _frame) {
      await tester.pump(_frame);
      await shot();
    }
    await gesture.up();
    _finger.value = null;
    await tester.pump(_frame);
    await shot();
  }

  /// A horizontal swipe from [from] by [by] over [steps] frames (eased),
  /// then release.
  Future<void> swipe(Offset from, Offset by, {int steps = 12}) async {
    _finger.value = (at: from, down: true);
    final gesture = await tester.startGesture(from);
    await tester.pump(_frame);
    await shot();
    for (var i = 1; i <= steps; i++) {
      final t = Curves.easeOutCubic.transform(i / steps);
      final at = from + by * t;
      await gesture.moveTo(at);
      _finger.value = (at: at, down: true);
      await tester.pump(_frame);
      await shot();
    }
    await tester.pump(_frame);
    await shot();
    await gesture.up();
    _finger.value = null;
  }

  /// Types [text] into [field] one character per [perChar] frames.
  Future<void> type(Finder field, String text, {int perChar = 2}) async {
    final runes = text.runes.toList();
    for (var i = 1; i <= runes.length; i++) {
      await tester.enterText(field, String.fromCharCodes(runes.take(i)));
      for (var f = 0; f < perChar; f++) {
        await tester.pump(_frame);
        await shot();
      }
    }
  }

  Future<void> save() async {
    final out = _out;
    if (out == null) return;
    await tester.runAsync(
      () => File('$out/$name.json').writeAsString(
        const JsonEncoder.withIndent(' ').convert({
          'scene': name,
          'width': _phoneSize.width * _pixelRatio,
          'height': _phoneSize.height * _pixelRatio,
          'frames': frames,
          'marks': marks,
        }),
      ),
    );
  }
}

/// Image decoding runs on the engine's threads; give it real time.
Future<void> _settleImages(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }
}

// ---------------------------------------------------------------------------
// Device chrome around the app: status bar, home indicator, finger.

Widget _phone(Widget app) => RepaintBoundary(
  key: _screen,
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      children: [
        Positioned.fill(child: app),
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder(
              valueListenable: _finger,
              builder: (context, touch, _) =>
                  CustomPaint(painter: _FingerPainter(touch)),
            ),
          ),
        ),
      ],
    ),
  ),
);

/// Status bar and home indicator in the theme's ink.
class _DeviceChrome extends StatelessWidget {
  const _DeviceChrome({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 44,
          child: IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 12, 26, 0),
              child: Row(
                children: [
                  Text(
                    '9:41',
                    style: TextStyle(
                      fontFamily: 'Roboto',
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: ink,
                      height: 1.2,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.signal_cellular_alt, size: 17, color: ink),
                  const SizedBox(width: 5),
                  Icon(Icons.wifi, size: 17, color: ink),
                  const SizedBox(width: 5),
                  Transform.rotate(
                    angle: math.pi / 2,
                    child: Icon(Icons.battery_full, size: 19, color: ink),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 8,
          child: IgnorePointer(
            child: Center(
              child: Container(
                width: 134,
                height: 5,
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: .5),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FingerPainter extends CustomPainter {
  _FingerPainter(this.touch);
  final ({Offset at, bool down})? touch;

  @override
  void paint(Canvas canvas, Size size) {
    final t = touch;
    if (t == null) return;
    final radius = t.down ? 21.0 : 25.0;
    canvas.drawCircle(
      t.at,
      radius,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: t.down ? .3 : .14),
    );
    canvas.drawCircle(
      t.at,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF9A9A9A).withValues(alpha: t.down ? .8 : .4),
    );
  }

  @override
  bool shouldRepaint(_FingerPainter old) => old.touch != touch;
}

// ---------------------------------------------------------------------------
// App host

/// The app's theme (`ChatLoomThemes.buildTheme`) plus the emoji fallback
/// the test renderer needs (it has no system font fallback).
ThemeData _theme(
  Brightness brightness, [
  NotionAppearance appearance = NotionAppearance.standard,
  NotionDisplayPreferences display = NotionDisplayPreferences.standard,
]) {
  final base = NotionTheme.build(brightness, appearance, display.trueBlack);
  final fallback = _emojiLoaded ? const [_emojiFamily] : null;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: fallback),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamilyFallback: fallback,
    ),
    extensions: [...base.extensions.values, display],
  );
}

Widget _materialApp({
  required Widget home,
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeMode themeMode = ThemeMode.dark,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('en'),
  supportedLocales: const [Locale('en')],
  localizationsDelegates: L10n.localizationsDelegates,
  theme: theme ?? _theme(Brightness.light),
  darkTheme: darkTheme ?? _theme(Brightness.dark),
  themeMode: themeMode,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      padding: const EdgeInsets.only(top: 44, bottom: 34),
      viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
    ),
    // Impeller's look: flutter_tester has no Impeller, glass is forced on
    // (as in the production capture goldens).
    child: NotionGlassScope(
      mode: NotionGlassMode.on,
      child: _DeviceChrome(child: child!),
    ),
  ),
  home: home,
);

Future<void> _mount(
  WidgetTester tester,
  Widget app, {
  required Client client,
  required SharedPreferences preferences,
}) async {
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: ConversationMatrix(client, preferences),
      child: _phone(app),
    ),
  );
}

// ---------------------------------------------------------------------------
// Inbox

void _noop() {}

typedef _Chat = ({
  String id,
  String name,
  String preview,
  String time,
  int unread,
  List<String> networks,
  bool mentioned,
  bool muted,
  NotionDeliveryState? delivery,
});

_Chat _chat(
  String id,
  String name,
  String preview,
  String time, {
  int unread = 0,
  List<String> networks = const ['whatsapp'],
  bool mentioned = false,
  bool muted = false,
  NotionDeliveryState? delivery,
}) => (
  id: id,
  name: name,
  preview: preview,
  time: time,
  unread: unread,
  networks: networks,
  mentioned: mentioned,
  muted: muted,
  delivery: delivery,
);

final _chats = <_Chat>[
  _chat(
    'maya',
    'Maya',
    'Bring chalk, I forgot mine last time',
    '9:35',
    unread: 2,
    networks: ['whatsapp', 'telegram'],
  ),
  _chat(
    'crew',
    'Climbing crew',
    'Leo: Who’s in for Saturday? 🧗',
    '9:12',
    unread: 5,
    networks: ['telegram'],
    mentioned: true,
  ),
  _chat(
    'priya',
    'Priya',
    'Voice message · 0:24',
    '8:47',
    unread: 1,
    networks: ['signal'],
  ),
  _chat(
    'design',
    'Design team',
    'Sam: New mockups are up',
    '8:20',
    unread: 3,
    networks: ['slack'],
    muted: true,
  ),
  _chat(
    'noah',
    'Noah',
    'Thanks, got it!',
    '7:55',
    networks: ['messenger'],
    delivery: NotionDeliveryState.read,
  ),
  _chat(
    'elena',
    'Elena',
    'Loved your story ✨',
    'Yesterday',
    unread: 1,
    networks: ['instagram'],
  ),
  _chat(
    'leo',
    'Leo',
    'Round video · 0:18',
    'Yesterday',
    networks: ['telegram'],
  ),
  _chat(
    'dad',
    'Dad',
    'Call me when you land ❤️',
    'Yesterday',
    networks: ['whatsapp'],
  ),
  _chat(
    'alex',
    'Alex',
    'Photo',
    'Tue',
    networks: ['telegram'],
    delivery: NotionDeliveryState.delivered,
  ),
  _chat(
    'book',
    'Book club',
    'Next pick: The Overstory',
    'Mon',
    networks: ['whatsapp'],
  ),
  _chat(
    'trip',
    'Lisbon trip',
    'Ines: Flights are booked ✈️',
    'Sun',
    networks: ['telegram'],
  ),
  _chat(
    'jordan',
    'Jordan',
    'Haha that reel 😂',
    'Sun',
    networks: ['instagram'],
  ),
];

class _InboxDemo extends StatefulWidget {
  const _InboxDemo();

  @override
  State<_InboxDemo> createState() => _InboxDemoState();
}

class _InboxDemoState extends State<_InboxDemo> {
  String? network;
  var view = InboxFilter.inbox;
  final archived = <String>{};
  final read = <String>{};

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final chat in _chats)
        if (!archived.contains(chat.id) &&
            (network == null || chat.networks.contains(network)))
          chat,
    ];
    int unreadOf(_Chat chat) => read.contains(chat.id) ? 0 : chat.unread;
    NotionPinnedShortcut pin(String id, int order, {bool group = false}) {
      final chat = _chats.firstWhere((chat) => chat.id == id);
      return NotionPinnedShortcut(
        name: chat.name,
        avatar: NotionInitialAvatar(
          name: chat.name,
          size: notionPinnedAvatarSize,
        ),
        onTap: _noop,
        order: order,
        unreadCount: unreadOf(chat),
        isGroup: group,
        networks: chat.networks,
      );
    }

    // Swipes as the inbox adapter wires them (chat_list.dart): left
    // archives (the row leaves this view), right toggles read.
    return NotionInboxPage(
      rows: [
        for (final chat in shown)
          NotionSwipeAction(
            key: ValueKey('row-${chat.id}'),
            endToStart: NotionSwipeActionSide(
              icon: Icons.archive_outlined,
              label: 'Archive',
              dismisses: true,
              onCommit: () => setState(() => archived.add(chat.id)),
            ),
            startToEnd: NotionSwipeActionSide(
              icon: unreadOf(chat) > 0
                  ? Icons.mark_chat_read_outlined
                  : Icons.mark_chat_unread_outlined,
              label: unreadOf(chat) > 0 ? 'Read' : 'Unread',
              onCommit: () => setState(() => read.add(chat.id)),
            ),
            child: NotionInboxRow(
              avatar: NotionInitialAvatar(
                name: chat.name,
                size: NotionSize.avatarLg,
              ),
              name: chat.name,
              preview: chat.preview,
              time: chat.time,
              unreadCount: unreadOf(chat),
              mentioned: chat.mentioned && unreadOf(chat) > 0,
              muted: chat.muted,
              delivery: chat.delivery,
              // Badges only while every network shows (UX-17).
              networks: network == null ? chat.networks : const [],
              onTap: _noop,
            ),
          ),
      ],
      pins: [pin('maya', 0), pin('crew', 1, group: true), pin('dad', 2)],
      onSettings: _noop,
      onSearch: _noop,
      networks: const [
        'whatsapp',
        'telegram',
        'signal',
        'messenger',
        'instagram',
        'slack',
      ],
      selectedNetwork: network,
      onNetworkSelected: (value) => setState(() => network = value),
      // The adapter's dock menu also lists views and two actions; the
      // scenes never pick them.
      selectedView: view,
      onViewSelected: (value) => setState(() => view = value),
      onManageNetworks: _noop,
      onMarkAllRead: _noop,
      unreadCount: shown.where((chat) => unreadOf(chat) > 0).length,
    );
  }
}

// ---------------------------------------------------------------------------
// Conversation fixtures

DateTime _today(int hour, int minute) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

const _maya = '@maya:example.invalid';

/// Media of the fixture by mxc URI (photo, stickers), served by the
/// database the SDK and the sticker cache read before any download.
class _Media extends ConversationDatabase {
  final files = <String, Uint8List>{};

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async => files[mxcUri.toString()];

  @override
  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) async {}

  @override
  int get maxFileSize => 64 * 1024 * 1024;
}

class _Client extends Client {
  _Client(this.media) : super('offline README fixture', database: media);
  final _Media media;

  @override
  String get userID => '@owner:example.invalid';

  @override
  Map<String, List<String>> get directChats => {
    _maya: rooms.map((r) => r.id).toList(),
  };
}

class _Room extends ConversationRoom {
  _Room(super.client, super.id, {required super.network}) {
    state(EventTypes.RoomName, {'name': 'Maya'});
    state(EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'Maya',
    }, key: _maya);
    state(EventTypes.RoomMember, {
      'membership': 'leave',
    }, key: '@anna:example.invalid');
  }

  Timeline? live;
  var _serial = 0;

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async => live = ConversationTimeline(
    room: this,
    chunk: TimelineChunk(events: sourceEvents),
    onUpdate: onUpdate,
  );

  /// A new event arrives (newest first), as a sync would deliver it.
  void push(Event event) {
    sourceEvents.insert(0, event);
    live?.addAggregatedEvent(event);
    live?.onUpdate?.call();
  }

  Event say(
    String id,
    DateTime at,
    String text, {
    bool own = false,
    Map<String, dynamic>? content,
  }) {
    final event = Event(
      room: this,
      eventId: id,
      type: EventTypes.Message,
      senderId: own ? client.userID! : _maya,
      originServerTs: at,
      content: content ?? {'msgtype': MessageTypes.Text, 'body': text},
    );
    sourceEvents.insert(0, event);
    return event;
  }

  Event react(String target, String key, {bool own = true, DateTime? at}) =>
      Event(
        room: this,
        eventId: '\$reaction-${++_serial}-$target',
        type: EventTypes.Reaction,
        senderId: own ? client.userID! : _maya,
        originServerTs: at ?? _today(9, 40),
        content: {
          'm.relates_to': {
            'rel_type': RelationshipTypes.reaction,
            'event_id': target,
            'key': key,
          },
        },
      );

  @override
  Future<String?> sendReaction(
    String eventId,
    String key, {
    String? txid,
  }) async {
    reactionsSent++;
    sentEmoji.add(key);
    final event = react(eventId, key, at: _today(9, 41));
    push(event);
    return event.eventId;
  }

  /// Stickers sent from the panel arrive in the timeline at once.
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) async {
    final id = '\$sent-event-${++_serial}';
    push(
      Event(
        room: this,
        eventId: id,
        type: type,
        senderId: client.userID!,
        originServerTs: _today(9, 42),
        content: content,
      ),
    );
    return id;
  }
}

/// Personal state of the fixture: transcripts appear when asked for, sent
/// text lands in the timeline as the server's echo would.
class _Personal extends ConversationPersonal {
  _Personal(super.client);

  final jobs = <String, TranscriptionJob>{};

  @override
  Map<String, TranscriptionJob> get transcripts => jobs;

  @override
  Future<void> transcribe(Event e, {String? language}) async {
    final id = transcriptId(e);
    jobs[id] = TranscriptionJob(
      id: id,
      source: source(e),
      state: JobState.processing,
    );
    notifyListeners();
  }

  void finish(Event e, String text) {
    final id = transcriptId(e);
    jobs[id] = TranscriptionJob(
      id: id,
      source: source(e),
      state: JobState.done,
      text: text,
      language: 'en',
    );
    notifyListeners();
  }

  @override
  Future<ImmediateSendResult> sendImmediate(
    Room room,
    String text, {
    Event? replyTo,
    String? editEventId,
    String? threadId,
    ImmediateDurable? onDurable,
  }) async {
    final result = await super.sendImmediate(
      room,
      text,
      replyTo: replyTo,
      editEventId: editEventId,
      threadId: threadId,
      onDurable: onDurable,
    );
    if (room is _Room) {
      room.push(
        Event(
          room: room,
          eventId: '\$sent-${sends.length}',
          type: EventTypes.Message,
          senderId: room.client.userID!,
          originServerTs: _today(9, 42),
          content: {'msgtype': MessageTypes.Text, 'body': text},
        ),
      );
    }
    return result;
  }
}

Future<Uint8List> _png(int width, int height, void Function(Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A sunset over hills, drawn in code (no real photo).
Future<Uint8List> _drawPhoto() => _png(960, 640, (canvas) {
  const w = 960.0, h = 640.0;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, w, h),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(0, h),
        const [Color(0xFF2B2D6E), Color(0xFFB4508C), Color(0xFFF59E5B)],
        const [0, .55, 1],
      ),
  );
  canvas.drawCircle(
    const Offset(w * .62, h * .6),
    86,
    Paint()..color = const Color(0xFFFFD58A),
  );
  Path hills(double base, List<double> peaks) {
    final path = Path()
      ..moveTo(0, h)
      ..lineTo(0, base);
    final step = w / (peaks.length - 1);
    for (var i = 0; i < peaks.length; i++) {
      path.lineTo(i * step, base - peaks[i]);
    }
    return path
      ..lineTo(w, h)
      ..close();
  }

  canvas.drawPath(
    hills(h * .72, [40, 120, 70, 160, 90, 130, 50]),
    Paint()..color = const Color(0xFF5A3361),
  );
  canvas.drawPath(
    hills(h * .84, [30, 70, 110, 60, 100, 40, 80, 20]),
    Paint()..color = const Color(0xFF2E1F3D),
  );
  canvas.drawPath(
    hills(h * .95, [10, 50, 30, 60, 20, 45]),
    Paint()..color = const Color(0xFF181226),
  );
});

/// A round blob character with a face, drawn in code (a fictional sticker).
Future<Uint8List> _drawSticker(int index) => _png(256, 256, (canvas) {
  const hues = [
    Color(0xFFFFC94D),
    Color(0xFF7AD3FF),
    Color(0xFFFF8FB1),
    Color(0xFF9BE37B),
    Color(0xFFC6A2FF),
    Color(0xFFFFA45C),
    Color(0xFF5EE0C6),
    Color(0xFFFF6B6B),
  ];
  final hue = hues[index % hues.length];
  const center = Offset(128, 136);
  // White die-cut outline, then the body.
  canvas.drawCircle(center, 104, Paint()..color = const Color(0xFFFFFFFF));
  canvas.drawCircle(
    center,
    94,
    Paint()
      ..shader = ui.Gradient.radial(
        center.translate(-30, -40),
        140,
        [Color.lerp(hue, const Color(0xFFFFFFFF), .35)!, hue],
      ),
  );
  final ink = Paint()..color = const Color(0xFF2B2135);
  final white = Paint()..color = const Color(0xFFFFFFFF);
  final blush = Paint()..color = const Color(0x55FF4F7B);
  canvas.drawCircle(center.translate(-52, 26), 14, blush);
  canvas.drawCircle(center.translate(52, 26), 14, blush);
  final stroke = Paint()
    ..color = const Color(0xFF2B2135)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 7
    ..strokeCap = StrokeCap.round;
  switch (index % 4) {
    case 0: // big smile
      canvas.drawCircle(center.translate(-30, -14), 11, ink);
      canvas.drawCircle(center.translate(30, -14), 11, ink);
      canvas.drawArc(
        Rect.fromCenter(center: center.translate(0, 18), width: 64, height: 46),
        .2,
        math.pi - .4,
        false,
        stroke,
      );
    case 1: // wink
      canvas.drawCircle(center.translate(-30, -14), 11, ink);
      canvas.drawArc(
        Rect.fromCenter(
          center: center.translate(30, -10),
          width: 30,
          height: 20,
        ),
        math.pi + .3,
        math.pi - .6,
        false,
        stroke,
      );
      canvas.drawArc(
        Rect.fromCenter(center: center.translate(0, 18), width: 56, height: 40),
        .3,
        math.pi - .6,
        false,
        stroke,
      );
    case 2: // heart eyes
      for (final dx in [-30.0, 30.0]) {
        final c = center.translate(dx, -14);
        final heart = Path()
          ..moveTo(c.dx, c.dy + 12)
          ..cubicTo(c.dx - 22, c.dy - 2, c.dx - 10, c.dy - 20, c.dx, c.dy - 8)
          ..cubicTo(c.dx + 10, c.dy - 20, c.dx + 22, c.dy - 2, c.dx, c.dy + 12);
        canvas.drawPath(heart, Paint()..color = const Color(0xFFE5245E));
      }
      canvas.drawArc(
        Rect.fromCenter(center: center.translate(0, 20), width: 50, height: 36),
        .2,
        math.pi - .4,
        false,
        stroke,
      );
    default: // surprised
      canvas.drawCircle(center.translate(-30, -16), 15, white);
      canvas.drawCircle(center.translate(30, -16), 15, white);
      canvas.drawCircle(center.translate(-28, -14), 8, ink);
      canvas.drawCircle(center.translate(32, -14), 8, ink);
      canvas.drawOval(
        Rect.fromCenter(center: center.translate(0, 30), width: 26, height: 32),
        ink,
      );
  }
});

/// Maya writes on WhatsApp and Telegram; ChatLoom shows one conversation.
class _Conversation {
  _Conversation(Uint8List photo, {bool voice = false}) {
    media = _Media();
    client = _Client(media);
    whatsapp = _Room(
      client,
      '!maya-whatsapp:example.invalid',
      network: 'whatsapp',
    );
    telegram = _Room(
      client,
      '!maya-telegram:example.invalid',
      network: 'telegram',
    );
    personal = _Personal(client);
    PersonalClient.debugUse(client, personal);
    media.files['mxc://example.invalid/sunday'] = photo;
    media.files['mxc://example.invalid/sunday-thumb'] = photo;
    whatsapp.say(r'$w1', _today(9, 24), 'Are we still on for tonight?');
    whatsapp.say(
      r'$w2',
      _today(9, 25),
      'Yes! 7pm at the usual gym?',
      own: true,
    );
    telegram.say(r'$t1', _today(9, 27), 'Perfect, I booked the wall 🧗');
    telegram.sourceEvents.insert(0, telegram.react(r'$t1', '❤️'));
    whatsapp.say(
      r'$w3',
      _today(9, 29),
      'sunday.png',
      content: {
        'msgtype': MessageTypes.Image,
        'body': 'sunday.png',
        'url': 'mxc://example.invalid/sunday',
        'info': {
          'w': 960,
          'h': 640,
          'mimetype': 'image/png',
          'size': photo.length,
          'thumbnail_url': 'mxc://example.invalid/sunday-thumb',
          'thumbnail_info': {
            'w': 960,
            'h': 640,
            'mimetype': 'image/png',
            'size': photo.length,
          },
        },
      },
    );
    whatsapp.say(r'$w4', _today(9, 30), 'The view from Sunday’s hike');
    whatsapp.say(
      r'$w5',
      _today(9, 31),
      'Wow, that light 😍',
      own: true,
      content: {
        'msgtype': MessageTypes.Text,
        'body': 'Wow, that light 😍',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$w3'},
        },
      },
    );
    if (voice) {
      this.voice = telegram.say(
        r'$t2',
        _today(9, 33),
        'Voice message',
        content: {
          'msgtype': MessageTypes.Audio,
          'body': 'Voice message',
          'url': 'mxc://example.invalid/voice',
          'info': {'duration': 12000, 'mimetype': 'audio/ogg'},
          'org.matrix.msc3245.voice': {},
          'org.matrix.msc1767.audio': {
            'duration': 12000,
            'waveform': [
              for (var i = 0; i < 40; i++)
                (250 +
                        700 *
                            (.5 + .5 * math.sin(i * .9)) *
                            (i % 3 == 0 ? .55 : 1))
                    .round(),
            ],
          },
        },
      );
    } else {
      whatsapp.say(
        r'$w6',
        _today(9, 35),
        'Bring chalk, I forgot mine last time',
      );
    }
    group = PersonGroup(
      id: 'maya',
      name: 'Maya',
      members: [personal.ref(whatsapp), personal.ref(telegram)],
      defaultRoomId: whatsapp.id,
    );
  }

  late final _Media media;
  late final _Client client;
  late final _Room whatsapp;
  late final _Room telegram;
  late final _Personal personal;
  late final PersonGroup group;
  Event? voice;

  Widget page() => MergedChatPage(personal: personal, group: group);

  /// The fully read marker at each source's newest message from Maya (the
  /// chat was read before), so the manual read button stays hidden.
  void markRead() {
    for (final room in [whatsapp, telegram]) {
      final newest = room.sourceEvents.firstWhere(
        (event) =>
            event.type == EventTypes.Message && event.senderId == _maya,
      );
      room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': newest.eventId},
      );
    }
  }

  void dispose() {
    for (final room in [whatsapp, telegram]) {
      room.live?.cancelSubscriptions();
    }
    personal.dispose();
  }
}

/// Mounts the merged conversation, settles its images and drops the
/// desktop autofocus of the test host (a phone opens a chat unfocused).
Future<_Conversation> _openChat(
  WidgetTester tester,
  SharedPreferences preferences, {
  bool voice = false,
  bool read = false,
  void Function(_Conversation chat)? before,
}) async {
  final photo = (await tester.runAsync(_drawPhoto))!;
  final chat = _Conversation(photo, voice: voice);
  if (read) chat.markRead();
  before?.call(chat);
  await _mount(
    tester,
    _materialApp(home: chat.page()),
    client: chat.client,
    preferences: preferences,
  );
  await tester.pumpAndSettle();
  await _settleImages(tester);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  return chat;
}

// ---------------------------------------------------------------------------
// Settings

class _SettingsDemo extends StatelessWidget {
  const _SettingsDemo();

  @override
  Widget build(BuildContext context) => NotionSettingsPage(
    data: const NotionSettingsData(
      name: 'Jamie',
      avatar: NotionInitialAvatar(name: 'Jamie', size: 44),
      summaries: {
        NotionSettingsCategory.account: 'Profile and sign out',
        NotionSettingsCategory.security:
            'Incognito on · App lock, devices and recovery',
        NotionSettingsCategory.appearance: 'Dark · Blue accent',
        NotionSettingsCategory.advanced: 'Private sync configured',
      },
    ),
    actions: NotionSettingsActions(
      back: _noop,
      open: (path) {
        if (!path.contains('security')) return;
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const _PrivacyDemo()));
      },
    ),
  );
}

/// Settings → Privacy & security, composed like `SettingsSecurityView`
/// from the same presenters (that view needs the app lock and router).
class _PrivacyDemo extends StatefulWidget {
  const _PrivacyDemo();

  @override
  State<_PrivacyDemo> createState() => _PrivacyDemoState();
}

class _PrivacyDemoState extends State<_PrivacyDemo> {
  var incognito = true;
  var typing = true;
  var receipts = false;
  var presence = false;

  @override
  Widget build(BuildContext context) => NotionSettingsScaffold(
    title: 'Privacy & security',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSettingsSection('Privacy on this device'),
        NotionPrivacyPreferences(
          incognito: incognito,
          typing: typing,
          receipts: receipts,
          onIncognito: (value) => setState(() => incognito = value),
          onTyping: (value) => setState(() => typing = value),
          onReceipts: (value) => setState(() => receipts = value),
        ),
        NotionSettingsToggle(
          value: presence,
          title: 'Show activity status',
          subtitle:
              '"online" or "last seen" under a chat name when the network '
              'shares it. Display only: it never shares your own status.',
          onChanged: (value) => setState(() => presence = value),
        ),
        const NotionSettingsSection('Encryption'),
        NotionListRow(
          leading: const Icon(Icons.key_outlined),
          title: 'Recovery key',
          subtitle: 'Unlocks your encrypted history on a new device',
          onTap: _noop,
        ),
        NotionListRow(
          leading: const Icon(Icons.devices_outlined),
          title: 'Devices',
          subtitle: 'This phone, MacBook',
          onTap: _noop,
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------

void main() {
  late SharedPreferences preferences;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    preferences = await SharedPreferences.getInstance();
    // The phone composer (voice mic that morphs into send) on a Linux host.
    PlatformInfos.debugPlatformCanRecord = true;
    final roboto = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      roboto.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await roboto.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final path in _emojiFonts) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      await (FontLoader(
        _emojiFamily,
      )..addFont(Future.value(bytes.buffer.asByteData()))).load();
      _emojiLoaded = true;
      break;
    }
  });

  tearDownAll(() => PlatformInfos.debugPlatformCanRecord = null);

  setUp(() => _finger.value = null);

  Future<void> phone(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _phoneSize;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('readme inbox: one inbox, every network', (tester) async {
    await phone(tester);
    final reel = _Reel(tester, 'inbox');
    await _mount(
      tester,
      _materialApp(home: const _InboxDemo()),
      client: ConversationClient(),
      preferences: preferences,
    );
    await reel.shot();
    // The first screenful rises in.
    await reel.play(const Duration(milliseconds: 640));
    await reel.hold(const Duration(milliseconds: 1500));
    reel.mark('home');
    await reel.tap(find.text('All networks'));
    await reel.play(const Duration(milliseconds: 480));
    await reel.hold(const Duration(milliseconds: 900));
    await reel.tap(find.text('Telegram').last);
    await reel.play(const Duration(milliseconds: 480));
    await reel.hold(const Duration(milliseconds: 1600));
    await reel.tap(find.text('Telegram').last);
    await reel.play(const Duration(milliseconds: 480));
    await reel.hold(const Duration(milliseconds: 600));
    await reel.tap(find.text('All networks').last);
    await reel.play(const Duration(milliseconds: 480));
    await reel.hold(const Duration(milliseconds: 1200));
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('readme swipe: triage with a swipe', (tester) async {
    await phone(tester);
    final reel = _Reel(tester, 'swipe');
    await _mount(
      tester,
      _materialApp(home: const _InboxDemo()),
      client: ConversationClient(),
      preferences: preferences,
    );
    await tester.pumpAndSettle();
    await reel.hold(const Duration(milliseconds: 900));
    double rowY(String name) => tester.getCenter(find.text(name)).dy + 10;
    // Right: mark read.
    await reel.swipe(Offset(120, rowY('Priya')), const Offset(190, 0));
    await reel.play(const Duration(milliseconds: 520));
    await reel.hold(const Duration(milliseconds: 700));
    // Left: archive; the row flies off and the list closes the gap.
    await reel.swipe(Offset(320, rowY('Design team')), const Offset(-230, 0));
    await reel.play(const Duration(milliseconds: 800));
    await reel.hold(const Duration(milliseconds: 700));
    await reel.swipe(Offset(120, rowY('Elena')), const Offset(190, 0));
    await reel.play(const Duration(milliseconds: 520));
    await reel.hold(const Duration(milliseconds: 1300));
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('readme chat: merged conversation and reactions', (
    tester,
  ) async {
    await phone(tester);
    final chat = await _openChat(tester, preferences);
    final reel = _Reel(tester, 'chat');
    await reel.hold(const Duration(milliseconds: 1300));
    await reel.longPress(find.text('Bring chalk, I forgot mine last time'));
    await reel.play(const Duration(milliseconds: 400));
    await reel.hold(const Duration(milliseconds: 800));
    reel.mark('menu');
    await reel.tap(find.byKey(const ValueKey('reaction-😂')));
    await reel.play(const Duration(milliseconds: 720));
    await reel.hold(const Duration(milliseconds: 900));
    // Double tap: the network's first quick reaction, with a burst.
    await reel.doubleTap(find.text('The view from Sunday’s hike'));
    await reel.play(const Duration(milliseconds: 900));
    await reel.hold(const Duration(milliseconds: 1500));
    reel.mark('end');
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
    chat.dispose();
  });

  testWidgets('readme voice: transcribe a voice message', (tester) async {
    await phone(tester);
    final chat = await _openChat(tester, preferences, voice: true);
    final reel = _Reel(tester, 'voice');
    await reel.hold(const Duration(milliseconds: 1000));
    await reel.tap(find.text('Transcribe'));
    await reel.play(const Duration(milliseconds: 1400));
    chat.personal.finish(
      chat.voice!,
      'Running ten minutes late, save me a rope! And grab two coffees ☕',
    );
    await reel.play(const Duration(milliseconds: 600));
    await reel.hold(const Duration(milliseconds: 2000));
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
    chat.dispose();
  });

  testWidgets('readme send: pick the network, type, send', (tester) async {
    await phone(tester);
    final chat = await _openChat(tester, preferences, read: true);
    final reel = _Reel(tester, 'send');
    await reel.hold(const Duration(milliseconds: 900));
    // Send through Telegram instead of WhatsApp.
    await reel.tap(find.byType(ConversationSourceChip));
    await reel.play(const Duration(milliseconds: 440));
    await reel.hold(const Duration(milliseconds: 800));
    await reel.tap(find.text('Telegram').last);
    await reel.play(const Duration(milliseconds: 440));
    await reel.hold(const Duration(milliseconds: 500));
    final field = find.byType(TextField).last;
    await reel.tap(field);
    await reel.type(field, 'On my way 🚴');
    await reel.play(const Duration(milliseconds: 200));
    await reel.hold(const Duration(milliseconds: 400));
    await reel.tap(find.byKey(const Key('send_button')));
    await reel.play(const Duration(milliseconds: 800));
    FocusManager.instance.primaryFocus?.unfocus();
    await reel.hold(const Duration(milliseconds: 1600));
    expect(chat.personal.sends.single.room, same(chat.telegram));
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
    chat.dispose();
  });

  testWidgets('readme stickers: the composer panel', (tester) async {
    await phone(tester);
    final stickers = <Uint8List>[
      for (var i = 0; i < 8; i++) (await tester.runAsync(() => _drawSticker(i)))!,
    ];
    final backend = FakeStickerBackend();
    late StickerLibrary library;
    StickerMediaCache.debugResetShared();
    StickerPanel.debugResetTab(StickerPanelTab.emoji);
    StickerTab.debugResetPosition();
    final chat = await _openChat(
      tester,
      preferences,
      read: true,
      before: (chat) {
        library = fakeLibrary(backend);
        StickerLibrary.debugSet(chat.client, library);
        const emoji = ['😀', '😉', '😍', '😮', '🥳', '😎', '🤗', '😲'];
        for (var i = 0; i < stickers.length; i++) {
          chat.media.files['mxc://example.invalid/blob-$i'] = stickers[i];
        }
        backend.rooms['!stickers:example.invalid'] = {
          'Blobs': pack('Happy blobs', {
            for (var i = 0; i < stickers.length; i++)
              'blob_$i': packImage(
                'blob-$i',
                emoji: emoji[i],
                mime: 'image/png',
              ),
          }, url: 'https://t.me/addstickers/HappyBlobs'),
        };
        library.addPack(
          const StickerPackRef(
            roomId: '!stickers:example.invalid',
            stateKey: 'Blobs',
          ),
        );
      },
    );
    final reel = _Reel(tester, 'stickers');
    await reel.hold(const Duration(milliseconds: 900));
    await reel.tap(find.byTooltip('Emoji picker'));
    await reel.play(const Duration(milliseconds: 520));
    await reel.hold(const Duration(milliseconds: 1000));
    await reel.tap(find.text('Stickers').last);
    await reel.play(const Duration(milliseconds: 360));
    await _settleImages(tester);
    await reel.hold(const Duration(milliseconds: 1000));
    await reel.tap(find.bySemanticsLabel('Sticker 😍'));
    await reel.play(const Duration(milliseconds: 360));
    await _settleImages(tester);
    await reel.play(const Duration(milliseconds: 400));
    await reel.hold(const Duration(milliseconds: 1600));
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
    chat.dispose();
    library.dispose();
  });

  testWidgets('readme appearance: accents re-theme the app live', (
    tester,
  ) async {
    await phone(tester);
    final reel = _Reel(tester, 'appearance');
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(ConversationClient(), preferences),
        child: _phone(
          ThemeBuilder(
            preferences: preferences,
            builder: (context, mode, appearance) {
              final display = ThemeController.of(context).displayPreferences;
              return _materialApp(
                theme: _theme(Brightness.light, appearance, display),
                darkTheme: _theme(Brightness.dark, appearance, display),
                themeMode: mode == ThemeMode.system ? ThemeMode.dark : mode,
                home: const SettingsStyle(),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    await reel.hold(const Duration(milliseconds: 1100));
    Future<void> pick(Finder target) async {
      await reel.tap(target);
      await reel.play(const Duration(milliseconds: 360));
      await reel.hold(const Duration(milliseconds: 650));
    }

    Finder label(String text) => find.bySemanticsLabel(RegExp('^$text'));
    await pick(label('Vivid colours'));
    await pick(label('Pink accent'));
    reel.mark('vivid');
    await pick(label('Orange accent'));
    await pick(label('Green accent'));
    await pick(find.text('Light'));
    await pick(label('Violet accent'));
    await pick(find.text('Dark'));
    await pick(label('Balanced colours'));
    await pick(label('Blue accent'));
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('readme privacy: incognito by default', (tester) async {
    await phone(tester);
    final reel = _Reel(tester, 'privacy');
    await _mount(
      tester,
      _materialApp(home: const _SettingsDemo()),
      client: ConversationClient(),
      preferences: preferences,
    );
    await tester.pumpAndSettle();
    await reel.hold(const Duration(milliseconds: 1000));
    await reel.tap(find.text('Privacy & security'));
    await reel.play(const Duration(milliseconds: 520));
    await reel.hold(const Duration(milliseconds: 1000));
    await reel.tap(find.text('Incognito mode'));
    await reel.play(const Duration(milliseconds: 400));
    await reel.hold(const Duration(milliseconds: 900));
    await reel.tap(find.text('Send read receipts'));
    await reel.play(const Duration(milliseconds: 300));
    await reel.hold(const Duration(milliseconds: 600));
    await reel.tap(find.text('Incognito mode'));
    await reel.play(const Duration(milliseconds: 400));
    await reel.hold(const Duration(milliseconds: 1400));
    expect(tester.takeException(), isNull);
    await reel.save();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
