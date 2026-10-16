// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/merged_chat_page.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/chat_preferences_page.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

String? _privateText(Object? value) => value is String ? value : null;

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
    personal.load();
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

  Future<void> _nickname(ConversationMetadata metadata) async {
    final controller = TextEditingController(
      text:
          metadata.nickname ??
          _privateText(
            personal.values['nickname:${metadata.entityId}']?['name'],
          ) ??
          '',
    );
    String? result;
    try {
      result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Private nickname'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(
              hintText: 'Leave blank to use the source network name',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
    if (result == null) return;
    final value = result.trim().isEmpty ? null : result.trim();
    await _saveMetadata(metadata.setNickname(value));
    // Keep the existing nickname hook interoperable, including explicit reset.
    await personal.put('nickname:${metadata.entityId}', {'name': value ?? ''});
  }

  Future<void> _avatar(String entity) async {
    final selection = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (selection == null) return;
    final length = await selection.length();
    if (length == null || length <= 0 || length > 2 * 1024 * 1024) {
      throw ArgumentError('Avatar must be an image under 2 MiB');
    }
    final bytes = await selection.readAsBytes();
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      throw ArgumentError('Avatar must be an image under 2 MiB');
    }
    await uploadPrivateAvatar(personal, entity, bytes);
  }

  Future<void> _theme(ConversationMetadata metadata) async {
    final result = await showDialog<ChatTheme>(
      context: context,
      builder: (_) => _ThemeDialog(initial: metadata.theme),
    );
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
        appBar: AppBar(title: Text('Private conversation preferences')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (!personal.ready)
                  const ListTile(
                    leading: Icon(Icons.lock_outline),
                    title: Text('Private sync is unavailable'),
                    subtitle: Text(
                      'Set it up in Settings → Sync & transcriptions to sync preferences between your devices.',
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
                  if (_waiting(key))
                    const ListTile(
                      leading: Icon(Icons.sync),
                      title: Text('Change awaiting sync confirmation'),
                    ),
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text('Visibility & notifications'),
                    subtitle: const Text(
                      'Ignore, restore or override network rules',
                    ),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            ChatPreferencesPage(personal: personal, room: room),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Pin chat'),
                    value: metadata.isPinned,
                    onChanged: editing
                        ? (v) => _run(
                            () => _saveMetadata(
                              metadata.setPin(
                                v ? _nextPinOrder(personal) : null,
                              ),
                            ),
                          )
                        : null,
                  ),
                  if (metadata.isPinned)
                    ListTile(
                      title: const Text('Move pinned conversation to the top'),
                      leading: const Icon(Icons.vertical_align_top),
                      onTap: editing
                          ? () => _run(() => _movePinToTop(personal, metadata))
                          : null,
                    ),
                  SwitchListTile(
                    title: const Text('Archive'),
                    subtitle: const Text(
                      'New activity returns this conversation to the inbox.',
                    ),
                    value: metadata.archived,
                    onChanged: editing
                        ? (v) =>
                              _run(() => _saveMetadata(metadata.setArchived(v)))
                        : null,
                  ),
                  SwitchListTile(
                    title: const Text('Low priority'),
                    subtitle: const Text(
                      'Outside the inbox. Mentions and thread replies may still notify.',
                    ),
                    value: metadata.lowPriority,
                    onChanged: editing
                        ? (v) => _run(
                            () => _saveMetadata(metadata.setLowPriority(v)),
                          )
                        : null,
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Private nickname'),
                    subtitle: Text(metadata.nickname ?? 'Source network name'),
                    onTap: editing
                        ? () => _run(() => _nickname(metadata))
                        : null,
                  ),
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
                  if (personal.values.containsKey(
                    'avatar:${metadata.entityId}',
                  ))
                    ListTile(
                      leading: const Icon(Icons.hide_image_outlined),
                      title: const Text('Restore source network avatar'),
                      onTap: personal.ready && !_busy
                          ? () => _run(
                              () => personal.delete(
                                'avatar:${metadata.entityId}',
                              ),
                            )
                          : null,
                    ),
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Conversation colors'),
                    onTap: editing ? () => _run(() => _theme(metadata)) : null,
                  ),
                  if (metadata.theme != null)
                    ListTile(
                      title: const Text('Restore default appearance'),
                      onTap: editing
                          ? () => _run(
                              () => _saveMetadata(metadata.setTheme(null)),
                            )
                          : null,
                    ),
                ],
                if (room == null) ...[
                  const ListTile(
                    leading: Icon(Icons.chat_bubble_outline),
                    title: Text('Choose a conversation'),
                    subtitle: Text(
                      'Open Chat details from a conversation to change its private appearance, nickname and visibility.',
                    ),
                  ),
                  for (final source
                      in projection
                          .rooms(personal.client.rooms, filter: InboxFilter.all)
                          .where((r) => r.membership == Membership.join))
                    ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(projection.displayName(source)),
                      subtitle: const Text(
                        'Private appearance and conversation preferences',
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
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

int _nextPinOrder(PersonalClient personal) {
  final orders = personal.values.entries
      .where((e) => e.key.startsWith('org:'))
      .map((e) => e.value['pinOrder'])
      .whereType<int>();
  return orders.isEmpty ? 0 : orders.reduce((a, b) => a > b ? a : b) + 1;
}

Future<void> _movePinToTop(
  PersonalClient personal,
  ConversationMetadata selected,
) async {
  final entries =
      personal.values.entries
          .where((e) => e.key.startsWith('org:') && e.value['pinOrder'] is int)
          .toList()
        ..sort(
          (a, b) => (a.value['pinOrder'] as int).compareTo(
            b.value['pinOrder'] as int,
          ),
        );
  if (entries.any(
    (e) => personal.pending.values.any((op) => op.entityId == e.key),
  )) {
    throw StateError('Pins are awaiting synchronization');
  }
  await personal.put(
    'org:${selected.entityId}',
    selected.setPin(0).toJson().cast<String, dynamic>(),
  );
  var order = 1;
  for (final entry in entries.where(
    (e) => e.key != 'org:${selected.entityId}',
  )) {
    await personal.put(entry.key, {...entry.value, 'pinOrder': order++});
  }
}

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
              child: value == colors[i]
                  ? Icon(
                      Icons.check,
                      color: Color(colors[i]).computeLuminance() > 0.5
                          ? Colors.black
                          : Colors.white,
                      size: 18,
                    )
                  : null,
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Conversation colors'),
    content: SizedBox(
      width: 440,
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
            TextButton(
              onPressed: () => setState(() {
                incoming = null;
                outgoing = null;
                background = null;
              }),
              child: const Text('Use default colors'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          ChatTheme(
            incomingColor: incoming,
            outgoingColor: outgoing,
            backgroundColor: background,
          ),
        ),
        child: const Text('Save'),
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
  await personal.put('avatar:$entity', {
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
  String? _fingerprint;
  Future<Uint8List?>? _loading;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.personal,
    builder: (context, _) {
      final value = widget.personal.values['avatar:${widget.entityId}'];
      final fingerprint = value == null ? null : jsonEncode(value);
      if (fingerprint != _fingerprint) {
        _fingerprint = fingerprint;
        _loading = value == null
            ? null
            : _download(Map<String, dynamic>.from(value));
      }
      final fallback =
          widget.fallback ??
          Container(
            width: widget.radius * 2,
            height: widget.radius * 2,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
            ),
            child: const Icon(Icons.person_outline),
          );
      if (_loading == null) return fallback;
      return FutureBuilder<Uint8List?>(
        future: _loading,
        builder: (context, snapshot) => snapshot.data == null
            ? fallback
            : ClipRRect(
                borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
                child: Image.memory(
                  snapshot.data!,
                  width: widget.radius * 2,
                  height: widget.radius * 2,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
              ),
      );
    },
  );
  Future<Uint8List?> _download(Map<String, dynamic> value) async {
    try {
      final uri = Uri.parse(value['mxc'] as String);
      if (uri.scheme != 'mxc' ||
          uri.host.isEmpty ||
          uri.pathSegments.length != 1 ||
          (value['size'] as int? ?? 0) > 2 * 1024 * 1024) {
        return null;
      }
      final content = await widget.personal.client.getContent(
        uri.host,
        uri.pathSegments.single,
      );
      if (content.data.length > 2 * 1024 * 1024) return null;
      return await widget.personal.client.nativeImplementations.decryptFile(
        EncryptedFile(
          data: content.data,
          iv: value['iv'] as String,
          k: value['key'] as String,
          sha256: value['sha256'] as String,
        ),
      );
    } catch (_) {
      return null;
    }
  }
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

Future<void> resolvePersonalMetadataConflict(
  BuildContext context,
  PersonalClient personal,
  String key,
) async {
  if (key.startsWith('draft:')) {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DraftConflictPage(personal: personal, entityKey: key),
      ),
    );
    return;
  }
  final original = personal.conflicts[key];
  if (original == null) return;
  final snapshot = Map<String, dynamic>.from(
    jsonDecode(jsonEncode(original)) as Map,
  );
  final current = snapshot['existingValue'];
  final proposed = snapshot['proposedValue'];
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Choose a settings version'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Saved version'),
            const SizedBox(height: 8),
            Text(_metadataConflictSummary(current, personal)),
            const Divider(height: 24),
            const Text('My change'),
            const SizedBox(height: 8),
            Text(_metadataConflictSummary(proposed, personal)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Back'),
        ),
        TextButton(
          onPressed: current is Map
              ? () => Navigator.pop(context, 'existing')
              : null,
          child: const Text('Keep saved version'),
        ),
        FilledButton(
          onPressed: proposed is Map && proposed.isNotEmpty
              ? () => Navigator.pop(context, 'proposed')
              : null,
          child: const Text('Use my change'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (jsonEncode(personal.conflicts[key]) != jsonEncode(snapshot) ||
      snapshot['revision'] is! int) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Settings changed again. Refresh both versions before choosing.',
        ),
      ),
    );
    return;
  }
  final selected = choice == 'existing' ? current : proposed;
  if (selected is! Map) return;
  await personal.command('metadata.put', key, {
    'value': Map<String, dynamic>.from(selected),
  }, baseRevision: snapshot['revision'] as int);
}

String _metadataConflictSummary(Object? value, PersonalClient personal) {
  if (value is! Map || value.isEmpty) {
    return 'The change is incomplete. Reopen the affected setting.';
  }
  final parts = <String>[];
  for (final entry in const {
    'name': 'Name',
    'nickname': 'Conversation name',
    'archived': 'Archive',
    'lowPriority': 'Low priority',
    'muted': 'Privately muted',
  }.entries) {
    final field = value[entry.key];
    if (field is String) parts.add('${entry.value}: $field');
    if (field is bool) parts.add('${entry.value}: ${field ? 'tak' : 'nie'}');
  }
  if (value['theme'] is Map) parts.add('Custom conversation colors');
  return parts.isEmpty ? 'Private conversation settings' : parts.join('\n');
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
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_busy) const LinearProgressIndicator(),
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
                    border: OutlineInputBorder(),
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
  final _events = <String, Future<Event?>>{};
  final _loaded = <String, Event?>{};
  int _generation = 0;
  StreamSubscription? _sync;
  @override
  void initState() {
    super.initState();
    _sync = widget.personal.client.onSync.stream.listen((_) {
      if (mounted) {
        setState(() {
          _generation++;
          _events.clear();
          _loaded.clear();
        });
      }
    });
  }

  @override
  void dispose() {
    _sync?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<Event?> _event(SourceEventRef source) async {
    final generation = _generation;
    if (source.conversation.accountId != widget.personal.client.userID) {
      return null;
    }
    try {
      final event = await widget.personal.client
          .getRoomById(source.conversation.roomId)
          ?.getEventById(source.eventId);
      if (mounted && generation == _generation) {
        setState(() => _loaded[source.key] = event);
      }
      return event;
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _loaded[source.key] = null);
      }
      return null;
    }
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
                      border: OutlineInputBorder(),
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
                Expanded(
                  child: entries.isEmpty
                      ? const Center(
                          child: Text(
                            'Bookmark a message to find it here later.',
                          ),
                        )
                      : noMatches || filtered.isEmpty
                      ? const Center(
                          child: Text('No bookmarks match this search.'),
                        )
                      : ListView(
                          children: [
                            for (final entry in filtered) _bookmark(entry),
                          ],
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
    return FutureBuilder<Event?>(
      future: _events.putIfAbsent(source.key, () => _event(source)),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const ListTile(title: Text('Loading saved message…'));
        }
        final event = snapshot.data;
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
        return ListTile(
          title: Text(
            event.text.isEmpty ? transcript ?? 'Saved attachment' : event.text,
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
        );
      },
    );
  }
}

class PersonalInboxFilters extends StatelessWidget {
  final PersonalClient personal;
  final InboxFilter value;
  final String? labelKey;
  final void Function(InboxFilter, String?) onChanged;
  const PersonalInboxFilters({
    super.key,
    required this.personal,
    required this.value,
    required this.onChanged,
    this.labelKey,
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            for (final entry in const <InboxFilter, String>{
              InboxFilter.inbox: 'Inbox',
              InboxFilter.unread: 'Unread',
              InboxFilter.drafts: 'Drafts',
              InboxFilter.unanswered: 'Unanswered',
              InboxFilter.direct: 'People',
              InboxFilter.groups: 'Groups',
              InboxFilter.ignored: 'Ignored',
              InboxFilter.technical: 'Technical',
              InboxFilter.archive: 'Archive',
              InboxFilter.lowPriority: 'Low priority',
              InboxFilter.all: 'All',
            }.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(entry.value),
                  selected: value == entry.key,
                  onSelected: (_) => onChanged(entry.key, null),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
