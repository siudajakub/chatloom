// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/conversation_mute.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/sync_changes.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/personal/ui/sync_changes_section.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_choice.dart';
import 'package:chatloom/ui/notion/notion_glass_header.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

String privateNotificationLabel(PersonalNotificationMode mode) =>
    switch (mode) {
      PersonalNotificationMode.all => 'All messages',
      PersonalNotificationMode.mentionsOnly => 'Mentions only',
      PersonalNotificationMode.muted => 'Muted',
    };

// The durable replica coalesces later edits without changing an attempted command.
// Pending synchronization must not lock an ignored chat out of being restored.
bool canEditChatPreferences(PersonalClient personal, String key) =>
    !kIsWeb && personal.ready && !personal.conflicts.containsKey(key);

/// Account-bound private rules. Does not write native Matrix notification rules.
class ChatPreferencesPage extends StatefulWidget {
  final PersonalClient personal;
  final Room room;
  const ChatPreferencesPage({
    super.key,
    required this.personal,
    required this.room,
  });
  @override
  State<ChatPreferencesPage> createState() => _ChatPreferencesPageState();
}

class _ChatPreferencesPageState extends State<ChatPreferencesPage> {
  bool _busy = false;
  String? _error;
  late final StreamSubscription _sync;
  PersonalClient get personal => widget.personal;
  bool get _active => identical(Matrix.of(context).client, personal.client);
  bool _canEdit(String key) =>
      _active && !_busy && canEditChatPreferences(personal, key);

  @override
  void initState() {
    super.initState();
    PersonalPageLoad.request(context, personal);
    _sync = personal.client.onSync.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sync.cancel();
    super.dispose();
  }

  Future<void> _save(String key, Map<String, dynamic> value) async {
    if (!_canEdit(key)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await personal.put(key, {...?personal.values[key], ...value});
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save this change. Check private sync and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, String> get _notificationChoices => {
    'inherit': 'Use default',
    for (final mode in PersonalNotificationMode.values)
      mode.name: privateNotificationLabel(mode),
  };

  /// The sync state of [keys] with its one-tap action: an unconfirmed change
  /// can be sent again, a conflict is resolved right here.
  List<Widget> _syncState(Set<String> keys) {
    final changes = SyncChanges.of(personal);
    final pending = changes.pending
        .where((change) => keys.contains(change.entity))
        .firstOrNull;
    final conflict = changes.conflicts
        .where((change) => keys.contains(change.entity))
        .firstOrNull;
    return [
      NotionSizeReveal(
        visible: pending != null,
        child: pending == null
            ? const SizedBox.shrink()
            : SyncPendingRow(
                personal: personal,
                change: pending,
                run: _runSync,
                title: 'Your latest change',
              ),
      ),
      NotionSizeReveal(
        visible: conflict != null,
        child: conflict == null
            ? const SizedBox.shrink()
            : SyncConflictTile(
                personal: personal,
                conflict: conflict,
                run: _runSync,
                title: 'Changed on another device too',
              ),
      ),
    ];
  }

  Future<void> _runSync(Future<void> Function() action) async {
    if (!_active) return;
    setState(() => _error = null);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save this choice. Check private sync and try again.',
        );
      }
    }
  }

  /// The private mute with its end (FX-07): Mute… opens the inbox's
  /// durations at the row, Unmute clears it; both with Undo.
  Widget _mute(
    String entity,
    ConversationMetadata metadata, {
    required bool enabled,
  }) {
    final muted = metadata.muted;
    return Builder(
      builder: (context) => NotionListRow(
        key: const ValueKey('preferences-mute'),
        leading: Icon(
          muted
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
        ),
        title: muted ? 'Unmute' : 'Mute…',
        subtitle: muted
            ? conversationMuteSubtitle(
                metadata.mutedUntil,
                DateTime.now(),
                MaterialLocalizations.of(context),
                use24h: MediaQuery.alwaysUse24HourFormatOf(context),
              )
            : 'For 1 hour, 8 hours, 1 week or until you unmute',
        trailing: const SizedBox.shrink(),
        onTap: enabled
            ? () => runConversationMute(
                context,
                personal,
                entity,
                unmute: muted,
                isCurrent: () => mounted && _active,
              )
            : null,
      ),
    );
  }

  List<Widget> _conversation(Room room, InboxProjection projection) {
    final entity = projection.entityFor(room);
    final key = 'org:$entity';
    final metadata = projection.metadataFor(room);
    final placement = projection.placementFor(room);
    final group = projection.groupFor(room);
    final sources = group == null
        ? [room]
        : group.members
              .map((source) => personal.client.getRoomById(source.roomId))
              .whereType<Room>()
              .toList();
    final ignored = placement == ChatPlacement.ignored;
    final enabled = _canEdit(key);
    return [
      Text(
        projection.displayName(room),
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      ..._syncState({key, for (final source in sources) 'org:${source.id}'}),
      _mute(entity, metadata, enabled: enabled && !ignored),
      if (group != null)
        const Text('Visibility applies to this person in all merged chats.'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Ignore chat'),
        subtitle: const Text(
          'Only in Ignored. No notifications, including mentions.',
        ),
        value: ignored,
        onChanged: enabled
            ? (value) {
                final kind = projection.classifier.classify(room);
                final updated = value
                    ? metadata.setIgnored(true)
                    : metadata.restoreIgnored(
                        inheritedIgnored:
                            kind.isGroup &&
                            projection
                                    .networkPreferences(kind.network)
                                    .groupPlacement ==
                                ChatPlacement.ignored,
                      );
                _save(key, updated.toJson().cast<String, dynamic>());
              }
            : null,
      ),
      PreferenceChoice(
        title: 'Show chat in',
        value: metadata.placement?.name ?? 'inherit',
        choices: {
          'inherit': 'Network default',
          'inbox': 'Main list',
          if (projection.classifier.classify(room).isGroup) 'groups': 'Groups',
        },
        onChanged: enabled && !ignored
            ? (value) => _save(
                key,
                metadata
                    .setPlacement(preferenceEnum(ChatPlacement.values, value))
                    .toJson()
                    .cast<String, dynamic>(),
              )
            : null,
      ),
      // Moved from "Colours & avatar" (CS-06): it decides where the chat
      // appears, like "Show chat in".
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Low priority'),
        subtitle: const Text(
          'Outside the inbox. Mentions and thread replies may still notify.',
        ),
        value: metadata.lowPriority,
        onChanged: enabled && !ignored
            ? (value) => _save(
                key,
                metadata.setLowPriority(value).toJson().cast<String, dynamic>(),
              )
            : null,
      ),
      for (final source in sources) ...[
        const Divider(height: 32),
        Text(
          notionNetworkLabel(projection.classifier.classify(source).network),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        if (sources.length > 1) Text(source.getLocalizedDisplayname()),
        PreferenceChoice(
          title: 'ChatLoom notifications',
          value:
              projection.metadataForEntity(source.id).notificationMode?.name ??
              'inherit',
          choices: _notificationChoices,
          onChanged: !ignored && _canEdit('org:${source.id}')
              ? (value) => _save(
                  'org:${source.id}',
                  projection
                      .metadataForEntity(source.id)
                      .setNotificationMode(
                        preferenceEnum(PersonalNotificationMode.values, value),
                      )
                      .toJson()
                      .cast<String, dynamic>(),
                )
              : null,
        ),
        NotionFadeThrough(
          child: Text(
            'Effective: ${privateNotificationLabel(projection.notificationModeFor(source))}',
            key: ValueKey(projection.notificationModeFor(source)),
          ),
        ),
        Text(
          'Account rule: ${switch (source.pushRuleState) {
            PushRuleState.notify => 'All messages',
            PushRuleState.mentionsOnly => 'Mentions only',
            PushRuleState.dontNotify => 'Muted',
          }}. Account restrictions still apply.',
        ),
        PreferenceChoice(
          title: 'Automatic transcription',
          value:
              switch (personal.transcriptionPolicy.chatOverrides[source.id]) {
                true => 'always',
                false => 'never',
                null => 'inherit',
              },
          choices: const {
            'inherit': 'Default',
            'always': 'Always',
            'never': 'Never',
          },
          onChanged: _canEdit(transcriptionPolicyEntity)
              ? (value) => _save(
                  transcriptionPolicyEntity,
                  personal.transcriptionPolicy.withChatOverride(
                    source.id,
                    switch (value) {
                      'always' => true,
                      'never' => false,
                      _ => null,
                    },
                  ).toJson(),
                )
              : null,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: personal,
    builder: (context, _) {
      final projection = InboxProjection(personal);
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: notionGlassAppBar(
          title: const Text('Visibility & notifications'),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NotionSize.contentMaxWidth,
            ),
            // Sections rise in once after the push; dependent notes and
            // progress open and close in place.
            child: NotionEntranceScope(
              child: Builder(
                builder: (context) => ListView(
                  // The rows scroll under the glass header.
                  padding: EdgeInsets.fromLTRB(
                    20,
                    20 + MediaQuery.paddingOf(context).top,
                    20,
                    20,
                  ),
                  children: NotionEntrance.stagger([
                    const Text(
                      'Private settings for ChatLoom. Your other Beeper apps are unchanged.',
                    ),
                    if (kIsWeb)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'Edit these encrypted preferences in the Android or macOS app.',
                        ),
                      )
                    else if (!_active)
                      const Text(
                        'The selected account changed. Go back and reopen these settings.',
                      )
                    else if (!personal.ready)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'Connect private sync in Settings › Advanced › Private sync to save these preferences.',
                        ),
                      ),
                    NotionSizeReveal(
                      visible: _busy,
                      duration: NotionMotion.short,
                      child: const NotionDelayedReveal(
                        placeholder: SizedBox(height: 4),
                        child: LinearProgressIndicator(),
                      ),
                    ),
                    NotionSizeReveal(
                      visible: _error != null,
                      child: NotionFadeThrough(
                        child: Text(_error ?? '', key: ValueKey(_error)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    ..._conversation(widget.room, projection),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// One private choice of this page, as a picker row.
class PreferenceChoice extends StatelessWidget {
  final String title;
  final String value;
  final Map<String, String> choices;
  final ValueChanged<String>? onChanged;
  const PreferenceChoice({
    super.key,
    required this.title,
    required this.value,
    required this.choices,
    this.onChanged,
  });

  /// A picker row (Telegram settings): the value on the right, a glass
  /// sheet of choices on tap (UI-10).
  @override
  Widget build(BuildContext context) => NotionPickerRow<String>(
    label: title,
    value: choices.containsKey(value) ? value : 'inherit',
    options: [
      for (final item in choices.entries) NotionChoice(item.key, item.value),
    ],
    onChanged: onChanged,
  );
}
