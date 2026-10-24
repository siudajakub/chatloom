// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/merged_chat_page.dart' show SourceChatPage;
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/conversation_content_controller.dart';
import 'package:chatloom/personal/ui/notion_chat_details_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
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
List<(String, List<Event>)> groupSharedMediaByMonth(Iterable<Event> events) {
  final months = <int, (String, List<Event>)>{};
  for (final event in events) {
    final date = event.originServerTs.toLocal();
    months
        .putIfAbsent(
          date.year * 12 + date.month,
          () => (sharedMonthLabel(date), <Event>[]),
        )
        .$2
        .add(event);
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
    // new player here.
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => SourceChatPage(source: source)),
    );
  }
}

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
    extends State<NotionConversationContentPage> {
  final _query = TextEditingController();
  late ConversationContentController _history;
  late String _scopeKey;
  late Client _account;
  int _tab = 0;
  final _subscriptions = <StreamSubscription>[];
  bool _remoteAllowed = false;
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
    final history = _history;
    () async {
      for (var page = 0; page < 3; page++) {
        await history.load();
        if (!mounted ||
            !identical(history, _history) ||
            history.localEnd ||
            history.sources.any((s) => s.error != null)) {
          return;
        }
      }
    }();
  }

  void _updated() {
    if (mounted) setState(() {});
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
      _tab = 0;
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
  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final events = _history.events
        .where(sharedVisible)
        .where(
          (e) =>
              query.isEmpty ||
              '${e.body} ${sharedLinks(e).join(' ')}'.toLowerCase().contains(
                query,
              ),
        )
        .toList();
    final links = [
      for (final event in events)
        for (final url in sharedLinks(event)) (event, url),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initialMedia ? 'Shared content' : 'Search this conversation',
          style: const TextStyle(fontSize: 17),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
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
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: widget.initialMedia
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
              if (widget.initialMedia)
                Row(
                  children: [
                    for (final (index, title) in [
                      'Media',
                      'Files',
                      'Links',
                    ].indexed)
                      Expanded(
                        child: Semantics(
                          selected: index == _tab,
                          child: TextButton(
                            onPressed: () => setState(() => _tab = index),
                            child: Column(
                              children: [
                                Text(
                                  title,
                                  style: TextStyle(
                                    fontWeight: index == _tab
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // The underline grows from the centre into
                                // the selected tab and shrinks out of the
                                // previous one.
                                AnimatedScale(
                                  duration: NotionMotion.of(
                                    context,
                                    NotionMotion.medium,
                                  ),
                                  curve: index == _tab
                                      ? NotionMotion.emphasized
                                      : NotionMotion.exitFast,
                                  scale: index == _tab ? 1 : 0,
                                  child: Container(
                                    height: 2,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              _ProgressLine(visible: _history.busy),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _scroll,
                  child: _FadeOnChange(
                    value: widget.initialMedia ? _tab : 1,
                    child: NotionEntranceScope(
                      child: IndexedStack(
                        index: widget.initialMedia ? _tab : 1,
                        children: [
                          _mediaGrid(events),
                          _list(
                            widget.initialMedia
                                ? events.where(sharedFile).toList()
                                : events,
                          ),
                          ListView.builder(
                            key: const PageStorageKey('content-links'),
                            padding: const EdgeInsets.all(20),
                            itemCount: links.length + 1,
                            itemBuilder: (context, index) {
                              if (index == links.length) {
                                return _end(links.isEmpty);
                              }
                              final (event, url) = links[index];
                              return _entering(
                                '${event.eventId}|$url',
                                NotionListRow(
                                  leading: const Icon(Icons.link_outlined),
                                  title: Uri.parse(url).host,
                                  subtitle:
                                      '$url\n${_linkContext(event)} · ${_date(event)}',
                                  onTap: () {
                                    if (PersonalPrivacy.surfaceUnlocked &&
                                        !event.redacted) {
                                      UrlLauncher(context, url).launchUrl();
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
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

  Widget _end(bool empty) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (empty && !_history.busy)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No matches in the loaded history.'),
        ),
      _footer(),
    ],
  );
  Widget _list(List<Event> events) => ListView.builder(
    key: const PageStorageKey('content-files'),
    padding: const EdgeInsets.all(20),
    itemCount: events.length + 1,
    itemBuilder: (context, index) {
      if (index == events.length) return _end(events.isEmpty);
      final event = events[index];
      // Search hits that are not files read as messages, not file rows.
      if (!sharedFile(event)) {
        return _entering(event.eventId, _messageRow(event, events));
      }
      final info = event.content['info'];
      final duration = _durationOf(event);
      final size = info is Map && info['size'] is num
          ? ' · ${((info['size'] as num) / 1024).ceil()} KB'
          : '';
      return _entering(
        event.eventId,
        NotionListRow(
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
        ),
      );
    },
  );

  /// A search hit that is a message (text, photo, video, sticker): who
  /// sent it, a one-paragraph snippet and when. A photo or video opens the
  /// viewer, anything else its conversation.
  Widget _messageRow(Event event, List<Event> listed) {
    final (icon, kind) = switch (event.messageType) {
      MessageTypes.Image => (Icons.image_outlined, 'Photo'),
      MessageTypes.Video => (Icons.videocam_outlined, 'Video'),
      MessageTypes.Sticker => (Icons.emoji_emotions_outlined, 'Sticker'),
      MessageTypes.Location => (Icons.place_outlined, 'Location'),
      _ => (Icons.chat_bubble_outline, null),
    };
    // A photo's or video's body is its file name unless it has a caption.
    final filename = event.content['filename'];
    final media = {
      MessageTypes.Image,
      MessageTypes.Video,
    }.contains(event.messageType);
    final body = media && (filename is! String || filename == event.body)
        ? ''
        : event.body;
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final snippet = text.length > 160 ? '${text.substring(0, 160)}…' : text;
    final line = [?kind, if (snippet.isNotEmpty) snippet].join(' · ');
    return NotionListRow(
      leading: Icon(icon),
      title: event.senderFromMemoryOrFallback.calcDisplayname(),
      subtitle: line.isEmpty ? _date(event) : '$line\n${_date(event)}',
      onTap: () =>
          _openEvent(context, event, media: listed.where(sharedMedia).toList()),
    );
  }

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
      return CustomScrollView(
        key: const PageStorageKey('content-media'),
        slivers: [
          for (final (label, monthEvents) in months) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Semantics(
                  header: true,
                  child: Text(label, style: NotionType.bodyStrong),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
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
                                      child: Container(
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
                                            if (_durationOf(event)
                                                case final duration?) ...[
                                              const SizedBox(width: 4),
                                              Text(
                                                duration,
                                                style: NotionType.caption
                                                    .copyWith(
                                                      color: NotionMediaColors
                                                          .onScrim,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
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
            sliver: SliverToBoxAdapter(child: _end(months.isEmpty)),
          ),
        ],
      );
    },
  );
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
