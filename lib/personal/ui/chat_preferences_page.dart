// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:fluffychat/personal/ui/notion_settings_load.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/matrix.dart';
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

String placementLabel(ChatPlacement placement) => switch (placement) {
  ChatPlacement.inbox => 'Main list',
  ChatPlacement.groups => 'Groups',
  ChatPlacement.ignored => 'Ignored',
};

// The durable replica coalesces later edits without changing an attempted command.
// Pending synchronization must not lock an ignored chat out of being restored.
bool canEditChatPreferences(PersonalClient personal, String key) =>
    !kIsWeb && personal.ready && !personal.conflicts.containsKey(key);

/// Account-bound private rules. Does not write native Matrix notification rules.
class ChatPreferencesPage extends StatefulWidget {
  final PersonalClient personal;
  final Room? room;
  const ChatPreferencesPage({super.key, required this.personal, this.room});
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

  Widget _network(String network, InboxProjection projection) {
    final key = 'network-policy:$network';
    final policy = projection.networkPreferences(network);
    final enabled = _canEdit(key);
    Future<void> update(Map<String, dynamic> patch) =>
        _save(key, {...policy.toJson(), ...patch});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        Text(
          notionNetworkLabel(network),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        PreferenceChoice(
          title: 'Groups appear in',
          value: policy.groupPlacement.name,
          choices: {
            for (final placement in ChatPlacement.values)
              placement.name: placementLabel(placement),
          },
          onChanged: enabled
              ? (value) => update({'groupPlacement': value})
              : null,
        ),
        PreferenceChoice(
          title: 'Notifications for this network',
          value: policy.notifications?.name ?? 'inherit',
          choices: _notificationChoices,
          onChanged: enabled
              ? (value) =>
                    update({'notifications': value == 'inherit' ? null : value})
              : null,
        ),
        PreferenceChoice(
          title: 'Notifications for all groups',
          value: policy.groupNotifications?.name ?? 'inherit',
          choices: _notificationChoices,
          onChanged: enabled
              ? (value) => update({
                  'groupNotifications': value == 'inherit' ? null : value,
                })
              : null,
        ),
        const Text(
          'Applies to current and future groups. Individual chat exceptions take priority.',
        ),
        NotionSizeReveal(
          visible: personal.pending.values.any((op) => op.entityId == key),
          child: const Text(
            'Saved locally · awaiting private sync confirmation.',
          ),
        ),
        NotionSizeReveal(
          visible: personal.conflicts.containsKey(key),
          child: const Text(
            'Conflicting changes. Review them in Sync & transcriptions.',
          ),
        ),
      ],
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
      NotionSizeReveal(
        visible: personal.pending.values.any(
          (op) =>
              op.entityId == key ||
              sources.any((source) => op.entityId == 'org:${source.id}'),
        ),
        child: const Text(
          'Saved locally · awaiting private sync confirmation.',
        ),
      ),
      if (group != null)
        const Text(
          'Visibility applies to this person across all merged sources.',
        ),
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
      for (final source in sources) ...[
        const Divider(height: 32),
        Text(
          notionNetworkLabel(projection.classifier.classify(source).network),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        if (sources.length > 1) Text(source.getLocalizedDisplayname()),
        PreferenceChoice(
          title: 'Personal Chat notifications',
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
      final networks =
          {
            for (final room in personal.client.rooms)
              if (!room.isSpace &&
                  !PersonalPrivacy.isJournal(room) &&
                  !projection.classifier.classify(room).technical)
                projection.classifier.classify(room).network,
            for (final key in personal.values.keys)
              if (key.startsWith('network-policy:'))
                key.substring('network-policy:'.length),
          }.toList()..sort(
            (a, b) => notionNetworkLabel(a).compareTo(notionNetworkLabel(b)),
          );
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.room == null
                ? 'Networks & chat rules'
                : 'Visibility & notifications',
          ),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            // Sections rise in once after the push; dependent notes and
            // progress open and close in place.
            child: NotionEntranceScope(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: NotionEntrance.stagger([
                  const Text(
                    'Private settings for Personal Chat. Other Beeper and Matrix clients are unchanged.',
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
                        'Connect private sync in Settings → Sync & transcriptions to save these preferences.',
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
                  if (widget.room case final room?)
                    ..._conversation(room, projection)
                  else ...[
                    if (networks.isEmpty) const Text('No networks loaded yet.'),
                    for (final network in networks)
                      _network(network, projection),
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

/// Stacked label/control keeps large text readable on narrow screens.
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
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title),
        DropdownButton<String>(
          isExpanded: true,
          style: Theme.of(context).textTheme.bodyLarge,
          itemHeight: (MediaQuery.textScalerOf(context).scale(18) * 1.5 + 16)
              .clamp(48.0, double.infinity),
          value: choices.containsKey(value) ? value : 'inherit',
          items: [
            for (final item in choices.entries)
              DropdownMenuItem(
                value: item.key,
                child: Text(
                  item.value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged == null
              ? null
              : (value) {
                  if (value != null) onChanged!(value);
                },
        ),
      ],
    ),
  );
}
