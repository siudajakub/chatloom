// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'contracts.dart';
import 'network_preferences.dart';

class PersonalLabel {
  final String id;
  final String name;
  final String? icon;
  final int? color;
  final bool showInInbox;
  final int revision;
  PersonalLabel({
    required this.id,
    required this.name,
    this.icon,
    this.color,
    this.showInInbox = true,
    this.revision = 0,
  }) {
    if (id.isEmpty || name.trim().isEmpty || revision < 0) {
      throw ArgumentError('Invalid label');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'color': color,
    'showInInbox': showInInbox,
    'revision': revision,
  };
  factory PersonalLabel.fromJson(Map<String, dynamic> j) => PersonalLabel(
    id: j['id'] as String,
    name: j['name'] as String,
    icon: j['icon'] as String?,
    color: j['color'] as int?,
    showInInbox: j['showInInbox'] as bool? ?? true,
    revision: j['revision'] as int? ?? 0,
  );
  @override
  String toString() => 'PersonalLabel(redacted)';
}

/// These overrides are private presentation metadata, not network room state.
class ChatTheme {
  final int? backgroundColor;
  final int? incomingColor;
  final int? outgoingColor;
  final String? wallpaperAsset;
  const ChatTheme({
    this.backgroundColor,
    this.incomingColor,
    this.outgoingColor,
    this.wallpaperAsset,
  });
  Map<String, Object?> toJson() => {
    'backgroundColor': backgroundColor,
    'incomingColor': incomingColor,
    'outgoingColor': outgoingColor,
    'wallpaperAsset': wallpaperAsset,
  };
  factory ChatTheme.fromJson(Map<String, dynamic> j) => ChatTheme(
    backgroundColor: j['backgroundColor'] as int?,
    incomingColor: j['incomingColor'] as int?,
    outgoingColor: j['outgoingColor'] as int?,
    wallpaperAsset: j['wallpaperAsset'] as String?,
  );
  @override
  String toString() => 'ChatTheme(redacted)';
}

class ConversationMetadata {
  final String entityId;
  final Set<String> labelIds;
  final int? pinOrder;
  final bool archived;
  final bool lowPriority;
  final bool muted;
  final bool ignored;
  final ChatPlacement? placement;
  final PersonalNotificationMode? notificationMode;
  final String? nickname;
  final String? avatarAsset;
  final ChatTheme? theme;
  final int revision;
  ConversationMetadata({
    required this.entityId,
    Iterable<String> labelIds = const [],
    this.pinOrder,
    this.archived = false,
    this.lowPriority = false,
    this.muted = false,
    this.ignored = false,
    this.placement,
    this.notificationMode,
    this.nickname,
    this.avatarAsset,
    this.theme,
    this.revision = 0,
  }) : labelIds = Set.unmodifiable(labelIds) {
    if (entityId.isEmpty ||
        revision < 0 ||
        (pinOrder != null && pinOrder! < 0)) {
      throw ArgumentError('Invalid conversation metadata');
    }
    if (this.labelIds.any((id) => id.isEmpty)) {
      throw ArgumentError('Invalid label membership');
    }
  }

  bool get isPinned => pinOrder != null;
  bool visibleInInbox(Iterable<PersonalLabel> labels) =>
      !archived &&
      !ignored &&
      (placement == null || placement == ChatPlacement.inbox) &&
      !lowPriority &&
      !labels.any((l) => labelIds.contains(l.id) && !l.showInInbox);

  /// Low Priority and mute allow only an explicit mention or a thread reply.
  bool shouldNotify({bool mentioned = false, bool threadReplyToMe = false}) =>
      !ignored &&
      placement != ChatPlacement.ignored &&
      notificationMode != PersonalNotificationMode.muted &&
      ((notificationMode == PersonalNotificationMode.all ||
              (notificationMode == null && !(muted || lowPriority))) ||
          mentioned ||
          threadReplyToMe);

  ConversationMetadata withLabel(String id, {bool add = true}) {
    if (id.isEmpty) throw ArgumentError('Invalid label');
    final updated = labelIds.toSet();
    add ? updated.add(id) : updated.remove(id);
    return _copy(labelIds: updated);
  }

  /// Deleting a label only removes its membership; messages remain untouched.
  ConversationMetadata withoutDeletedLabel(String id) =>
      labelIds.contains(id) ? withLabel(id, add: false) : this;

  ConversationMetadata onActivity() => archived ? _copy(archived: false) : this;
  ConversationMetadata setArchived(bool value) => _copy(archived: value);
  ConversationMetadata setLowPriority(bool value) => _copy(lowPriority: value);
  ConversationMetadata setMuted(bool value) => _copy(muted: value);
  ConversationMetadata setIgnored(bool value) => _copy(ignored: value);
  ConversationMetadata restoreIgnored({bool inheritedIgnored = false}) {
    final restored = setIgnored(false);
    return placement == ChatPlacement.ignored ||
            (placement == null && inheritedIgnored)
        ? restored.setPlacement(ChatPlacement.inbox)
        : restored;
  }

  ConversationMetadata setPlacement(ChatPlacement? value) =>
      _copy(placement: () => value);
  ConversationMetadata setNotificationMode(PersonalNotificationMode? value) =>
      _copy(notificationMode: () => value);
  ConversationMetadata setPin(int? order) => _copy(pinOrder: () => order);
  ConversationMetadata setNickname(String? value) =>
      _copy(nickname: () => value?.trim());
  ConversationMetadata setAvatar(String? asset) =>
      _copy(avatarAsset: () => asset);
  ConversationMetadata setTheme(ChatTheme? value) => _copy(theme: () => value);

  ConversationMetadata _copy({
    Iterable<String>? labelIds,
    int? Function()? pinOrder,
    bool? archived,
    bool? lowPriority,
    bool? muted,
    bool? ignored,
    ChatPlacement? Function()? placement,
    PersonalNotificationMode? Function()? notificationMode,
    String? Function()? nickname,
    String? Function()? avatarAsset,
    ChatTheme? Function()? theme,
  }) => ConversationMetadata(
    entityId: entityId,
    labelIds: labelIds ?? this.labelIds,
    pinOrder: pinOrder == null ? this.pinOrder : pinOrder(),
    archived: archived ?? this.archived,
    lowPriority: lowPriority ?? this.lowPriority,
    muted: muted ?? this.muted,
    ignored: ignored ?? this.ignored,
    placement: placement == null ? this.placement : placement(),
    notificationMode: notificationMode == null
        ? this.notificationMode
        : notificationMode(),
    nickname: nickname == null ? this.nickname : nickname(),
    avatarAsset: avatarAsset == null ? this.avatarAsset : avatarAsset(),
    theme: theme == null ? this.theme : theme(),
    revision: revision + 1,
  );
  Map<String, Object?> toJson() => {
    'entityId': entityId,
    'labelIds': labelIds.toList()..sort(),
    'pinOrder': pinOrder,
    'archived': archived,
    'lowPriority': lowPriority,
    'muted': muted,
    'ignored': ignored,
    'placement': placement?.name,
    'notificationMode': notificationMode?.name,
    'nickname': nickname,
    'avatarAsset': avatarAsset,
    'theme': theme?.toJson(),
    'revision': revision,
  };
  factory ConversationMetadata.fromJson(Map<String, dynamic> j) =>
      ConversationMetadata(
        entityId: j['entityId'] as String,
        labelIds: (j['labelIds'] as List? ?? const []).cast<String>(),
        pinOrder: j['pinOrder'] as int?,
        archived: j['archived'] as bool? ?? false,
        lowPriority: j['lowPriority'] as bool? ?? false,
        muted: j['muted'] as bool? ?? false,
        ignored: j['ignored'] as bool? ?? false,
        placement: preferenceEnum(ChatPlacement.values, j['placement']),
        notificationMode: preferenceEnum(
          PersonalNotificationMode.values,
          j['notificationMode'],
        ),
        nickname: j['nickname'] as String?,
        avatarAsset: j['avatarAsset'] as String?,
        theme: j['theme'] == null
            ? null
            : ChatTheme.fromJson(Map<String, dynamic>.from(j['theme'] as Map)),
        revision: j['revision'] as int? ?? 0,
      );
  @override
  String toString() => 'ConversationMetadata(redacted, revision: $revision)';
}

class BookmarkRef {
  final SourceEventRef source;
  final DateTime createdAt;
  const BookmarkRef({required this.source, required this.createdAt});
  String get key => source.key;
  Map<String, Object?> toJson() => {
    'source': source.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
  factory BookmarkRef.fromJson(Map<String, dynamic> j) => BookmarkRef(
    source: SourceEventRef.fromJson(
      Map<String, dynamic>.from(j['source'] as Map),
    ),
    createdAt: DateTime.parse(j['createdAt'] as String),
  );
  @override
  String toString() => 'BookmarkRef(redacted)';
}

class TextDraft {
  final ConversationRef conversation;
  final String operationId;
  final int baseRevision;
  final Set<String> parentOperationIds;
  final String text;
  final DateTime updatedAt;
  TextDraft({
    required this.conversation,
    required this.operationId,
    required this.text,
    required this.updatedAt,
    this.baseRevision = 0,
    Iterable<String> parentOperationIds = const [],
  }) : parentOperationIds = Set.unmodifiable(parentOperationIds) {
    if (operationId.isEmpty ||
        baseRevision < 0 ||
        this.parentOperationIds.contains(operationId) ||
        this.parentOperationIds.any((id) => id.isEmpty) ||
        ((baseRevision == 0) != this.parentOperationIds.isEmpty)) {
      throw ArgumentError('Invalid text draft');
    }
  }
  int get revision => baseRevision + 1;
  Map<String, Object?> toJson() => {
    'conversation': conversation.toJson(),
    'operationId': operationId,
    'baseRevision': baseRevision,
    'parentOperationIds': parentOperationIds.toList()..sort(),
    'text': text,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
  factory TextDraft.fromJson(Map<String, dynamic> j) => TextDraft(
    conversation: ConversationRef.fromJson(
      Map<String, dynamic>.from(j['conversation'] as Map),
    ),
    operationId: j['operationId'] as String,
    baseRevision: j['baseRevision'] as int? ?? 0,
    parentOperationIds: (j['parentOperationIds'] as List? ?? const [])
        .cast<String>(),
    text: j['text'] as String,
    updatedAt: DateTime.parse(j['updatedAt'] as String),
  );
  @override
  String toString() => 'TextDraft(redacted, revision: $revision)';
}

enum DraftApplyResult { accepted, duplicate, conflict }

/// A conservative text draft reducer: concurrent edits/deletes retain all
/// branches. A timestamp cannot silently select a winning draft.
class RevisionedDraftStore {
  final Map<String, TextDraft> _operations = {};
  final Map<String, String> _seen = {};

  List<TextDraft> operationsFor(ConversationRef conversation) =>
      List.unmodifiable(
        _operations.values.where((d) => d.conversation == conversation).toList()
          ..sort((a, b) => a.operationId.compareTo(b.operationId)),
      );
  List<TextDraft> branchesFor(ConversationRef conversation) {
    final operations = operationsFor(conversation);
    final superseded = operations.expand((d) => d.parentOperationIds).toSet();
    return List.unmodifiable(
      operations.where((d) => !superseded.contains(d.operationId)),
    );
  }

  bool hasConflict(ConversationRef conversation) {
    final branches = branchesFor(conversation);
    return branches.length > 1 ||
        operationsFor(conversation).any(
          (d) => d.parentOperationIds.any(
            (parent) => !_operations.containsKey(parent),
          ),
        );
  }

  bool hasDraft(ConversationRef conversation) =>
      branchesFor(conversation).any((branch) => branch.text.isNotEmpty);

  DraftApplyResult apply(TextDraft incoming) {
    if (_alreadySeen(incoming)) return DraftApplyResult.duplicate;
    // Integer revisions alone cannot prove ancestry: explicit parent IDs keep
    // edits from two devices with the same revision from deleting one another.
    for (final draft in [..._operations.values, incoming]) {
      final parents = draft.parentOperationIds
          .map((id) => id == incoming.operationId ? incoming : _operations[id])
          .toList();
      if (parents.whereType<TextDraft>().any(
        (parent) =>
            parent.conversation != draft.conversation ||
            parent.revision >= draft.revision,
      )) {
        throw StateError('Invalid draft ancestry');
      }
      if (parents.isNotEmpty && parents.every((p) => p != null)) {
        final expected = parents
            .whereType<TextDraft>()
            .map((p) => p.revision)
            .reduce((a, b) => a > b ? a : b);
        if (draft.baseRevision != expected) {
          throw StateError('Invalid draft base revision');
        }
      }
    }
    _operations[incoming.operationId] = incoming;
    _seen[incoming.operationId] = jsonEncode(incoming.toJson());
    return hasConflict(incoming.conversation)
        ? DraftApplyResult.conflict
        : DraftApplyResult.accepted;
  }

  TextDraft resolve({
    required ConversationRef conversation,
    required Set<String> expectedBranchIds,
    required String selectedBranchId,
    required String operationId,
    required DateTime updatedAt,
    String? mergedText,
  }) {
    final current = branchesFor(conversation);
    final ids = current.map((d) => d.operationId).toSet();
    if (current.isEmpty ||
        ids.length != expectedBranchIds.length ||
        !ids.containsAll(expectedBranchIds)) {
      throw StateError('Draft changed while resolving; review all branches');
    }
    final selected = current.firstWhere(
      (d) => d.operationId == selectedBranchId,
      orElse: () => throw ArgumentError('Unknown draft branch'),
    );
    final maxRevision = current
        .map((d) => d.revision)
        .reduce((a, b) => a > b ? a : b);
    final resolved = TextDraft(
      conversation: conversation,
      operationId: operationId,
      baseRevision: maxRevision,
      parentOperationIds: ids,
      text: mergedText ?? selected.text,
      updatedAt: updatedAt,
    );
    if (_seen.containsKey(operationId)) {
      throw StateError('Resolution operation must be new');
    }
    apply(resolved);
    return resolved;
  }

  bool _alreadySeen(TextDraft incoming) {
    final fingerprint = _seen[incoming.operationId];
    if (fingerprint == null) return false;
    if (fingerprint != jsonEncode(incoming.toJson())) {
      throw StateError('Operation ID reused with different draft data');
    }
    return true;
  }
}

enum ReminderState { scheduled, due, dismissed, cancelled }

class ChatReminder {
  final String id;
  final String entityId;
  final DateTime dueAt;
  final bool dismissOnIncomingMessage;
  final bool archiveUntilDue;
  final ReminderState state;
  const ChatReminder({
    required this.id,
    required this.entityId,
    required this.dueAt,
    this.dismissOnIncomingMessage = true,
    this.archiveUntilDue = true,
    this.state = ReminderState.scheduled,
  });
  bool dueAtTime(DateTime now) =>
      state == ReminderState.scheduled && !dueAt.isAfter(now);
  ChatReminder evaluate(DateTime now) =>
      dueAtTime(now) ? _state(ReminderState.due) : this;

  /// Call only for a new live incoming event, never for backfilled history.
  ChatReminder onIncoming() =>
      dismissOnIncomingMessage && state == ReminderState.scheduled
      ? _state(ReminderState.dismissed)
      : this;
  ChatReminder cancel() =>
      state == ReminderState.scheduled || state == ReminderState.due
      ? _state(ReminderState.cancelled)
      : this;
  ChatReminder dismiss() => _state(ReminderState.dismissed);
  ChatReminder _state(ReminderState value) => ChatReminder(
    id: id,
    entityId: entityId,
    dueAt: dueAt,
    dismissOnIncomingMessage: dismissOnIncomingMessage,
    archiveUntilDue: archiveUntilDue,
    state: value,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'entityId': entityId,
    'dueAt': dueAt.toUtc().toIso8601String(),
    'dismissOnIncomingMessage': dismissOnIncomingMessage,
    'archiveUntilDue': archiveUntilDue,
    'state': state.name,
  };
  factory ChatReminder.fromJson(Map<String, dynamic> j) => ChatReminder(
    id: j['id'] as String,
    entityId: j['entityId'] as String,
    dueAt: DateTime.parse(j['dueAt'] as String),
    dismissOnIncomingMessage: j['dismissOnIncomingMessage'] as bool? ?? true,
    archiveUntilDue: j['archiveUntilDue'] as bool? ?? true,
    state: ReminderState.values.byName(
      j['state'] as String? ?? ReminderState.scheduled.name,
    ),
  );
  @override
  String toString() => 'ChatReminder(${state.name}, redacted)';
}
