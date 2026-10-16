// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:fluffychat/pages/image_viewer/image_viewer.dart';
import 'package:fluffychat/personal/merged_chat_page.dart' show SourceChatPage;
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:personal_core/personal_core.dart' show RoundMediaPolicy;
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:fluffychat/personal/ui/conversation_content_controller.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

bool _thumbnailAllowed(Event event) =>
    event.showThumbnail &&
    event.hasThumbnail &&
    RoundMediaPolicy.fromContent(event.content).canPlay;

Widget _thumbnailPlaceholder(BuildContext context) => ColoredBox(
  color: Theme.of(context).colorScheme.surfaceContainerHigh,
  child: const Center(child: Icon(Icons.image_outlined)),
);

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
  void _create() {
    _scopeKey = _scope(widget.rooms);
    _history = ConversationContentController(
      widget.rooms.map(MatrixContentSource.new).toList(),
      unlocked: () => PersonalPrivacy.surfaceUnlocked,
      privacyGeneration: () => PersonalPrivacy.surfaceGeneration,
    );
    _history.addListener(_updated);
    _history.load();
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void didUpdateWidget(NotionLocalSharedPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_scopeKey != _scope(widget.rooms)) {
      _history.dispose();
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
        if (_history.busy) const LinearProgressIndicator(minHeight: 1),
        if (_history.sources.any((s) => s.error != null))
          TextButton(
            onPressed: _history.busy
                ? null
                : () => _history.load(refresh: true),
            child: const Text('Some shared content could not load. Retry'),
          ),
        if (events.isEmpty && !_history.busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No photos or videos in the loaded local history.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        if (events.isNotEmpty)
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: events.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) =>
                  _SharedPreviewBlock(events[index]),
            ),
          ),
      ],
    );
  }
}

class _SharedPreviewBlock extends StatelessWidget {
  final Event event;
  const _SharedPreviewBlock(this.event);
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
            ? MxcImage(
                event: event,
                width: 144,
                height: 92,
                fit: BoxFit.cover,
                isThumbnail: true,
                animated: false,
                placeholder: _thumbnailPlaceholder,
              )
            : null,
        audio: event.messageType == MessageTypes.Audio,
        video: event.messageType == MessageTypes.Video,
        onTap: () => _openEvent(context, event),
      ),
    );
  }
}

void _openEvent(BuildContext context, Event event) {
  if (!PersonalPrivacy.surfaceUnlocked || event.redacted) return;
  if (event.room.client.userID == null) return;
  final source = PersonalClient.of(event.room.client).source(event);
  if (Matrix.of(context).client.userID != source.conversation.accountId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => SourceChatPage(source: source)),
    );
    return;
  }
  if (event.messageType == MessageTypes.Image && event.showThumbnail) {
    showDialog(
      context: context,
      builder: (_) => ImageViewer(event, outerContext: context),
    );
  } else {
    // Reuse the actual source conversation for protected/video/audio playback,
    // with its consent and capability controls. Never create a new player here.
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
            history.sources.any((s) => s.error != null))
          return;
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
                                Container(
                                  height: 2,
                                  color: index == _tab
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.transparent,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              if (_history.busy) const LinearProgressIndicator(minHeight: 1),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _scroll,
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
                          if (index == links.length) return _end(links.isEmpty);
                          final (event, url) = links[index];
                          return NotionListRow(
                            leading: const Icon(Icons.link_outlined),
                            title: Uri.parse(url).host,
                            subtitle:
                                '$url\n${_linkContext(event)} · ${_date(event)}',
                            onTap: () {
                              if (PersonalPrivacy.surfaceUnlocked &&
                                  !event.redacted)
                                UrlLauncher(context, url).launchUrl();
                            },
                          );
                        },
                      ),
                    ],
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
        _history.busy)
      return false;
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
      final info = event.content['info'];
      final size = info is Map && info['size'] is num
          ? ' · ${((info['size'] as num) / 1024).ceil()} KB'
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
            '${event.messageType == MessageTypes.Audio ? 'Audio · ' : ''}${info is Map && info['mimetype'] is String ? '${info['mimetype']} · ' : ''}${info is Map && info['duration'] is num ? '${Duration(milliseconds: (info['duration'] as num).toInt()).inMinutes}:${(Duration(milliseconds: (info['duration'] as num).toInt()).inSeconds % 60).toString().padLeft(2, '0')} · ' : ''}${_date(event)}$size',
        onTap: () => _openEvent(context, event),
      );
    },
  );
  Widget _mediaGrid(List<Event> events) => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          (constraints.maxWidth /
                  (MediaQuery.textScalerOf(context).scale(1) > 1.5 ? 150 : 120))
              .floor()
              .clamp(2, 6);
      final months = <String, List<Event>>{};
      for (final event in events.where(sharedMedia)) {
        final date = event.originServerTs.toLocal().toString().substring(0, 7);
        (months[date] ??= []).add(event);
      }
      return CustomScrollView(
        key: const PageStorageKey('content-media'),
        slivers: [
          for (final month in months.entries) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              sliver: SliverToBoxAdapter(child: Text(month.key)),
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
                  final event = month.value[index];
                  final video = event.messageType == MessageTypes.Video;
                  return Semantics(
                    label: '${video ? 'Video' : 'Photo'}, ${_date(event)}',
                    button: true,
                    child: InkWell(
                      onTap: () => _openEvent(context, event),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_thumbnailAllowed(event))
                            MxcImage(
                              event: event,
                              width: 240,
                              height: 240,
                              fit: BoxFit.cover,
                              isThumbnail: true,
                              animated: false,
                              placeholder: _thumbnailPlaceholder,
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
                                  color: Colors.black54,
                                  padding: const EdgeInsets.all(3),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.play_circle_outline,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                      if (event.infoMap['duration'] is num) ...[
                                        const SizedBox(width: 4),
                                        Text(
                                          '${Duration(milliseconds: (event.infoMap['duration'] as num).toInt()).inSeconds}s',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
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
                  );
                }, childCount: month.value.length),
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
