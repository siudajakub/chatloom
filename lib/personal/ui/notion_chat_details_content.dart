// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/conversation_navigation.dart'
    show ConversationJumpTargets;
import 'package:chatloom/pages/chat/conversation_search.dart'
    show ConversationSearchResultRow;
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/bridge_contact_search.dart' show searchFold;
import 'package:chatloom/personal/local_message_search.dart';
import 'package:chatloom/personal/merged_chat_page.dart' show SourceChatPage;
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/conversation_content_controller.dart';
import 'package:chatloom/personal/ui/notion_chat_details_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show RoundMediaPolicy, RoundVideoDescriptor;

bool _thumbnailAllowed(Event event) =>
    event.showThumbnail &&
    event.hasThumbnail &&
    RoundMediaPolicy.fromContent(event.content).canPlay;

Widget _thumbnailPlaceholder(BuildContext context) => ColoredBox(
  color: Theme.of(context).colorScheme.surfaceContainerHigh,
  child: const Center(child: Icon(Icons.image_outlined)),
);

/// Month header of the shared media grid: "October 2026" (Telegram's
/// shared media sections). English, like the rest of the app; no locale
/// data needs to be loaded.
@visibleForTesting
String sharedMonthLabel(DateTime local) =>
    '${_months[local.month - 1]} ${local.year}';

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// A media length as Telegram prints it: "0:07", "1:13", "1:02:05".
@visibleForTesting
String sharedDurationLabel(Duration duration) {
  final seconds = duration.inSeconds;
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// The `info.duration` (ms) of [event] as [sharedDurationLabel], or null.
String? _durationOf(Event event) {
  final ms = event.infoMap['duration'];
  return ms is num && ms > 0
      ? sharedDurationLabel(Duration(milliseconds: ms.toInt()))
      : null;
}

/// [events] (newest first) grouped by local calendar month, newest month
/// first, each month keeping the events' order.
@visibleForTesting
List<(String, List<Event>)> groupSharedMediaByMonth(Iterable<Event> events) =>
    groupSharedByMonth(events, (e) => e.originServerTs);

/// [items] (newest first) grouped by the local calendar month of [date].
@visibleForTesting
List<(String, List<T>)> groupSharedByMonth<T>(
  Iterable<T> items,
  DateTime Function(T) date,
) {
  final months = <int, (String, List<T>)>{};
  for (final item in items) {
    final local = date(item).toLocal();
    months
        .putIfAbsent(
          local.year * 12 + local.month,
          () => (sharedMonthLabel(local), <T>[]),
        )
        .$2
        .add(item);
  }
  return months.values.toList();
}

/// Media the full-screen viewer opens itself (photos, playable videos);
/// rounds, protected media and other kinds go to their conversation.
@visibleForTesting
bool sharedOpensInViewer(Event event, {bool? supportsVideo}) {
  if (event.redacted || !event.showThumbnail) return false;
  if (event.messageType == MessageTypes.Image) return true;
  if (event.messageType != MessageTypes.Video) return false;
  return (supportsVideo ?? PlatformInfos.supportsVideoPlayer) &&
      RoundMediaPolicy.fromContent(event.content).canPlay &&
      RoundVideoDescriptor.fromContent(event.content) == null;
}

/// A bounded local preview. No total is inferred from a partial history page.
class NotionLocalSharedPreview extends StatefulWidget {
  final List<Room> rooms;
  const NotionLocalSharedPreview({super.key, required this.rooms});
  @override
  State<NotionLocalSharedPreview> createState() =>
      _NotionLocalSharedPreviewState();
}

class _NotionLocalSharedPreviewState extends State<NotionLocalSharedPreview> {
  late ConversationContentController _history;
  late String _scopeKey;
  String _scope(List<Room> rooms) => rooms
      .map((r) => (identityHashCode(r.client), r.client.userID, r.id))
      .join('|');
  void _create({bool afterTransition = false}) {
    _scopeKey = _scope(widget.rooms);
    final history = _history = ConversationContentController(
      widget.rooms.map(MatrixContentSource.new).toList(),
      unlocked: () => PersonalPrivacy.surfaceUnlocked,
      privacyGeneration: () => PersonalPrivacy.surfaceGeneration,
    );
    history.addListener(_updated);
    if (!afterTransition) {
      history.load();
      return;
    }
    // Reading local history pages decrypts and filters events; start it once
    // the details page finished sliding in.
    _waiting = true;
    NotionMotion.afterRouteSettled(context, () {
      if (!identical(history, _history)) return;
      _waiting = false;
      history.load();
      _updated();
    });
  }

  /// True until the deferred first load starts; shows the loading line.
  bool _waiting = false;

  void _updated() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _create(afterTransition: true);
  }

  @override
  void didUpdateWidget(NotionLocalSharedPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_scopeKey != _scope(widget.rooms)) {
      _history.dispose();
      _waiting = false;
      _create();
    }
  }

  @override
  void dispose() {
    _history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = _history.events.where(sharedMedia).take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProgressLine(visible: _history.busy || _waiting),
        NotionSizeReveal(
          visible: _history.sources.any((s) => s.error != null),
          child: SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _history.busy
                  ? null
                  : () => _history.load(refresh: true),
              child: const Text('Some shared content could not load. Retry'),
            ),
          ),
        ),
        NotionSizeReveal(
          visible: events.isEmpty && !_history.busy && !_waiting,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No photos or videos in the loaded local history.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ),
        // The strip opens once the first page decoded; each tile grows in.
        NotionSizeReveal(
          visible: events.isNotEmpty,
          child: SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: events.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => NotionEntrance(
                index: index,
                afterRoute: false,
                rise: 0,
                scale: NotionMotion.dialogFrom,
                child: _SharedPreviewBlock(events[index], media: events),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SharedPreviewBlock extends StatelessWidget {
  final Event event;
  final List<Event> media;
  const _SharedPreviewBlock(this.event, {required this.media});
  @override
  Widget build(BuildContext context) {
    final image =
        {MessageTypes.Image, MessageTypes.Video}.contains(event.messageType) &&
        _thumbnailAllowed(event);
    return SizedBox.square(
      dimension: 92,
      child: NotionSharedContentBlock(
        label: image
            ? '${event.messageType == MessageTypes.Video ? 'Video' : 'Photo'} · ${event.originServerTs.toLocal().toString().substring(0, 16)}'
            : event.messageType == MessageTypes.Audio
            ? 'Voice message'
            : event.body,
        thumbnail: image
            ? _MediaSource(
                event: event,
                child: MxcImage(
                  event: event,
                  width: 144,
                  height: 92,
                  fit: BoxFit.cover,
                  isThumbnail: true,
                  animated: false,
                  cacheKey: _thumbnailCacheKey(event),
                  cacheName: event.room.id,
                  placeholder: _thumbnailPlaceholder,
                ),
              )
            : null,
        audio: event.messageType == MessageTypes.Audio,
        video: event.messageType == MessageTypes.Video,
        onTap: () => _openEvent(context, event, media: media),
      ),
    );
  }
}

/// Hero tag of a details thumbnail; distinct from the timeline bubble's
/// event-id tag, so a chat and its details side by side never clash.
Object _mediaHeroTag(Event event) => ('details-media', event.eventId);

/// Memory-cache key of a details thumbnail, so the flying copy of the
/// thumbnail (the hero shuttle) paints from the first frame.
String _thumbnailCacheKey(Event event) => 'details:${event.eventId}';

/// A details thumbnail the full-screen viewer flies out of and back into.
class _MediaSource extends StatelessWidget {
  const _MediaSource({required this.event, required this.child});

  final Event event;
  final Widget child;

  @override
  Widget build(BuildContext context) => Hero(
    tag: _mediaHeroTag(event),
    createRectTween: NotionMediaHero.rectTween,
    child: child,
  );
}

/// Opens [event] from the shared content: photos and videos in the
/// full-screen viewer, swiping through [media] (newest first, as listed;
/// the viewer gets them oldest first); anything else in its conversation.
void _openEvent(BuildContext context, Event event, {List<Event>? media}) {
  if (!PersonalPrivacy.surfaceUnlocked || event.redacted) return;
  if (event.room.client.userID == null) return;
  final source = PersonalClient.of(event.room.client).source(event);
  if (Matrix.of(context).client.userID != source.conversation.accountId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => SourceChatPage(source: source)),
    );
    return;
  }
  if (sharedOpensInViewer(event)) {
    // Swipes stay within the same account's rooms (a merged person may mix
    // accounts; the viewer downloads through each event's own client).
    final set = [
      for (final item in media ?? const <Event>[])
        if (identical(item.room.client, event.room.client) &&
            sharedOpensInViewer(item))
          item,
    ].reversed.toList();
    showImageViewer(
      context,
      event,
      mediaEvents: set.any((e) => e.eventId == event.eventId) ? set : [event],
      // Follow-up (lane media-view): a per-event hero tag, so a swiped-to
      // item also flies back into its own tile.
      heroTag: _mediaHeroTag(event),
      sourceRadius: NotionRadius.smAll,
    );
  } else {
    // Reuse the actual source conversation for protected/round/audio
    // playback, with its consent and capability controls. Never create a
    // new player here. The chat this page was opened from takes it back
    // (FX-03): it is popped to and jumps there, instead of a second chat page.
    if (ConversationJumpTargets.open(context, event)) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => SourceChatPage(source: source)),
    );
  }
}

/// A message search hit: the open chat below shows it in place; without
/// one it opens like shared content.
void _openMessage(BuildContext context, Event event) {
  if (!PersonalPrivacy.surfaceUnlocked || event.redacted) return;
  if (ConversationJumpTargets.open(context, event)) return;
  _openEvent(context, event);
}

/// The projections of the shared content page, in tab order.
enum _SharedTab { media, messages, files, links }

class NotionConversationContentPage extends StatefulWidget {
  final List<Room> rooms;
  final String name;
  final bool initialMedia;
  const NotionConversationContentPage({
    super.key,
    required this.rooms,
    required this.name,
    this.initialMedia = false,
  });
  @override
  State<NotionConversationContentPage> createState() =>
      _NotionConversationContentPageState();
}

class _NotionConversationContentPageState
    extends State<NotionConversationContentPage>
    with SingleTickerProviderStateMixin {
  /// Local history is read until the open tab has this many items...
  static const _fillTarget = 48;

  /// ...or this many events per source were read (older ones on scroll).
  static const _fillCap = 2560;

  final _query = TextEditingController();
  // The theme's sliding pill tabs (UI-22), as in chat search.
  late final TabController _tabs =
      TabController(length: _SharedTab.values.length, vsync: this)
        ..addListener(() {
          if (_tab.index != _tabs.index && mounted) {
            setState(() => _tab = _SharedTab.values[_tabs.index]);
            _scheduleFill();
          }
        });
  late ConversationContentController _history;
  late String _scopeKey;
  late Client _account;
  _SharedTab _tab = _SharedTab.media;
  SharedSender _sender = SharedSender.everyone;
  final _subscriptions = <StreamSubscription>[];
  bool _remoteAllowed = false, _fillScheduled = false;
  String? _autoSignature;
  String _scope(List<Room> rooms) => rooms
      .map((r) => (identityHashCode(r.client), r.client.userID, r.id))
      .join('|');
  @override
  void initState() {
    super.initState();
    _account = Matrix.of(context).client;
    _createHistory();
  }

  void _createHistory() {
    _scopeKey = _scope(widget.rooms);
    _history = ConversationContentController(
      widget.rooms.map(MatrixContentSource.new).toList(),
      unlocked: () =>
          PersonalPrivacy.surfaceUnlocked &&
          identical(Matrix.of(context).client, _account),
      privacyGeneration: () => PersonalPrivacy.surfaceGeneration,
    );
    for (final state in _history.sources) {
      final source = state.source as MatrixContentSource;
      for (final stream in [
        source.room.client.onTimelineEvent.stream,
        source.room.client.onHistoryEvent.stream,
      ]) {
        _subscriptions.add(
          stream
              .where((e) => e.roomId == source.room.id)
              .listen((e) => _history.accept(source, e)),
        );
      }
    }
    _history.addListener(_updated);
    _fill();
  }

  void _updated() {
    if (!mounted) return;
    setState(() {});
    _scheduleFill();
  }

  /// Once per microtask, never from inside a notification.
  void _scheduleFill() {
    if (_fillScheduled) return;
    _fillScheduled = true;
    scheduleMicrotask(() {
      _fillScheduled = false;
      if (mounted) _fill();
    });
  }

  /// Reads the next local page while the open projection is short of a
  /// screenful: a chat with few photos among many messages still opens on
  /// a filled grid. Each finished page notifies, which calls this again.
  void _fill() {
    final history = _history;
    if (history.busy ||
        history.localEnd ||
        history.sources.any((s) => s.error != null) ||
        history.sources.every((s) => s.localEnd || s.localLimit >= _fillCap) ||
        _visibleCount() >= _fillTarget) {
      return;
    }
    history.load();
  }

  int _visibleCount() {
    final terms = localSearchTerms(_query.text);
    final events = _filtered(terms);
    if (!widget.initialMedia) return events.length;
    return switch (_tab) {
      _SharedTab.media => events.where(sharedMedia).length,
      _SharedTab.messages => events.where(sharedMessage).length,
      _SharedTab.files => events.where(sharedFile).length,
      _SharedTab.links => events.fold(0, (n, e) => n + sharedLinks(e).length),
    };
  }

  @override
  void didUpdateWidget(NotionConversationContentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_scopeKey != _scope(widget.rooms)) {
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _subscriptions.clear();
      _history.dispose();
      _remoteAllowed = false;
      _autoSignature = null;
      _query.clear();
      _tab = _SharedTab.media;
      _sender = SharedSender.everyone;
      _tabs.index = 0;
      _account = Matrix.of(context).client;
      _createHistory();
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _history.dispose();
    _query.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Widget _footer() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_history.encrypted > 0)
          const Text(
            'Some encrypted history is unavailable. Encryption keys may be needed.',
          ),
        if (_history.encrypted > 0)
          TextButton(
            onPressed: _history.busy ? null : _history.retryEncrypted,
            child: const Text('Retry encrypted items'),
          ),
        for (final state in _history.sources.where((s) => s.error != null))
          Semantics(
            liveRegion: true,
            child: Text(
              '${widget.rooms.length > 1 ? '${state.source.name}: ' : ''}${state.error}',
            ),
          ),
        if (!_history.localEnd)
          TextButton.icon(
            onPressed: _history.busy ? null : () => _history.load(),
            icon: const Icon(Icons.expand_more),
            label: const Text('Load more local history'),
          ),
        if (!_history.remoteEnd) ...[
          const Text(
            'Only loaded history is shown. Older history is downloaded only when requested. Search stays on this device.',
            style: TextStyle(fontSize: 12),
          ),
          TextButton.icon(
            onPressed: _history.busy
                ? null
                : () {
                    _remoteAllowed = true;
                    _history.load(remote: true);
                  },
            icon: const Icon(Icons.history_outlined),
            label: const Text('Load older history'),
          ),
        ],
        if (_history.sources.any((s) => s.error != null))
          TextButton(
            onPressed: _history.busy
                ? null
                : () => _history.load(remote: _history.localEnd),
            child: const Text('Retry'),
          ),
      ],
    ),
  );
  String _date(Event event) =>
      '${widget.rooms.length > 1 ? '${event.room.getLocalizedDisplayname()} · ' : ''}${event.originServerTs.toLocal().toString().substring(0, 16)}';

  /// The loaded events matching the query and the sender filter.
  List<Event> _filtered(List<String> terms) => [
    for (final e in _history.events)
      if (sharedVisible(e) &&
          (!widget.initialMedia || sharedSenderMatches(e, _sender)) &&
          (terms.isEmpty ||
              localTextMatches(
                searchFold('${e.body} ${sharedLinks(e).join(' ')}'),
                terms,
              )))
        e,
  ];

  /// Nothing to show yet, but the first pages are still being read: the
  /// projection draws placeholders in its final layout instead of a blank.
  bool _loading(bool empty) =>
      empty &&
      !_history.sources.any((s) => s.error != null) &&
      (_history.busy ||
          _history.sources.every((s) => s.localLimit == 0 && !s.localEnd));

  /// "Anna" in a one-to-one chat (or a merged person), "Others" in groups.
  String get _otherLabel {
    if (!widget.rooms.every((r) => r.isDirectChat)) return 'Others';
    final first = widget.name.trim().split(RegExp(r'\s+')).first;
    return first.isEmpty ? 'Others' : first;
  }

  void _setSender(SharedSender sender) {
    if (sender == _sender) return;
    NotionHaptics.selection();
    setState(() => _sender = sender);
    _scheduleFill();
  }

  /// Who sent it: Telegram's shared media has none, Messenger's filter is
  /// one tap away, so the three choices sit under the tabs as pills.
  Widget _senderFilter() {
    final options = [
      (SharedSender.everyone, 'Everyone'),
      (SharedSender.me, 'Me'),
      (SharedSender.others, _otherLabel),
    ];
    return Semantics(
      container: true,
      label: 'Sent by',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          NotionSpace.inset,
          NotionSpace.xs,
          NotionSpace.inset,
          NotionSpace.xxs,
        ),
        child: Row(
          children: [
            for (final (index, (value, label)) in options.indexed) ...[
              if (index > 0) const SizedBox(width: NotionSpace.xs),
              NotionGlassPill(
                key: ValueKey('shared-sender-${value.name}'),
                label: label,
                selected: value == _sender,
                onPressed: () => _setSender(value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Folded like every other search: "lukasz" finds "Łukasz", each word
    // must occur.
    final terms = localSearchTerms(_query.text);
    final events = _filtered(terms);
    final media = widget.initialMedia;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: notionGlassAppBar(
        title: Text(media ? 'Shared content' : 'Search this conversation'),
      ),
      body: NotionBelowGlassHeader(
        child: Center(
          child: ConstrainedBox(
            // The media grid may use a wide window; message results keep the
            // reading width of every other page.
            constraints: BoxConstraints(
              maxWidth: media ? 960 : NotionSize.contentMaxWidth,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.name, style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _query,
                        onChanged: (_) {
                          setState(() {});
                          _scheduleFill();
                        },
                        decoration: InputDecoration(
                          hintText: media
                              ? 'Search loaded content'
                              : 'Search local messages',
                          prefixIcon: const Icon(Icons.search_outlined),
                          suffixIcon: _query.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _query.clear();
                                    setState(() {});
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (media) ...[
                  Container(
                    alignment: AlignmentDirectional.centerStart,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NotionSpace.inset,
                    ),
                    child: TabBar(
                      controller: _tabs,
                      // Sized to their labels: four fit a phone without
                      // clipping "Messages", large text scrolls.
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: const [
                        Tab(text: 'Media'),
                        Tab(text: 'Messages'),
                        Tab(text: 'Files'),
                        Tab(text: 'Links'),
                      ],
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _senderFilter(),
                  ),
                ],
                _ProgressLine(visible: _history.busy),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _scroll,
                    child: _FadeOnChange(
                      value: media ? (_tab, _sender) : 0,
                      child: NotionEntranceScope(
                        child: media
                            ? IndexedStack(
                                index: _tab.index,
                                children: [
                                  _mediaGrid(events),
                                  _voiceAndRounds(
                                    events.where(sharedMessage).toList(),
                                  ),
                                  _files(events.where(sharedFile).toList()),
                                  _links(events),
                                ],
                              )
                            : _messages(events, terms),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _linkContext(Event event) {
    final text = event.body
        .replaceAll(RegExp(r'https?://\S+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  bool _scroll(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification ||
        notification.metrics.extentAfter > 200 ||
        _history.busy) {
      return false;
    }
    if (_history.sources.any((s) => s.error != null)) return false;
    final signature = _history.sources
        .map((s) => (s.localLimit, s.cursor, s.remoteEnd))
        .join('|');
    if (_autoSignature == signature) return false;
    if (!_history.localEnd || (_remoteAllowed && !_history.remoteEnd)) {
      _autoSignature = signature;
      _history.load(remote: _history.localEnd);
    }
    return false;
  }

  Widget _end(bool empty, {IconData icon = Icons.search_off_outlined}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NotionSizeReveal(
            visible: empty && !_history.busy && !_loading(empty),
            child: NotionEmptyState(
              icon: icon,
              title: switch (_sender) {
                _ when !widget.initialMedia => 'Nothing found',
                SharedSender.everyone => 'Nothing here yet',
                SharedSender.me => 'Nothing from you',
                SharedSender.others => 'Nothing from $_otherLabel',
              },
              message: 'No matches in the loaded history.',
            ),
          ),
          _footer(),
        ],
      );

  /// Message search hits: sender, date and the matching words in bold
  /// (Telegram's results); a tap shows the message in its chat.
  Widget _messages(List<Event> events, List<String> terms) => ListView.builder(
    key: const PageStorageKey('content-messages'),
    padding: const EdgeInsets.symmetric(
      horizontal: NotionSpace.sm,
      vertical: NotionSpace.md,
    ),
    itemCount: events.length + 1,
    itemBuilder: (context, index) {
      if (index == events.length) return _end(events.isEmpty);
      final event = events[index];
      return _entering(
        event.eventId,
        ConversationSearchResultRow(
          hit: LocalMessageHit(event: event, text: event.body),
          terms: terms,
          sourceLabel: widget.rooms.length > 1
              ? event.room.getLocalizedDisplayname()
              : null,
          onTap: () => _openMessage(context, event),
        ),
      );
    },
  );

  /// A month-sectioned list (Telegram's shared files, voice and links): one
  /// header per local calendar month, newest first, then [row]s. While the
  /// first pages are read, placeholder rows hold the layout.
  Widget _monthList<T>({
    required String storageKey,
    required List<T> items,
    required DateTime Function(T) date,
    required Object Function(T) key,
    required Widget Function(T) row,
    required IconData emptyIcon,
  }) {
    final loading = _loading(items.isEmpty);
    return CustomScrollView(
      key: PageStorageKey(storageKey),
      slivers: [
        if (loading)
          SliverPadding(
            padding: const EdgeInsets.all(NotionSpace.inset),
            sliver: SliverToBoxAdapter(
              child: NotionSkeleton(
                child: Column(
                  children: [
                    for (var i = 0; i < 8; i++) const NotionSkeletonRow(),
                  ],
                ),
              ),
            ),
          ),
        for (final (label, monthItems) in groupSharedByMonth(items, date)) ...[
          _monthHeader(label),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.inset),
            sliver: SliverList.builder(
              itemCount: monthItems.length,
              itemBuilder: (context, index) {
                final item = monthItems[index];
                return _entering(key(item), row(item));
              },
            ),
          ),
        ],
        SliverPadding(
          padding: const EdgeInsets.all(NotionSpace.inset),
          sliver: SliverToBoxAdapter(
            child: _end(items.isEmpty && !loading, icon: emptyIcon),
          ),
        ),
      ],
    );
  }

  Widget _monthHeader(String label) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
    sliver: SliverToBoxAdapter(
      child: Semantics(
        header: true,
        child: Text(label, style: NotionType.bodyStrong),
      ),
    ),
  );

  /// Voice notes and rounds: who sent it, its length and when; a tap plays
  /// it in its conversation (consent and capability controls live there).
  Widget _voiceAndRounds(List<Event> events) => _monthList<Event>(
    storageKey: 'content-voice',
    items: events,
    date: (e) => e.originServerTs,
    key: (e) => e.eventId,
    emptyIcon: Icons.mic_none_outlined,
    row: (event) {
      final round = sharedRound(event);
      final duration = _durationOf(event);
      final sender = sharedFromMe(event)
          ? 'You'
          : event.senderFromMemoryOrFallback.calcDisplayname();
      return NotionListRow(
        leading: _MessageGlyph(event, round: round),
        title: round ? 'Video message' : 'Voice message',
        subtitle: [sender, ?duration, _date(event)].join(' · '),
        trailing: const Icon(Icons.play_arrow_rounded),
        onTap: () => _openEvent(context, event),
      );
    },
  );

  Widget _files(List<Event> events) => _monthList<Event>(
    storageKey: 'content-files',
    items: events,
    date: (e) => e.originServerTs,
    key: (e) => e.eventId,
    emptyIcon: Icons.description_outlined,
    row: (event) {
      final info = event.content['info'];
      final duration = _durationOf(event);
      final size = info is Map && info['size'] is num
          ? ' · ${(info['size'] as num).sizeString}'
          : '';
      return NotionListRow(
        leading: Icon(
          event.messageType == MessageTypes.Audio
              ? Icons.audio_file_outlined
              : Icons.description_outlined,
        ),
        title: event.content['filename'] is String
            ? event.content['filename'] as String
            : event.body.isEmpty
            ? 'Shared file'
            : event.body,
        subtitle:
            '${event.messageType == MessageTypes.Audio ? 'Audio · ' : ''}${info is Map && info['mimetype'] is String ? '${info['mimetype']} · ' : ''}${duration == null ? '' : '$duration · '}${_date(event)}$size',
        onTap: () => _openEvent(context, event),
      );
    },
  );

  Widget _links(List<Event> events) => _monthList<(Event, String)>(
    storageKey: 'content-links',
    items: [
      for (final event in events)
        for (final url in sharedLinks(event)) (event, url),
    ],
    date: (l) => l.$1.originServerTs,
    key: (l) => '${l.$1.eventId}|${l.$2}',
    emptyIcon: Icons.link_off_outlined,
    row: (link) {
      final (event, url) = link;
      return NotionListRow(
        leading: const Icon(Icons.link_outlined),
        title: Uri.parse(url).host,
        subtitle: [
          url,
          [
            if (_linkContext(event) case final text when text.isNotEmpty) text,
            _date(event),
          ].join(' · '),
        ].join('\n'),
        onTap: () {
          if (PersonalPrivacy.surfaceUnlocked && !event.redacted) {
            UrlLauncher(context, url).launchUrl();
          }
        },
      );
    },
  );

  /// First-screenful entrance of a list row (the enclosing scope stops it
  /// for rows built later by scrolling or filtering).
  Widget _entering(Object key, Widget child) => NotionEntrance(
    playKey: key,
    afterRoute: false,
    rise: NotionMotion.riseList,
    child: child,
  );

  Widget _mediaGrid(List<Event> events) => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          (constraints.maxWidth /
                  (MediaQuery.textScalerOf(context).scale(1) > 1.5 ? 150 : 120))
              .floor()
              .clamp(2, 6);
      final media = events.where(sharedMedia).toList();
      final months = groupSharedMediaByMonth(media);
      final loading = _loading(media.isEmpty);
      SliverGridDelegate grid() => SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      );
      return CustomScrollView(
        key: const PageStorageKey('content-media'),
        slivers: [
          // Placeholder tiles in the grid's own geometry while the first
          // pages are read; the real tiles grow in over them.
          if (loading)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              sliver: NotionSkeleton.sliver(
                child: SliverGrid(
                  gridDelegate: grid(),
                  delegate: SliverChildBuilderDelegate(
                    (context, _) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.notion.colors.surface,
                        borderRadius: NotionRadius.smAll,
                      ),
                    ),
                    childCount: columns * 4,
                  ),
                ),
              ),
            ),
          for (final (label, monthEvents) in months) ...[
            _monthHeader(label),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid(
                gridDelegate: grid(),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final event = monthEvents[index];
                  final video = event.messageType == MessageTypes.Video;
                  // Tiles of the first screenful grow in; later ones do not.
                  return NotionEntrance(
                    playKey: event.eventId,
                    afterRoute: false,
                    rise: 0,
                    scale: NotionMotion.dialogFrom,
                    child: Semantics(
                      label: '${video ? 'Video' : 'Photo'}, ${_date(event)}',
                      button: true,
                      child: NotionPressable(
                        scale: NotionMotion.pressRow,
                        child: InkWell(
                          onTap: () => _openEvent(context, event, media: media),
                          borderRadius: NotionRadius.smAll,
                          // Rounded tiles; a clip per tile is cheap next to
                          // the image decode (no blur in the grid).
                          child: ClipRRect(
                            borderRadius: NotionRadius.smAll,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_thumbnailAllowed(event))
                                  _MediaSource(
                                    event: event,
                                    child: MxcImage(
                                      event: event,
                                      width: 240,
                                      height: 240,
                                      fit: BoxFit.cover,
                                      isThumbnail: true,
                                      animated: false,
                                      cacheKey: _thumbnailCacheKey(event),
                                      cacheName: event.room.id,
                                      placeholder: _thumbnailPlaceholder,
                                    ),
                                  )
                                else
                                  ColoredBox(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHigh,
                                    child: Icon(
                                      video
                                          ? Icons.videocam_outlined
                                          : Icons.image_outlined,
                                    ),
                                  ),
                                if (video)
                                  Align(
                                    alignment: Alignment.bottomRight,
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: _DurationPill(event),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }, childCount: monthEvents.length),
              ),
            ),
          ],
          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverToBoxAdapter(
              child: _end(
                months.isEmpty && !loading,
                icon: Icons.photo_library_outlined,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The play glyph and length over a video tile.
class _DurationPill extends StatelessWidget {
  final Event event;
  const _DurationPill(this.event);
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: NotionMediaColors.scrim,
      borderRadius: NotionRadius.pillAll,
    ),
    padding: const EdgeInsets.symmetric(
      horizontal: NotionSpace.xs,
      vertical: NotionSpace.xxs,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.play_circle_outline,
          color: NotionMediaColors.onScrim,
          size: 18,
        ),
        if (_durationOf(event) case final duration?) ...[
          const SizedBox(width: 4),
          Text(
            duration,
            style: NotionType.caption.copyWith(
              color: NotionMediaColors.onScrim,
            ),
          ),
        ],
      ],
    ),
  );
}

/// The leading glyph of a voice or round row: the round's own frame in a
/// circle when thumbnails may show (it is round in the chat too), else an
/// icon like the file rows.
class _MessageGlyph extends StatelessWidget {
  final Event event;
  final bool round;
  const _MessageGlyph(this.event, {required this.round});
  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      round ? Icons.video_camera_front_outlined : Icons.mic_none_outlined,
    );
    if (!round || !_thumbnailAllowed(event)) return icon;
    return SizedBox.square(
      dimension: NotionSize.iconLg,
      child: ClipOval(
        child: MxcImage(
          event: event,
          width: NotionSize.iconLg,
          height: NotionSize.iconLg,
          fit: BoxFit.cover,
          isThumbnail: true,
          animated: false,
          cacheKey: _thumbnailCacheKey(event),
          cacheName: event.room.id,
          placeholder: (_) => icon,
        ),
      ),
    );
  }
}

/// A 1 px progress line that only shows up for waits long enough to notice
/// and opens/closes smoothly instead of shifting the content below.
class _ProgressLine extends StatelessWidget {
  final bool visible;
  const _ProgressLine({required this.visible});
  @override
  Widget build(BuildContext context) => NotionSizeReveal(
    visible: visible,
    duration: NotionMotion.short,
    child: const NotionDelayedReveal(
      placeholder: SizedBox(height: 1),
      child: LinearProgressIndicator(minHeight: 1),
    ),
  );
}

/// Restarts a short fade-and-rise of [child] whenever [value] changes (tab
/// switches). One child, one controller: subtrees keep their state.
class _FadeOnChange extends StatefulWidget {
  final Object value;
  final Widget child;
  const _FadeOnChange({required this.value, required this.child});
  @override
  State<_FadeOnChange> createState() => _FadeOnChangeState();
}

class _FadeOnChangeState extends State<_FadeOnChange>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: NotionMotion.medium,
    value: 1,
  );
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, .6, curve: NotionMotion.standard),
  );
  late final Animation<Offset> _rise =
      Tween(begin: const Offset(0, .015), end: Offset.zero).animate(
        CurvedAnimation(parent: _controller, curve: NotionMotion.emphasized),
      );

  @override
  void didUpdateWidget(_FadeOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !NotionMotion.reduced(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: SlideTransition(position: _rise, child: widget.child),
  );
}
