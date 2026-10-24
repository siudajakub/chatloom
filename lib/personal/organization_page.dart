// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/private_avatar.dart';
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/cover_resize_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

const _bubbleColors = <int>[
  0xffdfebdb,
  0xffdbe6f5,
  0xfff0dfe9,
  0xfff1e6d2,
  0xffd8eeec,
  0xffe5def2,
  0xfff2dddd,
  0xffe5e7eb,
];

/// Actual private preferences, shared by the two clients through personal sync.
class OrganizationPage extends StatefulWidget {
  final PersonalClient personal;
  final Room? room;
  const OrganizationPage({super.key, required this.personal, this.room});
  @override
  State<OrganizationPage> createState() => _OrganizationPageState();
}

class _OrganizationPageState extends State<OrganizationPage> {
  bool _busy = false;
  PersonalClient get personal => widget.personal;
  InboxProjection get projection => InboxProjection(personal);

  @override
  void initState() {
    super.initState();
    PersonalPageLoad.request(context, personal);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not save this change. Check private sync and try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _waiting(String entityKey) =>
      personal.pending.values.any((op) => op.entityId == entityKey);
  bool _canEdit(String entityKey) =>
      personal.ready && !_busy && !_waiting(entityKey);
  Future<void> _saveMetadata(ConversationMetadata metadata) async {
    final existing = personal.values['org:${metadata.entityId}'];
    final value = {...metadata.toJson()}.cast<String, dynamic>();
    if (metadata.archived &&
        (existing?['archived'] != true ||
            !projection.metadataForEntity(metadata.entityId).archived)) {
      value['archivedAt'] = DateTime.now().toUtc().toIso8601String();
      final room = widget.room;
      final group = room == null ? null : projection.groupFor(room);
      final rooms = group == null
          ? [?room]
          : group.members
                .map((m) => personal.client.getRoomById(m.roomId))
                .whereType<Room>();
      value['archiveSources'] = {
        for (final source in rooms) source.id: source.lastEvent?.eventId,
      };
    } else if (metadata.archived && existing?['archiveSources'] is Map) {
      value['archiveSources'] = existing!['archiveSources'];
      if (existing['archivedAt'] is String) {
        value['archivedAt'] = existing['archivedAt'];
      }
    }
    await personal.put('org:${metadata.entityId}', value);
  }

  Future<void> _avatar(String entity) =>
      pickAndUploadPrivateAvatar(personal, entity);

  Future<void> _theme(ConversationMetadata metadata) async {
    final result = await showChatThemeDialog(context, metadata.theme);
    if (result != null) await _saveMetadata(metadata.setTheme(result));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) {
      final room = widget.room;
      final metadata = room == null ? null : projection.metadataFor(room);
      final key = metadata == null ? '' : 'org:${metadata.entityId}';
      final editing = metadata != null && _canEdit(key);
      return Scaffold(
        appBar: AppBar(title: const Text('Colours & avatar')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            // Rows rise in once; rows that depend on state reveal in place.
            child: NotionEntranceScope(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: NotionEntrance.stagger([
                  NotionSizeReveal(
                    visible: _busy,
                    child: const NotionDelayedReveal(
                      child: LinearProgressIndicator(),
                    ),
                  ),
                  if (!personal.ready)
                    const ListTile(
                      leading: Icon(Icons.lock_outline),
                      title: Text('Private sync is unavailable'),
                      subtitle: Text(
                        'Connect it in Settings › Advanced › Private sync to change these.',
                      ),
                    ),
                  if (metadata != null && room != null) ...[
                    ListTile(
                      leading: PrivateAvatarPreview(
                        personal: personal,
                        entityId: metadata.entityId,
                      ),
                      title: Text(projection.displayName(room)),
                      subtitle: const Text(
                        'Private preferences for your own devices.',
                      ),
                    ),
                    NotionSizeReveal(
                      visible: _waiting(key),
                      child: const ListTile(
                        leading: Icon(Icons.sync),
                        title: Text('Change awaiting sync confirmation'),
                      ),
                    ),
                    // Notifications, visibility, low priority, pin, archive
                    // and the nickname are on Chat details (CS-06).
                    _pressable(
                      ListTile(
                        leading: const Icon(Icons.add_photo_alternate_outlined),
                        title: const Text('Private avatar'),
                        subtitle: const Text(
                          'Privately encrypted. PNG, JPEG or WebP, up to 2 MB.',
                        ),
                        onTap:
                            personal.ready &&
                                !_busy &&
                                !_waiting('avatar:${metadata.entityId}')
                            ? () => _run(() => _avatar(metadata.entityId))
                            : null,
                      ),
                    ),
                    NotionSizeReveal(
                      visible: personal.values.containsKey(
                        'avatar:${metadata.entityId}',
                      ),
                      child: _pressable(
                        ListTile(
                          leading: const Icon(Icons.hide_image_outlined),
                          title: const Text('Use the network’s photo'),
                          onTap: personal.ready && !_busy
                              ? () => _run(
                                  () => personal.delete(
                                    'avatar:${metadata.entityId}',
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    _pressable(
                      ListTile(
                        leading: const Icon(Icons.palette_outlined),
                        title: const Text('Conversation colours'),
                        onTap: editing
                            ? () => _run(() => _theme(metadata))
                            : null,
                      ),
                    ),
                    NotionSizeReveal(
                      visible: metadata.theme != null,
                      child: _pressable(
                        ListTile(
                          title: const Text('Restore default appearance'),
                          onTap: editing
                              ? () => _run(
                                  () => _saveMetadata(metadata.setTheme(null)),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ],
                  if (room == null) ...[
                    const ListTile(
                      leading: Icon(Icons.chat_bubble_outline),
                      title: Text('Choose a conversation'),
                      subtitle: Text(
                        'Open Chat details from a conversation to change its colours and avatar.',
                      ),
                    ),
                    for (final source
                        in projection
                            .rooms(
                              personal.client.rooms,
                              filter: InboxFilter.all,
                            )
                            .where((r) => r.membership == Membership.join))
                      _pressable(
                        ListTile(
                          leading: const Icon(Icons.chat_bubble_outline),
                          title: Text(projection.displayName(source)),
                          subtitle: const Text(
                            'Colours and avatar',
                          ),
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => OrganizationPage(
                                personal: personal,
                                room: source,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Picks an image and stores it as the private avatar of [entity]; false
/// when nothing was picked. Throws for an unsupported or too large image.
Future<bool> pickAndUploadPrivateAvatar(
  PersonalClient personal,
  String entity,
) async {
  final selection = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
  );
  if (selection == null) return false;
  final length = await selection.length();
  if (length == null || length <= 0 || length > 2 * 1024 * 1024) {
    throw ArgumentError('Avatar must be an image under 2 MiB');
  }
  final bytes = await selection.readAsBytes();
  if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
    throw ArgumentError('Avatar must be an image under 2 MiB');
  }
  await uploadPrivateAvatar(personal, entity, bytes);
  return true;
}

/// The private colours of a conversation; null when cancelled.
Future<ChatTheme?> showChatThemeDialog(
  BuildContext context,
  ChatTheme? initial,
) => showNotionCustomDialog<ChatTheme>(
  context: context,
  builder: (_) => _ThemeDialog(initial: initial),
);

class _ColorChoices extends StatelessWidget {
  final List<int> colors;
  final int? value;
  final ValueChanged<int> onChanged;
  const _ColorChoices({
    required this.colors,
    required this.value,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    children: [
      for (var i = 0; i < colors.length; i++)
        Semantics(
          label: 'Color ${i + 1}',
          selected: value == colors[i],
          button: true,
          child: IconButton(
            tooltip: 'Color ${i + 1}',
            onPressed: () => onChanged(colors[i]),
            icon: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Color(colors[i]),
                shape: BoxShape.circle,
              ),
              // The check pops in on the picked swatch and out of the old one.
              child: NotionPop(
                visible: value == colors[i],
                playOnMount: false,
                bounce: false,
                child: Icon(
                  Icons.check,
                  color: Color(colors[i]).computeLuminance() > 0.5
                      ? Colors.black
                      : Colors.white,
                  size: 18,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _ThemeDialog extends StatefulWidget {
  final ChatTheme? initial;
  const _ThemeDialog({this.initial});
  @override
  State<_ThemeDialog> createState() => _ThemeDialogState();
}

class _ThemeDialogState extends State<_ThemeDialog> {
  late int? incoming = widget.initial?.incomingColor;
  late int? outgoing = widget.initial?.outgoingColor;
  late int? background = widget.initial?.backgroundColor;
  @override
  Widget build(BuildContext context) => NotionDialog(
    title: 'Conversation colors',
    content: SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Incoming message appearance'),
            _ColorChoices(
              colors: _bubbleColors,
              value: incoming,
              onChanged: (v) => setState(() => incoming = v),
            ),
            const SizedBox(height: 16),
            const Text('Outgoing message appearance'),
            _ColorChoices(
              colors: _bubbleColors,
              value: outgoing,
              onChanged: (v) => setState(() => outgoing = v),
            ),
            const SizedBox(height: 16),
            const Text('Background'),
            _ColorChoices(
              colors: [
                0xfffafafa,
                0xfff0f2f4,
                0xfff8f4ec,
                0xffecf3f0,
                0xff202329,
                0xff292329,
              ],
              value: background,
              onChanged: (v) => setState(() => background = v),
            ),
            NotionButton.ghost(
              label: 'Use default colors',
              onPressed: () => setState(() {
                incoming = null;
                outgoing = null;
                background = null;
              }),
            ),
          ],
        ),
      ),
    ),
    actions: [
      NotionButton.ghost(
        label: 'Cancel',
        onPressed: () => Navigator.pop(context),
      ),
      NotionButton.primary(
        label: 'Save',
        onPressed: () => Navigator.pop(
          context,
          ChatTheme(
            incomingColor: incoming,
            outgoingColor: outgoing,
            backgroundColor: background,
          ),
        ),
      ),
    ],
  );
}

/// The blob is SDK-encrypted before upload. Only its encrypted journal metadata
/// includes the attachment key; the source room avatar is never modified.
Future<void> uploadPrivateAvatar(
  PersonalClient personal,
  String entity,
  Uint8List input,
) async {
  final journal = personal.journal;
  if (!personal.ready || journal == null || !journal.encrypted) {
    throw StateError('Encrypted sync unavailable');
  }
  final members = await journal.requestParticipants();
  if (members.any(
    (m) =>
        (m.membership == Membership.join ||
            m.membership == Membership.invite) &&
        m.id != personal.client.userID,
  )) {
    throw StateError('Unsafe journal membership');
  }
  if (input.isEmpty || input.length > 2 * 1024 * 1024) {
    throw ArgumentError('Image size unsupported');
  }
  final mime = lookupMimeType('avatar', headerBytes: input);
  if (!{'image/png', 'image/jpeg', 'image/webp'}.contains(mime)) {
    throw ArgumentError('Image format unsupported');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(input);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  Uint8List bytes;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 4096 ||
        descriptor.height > 4096 ||
        descriptor.width * descriptor.height > 8000000) {
      throw ArgumentError('Image dimensions unsupported');
    }
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final scale = longest > 512 ? 512 / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round(),
      targetHeight: (descriptor.height * scale).round(),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Image conversion failed');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
  final encrypted = await MatrixFile(
    bytes: bytes,
    name: 'avatar.png',
    mimeType: 'image/png',
  ).encrypt();
  final uri = await personal.client.uploadContent(
    encrypted.data,
    filename: 'avatar.enc',
    contentType: 'application/octet-stream',
  );
  await personal.put(privateAvatarKey(entity), {
    'mxc': uri.toString(),
    'iv': encrypted.iv,
    'key': encrypted.k,
    'sha256': encrypted.sha256,
    'mimeType': 'image/png',
    'size': bytes.length,
  });
}

class PrivateAvatarPreview extends StatefulWidget {
  final PersonalClient personal;
  final String entityId;
  final double radius;
  final Widget? fallback;
  const PrivateAvatarPreview({
    super.key,
    required this.personal,
    required this.entityId,
    this.radius = 22,
    this.fallback,
  });
  @override
  State<PrivateAvatarPreview> createState() => _PrivateAvatarPreviewState();
}

class _PrivateAvatarPreviewState extends State<PrivateAvatarPreview> {
  Map<String, dynamic>? _value;
  String? _fingerprint;
  Future<Uint8List?>? _loading;

  @override
  void initState() {
    super.initState();
    widget.personal.addListener(_personalChanged);
    _read();
  }

  @override
  void didUpdateWidget(PrivateAvatarPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.personal, widget.personal)) {
      oldWidget.personal.removeListener(_personalChanged);
      widget.personal.addListener(_personalChanged);
    }
    if (!identical(oldWidget.personal, widget.personal) ||
        oldWidget.entityId != widget.entityId) {
      _read();
    }
  }

  @override
  void dispose() {
    widget.personal.removeListener(_personalChanged);
    super.dispose();
  }

  /// Every row listens to the private store, which notifies for any change
  /// of any value; only a change of this row's avatar value rebuilds it.
  void _personalChanged() {
    if (mounted && _read()) setState(() {});
  }

  /// Picks up this entity's avatar value; true when it changed. The replica
  /// replaces a value's map on every update, so an identical map is
  /// unchanged without encoding it.
  bool _read() {
    final value = widget.personal.values[privateAvatarKey(widget.entityId)];
    if (identical(value, _value)) return false;
    _value = value;
    final fingerprint = value == null ? null : jsonEncode(value);
    if (fingerprint == _fingerprint) return false;
    _fingerprint = fingerprint;
    _loading = value == null
        ? null
        : _download(Map<String, dynamic>.from(value));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final size = widget.radius * 2;
    final fallback =
        widget.fallback ??
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
          ),
          child: const Icon(Icons.person_outline),
        );
    if (_loading == null) return fallback;
    // Decode the uploaded original at the avatar's physical size.
    final decodeSize = (size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 1024);
    return FutureBuilder<Uint8List?>(
      future: _loading,
      initialData: cachedPrivateAvatar(value),
      // A freshly decrypted avatar fades through the placeholder; a cached
      // one is there on the first frame.
      builder: (context, snapshot) => NotionFadeThrough(
        alignment: Alignment.center,
        child: snapshot.data == null
            ? KeyedSubtree(key: const ValueKey('fallback'), child: fallback)
            : ClipRRect(
                key: const ValueKey('avatar'),
                borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
                child: Image(
                  image: CoverResizeImage(
                    MemoryImage(snapshot.data!),
                    width: decodeSize,
                    height: decodeSize,
                  ),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
              ),
      ),
    );
  }

  Future<Uint8List?> _download(Map<String, dynamic> value) =>
      downloadPrivateAvatarValue(widget.personal.client, value);
}

class DraftConflictPage extends StatefulWidget {
  final PersonalClient personal;
  final String entityKey;
  const DraftConflictPage({
    super.key,
    required this.personal,
    required this.entityKey,
  });
  @override
  State<DraftConflictPage> createState() => _DraftConflictPageState();
}

class _DraftConflictPageState extends State<DraftConflictPage> {
  late Map<String, dynamic>? _snapshot;
  late String? _fingerprint;
  late final TextEditingController _merged;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _snapshot = _copyConflict();
    _fingerprint = jsonEncode(_snapshot);
    _merged = TextEditingController(text: _text('proposedValue'));
  }

  Map<String, dynamic>? _copyConflict() {
    final current = widget.personal.conflicts[widget.entityKey];
    return current == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(jsonEncode(current)) as Map);
  }

  String _text(String field) =>
      (_snapshot?[field] as Map?)?['text'] as String? ?? '';
  @override
  void dispose() {
    _merged.dispose();
    super.dispose();
  }

  Future<void> _resolve(String text) async {
    final snapshot = _snapshot;
    if (snapshot == null || _busy) {
      return;
    }
    if (jsonEncode(widget.personal.conflicts[widget.entityKey]) !=
        _fingerprint) {
      setState(
        () => _error =
            'The draft changed on another device. Refresh both versions before choosing.',
      );
      return;
    }
    final revision = snapshot['revision'];
    if (revision is! int) {
      setState(
        () => _error =
            'Could not confirm the draft version. Refresh private sync.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Save both untouched copies before replacing the contested draft.
      for (final field in ['existingValue', 'proposedValue']) {
        final value = snapshot[field];
        if (value is Map) {
          await widget.personal.put('draft-copy:${const Uuid().v4()}', {
            ...Map<String, dynamic>.from(value),
            'sourceEntity': widget.entityKey,
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          });
        }
      }
      final proposed = snapshot['proposedValue'];
      final existing = snapshot['existingValue'];
      final base = proposed is Map
          ? Map<String, dynamic>.from(proposed)
          : existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      await widget.personal.command('metadata.put', widget.entityKey, {
        'value': {
          ...base,
          'text': text,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      }, baseRevision: revision);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not save your choice. Both versions remain.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.personal,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Choose a draft')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Both versions are kept as copies. The chosen text returns to the composer.',
              ),
              NotionSizeReveal(
                visible: _error != null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error ?? '',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
              NotionSizeReveal(
                visible: _busy,
                child: const NotionDelayedReveal(
                  child: LinearProgressIndicator(),
                ),
              ),
              if (_snapshot == null)
                const ListTile(
                  title: Text('This draft no longer has a conflict.'),
                ),
              if (_snapshot != null) ...[
                const SizedBox(height: 24),
                Text(
                  'Saved version',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(_text('existingValue')),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy || !widget.personal.ready
                        ? null
                        : () => _resolve(_text('existingValue')),
                    child: const Text('Use saved version'),
                  ),
                ),
                const Divider(height: 32),
                Text(
                  'Other version',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(_text('proposedValue')),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy || !widget.personal.ready
                        ? null
                        : () => _resolve(_text('proposedValue')),
                    child: const Text('Use other version'),
                  ),
                ),
                const Divider(height: 32),
                TextField(
                  controller: _merged,
                  minLines: 4,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    labelText: 'Combine or edit text',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy || !widget.personal.ready
                      ? null
                      : () => _resolve(_merged.text),
                  child: const Text('Save combined draft'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _snapshot = _copyConflict();
                          _fingerprint = jsonEncode(_snapshot);
                          _merged.text = _text('proposedValue');
                          _error = null;
                        }),
                  child: const Text('Refresh both versions'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class BookmarkSearchPage extends StatefulWidget {
  final PersonalClient personal;
  const BookmarkSearchPage({super.key, required this.personal});
  @override
  State<BookmarkSearchPage> createState() => _BookmarkSearchPageState();
}

class _BookmarkSearchPageState extends State<BookmarkSearchPage> {
  final _search = TextEditingController();
  String? _network;

  /// Last loaded event per bookmark; kept on screen while it is refreshed.
  final _loaded = <String, Event?>{};

  /// Latest request per bookmark key; an older answer never overwrites it.
  final _requests = <String, int>{};
  int _requestSeq = 0;
  final _staleRooms = <String>{};
  Timer? _refresh;
  StreamSubscription? _sync;

  /// Receipts and typing sync constantly; only a timeline change (new
  /// event, edit, redaction) or leaving a room can change a saved message.
  static const refreshDelay = Duration(milliseconds: 600);

  @override
  void initState() {
    super.initState();
    _sync = widget.personal.client.onSync.stream.listen((sync) {
      final rooms = bookmarkRoomsChangedBy(sync);
      if (!mounted || rooms.isEmpty) return;
      _staleRooms.addAll(rooms);
      _refresh?.cancel();
      _refresh = Timer(refreshDelay, _refreshStale);
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _sync?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _refreshStale() {
    _refresh = null;
    if (!mounted) return;
    final rooms = Set.of(_staleRooms);
    _staleRooms.clear();
    for (final entry in widget.personal.values.entries) {
      if (!entry.key.startsWith('bookmark:')) continue;
      final source = _source(entry.value);
      if (source == null ||
          !rooms.contains(source.conversation.roomId) ||
          !_requests.containsKey(source.key)) {
        continue;
      }
      unawaited(_fetch(source, refresh: true));
    }
  }

  /// Requests [source] once; the row shows a skeleton until it answers.
  void _ensureLoaded(SourceEventRef source) {
    if (_requests.containsKey(source.key)) return;
    unawaited(_fetch(source));
  }

  Future<void> _fetch(SourceEventRef source, {bool refresh = false}) async {
    final request = _requests[source.key] = ++_requestSeq;
    Event? event;
    var failed = false;
    if (source.conversation.accountId == widget.personal.client.userID) {
      try {
        event = await widget.personal.client
            .getRoomById(source.conversation.roomId)
            ?.getEventById(source.eventId);
      } catch (_) {
        failed = true;
      }
    }
    if (!mounted || _requests[source.key] != request) return;
    // A failed refresh (offline) keeps what was already shown.
    if (failed && refresh && _loaded.containsKey(source.key)) return;
    setState(() => _loaded[source.key] = event);
  }

  Future<void> _removeBookmark(String key) async {
    try {
      await widget.personal.delete(key);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not remove this bookmark. Check private sync and try again.',
            ),
          ),
        );
      }
    }
  }

  SourceEventRef? _source(Map<String, dynamic> value) {
    try {
      return SourceEventRef.fromJson(
        Map<String, dynamic>.from(value['source'] as Map),
      );
    } catch (_) {
      return null;
    }
  }

  bool _matches(MapEntry<String, Map<String, dynamic>> entry, Event event) {
    final source = _source(entry.value);
    if (source == null || event.redacted) return false;
    final transcript = widget.personal.transcripts.values
        .where((j) => j.source.key == source.key && j.state == JobState.done)
        .firstOrNull
        ?.text;
    return PersonalSearchQuery(
      text: _search.text,
      bookmarksOnly: true,
    ).matchesMessage(
      MessageSearchEntry(
        source: source,
        timestamp: event.originServerTs,
        text: event.text,
        transcript: transcript,
        fileName: event.content['filename'] as String?,
        bookmarked: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.personal,
    builder: (context, _) {
      final entries = widget.personal.values.entries
          .where((e) => e.key.startsWith('bookmark:'))
          .toList();
      final filtered = entries
          .where((e) => _network == null || e.value['network'] == _network)
          .toList();
      final sources = filtered
          .map((e) => _source(e.value))
          .whereType<SourceEventRef>()
          .toList();
      final finished = sources.every(
        (source) => _loaded.containsKey(source.key),
      );
      final noMatches =
          _search.text.trim().isNotEmpty &&
          finished &&
          !filtered.any((entry) {
            final source = _source(entry.value);
            final event = source == null ? null : _loaded[source.key];
            return event != null && _matches(entry, event);
          });
      final networks =
          entries
              .map((e) => e.value['network'])
              .whereType<String>()
              .toSet()
              .toList()
            ..sort();
      return Scaffold(
        appBar: AppBar(title: const Text('Bookmarks')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search text, transcripts or filenames',
                    ),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        ChoiceChip(
                          label: const Text('All networks'),
                          selected: _network == null,
                          onSelected: (_) => setState(() => _network = null),
                        ),
                        for (final network in networks)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: ChoiceChip(
                              label: Text(network),
                              selected: _network == network,
                              onSelected: (_) =>
                                  setState(() => _network = network),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // Empty, no-match and each network's list fade through;
                // the first screenful of bookmarks rises in.
                Expanded(
                  child: NotionFadeThrough(
                    child: entries.isEmpty
                        ? const NotionEmptyState(
                            key: ValueKey('empty'),
                            icon: Icons.bookmark_outline,
                            title: 'No bookmarks',
                            message:
                                'Long-press a message and choose Bookmark.',
                          )
                        : noMatches || filtered.isEmpty
                        ? const NotionEmptyState(
                            key: ValueKey('none'),
                            icon: Icons.search_off_outlined,
                            title: 'No matching bookmarks',
                          )
                        : NotionEntranceScope(
                            key: ValueKey('list:$_network'),
                            child: ListView(
                              children: [
                                for (final entry in filtered)
                                  NotionEntrance(
                                    key: ValueKey(entry.key),
                                    playKey: entry.key,
                                    rise: NotionMotion.riseList,
                                    child: _bookmark(entry),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  Widget _bookmark(MapEntry<String, Map<String, dynamic>> entry) {
    SourceEventRef source;
    try {
      source = SourceEventRef.fromJson(
        Map<String, dynamic>.from(entry.value['source'] as Map),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (_network != null && entry.value['network'] != _network) {
      return const SizedBox.shrink();
    }
    if (!_loaded.containsKey(source.key)) {
      _ensureLoaded(source);
      return const NotionSkeleton(
        child: ListTile(
          title: Text('Loading saved message…'),
          subtitle: Text('Conversation · Network'),
        ),
      );
    }
    return Builder(
      builder: (context) {
        final event = _loaded[source.key];
        final transcript = widget.personal.transcripts.values
            .where(
              (j) => j.source.key == source.key && j.state == JobState.done,
            )
            .firstOrNull
            ?.text;
        if (event == null || event.redacted) {
          return ListTile(
            title: const Text('Saved message unavailable'),
            trailing: IconButton(
              tooltip: 'Remove bookmark',
              icon: const Icon(Icons.bookmark_remove_outlined),
              onPressed: widget.personal.ready
                  ? () => _removeBookmark(entry.key)
                  : null,
            ),
          );
        }
        final query = PersonalSearchQuery(
          text: _search.text,
          bookmarksOnly: true,
        );
        if (!query.matchesMessage(
          MessageSearchEntry(
            source: source,
            timestamp: event.originServerTs,
            text: event.text,
            transcript: transcript,
            fileName: event.content['filename'] as String?,
            bookmarked: true,
          ),
        )) {
          return const SizedBox.shrink();
        }
        final room = widget.personal.client.getRoomById(
          source.conversation.roomId,
        );
        return _pressable(
          ListTile(
            title: Text(
              event.text.isEmpty
                  ? transcript ?? 'Saved attachment'
                  : event.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${room == null ? '' : InboxProjection(widget.personal).displayName(room)} · ${entry.value['network'] as String? ?? ''}',
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SourceChatPage(source: source),
              ),
            ),
            trailing: IconButton(
              tooltip: 'Remove bookmark',
              icon: const Icon(Icons.bookmark_remove_outlined),
              onPressed: widget.personal.ready
                  ? () => _removeBookmark(entry.key)
                  : null,
            ),
          ),
        );
      },
    );
  }
}

/// Rooms of [sync] whose saved messages may have changed: joined rooms with
/// timeline events (new, edited or redacted messages) and rooms that were
/// left. Receipt, typing and account-data-only syncs return nothing.
@visibleForTesting
Set<String> bookmarkRoomsChangedBy(SyncUpdate sync) => {
  for (final entry
      in sync.rooms?.join?.entries ??
          const <MapEntry<String, JoinedRoomUpdate>>[])
    if (entry.value.timeline?.events?.isNotEmpty ?? false) entry.key,
  ...?sync.rooms?.leave?.keys,
};

/// Press feedback for a tappable Material [ListTile] row.
Widget _pressable(Widget row) =>
    NotionPressable(scale: NotionMotion.pressRow, child: row);
