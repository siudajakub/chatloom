// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/organization_page.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/personal_search_page.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/scheduled_composer.dart';
import 'package:fluffychat/personal/storage/storage_failure.dart';
import 'package:fluffychat/utils/background_push.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/notion_room_actions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

import 'merged_chat_page.dart';

Future<String?> personalText(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final c = TextEditingController(text: initial);
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, maxLines: 3),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  } finally {
    c.dispose();
  }
}

Future<DateTime?> personalDate(BuildContext context) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365)),
    initialDate: now,
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 10))),
  );
  return time == null
      ? null
      : DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// The selected room is frozen before either picker opens. No source message is
/// sent during preparation; only SDK-encrypted ciphertext is uploaded.
Future<bool> schedulePersonalAttachment(
  BuildContext context,
  PersonalClient personal,
  SendTarget target, {
  FrozenScheduledComposer? composeContext,
}) async {
  final room = personal.client.getRoomById(target.conversation.roomId);
  if (target.conversation.accountId != personal.client.userID ||
      room == null ||
      room.membership != Membership.join ||
      !room.canSendDefaultMessages ||
      !personal.ready) {
    throw StateError('The selected source or private sync is unavailable.');
  }
  final frozen = composeContext ??
      FrozenScheduledComposer.capture(
        room: room,
        target: target,
        isCurrent: () => context.mounted &&
            identical(Matrix.of(context).client, personal.client),
      );
  if (jsonEncode(frozen.target.toJson()) != jsonEncode(target.toJson())) {
    throw StateError('The scheduled source does not match the attachment.');
  }
  frozen.validateCurrent();
  final file = await FilePicker.pickFile(
    dialogTitle: 'Attachment for a scheduled message',
    type: FileType.any,
  );
  if (file == null || !context.mounted) return false;
  frozen.validateCurrent();
  const maximum = 25 * 1024 * 1024;
  final size = await file.length();
  if (size == null || size <= 0 || size > maximum) {
    throw StateError('Choose an attachment up to 25 MB.');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > maximum || bytes.isEmpty) {
    throw StateError(
      'Could not load the attachment. Choose a file up to 25 MB.',
    );
  }
  final mime =
      lookupMimeType(file.name, headerBytes: bytes) ??
      'application/octet-stream';
  final matrixFile = MatrixFile.fromMimeType(
    bytes: bytes,
    name: file.name,
    mimeType: mime,
  );
  final msgtype = matrixFile.msgType;
  final feature = switch (msgtype) {
    MessageTypes.Image => BridgeFeature.image,
    MessageTypes.Video => BridgeFeature.video,
    MessageTypes.Audio => BridgeFeature.audio,
    _ => BridgeFeature.upload,
  };
  int? width, height;
  if (msgtype == MessageTypes.Image) {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      width = descriptor.width;
      height = descriptor.height;
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }
  final media = BridgeMediaRequest(
    mimeType: mime,
    sizeBytes: bytes.length,
    width: width,
    height: height,
  );
  final capability = RoomCapabilities.forFeature(feature, room, media: media);
  if (!capability.allowed) throw StateError(capability.reason);
  if (!context.mounted) return false;
  final due = await personalDate(context);
  if (due == null || !context.mounted) return false;
  if (!due.isAfter(DateTime.now())) {
    throw StateError('Choose a future date and time.');
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Schedule an attachment'),
      content: Text(
        '${file.name}\n${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB\n${target.conversation.network} · ${due.toLocal()}${frozen.contextLabel == null ? '' : '\n${frozen.contextLabel}'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Schedule'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  frozen.validateCurrent();
  if (personal.client.getRoomById(target.conversation.roomId) != room ||
      !RoomCapabilities.forFeature(feature, room, media: media).allowed) {
    throw StateError('The selected source changed. Select it again.');
  }
  final encrypted = await matrixFile.encrypt();
  frozen.validateCurrent();
  final mxc = await personal.client.uploadContent(
    encrypted.data,
    filename: 'scheduled-attachment.enc',
    contentType: 'application/octet-stream',
  );
  frozen.validateCurrent();
  if (!RoomCapabilities.forFeature(feature, room, media: media).allowed) {
    throw StateError('The selected source changed. Select it again.');
  }
  final id = const Uuid().v4();
  final job = ScheduledSend(
    id: id,
    target: target,
    dueAt: due,
    transactionId: 'schedule-$id',
    content: frozen.content({
      'msgtype': msgtype,
      'body': file.name,
      'filename': file.name,
      'file': {
        'url': mxc.toString(),
        'mimetype': mime,
        'v': 'v2',
        'key': {
          'alg': 'A256CTR',
          'ext': true,
          'k': encrypted.k,
          'key_ops': ['encrypt', 'decrypt'],
          'kty': 'oct',
        },
        'iv': encrypted.iv,
        'hashes': {'sha256': encrypted.sha256},
      },
      'info': {
        'mimetype': mime,
        'size': bytes.length,
        'w': ?width,
        'h': ?height,
      },
    }),
  );
  await personal.schedule(job);
  return true;
}

class PersonalHubButton extends StatelessWidget {
  const PersonalHubButton({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Personal tools',
    icon: const Icon(Icons.tune),
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PersonalHub(client: Matrix.of(context).client),
      ),
    ),
  );
}

class PersonalHub extends StatefulWidget {
  final Client client;
  const PersonalHub({super.key, required this.client});
  @override
  State<PersonalHub> createState() => _PersonalHubState();
}

class _PersonalHubState extends State<PersonalHub> {
  late final personal = PersonalClient.of(widget.client);
  @override
  void initState() {
    super.initState();
    personal.load();
  }

  Future<void> _configurePush() async {
    final url = await personalText(
      context,
      'Notification gateway HTTPS address',
      initial: AppSettings.pushNotificationsGatewayUrl.value,
    );
    if (url == null || !mounted) return;
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter a full HTTPS address without credentials, query parameters or a fragment.',
          ),
        ),
      );
      return;
    }
    final nonceController = TextEditingController();
    final form = GlobalKey<FormState>();
    String? nonce;
    try {
      nonce = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Private device key'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Paste the random key also saved in your gateway configuration. Use at least 32 characters and keep it private.',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: nonceController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Device key'),
                  validator: (value) =>
                      RegExp(r'^[A-Za-z0-9_-]{32,}$').hasMatch(value ?? '')
                      ? null
                      : 'Use at least 32 random letters, digits, underscores or hyphens.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState?.validate() == true) {
                  Navigator.pop(context, nonceController.text);
                }
              },
              child: const Text('Save & register'),
            ),
          ],
        ),
      );
    } finally {
      nonceController.dispose();
    }
    if (nonce == null || !mounted) return;
    await const FlutterSecureStorage().write(
      key: 'personal_gateway_nonce',
      value: nonce,
    );
    await AppSettings.pushNotificationsGatewayUrl.setItem(uri.toString());
    if (!mounted) return;
    await BackgroundPush(Matrix.of(context)).setupPush(context);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Settings saved. Notifications require the same device key in the gateway configuration.',
          ),
        ),
      );
    }
  }

  Future<void> _copyPushRegistration() async {
    final token = BackgroundPush(Matrix.of(context)).fcmToken;
    final device = widget.client.deviceID;
    final nonce = await const FlutterSecureStorage().read(
      key: 'personal_gateway_nonce',
    );
    if (!mounted) return;
    if (token == null ||
        token.isEmpty ||
        device == null ||
        device.isEmpty ||
        nonce == null ||
        !RegExp(r'^[A-Za-z0-9_-]{32,}$').hasMatch(nonce)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Save the configuration and register notifications first. A token or valid device key is missing.',
          ),
        ),
      );
      return;
    }
    var appId = '${AppConfig.pushNotificationsAppId}.$device';
    if (appId.length > 64) appId = appId.substring(0, 64);
    await Clipboard.setData(
      ClipboardData(
        text: jsonEncode({'app_id': appId, 'pushkey': token, 'nonce': nonce}),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Registration secrets copied. Paste them only into your private gateway configuration.',
          ),
        ),
      );
    }
  }

  Future<void> run(Future<void> Function() f) async {
    try {
      await f();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is StorageFailure &&
                      error.code == StorageFailureCode.unsupportedPlatform
                  ? 'Private encrypted storage requires the native app. This feature is unavailable in the browser.'
                  : error is PersonalCapabilityUnavailable
                  ? error.reason
                  : 'The operation was not confirmed. Check private sync.',
            ),
          ),
        );
      }
    }
  }

  Future<void> merge() async {
    final rooms = widget.client.rooms
        .where(
          (r) => r.directChatMatrixID != null && !PersonalPrivacy.isJournal(r),
        )
        .toList();
    final selected = <String>{};
    final name = TextEditingController();
    final group = await showDialog<PersonGroup>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Merge conversations for one person'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Person name'),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final room in rooms)
                        CheckboxListTile(
                          value: selected.contains(room.id),
                          title: Text(room.getLocalizedDisplayname()),
                          subtitle: Text(PersonalClient.networkOf(room)),
                          onChanged: (v) => set(
                            () => v == true
                                ? selected.add(room.id)
                                : selected.remove(room.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.length < 2 || name.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      PersonGroup(
                        id: const Uuid().v4(),
                        name: name.text.trim(),
                        members: rooms
                            .where((r) => selected.contains(r.id))
                            .map(personal.ref)
                            .toList(),
                        defaultRoomId: selected.first,
                      ),
                    ),
              child: const Text('Merge'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    if (group != null) {
      await personal.put(
        'person:${group.id}',
        group.toJson().cast<String, dynamic>(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Personal tools')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Incognito mode'),
            subtitle: const Text(
              'Suppress automatic read receipts, typing and presence on this device. Your source network may mark messages read when you reply.',
            ),
            value: AppSettings.personalIncognito.value,
            onChanged: (v) => run(() async {
              await PersonalPrivacy.setIncognito(
                v,
                Matrix.of(context).widget.clients,
              );
              if (mounted) setState(() {});
            }),
          ),
          ListTile(
            leading: Icon(personal.ready ? Icons.lock : Icons.lock_outline),
            title: Text(
              personal.ready
                  ? 'Private sync configured'
                  : 'Set up private sync',
            ),
            subtitle: Text(
              kIsWeb
                  ? 'Private encrypted storage requires the native app. Ordinary conversations are available in the browser.'
                  : personal.problem ??
                        (personal.workerOnline
                            ? 'Background worker heartbeat received'
                            : 'Background tasks need a paired worker'),
            ),
            onTap: kIsWeb ? null : () => run(personal.connect),
          ),
          if (personal.pending.isNotEmpty)
            ListTile(
              title: Text(
                '${personal.pending.length} changes awaiting confirmation',
              ),
            ),
          if (personal.conflicts.isNotEmpty) ...[
            const ListTile(title: Text('Conflicts — both versions retained')),
            for (final conflict in personal.conflicts.entries)
              ListTile(
                onTap: () => run(
                  () => resolvePersonalMetadataConflict(
                    context,
                    personal,
                    conflict.key,
                  ),
                ),
                title: const Text('Concurrent change'),
                subtitle: const Text(
                  'Reopen the affected draft or setting before choosing a version.',
                ),
              ),
          ],
          ListTile(
            title: const Text('Notification setup'),
            subtitle: const Text(
              kIsWeb
                  ? 'Private push gateway setup requires the native app.'
                  : 'Register this device with your private HTTPS gateway.',
            ),
            onTap: kIsWeb ? null : () => run(_configurePush),
          ),
          ListTile(
            title: const Text('Copy private push registration (secrets)'),
            subtitle: const Text(
              'The token and key are copied only when you choose this action.',
            ),
            leading: const Icon(Icons.copy_outlined),
            onTap: kIsWeb ? null : () => run(_copyPushRegistration),
          ),
          const Divider(),
          ListTile(
            title: const Text('Search conversations'),
            leading: const Icon(Icons.search),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => PersonalSearchPage(personal: personal),
              ),
            ),
          ),
          ListTile(
            title: const Text('Organization & appearance'),
            leading: const Icon(Icons.palette_outlined),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => OrganizationPage(personal: personal),
              ),
            ),
          ),
          ListTile(
            title: const Text('Search bookmarks'),
            leading: const Icon(Icons.bookmarks_outlined),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => BookmarkSearchPage(personal: personal),
              ),
            ),
          ),
          ListTile(
            title: const Text('People & merged conversations'),
            trailing: IconButton(
              tooltip: 'Merge conversations',
              icon: const Icon(Icons.add),
              onPressed: () => run(merge),
            ),
          ),
          for (final group in personal.groups)
            ListTile(
              title: Text(group.name),
              subtitle: Text('${group.members.length} sources'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      MergedChatPage(personal: personal, group: group),
                ),
              ),
              trailing: IconButton(
                tooltip: 'Unmerge',
                icon: const Icon(Icons.call_split),
                onPressed: () =>
                    run(() => personal.delete('person:${group.id}')),
              ),
            ),
          if (personal.invalidGroupCount > 0)
            ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: const Text(
                'Some saved conversation groups could not be loaded. Their data is preserved.',
              ),
              subtitle: Text('${personal.invalidGroupCount} saved groups'),
            ),
          const Divider(),
          ListTile(
            title: const Text('Labels'),
            trailing: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => run(() async {
                final name = await personalText(context, 'New label');
                if (name != null && name.trim().isNotEmpty) {
                  await personal.put('label:${const Uuid().v4()}', {
                    'name': name.trim(),
                    'showInInbox': true,
                  });
                }
              }),
            ),
          ),
          for (final e in personal.values.entries.where(
            (e) => e.key.startsWith('label:'),
          ))
            ListTile(
              title: Text(e.value['name'] as String? ?? 'Label'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => run(() => personal.delete(e.key)),
              ),
            ),
          const Divider(),
          const ListTile(title: Text('Reminders')),
          for (final e in personal.reminders.entries)
            ListTile(
              title: const Text('Conversation reminder'),
              subtitle: Text('${e.value['dueAt']} · ${e.value['state']}'),
              trailing: IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close),
                onPressed: () => run(() async {
                  await personal.command('reminder.cancel', e.key, {
                    'id': e.key,
                  }, baseRevision: e.value['revision'] as int? ?? 0);
                }),
              ),
            ),
          const ListTile(title: Text('Scheduled messages')),
          for (final e in personal.schedules.entries)
            ListTile(
              title: Text(
                (e.value['content'] as Map?)?['body'] as String? ?? 'Message',
              ),
              subtitle: Text(
                '${e.value['state']} · ${e.value['dueAt']}\n${scheduledSourceSummary(e.value)}',
              ),
              trailing: PopupMenuButton<String>(
                enabled:
                    personal.ready &&
                    {
                      'queued',
                      'paused',
                      'waitingKeys',
                    }.contains(e.value['state']) &&
                    e.value['attempted'] != true &&
                    !personal.pending.values.any((op) => op.entityId == e.key),
                onSelected: (kind) => run(() async {
                  if (kind == 'update') {
                    final content = Map<String, dynamic>.from(
                      e.value['content'] as Map,
                    );
                    if ({'m.text', 'm.notice'}.contains(content['msgtype'])) {
                      final text = await personalText(
                        context,
                        'Message text',
                        initial: content['body'] as String? ?? '',
                      );
                      if (text == null ||
                          text.trim().isEmpty ||
                          !context.mounted) {
                        return;
                      }
                      content['body'] = text;
                    }
                    if (!context.mounted) return;
                    final due = await personalDate(context);
                    if (due == null || !due.isAfter(DateTime.now())) return;
                    final job = ScheduledSend.fromJson({
                      ...e.value,
                      'dueAt': due.toUtc().toIso8601String(),
                      'content': content,
                    });
                    await personal.command(
                      'schedule.update',
                      e.key,
                      job.toJson().cast<String, dynamic>(),
                      baseRevision: e.value['revision'] as int? ?? 0,
                    );
                  } else {
                    await personal.command('schedule.$kind', e.key, {
                      'id': e.key,
                    }, baseRevision: e.value['revision'] as int? ?? 0);
                  }
                }),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'sendNow',
                    child: Text('Send now'),
                  ),
                  PopupMenuItem(
                    value: 'update',
                    enabled: {'queued', 'paused'}.contains(e.value['state']),
                    child: Text('Edit time or message'),
                  ),
                  const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                ],
              ),
            ),
          const Divider(),
          const ListTile(title: Text('Bookmarks')),
          for (final e in personal.values.entries.where(
            (e) => e.key.startsWith('bookmark:'),
          ))
            ListTile(
              title: const Text('Saved message'),
              subtitle: Text(e.value['network'] as String? ?? ''),
              onTap: () {
                final source = SourceEventRef.fromJson(
                  Map<String, dynamic>.from(e.value['source'] as Map),
                );
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SourceChatPage(source: source),
                  ),
                );
              },
              trailing: IconButton(
                icon: const Icon(Icons.bookmark_remove),
                onPressed: () => run(() => personal.delete(e.key)),
              ),
            ),
          const Divider(),
          const ListTile(
            title: Text('Manual transcriptions'),
            subtitle: Text(
              'Only requested manually from a voice message. No monthly limit. Costs are estimates, not a bill.',
            ),
          ),
          ListTile(
            title: Text(
              '${personal.transcripts.values.where((j) => j.state == JobState.done).length} completed',
            ),
            subtitle: Text(
              'Estimated cost: \$${personal.transcripts.values.fold<double>(0, (v, j) => v + (j.estimatedCostUsd ?? 0)).toStringAsFixed(4)} · ${personal.transcripts.values.where((j) => j.state == JobState.unknown).length} unknown attempts',
            ),
          ),
        ],
      ),
    ),
  );
}

class RoomPersonalButton extends StatelessWidget {
  final Room room;
  final TextEditingController composer;
  final String? Function() readCutoff;
  final Event? Function()? replyEvent;
  final bool Function()? isEditing;
  final String? Function()? threadRootEventId;
  final String? Function()? threadLastEventId;
  final bool Function()? isCurrentSource;
  final VoidCallback? clearScheduledReply;
  final bool includeChatSettings;
  const RoomPersonalButton({
    super.key,
    required this.room,
    required this.composer,
    required this.readCutoff,
    this.replyEvent,
    this.isEditing,
    this.threadRootEventId,
    this.threadLastEventId,
    this.isCurrentSource,
    this.clearScheduledReply,
    this.includeChatSettings = false,
  });
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: includeChatSettings
        ? 'Conversation options'
        : 'Conversation tools',
    icon: Icon(includeChatSettings ? Icons.more_horiz : Icons.more_time),
    itemBuilder: (_) => [
      if (includeChatSettings) ...[
        const PopupMenuItem(
          value: 'source.details',
          child: Text('Chat details'),
        ),
        const PopupMenuItem(
          value: 'source.search',
          child: Text('Search this conversation'),
        ),
        const PopupMenuItem(
          value: 'source.encryption',
          child: Text('Encryption & keys'),
        ),
        const PopupMenuDivider(),
      ],
      const PopupMenuItem(
        value: 'organization',
        child: Text('Organization & appearance'),
      ),
      const PopupMenuItem(
        value: 'capabilities',
        child: Text('Conversation capabilities'),
      ),
      const PopupMenuItem(value: 'read', child: Text('Mark as read')),
      PopupMenuItem(
        value: 'schedule',
        enabled: isEditing?.call() != true,
        child: Text(isEditing?.call() == true
            ? 'Send later (finish editing first)'
            : 'Send later'),
      ),
      PopupMenuItem(
        value: 'scheduleMedia',
        enabled: isEditing?.call() != true,
        child: const Text('Schedule an attachment'),
      ),
      const PopupMenuItem(value: 'reminder', child: Text('Remind me')),
      const PopupMenuItem(value: 'nickname', child: Text('Nickname')),
      const PopupMenuItem(value: 'label', child: Text('Label')),
      const PopupMenuItem(
        value: 'bookmark',
        child: Text('Bookmark latest message'),
      ),
      if (includeChatSettings) ...[
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'source.leave',
          child: Text('Leave source conversation'),
        ),
      ],
    ],
    onSelected: (kind) async {
      if (kind.startsWith('source.')) {
        await performNotionRoomAction(context, room, kind.substring(7));
        return;
      }
      final p = PersonalClient.of(room.client);
      try {
        // Freeze relation, source and text before even the private-sync await.
        final frozenText = composer.text;
        final scheduled = {'schedule', 'scheduleMedia'}.contains(kind)
            ? FrozenScheduledComposer.capture(
                room: room,
                target: SendTarget(
                  conversation: p.ref(room),
                  readUpToEventId: readCutoff(),
                ),
                reply: replyEvent?.call(),
                editing: isEditing?.call() == true,
                threadRootEventId: threadRootEventId?.call(),
                threadLastEventId: threadLastEventId?.call(),
                isCurrent: () => context.mounted &&
                    isCurrentSource?.call() != false &&
                    identical(Matrix.of(context).client, room.client),
              )
            : null;
        bool sameComposerContext() => context.mounted &&
            isCurrentSource?.call() != false &&
            identical(Matrix.of(context).client, room.client) &&
            scheduled!.matchesContext(
              reply: replyEvent?.call(),
              editing: isEditing?.call() == true,
              threadRootEventId: threadRootEventId?.call(),
              threadLastEventId: threadLastEventId?.call(),
            );
        await p.load();
        if (!context.mounted) return;
        if (kind == 'capabilities') {
          await showDialog<void>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Conversation capabilities'),
              content: SizedBox(
                width: 460,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final feature in BridgeFeature.values)
                      ListTile(
                        title: Text(feature.name),
                        subtitle: Text(
                          RoomCapabilities.forFeature(feature, room).reason,
                        ),
                        trailing: Icon(switch (RoomCapabilities.forFeature(
                          feature,
                          room,
                        ).status) {
                          CapabilityStatus.available =>
                            Icons.check_circle_outline,
                          CapabilityStatus.unavailable => Icons.block,
                          CapabilityStatus.unverified => Icons.help_outline,
                        }),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
          return;
        }
        if (kind == 'organization') {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => OrganizationPage(personal: p, room: room),
            ),
          );
          return;
        }
        if (kind == 'read') {
          final id = room.lastEvent?.eventId;
          if (id != null) {
            await PersonalPrivacy.markRead(room, id, manual: true);
          }
          return;
        }
        if (kind == 'schedule') {
          if (frozenText.trim().isEmpty) throw StateError('Empty draft');
          final due = await personalDate(context);
          if (due == null || !context.mounted) return;
          scheduled!.validateCurrent();
          if (!due.isAfter(DateTime.now())) throw StateError('Past date');
          final id = const Uuid().v4();
          final job = ScheduledSend(
            id: id,
            target: scheduled.target,
            dueAt: due,
            content: scheduled.content({'msgtype': 'm.text', 'body': frozenText}),
            transactionId: 'schedule-$id',
          );
          await p.schedule(job);
          if (composer.text == frozenText && sameComposerContext()) {
            await p.saveDraft(room, '');
            if (composer.text == frozenText && sameComposerContext()) {
              composer.clear();
              clearScheduledReply?.call();
            } else {
              await p.saveDraft(room, composer.text);
            }
          }
        }
        if (!context.mounted) return;
        if (kind == 'scheduleMedia') {
          if (!context.mounted) return;
          await schedulePersonalAttachment(
            context,
            p,
            scheduled!.target,
            composeContext: scheduled,
          );
        }
        if (kind == 'reminder') {
          if (!context.mounted) return;
          final due = await personalDate(context);
          if (due == null) return;
          if (!context.mounted) return;
          var untilReply = true, archive = false;
          final options = await showDialog<Map<String, bool>>(
            context: context,
            builder: (context) => StatefulBuilder(
              builder: (context, set) => AlertDialog(
                title: const Text('Remind me about this conversation'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      title: const Text('Remind me only if there is no reply'),
                      value: untilReply,
                      onChanged: (value) =>
                          set(() => untilReply = value ?? false),
                    ),
                    CheckboxListTile(
                      title: const Text(
                        'Archive this conversation until the reminder',
                      ),
                      value: archive,
                      onChanged: (value) => set(() => archive = value ?? false),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, {
                      'untilReply': untilReply,
                      'archive': archive,
                    }),
                    child: const Text('Save reminder'),
                  ),
                ],
              ),
            ),
          );
          if (options == null) return;
          final id = const Uuid().v4();
          await p.command('reminder.create', id, {
            'id': id,
            'conversation': p.ref(room).toJson(),
            'dueAt': due.toUtc().toIso8601String(),
            'untilReply': options['untilReply'],
          });
          if (options['archive'] == true) {
            final projection = InboxProjection(p);
            final metadata = projection.metadataFor(room).setArchived(true);
            final group = projection.groupFor(room);
            final sources = group == null
                ? [room]
                : group.members
                      .map((member) => p.client.getRoomById(member.roomId))
                      .whereType<Room>();
            await p.put(projection.metadataKey(room), {
              ...metadata.toJson(),
              'archivedAt': DateTime.now().toUtc().toIso8601String(),
              'archiveSources': {
                for (final source in sources)
                  source.id: source.lastEvent?.eventId,
              },
            });
          }
        }
        if (!context.mounted) return;
        if (kind == 'nickname') {
          final name = await personalText(
            context,
            'Private nickname for this conversation',
          );
          if (name != null) await p.put('nickname:${room.id}', {'name': name});
        }
        if (!context.mounted) return;
        if (kind == 'label') {
          final selected = await showDialog<String>(
            context: context,
            builder: (c) => SimpleDialog(
              title: const Text('Label'),
              children: [
                for (final label in p.values.entries.where(
                  (e) => e.key.startsWith('label:'),
                ))
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, label.key),
                    child: Text(label.value['name'] as String? ?? 'Label'),
                  ),
              ],
            ),
          );
          if (selected != null) {
            await p.put('labels:${room.id}', {
              'labels': [selected],
            });
          }
        }
        if (kind == 'bookmark' && room.lastEvent != null) {
          final e = room.lastEvent!;
          await p.put('bookmark:${p.transcriptId(e)}', {
            'source': p.source(e).toJson(),
            'network': PersonalClient.networkOf(room),
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          });
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved locally. Awaiting sync confirmation.'),
            ),
          );
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not request this action. Set up private sync and check the message and time.',
              ),
            ),
          );
        }
      }
    },
  );
}
