// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/automatic_push.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/conversation_mute.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/reminder_list.dart' show reminderWhen;
import 'package:chatloom/personal/scheduled_composer.dart';
import 'package:chatloom/personal/send_later.dart' show runSendLater;
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/personal/ui/people_section.dart';
import 'package:chatloom/personal/ui/reminders_page.dart'
    show requestConversationReminder;
import 'package:chatloom/personal/ui/scheduled_page.dart';
import 'package:chatloom/personal/ui/sync_changes_section.dart';
import 'package:chatloom/personal/ui/transcription_settings.dart';
import 'package:chatloom/personal/ui/worker_status_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/notion_room_actions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

export 'package:chatloom/personal/ui/reminders_page.dart'
    show requestConversationReminder;

/// A one-field text dialog (Developer settings' gateway URL), in the
/// Notion glass dialog. Returns the text on Save, null on Cancel.
Future<String?> personalText(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final c = TextEditingController(text: initial);
  try {
    return await showNotionDialog<String>(
      context: context,
      title: title,
      content: NotionTextField(
        controller: c,
        autofocus: true,
        maxLines: 3,
        minLines: 1,
      ),
      actions: (context) => [
        NotionButton.ghost(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        NotionButton.primary(
          label: 'Save',
          onPressed: () => Navigator.pop(context, c.text),
        ),
      ],
    );
  } finally {
    c.dispose();
  }
}

/// The selected room is frozen before either picker opens. No source message is
/// sent during preparation; only SDK-encrypted ciphertext is uploaded.
///
/// With [dueAt] (Send later already chose the time) the file is scheduled
/// right after it is picked; without it a date picker and a confirmation
/// follow. Problems the user can fix throw [SendLaterProblem].
Future<bool> schedulePersonalAttachment(
  BuildContext context,
  PersonalClient personal,
  SendTarget target, {
  FrozenScheduledComposer? composeContext,
  DateTime? dueAt,
}) async {
  final room = personal.client.getRoomById(target.conversation.roomId);
  if (target.conversation.accountId != personal.client.userID ||
      room == null ||
      room.membership != Membership.join ||
      !room.canSendDefaultMessages ||
      !personal.ready) {
    throw SendLaterProblem(
      personal.ready
          ? 'This chat can’t receive scheduled attachments right now.'
          : 'Send later needs private sync. Your draft is kept.',
      needsSync: !personal.ready,
    );
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
    throw SendLaterProblem(
      'The scheduled source does not match the attachment.',
    );
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
    throw SendLaterProblem('Choose an attachment up to 25 MB.');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > maximum || bytes.isEmpty) {
    throw SendLaterProblem(
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
  if (!capability.allowed) throw SendLaterProblem(capability.reason);
  if (!context.mounted) return false;
  // Without a time from Send later: the same one-tap times and Date/Time
  // rows as Send later and Remind me (not the stock date + time pickers).
  final due =
      dueAt ??
      (await showScheduledEditor(
        context,
        chatName: InboxProjection(personal).displayName(room),
        title: 'Schedule an attachment',
        saveLabel: 'Continue',
      ))?.at;
  if (due == null || !context.mounted) return false;
  if (!due.isAfter(DateTime.now())) {
    throw SendLaterProblem('That time has passed. Choose a new time.');
  }
  final confirmed =
      dueAt != null ||
      await showNotionConfirmDialog(
        context: context,
        title: 'Schedule an attachment',
        message: [
          '${file.name} · ${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB',
          [
            notionNetworkLabel(target.conversation.network),
            reminderWhen(
              due,
              DateTime.now(),
              MaterialLocalizations.of(context),
              use24h: MediaQuery.alwaysUse24HourFormatOf(context),
            ),
          ].join(' · '),
          ?frozen.contextLabel,
        ].join('\n'),
        confirmLabel: 'Schedule',
      );
  if (!confirmed) return false;
  frozen.validateCurrent();
  if (personal.client.getRoomById(target.conversation.roomId) != room ||
      !RoomCapabilities.forFeature(feature, room, media: media).allowed) {
    throw SendLaterProblem('The selected source changed. Select it again.');
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
    throw SendLaterProblem('The selected source changed. Select it again.');
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
  sync('Private sync'),
  people('Merged conversations'),
  transcriptions('Transcription'),
  scheduled('Scheduled messages'),
  push('Push setup');

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
                              (personal.ready
                                  ? 'Your private preferences, drafts and schedules sync between your devices.'
                                  : 'Connect to keep private preferences in sync.'),
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
                WorkerStatusRow(personal: personal),
                NotionSizeReveal(
                  visible: personal.problem != null,
                  child: NotionListRow(
                    title: 'Retry private sync',
                    subtitle:
                        'Reload existing local state and synchronization status.',
                    onTap: () => run(personal.retry),
                  ),
                ),
                // What still waits for the worker and what changed on two
                // devices, each named and with its one-tap action.
                SyncChangesSection(personal: personal, run: run),
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
                // Manual gateway setup, its secrets and registration details
                // are in Settings › Advanced › Developer (CS-02); diagnostics
                // has its own row on the Notifications page (CS-20).
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'On Android, notifications are set up after sign-in. Allow the notification permission when asked. To send a test notification, use Troubleshoot notifications.',
                  ),
                ),
              ],
              PersonalSettingsSection.people => <Widget>[
                // Merge, suggestions and merged persons (people_section.dart).
                PeopleSettingsSection(personal: personal, run: run),
              ],
              PersonalSettingsSection.scheduled => <Widget>[
                // Sections, human states and times, glass menus (UI-04).
                ScheduledMessagesSection(personal: personal, run: run),
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
  Widget build(BuildContext context) => NotionMenuButton<String>(
    label: includeChatSettings ? 'Conversation options' : 'Conversation tools',
    icon: includeChatSettings ? Icons.more_horiz : Icons.more_time,
    alignEnd: true,
    entries: () {
      final p = PersonalClient.of(room.client);
      return conversationQuickActions(
        editing: isEditing?.call() == true,
        mute: room.membership == Membership.join
            ? conversationMuteState(
                context,
                p,
                InboxProjection(p).entityFor(room),
              )
            : null,
      );
    },
    onSelected: (kind) => run(context, kind),
  );

  /// Runs one quick action ([conversationQuickActions]) for this source; the
  /// composer's long press on Send calls it with `schedule` and `reminder`.
  Future<void> run(BuildContext context, String kind) async {
    if (!context.mounted ||
        !identical(Matrix.of(context).client, room.client) ||
        isCurrentSource?.call() == false) {
      return;
    }
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
    if (kind == 'mute' || kind == 'unmute') {
      await runConversationMute(
        context,
        p,
        InboxProjection(p).entityFor(room),
        unmute: kind == 'unmute',
        isCurrent: () =>
            context.mounted &&
            isCurrentSource?.call() != false &&
            identical(Matrix.of(context).client, room.client),
      );
      return;
    }
    if (kind == 'schedule') {
      await _sendLater(context, p);
      return;
    }
    try {
      await p.load();
      if (!context.mounted ||
          isCurrentSource?.call() == false ||
          !identical(Matrix.of(context).client, room.client) ||
          !PersonalPrivacy.surfaceUnlocked) {
        return;
      }
      if (kind == 'read') {
        final id = room.lastEvent?.eventId;
        if (id != null) {
          await PersonalPrivacy.markRead(room, id, manual: true);
        }
        return;
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
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kind == 'reminder'
                  ? 'The reminder could not be saved. Check private sync and try again.'
                  : 'This chat could not be marked as read. Try again.',
            ),
          ),
        );
      }
    }
  }

  /// Send later: relation, source and text are frozen before the first
  /// await; the draft is emptied only if it is still the scheduled text.
  Future<void> _sendLater(BuildContext context, PersonalClient p) {
    final frozenText = composer.text;
    final privacyGeneration = PersonalPrivacy.surfaceGeneration;
    late final FrozenScheduledComposer scheduled;
    bool sameComposerContext() =>
        context.mounted &&
        isCurrentSource?.call() != false &&
        identical(Matrix.of(context).client, room.client) &&
        scheduled.matchesContext(
          reply: replyEvent?.call(),
          editing: isEditing?.call() == true,
          threadRootEventId: threadRootEventId?.call(),
          threadLastEventId: threadLastEventId?.call(),
        );
    return runSendLater(
      context,
      personal: p,
      text: frozenText,
      chatName: InboxProjection(p).displayName(room),
      freeze: () {
        final frozenReply = replyEvent?.call();
        final frozenRoot = threadRootEventId?.call();
        final frozenLast = threadLastEventId?.call();
        return scheduled = FrozenScheduledComposer.capture(
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
        );
      },
      onTextScheduled: () async {
        if (composer.text != frozenText || !sameComposerContext()) return;
        await p.saveDraft(room, '');
        if (composer.text == frozenText && sameComposerContext()) {
          composer.clear();
          clearScheduledReply?.call();
        } else {
          await p.saveDraft(room, composer.text);
        }
      },
    );
  }
}

/// The same short menu is used by ordinary and merged conversations
/// (glass `showNotionMenu` rows keyed `menu-<value>`). [mute] adds Mute… /
/// Unmute; a timed mute shows its end under Unmute (FX-07).
List<NotionMenuEntry<String>> conversationQuickActions({
  bool editing = false,
  bool merged = false,
  ConversationMuteState? mute,
}) => [
  const NotionMenuEntry(
    key: ValueKey('menu-source.search'),
    value: 'source.search',
    label: 'Search conversation',
    icon: Icons.search_outlined,
  ),
  NotionMenuEntry(
    key: const ValueKey('menu-schedule'),
    value: 'schedule',
    enabled: !editing,
    label: editing ? 'Send later (finish editing first)' : 'Send later',
    icon: Icons.schedule_outlined,
  ),
  const NotionMenuEntry(
    key: ValueKey('menu-reminder'),
    value: 'reminder',
    label: 'Remind me',
    icon: Icons.alarm_outlined,
  ),
  NotionMenuEntry(
    key: const ValueKey('menu-read'),
    value: 'read',
    label: merged ? 'Mark all sources as read' : 'Mark as read',
    icon: Icons.mark_chat_read_outlined,
  ),
  if (mute != null)
    mute.muted
        ? NotionMenuEntry(
            key: const ValueKey('menu-unmute'),
            value: 'unmute',
            label: 'Unmute',
            subtitle: mute.until,
            icon: Icons.notifications_active_outlined,
            enabled: mute.canChange,
          )
        : NotionMenuEntry(
            key: const ValueKey('menu-mute'),
            value: 'mute',
            label: 'Mute…',
            icon: Icons.notifications_off_outlined,
            enabled: mute.canChange,
          ),
  const NotionMenuEntry.divider(),
  const NotionMenuEntry(
    key: ValueKey('menu-source.details'),
    value: 'source.details',
    label: 'Chat details',
    icon: Icons.info_outline,
  ),
];
