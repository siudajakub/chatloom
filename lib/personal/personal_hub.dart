// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/automatic_push.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/personal/scheduled_composer.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/personal/ui/merge_picker_sheet.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/personal/ui/transcription_settings.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/notion_room_actions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

import 'person_route.dart';

Future<String?> personalText(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final c = TextEditingController(text: initial);
  try {
    return await showNotionCustomDialog<String>(
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
  final confirmed = await showNotionCustomDialog<bool>(
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
    // Load after the page slid in, and skip it right after another page did.
    PersonalPageLoad.request(context, personal);
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
      nonce = await showNotionCustomDialog<String>(
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

  Future<void> _setupAutomaticPush() async {
    final account = widget.client;
    final owner = account.userID;
    final device = account.deviceID;
    bool current() =>
        mounted &&
        identical(widget.client, account) &&
        identical(Matrix.of(context).client, account) &&
        account.isLogged() &&
        account.userID == owner &&
        account.deviceID == device;
    final push = BackgroundPush(Matrix.of(context));
    push.beginRegistrationUpdate();
    try {
      await AppSettings.pushNotificationsGatewayUrl.setItem(
        personalPushGateway,
      );
    } finally {
      push.endRegistrationUpdate();
    }
    if (!mounted || !current()) return;
    await push.setupPush(context);
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

  /// Merge from People settings: the picker needs at least two chats; the
  /// first selected chat names the person (see [planMerge]).
  Future<void> merge() async {
    final owner = personal;
    if (!owner.ready) return;
    final picked = await showMergePicker(context, personal: owner);
    if (picked == null ||
        picked.length < 2 ||
        !mounted ||
        !identical(owner, personal) ||
        !identical(Matrix.of(context).client, owner.client))
      return;
    final plan = planMerge(owner, [
      for (final candidate in picked) ...candidate.sources,
    ], anchor: picked.first.representative);
    await applyMerge(owner, plan);
  }

  Future<void> _unmerge(PersonGroup group) async {
    final owner = personal;
    final confirmed = await showNotionConfirmDialog(
      context: context,
      title: 'Unmerge conversations?',
      message:
          'The source chats and their messages are kept and return to the inbox as separate chats.',
      confirmLabel: 'Unmerge',
    );
    if (!confirmed ||
        !mounted ||
        !identical(owner, personal) ||
        !identical(Matrix.of(context).client, owner.client) ||
        !owner.ready)
      return;
    // Hidden at once; the delete may wait for a merge acknowledgement. If
    // that never comes, the person returns and the user is told.
    final messenger = ScaffoldMessenger.of(context);
    unawaited(
      owner.removeGroup(group.id).catchError((Object _) {
        if (!mounted || !identical(owner, personal)) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text('The change was not saved. Check private sync.'),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) => NotionSettingsScaffold(
      title: widget.section.title,
      // Rows rise in once after the page settles; rows that come and go
      // later (sync problems, pending changes) reveal in place.
      child: NotionEntranceScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: NotionEntrance.stagger([
            NotionSizeReveal(
              visible:
                  !personal.ready &&
                  widget.section != PersonalSettingsSection.push &&
                  widget.section != PersonalSettingsSection.sync,
              child: NotionListRow(
                leading: const Icon(Icons.lock_outline),
                title: 'Private sync is unavailable',
                subtitle: kIsWeb
                    ? 'Private encrypted storage requires the native app.'
                    : personal.problem ??
                          'Connect private sync to use this feature.',
                onTap: () => context.push('/rooms/settings/sync'),
              ),
            ),
            ...switch (widget.section) {
              PersonalSettingsSection.sync => <Widget>[
                ListTile(
                  leading: NotionMorphSwitcher(
                    child: Icon(
                      personal.ready ? Icons.lock : Icons.lock_outline,
                      key: ValueKey(personal.ready),
                    ),
                  ),
                  title: NotionFadeThrough(
                    child: Text(
                      personal.ready
                          ? 'Private sync configured'
                          : 'Private sync not connected',
                      key: ValueKey(personal.ready),
                    ),
                  ),
                  subtitle: Text(
                    kIsWeb
                        ? 'Private encrypted storage requires the native app. Ordinary conversations are available in the browser.'
                        : personal.problem ??
                              personal.workerReadinessDescription,
                  ),
                ),
                NotionSizeReveal(
                  visible: !personal.ready && !kIsWeb,
                  child: NotionListRow(
                    title: 'Connect private sync',
                    subtitle:
                        'Find your existing private journal or set it up.',
                    onTap: () => run(personal.connect),
                  ),
                ),
                NotionListRow(
                  leading: const Icon(Icons.cloud_outlined),
                  title: 'Background services',
                  subtitle: personal.workerReadinessDescription,
                ),
                NotionSizeReveal(
                  visible: personal.problem != null,
                  child: NotionListRow(
                    title: 'Retry private sync',
                    subtitle:
                        'Reload existing local state and synchronization status.',
                    onTap: () => run(personal.retry),
                  ),
                ),
                NotionSizeReveal(
                  visible: personal.pending.isNotEmpty,
                  child: ListTile(
                    leading: const NotionDelayedSpinner(),
                    title: NotionAnimatedCount(
                      count: personal.pending.length,
                      format: (count) => '$count changes awaiting confirmation',
                    ),
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
                    _pressable(
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
                  subtitle:
                      'Automatic transcription, language, limits and usage',
                  onTap: () => context.push('/rooms/settings/transcriptions'),
                ),
              ],
              PersonalSettingsSection.push => <Widget>[
                _pressable(
                  ListTile(
                    title: const Text('Set up notifications automatically'),
                    subtitle: Text(
                      kIsWeb
                          ? 'Automatic notifications require the Android app.'
                          : !PlatformInfos.isAndroid
                          ? 'Automatic background notifications are available on Android.'
                          : _push?.registrationDescription(widget.client) ??
                                'Notification registration has not been checked.',
                    ),
                    onTap: !PlatformInfos.isAndroid
                        ? null
                        : () => run(_setupAutomaticPush),
                    trailing: !PlatformInfos.isAndroid
                        ? null
                        : const Icon(Icons.refresh),
                  ),
                ),
                ExpansionTile(
                  title: const Text('Advanced notification settings'),
                  children: [
                    ListTile(
                      title: const Text('Configure a gateway manually'),
                      onTap: kIsWeb ? null : () => run(_configurePush),
                    ),
                    ListTile(
                      title: const Text(
                        'Copy private push registration (secrets)',
                      ),
                      subtitle: const Text(
                        'Only needed for manual gateway configuration.',
                      ),
                      leading: const Icon(Icons.copy_outlined),
                      onTap: kIsWeb ? null : () => run(_copyPushRegistration),
                    ),
                  ],
                ),
                NotionListRow(
                  title: 'Notification registration details',
                  subtitle: 'Registered devices and available push providers',
                  onTap: () => context.push(
                    '/rooms/settings/notifications/registration',
                  ),
                ),
                NotionListRow(
                  leading: const Icon(Icons.troubleshoot_outlined),
                  title: 'Notification diagnostics',
                  subtitle: 'Checks, recent outcomes and a test notification',
                  onTap: () =>
                      context.push('/rooms/settings/notifications/diagnostics'),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'On Android, notifications are set up after sign-in. Allow the notification permission when asked. Use Notification diagnostics to send a test notification.',
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
                  _pressable(
                    ListTile(
                      key: ValueKey(group.id),
                      title: Text(group.name),
                      subtitle: Text('${group.members.length} sources'),
                      onTap: () => context.push(personChatLocation(group.id)),
                      trailing: IconButton(
                        tooltip: 'Unmerge',
                        icon: const Icon(Icons.call_split),
                        onPressed: personal.ready
                            ? () => run(() => _unmerge(group))
                            : null,
                      ),
                    ),
                  ),
                if (personal.invalidGroupCount > 0)
                  ListTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: const Text(
                      'Some saved conversation groups could not be loaded. Their data is preserved.',
                    ),
                    subtitle: Text(
                      '${personal.invalidGroupCount} saved groups',
                    ),
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
                    title: Text(_reminderChatName(personal, e.value)),
                    subtitle: Text(_reminderSubtitle(context, e.value)),
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
                              await personal.command(
                                'reminder.cancel',
                                e.key,
                                {'id': e.key},
                                baseRevision: e.value['revision'] as int? ?? 0,
                              );
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
                      popUpAnimationStyle: NotionMotion.menuStyle,
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
                TranscriptionSettingsSection(personal: personal, run: run),
              ],
            },
          ]),
        ),
      ),
    ),
  );
}

/// Press feedback for a tappable Material [ListTile] row.
Widget _pressable(Widget row) =>
    NotionPressable(scale: NotionMotion.pressRow, child: row);

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
    popUpAnimationStyle: NotionMotion.menuStyle,
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
          final choice = await showNotionCustomDialog<String>(
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

/// Chat name for a reminder row, respecting private nicknames.
String _reminderChatName(PersonalClient p, Map<String, dynamic> reminder) {
  try {
    final conversation = reminder['conversation'];
    final roomId = conversation is Map ? conversation['roomId'] : null;
    final room = roomId is String ? p.client.getRoomById(roomId) : null;
    if (room != null) return InboxProjection(p).displayName(room);
  } catch (_) {}
  return 'Conversation reminder';
}

String _reminderSubtitle(BuildContext context, Map<String, dynamic> reminder) {
  final due = reminder['dueAt'];
  final at = due is String ? DateTime.tryParse(due)?.toLocal() : null;
  final localizations = MaterialLocalizations.of(context);
  final when = at == null
      ? 'No date'
      : '${localizations.formatMediumDate(at)} · '
            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(at), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
  final state = switch (reminder['state']) {
    'queued' => 'Scheduled',
    'waitingKeys' || 'waitingSync' => 'Waiting to check for replies',
    'done' => 'Done',
    'cancelled' => 'Cancelled',
    'conflict' => 'Not saved',
    _ => 'Pending',
  };
  return '$when · $state';
}

Future<void> requestConversationReminder(
  BuildContext context,
  PersonalClient p,
  Room room, {
  required bool Function() isCurrent,
}) async {
  // The message the user is looking at; the reminder notification shows it.
  final anchor = room.lastEvent?.eventId;
  final anchorEventId =
      anchor != null && anchor.startsWith(r'$') && anchor.length <= 255
      ? anchor
      : null;
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
  final options = await showNotionCustomDialog<Map<String, bool>>(
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
    'anchorEventId': ?anchorEventId,
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
