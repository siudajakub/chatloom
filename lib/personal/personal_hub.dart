// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/organization_page.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_content.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/push_registration.dart';
import 'package:fluffychat/personal/scheduled_composer.dart';
import 'package:fluffychat/personal/storage/storage_failure.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/background_push.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/notion_room_actions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
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
  final frozen =
      composeContext ??
      FrozenScheduledComposer.capture(
        room: room,
        target: target,
        isCurrent: () =>
            context.mounted &&
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

enum PersonalSettingsSection {
  sync('Sync & transcriptions'),
  people('People & merged conversations'),
  transcriptions('Transcriptions'),
  reminders('Reminders'),
  scheduled('Scheduled messages'),
  push('Push setup & registration');

  final String title;
  const PersonalSettingsSection(this.title);
}

class PersonalSettingsPage extends StatefulWidget {
  final Client client;
  final PersonalSettingsSection section;
  const PersonalSettingsPage({
    super.key,
    required this.client,
    required this.section,
  });
  @override
  State<PersonalSettingsPage> createState() => _PersonalSettingsPageState();
}

class _PersonalSettingsPageState extends State<PersonalSettingsPage> {
  late PersonalClient personal = PersonalClient.of(widget.client);
  Timer? _readinessTimer;
  AppLifecycleListener? _readinessLifecycle;
  BackgroundPush? _push;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final push = BackgroundPush(Matrix.of(context));
    if (!identical(_push, push)) {
      _push?.registrationChanges.removeListener(_refreshReadiness);
      _push = push;
      push.registrationChanges.addListener(_refreshReadiness);
    }
  }

  @override
  void didUpdateWidget(covariant PersonalSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      personal = PersonalClient.of(widget.client);
      unawaited(personal.load());
    }
  }

  void _refreshReadiness() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _readinessTimer?.cancel();
    _readinessLifecycle?.dispose();
    _push?.registrationChanges.removeListener(_refreshReadiness);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _readinessLifecycle = AppLifecycleListener(
      onStateChange: (_) => _updateReadinessTimer(),
    );
    _updateReadinessTimer();
    personal.load();
  }

  void _updateReadinessTimer() {
    _readinessTimer?.cancel();
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _refreshReadiness();
    _readinessTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshReadiness(),
    );
  }

  Future<void> _configurePush() async {
    final account = widget.client;
    final owner = account.userID, device = account.deviceID;
    bool current() =>
        mounted &&
        identical(account, widget.client) &&
        identical(Matrix.of(context).client, account) &&
        account.userID == owner &&
        account.deviceID == device &&
        account.isLogged();
    final url = await personalText(
      context,
      'Notification gateway HTTPS address',
      initial: AppSettings.pushNotificationsGatewayUrl.value,
    );
    if (url == null || !mounted || !current()) return;
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
                  'Paste the random key also saved in your gateway configuration. Use 43–128 base64url characters and keep it private.',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: nonceController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Device key'),
                  validator: (value) => validGatewayNonce(value)
                      ? null
                      : 'Use 43–128 random letters, digits, underscores or hyphens.',
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
    if (nonce == null || !mounted || !current()) return;
    final push = BackgroundPush(Matrix.of(context));
    push.beginRegistrationUpdate();
    try {
      await const FlutterSecureStorage().write(
        key: 'personal_gateway_nonce',
        value: nonce,
      );
      if (!current()) return;
      await AppSettings.pushNotificationsGatewayUrl.setItem(uri.toString());
    } finally {
      push.endRegistrationUpdate();
    }
    if (!mounted || !current()) return;
    await BackgroundPush(Matrix.of(context)).setupPush(context);
    if (mounted && current()) {
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
    final account = widget.client;
    final owner = account.userID;
    final push = BackgroundPush(Matrix.of(context));
    final token = push.fcmToken;
    final revision = push.registrationRevision;
    final device = widget.client.deviceID;
    final nonce = await const FlutterSecureStorage().read(
      key: 'personal_gateway_nonce',
    );
    if (!mounted ||
        !identical(account, widget.client) ||
        !identical(Matrix.of(context).client, account) ||
        account.userID != owner ||
        account.deviceID != device ||
        !account.isLogged() ||
        _push?.fcmToken != token ||
        push.registrationRevision != revision) {
      return;
    }
    if (token == null ||
        token.isEmpty ||
        device == null ||
        device.isEmpty ||
        nonce == null ||
        !validGatewayNonce(nonce)) {
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
    final owner = personal;
    if (!mounted || !identical(Matrix.of(context).client, owner.client)) return;
    try {
      await f();
    } catch (error) {
      if (mounted &&
          identical(owner, personal) &&
          identical(Matrix.of(context).client, owner.client)) {
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

  bool _canChange(String entity) =>
      personal.ready &&
      !personal.pending.values.any((op) => op.entityId == entity);

  Future<void> merge() async {
    final owner = personal;
    if (!owner.ready) return;
    final rooms = owner.client.rooms
        .where(
          (room) =>
              room.membership == Membership.join &&
              room.directChatMatrixID != null &&
              !PersonalPrivacy.isJournal(room),
        )
        .toList();
    final group = await Navigator.of(context).push<PersonGroup>(
      MaterialPageRoute(
        builder: (_) => _MergeSelectionPage(personal: owner, rooms: rooms),
      ),
    );
    if (group == null ||
        !mounted ||
        !identical(owner, personal) ||
        !identical(Matrix.of(context).client, owner.client))
      return;
    await owner.put(
      'person:${group.id}',
      group.toJson().cast<String, dynamic>(),
    );
  }

  Future<void> _unmerge(PersonGroup group) async {
    final owner = personal;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unmerge conversations?'),
        content: const Text(
          'The source conversations and their messages will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unmerge'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !identical(owner, personal) ||
        !identical(Matrix.of(context).client, owner.client) ||
        !_canChange('person:${group.id}'))
      return;
    await owner.delete('person:${group.id}');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) => NotionSettingsScaffold(
      title: widget.section.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!personal.ready &&
              widget.section != PersonalSettingsSection.push &&
              widget.section != PersonalSettingsSection.sync)
            NotionListRow(
              leading: const Icon(Icons.lock_outline),
              title: 'Private sync is unavailable',
              subtitle: kIsWeb
                  ? 'Private encrypted storage requires the native app.'
                  : personal.problem ??
                        'Connect private sync to use this feature.',
              onTap: () => context.push('/rooms/settings/sync'),
            ),
          ...switch (widget.section) {
            PersonalSettingsSection.sync => <Widget>[
              ListTile(
                leading: Icon(personal.ready ? Icons.lock : Icons.lock_outline),
                title: Text(
                  personal.ready
                      ? 'Private sync configured'
                      : 'Private sync not connected',
                ),
                subtitle: Text(
                  kIsWeb
                      ? 'Private encrypted storage requires the native app. Ordinary conversations are available in the browser.'
                      : personal.problem ?? personal.workerReadinessDescription,
                ),
              ),
              if (!personal.ready && !kIsWeb)
                NotionListRow(
                  title: 'Connect private sync',
                  subtitle: 'Find your existing private journal or set it up.',
                  onTap: () => run(personal.connect),
                ),
              NotionListRow(
                leading: const Icon(Icons.cloud_outlined),
                title: 'Background services',
                subtitle: personal.workerReadinessDescription,
              ),
              if (personal.problem != null)
                NotionListRow(
                  title: 'Retry private sync',
                  subtitle:
                      'Reload existing local state and synchronization status.',
                  onTap: () => run(personal.retry),
                ),
              if (personal.pending.isNotEmpty)
                ListTile(
                  title: Text(
                    '${personal.pending.length} changes awaiting confirmation',
                  ),
                ),
              if (personal.conflicts.keys.any(
                (key) =>
                    !key.startsWith('label:') && !key.startsWith('labels:'),
              )) ...[
                const ListTile(
                  title: Text('Conflicts — both versions retained'),
                ),
                for (final conflict in personal.conflicts.entries.where(
                  (e) =>
                      !e.key.startsWith('label:') &&
                      !e.key.startsWith('labels:'),
                ))
                  ListTile(
                    onTap: () => run(() async {
                      if (conflict.key.startsWith('draft:')) {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => DraftConflictPage(
                              personal: personal,
                              entityKey: conflict.key,
                            ),
                          ),
                        );
                      } else {
                        await resolvePersonalMetadataConflict(
                          context,
                          personal,
                          conflict.key,
                        );
                      }
                    }),
                    title: Text(
                      conflict.key.startsWith('draft:')
                          ? 'Two draft versions'
                          : 'Concurrent change',
                    ),
                    subtitle: const Text(
                      'Reopen the affected draft or setting before choosing a version.',
                    ),
                  ),
              ],
              for (final copy in personal.values.entries.where(
                (e) => e.key.startsWith('draft-copy:'),
              ))
                ExpansionTile(
                  title: const Text('Retained draft copy'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        copy.value['text'] is String
                            ? copy.value['text'] as String
                            : '',
                      ),
                    ),
                  ],
                ),
              NotionListRow(
                leading: const Icon(Icons.description_outlined),
                title: 'Transcriptions',
                subtitle: 'Manual requests, estimated costs and service status',
                onTap: () => context.push('/rooms/settings/transcriptions'),
              ),
            ],
            PersonalSettingsSection.push => <Widget>[
              ListTile(
                title: const Text('Notification setup'),
                subtitle: Text(
                  kIsWeb
                      ? 'Private push gateway setup requires the native app.'
                      : _push?.registrationDescription(widget.client) ??
                            'Notification registration has not been checked.',
                ),
                onTap: kIsWeb ? null : () => run(_configurePush),
                trailing: kIsWeb ? null : const Icon(Icons.chevron_right),
              ),
              ListTile(
                title: const Text('Copy private push registration (secrets)'),
                subtitle: const Text(
                  'The token and key are copied only when you choose this action.',
                ),
                leading: const Icon(Icons.copy_outlined),
                onTap: kIsWeb ? null : () => run(_copyPushRegistration),
              ),
              NotionListRow(
                title: 'Notification registration details',
                subtitle: 'Registered devices and available push providers',
                onTap: () =>
                    context.push('/rooms/settings/notifications/registration'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Registration describes this device configuration. It does not confirm gateway authorization or notification delivery.',
                ),
              ),
            ],
            PersonalSettingsSection.people => <Widget>[
              ListTile(
                title: const Text('Merge conversations'),
                trailing: IconButton(
                  tooltip: 'Merge conversations',
                  icon: const Icon(Icons.add),
                  onPressed: personal.ready ? () => run(merge) : null,
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
                    onPressed:
                        personal.ready &&
                            !personal.pending.values.any(
                              (op) => op.entityId == 'person:${group.id}',
                            )
                        ? () => run(() => _unmerge(group))
                        : null,
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
              if (personal.groups.isEmpty)
                const ListTile(
                  subtitle: Text(
                    'Merge two or more conversations for one person using the add button. Every message keeps its source network.',
                  ),
                ),
            ],
            PersonalSettingsSection.reminders => <Widget>[
              for (final e in personal.reminders.entries)
                ListTile(
                  title: const Text('Conversation reminder'),
                  subtitle: Text('${e.value['dueAt']} · ${e.value['state']}'),
                  trailing: IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed:
                        !personal.ready ||
                            personal.pending.values.any(
                              (op) => op.entityId == e.key,
                            )
                        ? null
                        : () => run(() async {
                            await personal.command('reminder.cancel', e.key, {
                              'id': e.key,
                            }, baseRevision: e.value['revision'] as int? ?? 0);
                          }),
                  ),
                ),
              if (personal.reminders.isEmpty)
                const ListTile(
                  title: Text('No reminders'),
                  subtitle: Text(
                    'Create a reminder from a conversation to bring it back at the right time.',
                  ),
                ),
            ],
            PersonalSettingsSection.scheduled => <Widget>[
              for (final e in personal.schedules.entries)
                ListTile(
                  title: Text(
                    (e.value['content'] as Map?)?['body'] as String? ??
                        'Message',
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
                        !personal.pending.values.any(
                          (op) => op.entityId == e.key,
                        ),
                    onSelected: (kind) => run(() async {
                      final owner = personal;
                      bool current() =>
                          mounted &&
                          identical(owner, personal) &&
                          identical(Matrix.of(context).client, owner.client);
                      if (!current()) return;
                      if (kind == 'update') {
                        final content = Map<String, dynamic>.from(
                          e.value['content'] as Map,
                        );
                        if ({
                          'm.text',
                          'm.notice',
                        }.contains(content['msgtype'])) {
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
                          if (!current()) return;
                          content['body'] = text;
                        }
                        if (!context.mounted) return;
                        final due = await personalDate(context);
                        if (due == null ||
                            !due.isAfter(DateTime.now()) ||
                            !current())
                          return;
                        final job = ScheduledSend.fromJson({
                          ...e.value,
                          'dueAt': due.toUtc().toIso8601String(),
                          'content': content,
                        });
                        await owner.command(
                          'schedule.update',
                          e.key,
                          job.toJson().cast<String, dynamic>(),
                          baseRevision: e.value['revision'] as int? ?? 0,
                        );
                      } else {
                        await owner.command('schedule.$kind', e.key, {
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
                        enabled: {
                          'queued',
                          'paused',
                        }.contains(e.value['state']),
                        child: Text('Edit time or message'),
                      ),
                      const PopupMenuItem(
                        value: 'cancel',
                        child: Text('Cancel'),
                      ),
                    ],
                  ),
                ),
              if (personal.schedules.isEmpty)
                const ListTile(
                  title: Text('No scheduled messages'),
                  subtitle: Text(
                    'Choose Send later when composing a message in a conversation.',
                  ),
                ),
            ],
            PersonalSettingsSection.transcriptions => <Widget>[
              ListTile(
                title: const Text('Transcription service'),
                subtitle: Text(personal.workerReadinessDescription),
              ),
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
          },
        ],
      ),
    ),
  );
}

class _MergeSelectionPage extends StatefulWidget {
  final PersonalClient personal;
  final List<Room> rooms;
  const _MergeSelectionPage({required this.personal, required this.rooms});
  @override
  State<_MergeSelectionPage> createState() => _MergeSelectionPageState();
}

class _MergeSelectionPageState extends State<_MergeSelectionPage> {
  final _name = TextEditingController();
  final _selected = <String>{};
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _current =>
      widget.personal.ready &&
      identical(Matrix.of(context).client, widget.personal.client);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: const BackButton(),
      title: const Text('Merge conversations'),
      centerTitle: false,
    ),
    body: NotionSettingsBody(
      withScrolling: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Person name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          const Text(
            'Select at least two conversations. Each message keeps its original network.',
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                for (final room in widget.rooms)
                  CheckboxListTile(
                    value: _selected.contains(room.id),
                    title: Text(room.getLocalizedDisplayname()),
                    subtitle: Text(PersonalClient.networkOf(room)),
                    onChanged: !_current
                        ? null
                        : (value) => setState(() {
                            value == true
                                ? _selected.add(room.id)
                                : _selected.remove(room.id);
                          }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: FilledButton(
              onPressed:
                  !_current || _selected.length < 2 || _name.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      PersonGroup(
                        id: const Uuid().v4(),
                        name: _name.text.trim(),
                        members: widget.rooms
                            .where((room) => _selected.contains(room.id))
                            .map(widget.personal.ref)
                            .toList(),
                        defaultRoomId: _selected.first,
                      ),
                    ),
              child: const Text('Merge conversations'),
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
    itemBuilder: (_) =>
        conversationQuickActions(editing: isEditing?.call() == true),
    onSelected: (kind) async {
      if (!context.mounted ||
          !identical(Matrix.of(context).client, room.client) ||
          isCurrentSource?.call() == false)
        return;
      if (kind == 'source.search') {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => NotionConversationContentPage(
              rooms: [room],
              name: InboxProjection(
                PersonalClient.of(room.client),
              ).displayName(room),
            ),
          ),
        );
        return;
      }
      if (kind.startsWith('source.')) {
        await performNotionRoomAction(context, room, kind.substring(7));
        return;
      }
      final p = PersonalClient.of(room.client);
      try {
        // Freeze relation, source and text before even the private-sync await.
        final frozenText = composer.text;
        final frozenReply = replyEvent?.call();
        final frozenRoot = threadRootEventId?.call();
        final frozenLast = threadLastEventId?.call();
        final privacyGeneration = PersonalPrivacy.surfaceGeneration;
        final scheduled = {'schedule', 'scheduleMedia'}.contains(kind)
            ? FrozenScheduledComposer.capture(
                room: room,
                target: SendTarget(
                  conversation: p.ref(room),
                  readUpToEventId: readCutoff(),
                ),
                reply: frozenReply,
                editing: isEditing?.call() == true,
                threadRootEventId: frozenRoot,
                threadLastEventId: frozenLast,
                isCurrent: () =>
                    context.mounted &&
                    isCurrentSource?.call() != false &&
                    PersonalPrivacy.surfaceUnlocked &&
                    privacyGeneration == PersonalPrivacy.surfaceGeneration &&
                    frozenReply?.eventId == replyEvent?.call()?.eventId &&
                    frozenRoot == threadRootEventId?.call() &&
                    frozenLast == threadLastEventId?.call() &&
                    isEditing?.call() != true &&
                    identical(Matrix.of(context).client, room.client),
              )
            : null;
        bool sameComposerContext() =>
            context.mounted &&
            isCurrentSource?.call() != false &&
            identical(Matrix.of(context).client, room.client) &&
            scheduled!.matchesContext(
              reply: replyEvent?.call(),
              editing: isEditing?.call() == true,
              threadRootEventId: threadRootEventId?.call(),
              threadLastEventId: threadLastEventId?.call(),
            );
        if (kind == 'schedule') {
          final choice = await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Send later'),
              children: [
                SimpleDialogOption(
                  onPressed: frozenText.trim().isEmpty
                      ? null
                      : () => Navigator.pop(context, 'schedule'),
                  child: Text(
                    frozenText.trim().isEmpty
                        ? 'Text (write a message first)'
                        : 'Text',
                  ),
                ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, 'scheduleMedia'),
                  child: const Text('Attachment'),
                ),
              ],
            ),
          );
          if (choice == null || !context.mounted) return;
          scheduled!.validateCurrent();
          kind = choice;
        }
        await p.load();
        if (!context.mounted ||
            isCurrentSource?.call() == false ||
            !identical(Matrix.of(context).client, room.client) ||
            !PersonalPrivacy.surfaceUnlocked)
          return;
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
            content: scheduled.content({
              'msgtype': 'm.text',
              'body': frozenText,
            }),
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
          await requestConversationReminder(
            context,
            p,
            room,
            isCurrent: () =>
                context.mounted &&
                isCurrentSource?.call() != false &&
                identical(Matrix.of(context).client, room.client),
          );
          return;
        }
        if (!context.mounted) return;
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

/// The same short menu is used by ordinary and merged conversations.
List<PopupMenuEntry<String>> conversationQuickActions({
  bool editing = false,
  bool merged = false,
}) => [
  const PopupMenuItem(
    value: 'source.search',
    child: ListTile(
      leading: Icon(Icons.search_outlined),
      title: Text('Search conversation'),
    ),
  ),
  PopupMenuItem(
    value: 'schedule',
    enabled: !editing,
    child: ListTile(
      leading: const Icon(Icons.schedule_outlined),
      title: Text(editing ? 'Send later (finish editing first)' : 'Send later'),
    ),
  ),
  const PopupMenuItem(
    value: 'reminder',
    child: ListTile(
      leading: Icon(Icons.alarm_outlined),
      title: Text('Remind me'),
    ),
  ),
  PopupMenuItem(
    value: 'read',
    child: ListTile(
      leading: const Icon(Icons.mark_chat_read_outlined),
      title: Text(merged ? 'Mark all sources as read' : 'Mark as read'),
    ),
  ),
  const PopupMenuDivider(),
  const PopupMenuItem(
    value: 'source.details',
    child: ListTile(
      leading: Icon(Icons.info_outline),
      title: Text('Chat details'),
    ),
  ),
];

Future<void> requestConversationReminder(
  BuildContext context,
  PersonalClient p,
  Room room, {
  required bool Function() isCurrent,
}) async {
  final account = p.client.userID;
  final generation = PersonalPrivacy.surfaceGeneration;
  bool current() =>
      context.mounted &&
      isCurrent() &&
      account != null &&
      p.client.userID == account &&
      identical(p.client.getRoomById(room.id), room) &&
      room.membership == Membership.join &&
      PersonalPrivacy.surfaceUnlocked &&
      PersonalPrivacy.surfaceGeneration == generation;
  await p.load();
  if (!current()) return;
  final due = await personalDate(context);
  if (due == null || !current()) return;
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
              onChanged: (value) => set(() => untilReply = value ?? false),
            ),
            CheckboxListTile(
              title: const Text('Archive this conversation until the reminder'),
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
  if (options == null || !current()) return;
  if (!due.isAfter(DateTime.now())) throw StateError('Past date');
  final id = const Uuid().v4();
  await p.command('reminder.create', id, {
    'id': id,
    'conversation': p.ref(room).toJson(),
    'dueAt': due.toUtc().toIso8601String(),
    'untilReply': options['untilReply'],
  });
  if (!current()) return;
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
        for (final source in sources) source.id: source.lastEvent?.eventId,
      },
    });
  }
}
