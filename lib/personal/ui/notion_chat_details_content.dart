// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/pages/image_viewer/image_viewer.dart';
import 'package:fluffychat/personal/merged_chat_page.dart' show SourceChatPage;
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

bool _visible(Event event) =>
    !event.redacted && event.type == EventTypes.Message;
bool _media(Event event) =>
    {
      MessageTypes.Image,
      MessageTypes.Video,
      MessageTypes.File,
      MessageTypes.Audio,
    }.contains(event.messageType) ||
    RegExp(r'https?://\S+').hasMatch(event.body);

/// A bounded local preview. No total is inferred from a partial history page.
class NotionLocalSharedPreview extends StatefulWidget {
  final List<Room> rooms;
  const NotionLocalSharedPreview({super.key, required this.rooms});
  @override
  State<NotionLocalSharedPreview> createState() =>
      _NotionLocalSharedPreviewState();
}

class _NotionLocalSharedPreviewState extends State<NotionLocalSharedPreview> {
  late Future<List<Event>> _events;
  @override
  void initState() {
    super.initState();
    _events = _load();
  }

  @override
  void didUpdateWidget(NotionLocalSharedPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rooms.map((r) => r.id).join('|') !=
        widget.rooms.map((r) => r.id).join('|'))
      _events = _load();
  }

  Future<List<Event>> _load() async {
    if (!PersonalPrivacy.surfaceUnlocked) return [];
    final entries = <Event>[];
    for (final room in widget.rooms) {
      entries.addAll(
        await room.client.database.getEventList(room, start: 0, limit: 80),
      );
    }
    if (!PersonalPrivacy.surfaceUnlocked) return [];
    return entries.where(_visible).where(_media).toList()
      ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Event>>(
    future: _events,
    builder: (context, snapshot) {
      final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
      if (snapshot.hasError)
        return TextButton(
          onPressed: () => setState(() => _events = _load()),
          child: const Text('Shared content could not load. Retry'),
        );
      if (!snapshot.hasData)
        return const Padding(
          padding: EdgeInsets.all(12),
          child: LinearProgressIndicator(minHeight: 1),
        );
      final events = snapshot.data!;
      if (events.isEmpty)
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'No shared content in the loaded local history.',
            style: TextStyle(color: secondary, fontSize: 13),
          ),
        );
      return SizedBox(
        height: 92,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: events.length.clamp(0, 3),
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) => _SharedPreviewBlock(events[index]),
        ),
      );
    },
  );
}

class _SharedPreviewBlock extends StatelessWidget {
  final Event event;
  const _SharedPreviewBlock(this.event);
  @override
  Widget build(BuildContext context) {
    final image =
        event.messageType == MessageTypes.Image && event.showThumbnail;
    return NotionSharedContentBlock(
      label: image
          ? 'Photo'
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
            )
          : null,
      audio: event.messageType == MessageTypes.Audio,
      video: event.messageType == MessageTypes.Video,
      onTap: () => _openEvent(context, event),
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
  final _events = <String, Event>{};
  final _offsets = <String, int>{};
  final _localEnd = <String>{};
  final _remoteEnd = <String>{};
  final _cursors = <String, String?>{};
  bool _loading = false;
  late bool _mediaOnly;
  String? _error;
  @override
  void initState() {
    super.initState();
    _mediaOnly = widget.initialMedia;
    _loadLocal();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    if (_loading || !PersonalPrivacy.surfaceUnlocked) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      for (final room in widget.rooms) {
        if (_localEnd.contains(room.id)) continue;
        final offset = _offsets[room.id] ?? 0;
        final page = await room.client.database.getEventList(
          room,
          start: offset,
          limit: 80,
        );
        if (!mounted || !PersonalPrivacy.surfaceUnlocked) return;
        for (final event in page.where(_visible)) {
          _events['${room.id}:${event.eventId}'] = event;
        }
        _offsets[room.id] = offset + page.length;
        if (page.length < 80) _localEnd.add(room.id);
        if (page.any((e) => e.type == EventTypes.RoomCreate))
          _remoteEnd.add(room.id);
      }
    } catch (_) {
      if (mounted)
        _error =
            'Local history could not load. Retry without clearing your results.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadEarlier() async {
    if (_loading || !PersonalPrivacy.surfaceUnlocked) return;
    // This explicit action downloads history. Search text is matched locally
    // and is never sent to a server-side directory or search endpoint.
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      for (final room in widget.rooms) {
        if (_remoteEnd.contains(room.id)) continue;
        final page = await room.searchEvents(
          nextBatch: _cursors[room.id] ?? room.prev_batch,
          limit: 80,
          searchFunc: _visible,
        );
        if (!mounted || !PersonalPrivacy.surfaceUnlocked) return;
        for (final event in page.events) {
          _events['${room.id}:${event.eventId}'] = event;
        }
        _cursors[room.id] = page.nextBatch;
        if (page.nextBatch == null) _remoteEnd.add(room.id);
      }
    } catch (_) {
      if (mounted)
        _error =
            'Earlier history could not load. Your loaded results are still available.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final events =
        _events.values
            .where(_visible)
            .where((e) => !_mediaOnly || _media(e))
            .where((e) => query.isEmpty || e.body.toLowerCase().contains(query))
            .toList()
          ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final localComplete = _localEnd.length == widget.rooms.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _mediaOnly ? 'Shared content' : 'Search this conversation',
          style: const TextStyle(fontSize: 17),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.name,
                      style: TextStyle(fontSize: 13, color: secondary),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _query,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: _mediaOnly
                            ? 'Search loaded media, files & links'
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
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _mediaOnly = false),
                          child: Text(
                            'Messages',
                            style: TextStyle(
                              fontWeight: !_mediaOnly
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _mediaOnly = true),
                          child: Text(
                            'Media, files & links',
                            style: TextStyle(
                              fontWeight: _mediaOnly
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${events.length} matching items in loaded history',
                      style: TextStyle(fontSize: 12, color: secondary),
                    ),
                  ],
                ),
              ),
              if (_loading) const LinearProgressIndicator(minHeight: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  itemCount: events.length + 1,
                  itemBuilder: (context, index) {
                    if (index == events.length)
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (events.isEmpty && !_loading)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                query.isEmpty
                                    ? 'No items in the loaded history.'
                                    : 'No matches in the loaded history.',
                                style: TextStyle(color: secondary),
                              ),
                            ),
                          if (_error != null)
                            Semantics(
                              liveRegion: true,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(_error!),
                              ),
                            ),
                          if (!localComplete)
                            TextButton.icon(
                              onPressed: _loading ? null : _loadLocal,
                              icon: const Icon(Icons.expand_more),
                              label: const Text('Load more local history'),
                            )
                          else if (_remoteEnd.length < widget.rooms.length) ...[
                            Text(
                              'Earlier messages can be downloaded from these sources. Your search stays on this device.',
                              style: TextStyle(fontSize: 12, color: secondary),
                            ),
                            TextButton.icon(
                              onPressed: _loading ? null : _loadEarlier,
                              icon: const Icon(Icons.history_outlined),
                              label: Text(
                                _error == null
                                    ? 'Download earlier history'
                                    : 'Retry earlier history',
                              ),
                            ),
                          ],
                        ],
                      );
                    final event = events[index];
                    final urls = RegExp(r'https?://\S+')
                        .allMatches(event.body)
                        .map((match) => match.group(0)!)
                        .toList();
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          NotionListRow(
                            leading: Icon(
                              event.messageType == MessageTypes.Image
                                  ? Icons.image_outlined
                                  : event.messageType == MessageTypes.Audio
                                  ? Icons.audio_file_outlined
                                  : event.messageType == MessageTypes.File
                                  ? Icons.description_outlined
                                  : Icons.chat_bubble_outline,
                            ),
                            title: event.messageType == MessageTypes.Audio
                                ? 'Voice message'
                                : event.body,
                            subtitle:
                                '${widget.rooms.length > 1 ? '${event.room.getLocalizedDisplayname()} · ' : ''}${event.originServerTs.toLocal().toString().substring(0, 16)}',
                            onTap: () => _openEvent(context, event),
                          ),
                          if (event.messageType == MessageTypes.Image &&
                              event.showThumbnail)
                            _SharedPreviewBlock(event),
                          for (final url in urls.take(3))
                            TextButton.icon(
                              onPressed: () =>
                                  UrlLauncher(context, url).launchUrl(),
                              icon: const Icon(Icons.link_outlined, size: 18),
                              label: Text(
                                url,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
