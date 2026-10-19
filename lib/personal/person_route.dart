// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/merged_chat_page.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

export 'person_location.dart';

/// Page of `/rooms/person/:groupId`: resolves the group from the private
/// store of the active account and renders the merged conversation.
class PersonChatRoutePage extends StatefulWidget {
  final String groupId;
  final String? sourceRoomId;
  final String? eventId;

  const PersonChatRoutePage({
    super.key,
    required this.groupId,
    this.sourceRoomId,
    this.eventId,
  });

  @override
  State<PersonChatRoutePage> createState() => _PersonChatRoutePageState();
}

class _PersonChatRoutePageState extends State<PersonChatRoutePage> {
  PersonalClient? _personal;
  bool _loaded = false;
  bool _redirected = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final personal = PersonalClient.of(Matrix.of(context).client);
    if (identical(personal, _personal)) return;
    _personal?.removeListener(_changed);
    _personal = personal..addListener(_changed);
    _loaded = false;
    final generation = ++_generation;
    unawaited(
      personal.loadLocal().catchError((Object _) {}).whenComplete(() {
        if (!mounted || generation != _generation) return;
        setState(() => _loaded = true);
      }),
    );
  }

  @override
  void dispose() {
    _personal?.removeListener(_changed);
    super.dispose();
  }

  /// Rebuild only when this group appears, changes or disappears.
  PersonGroup? _lastGroup;
  void _changed() {
    if (!mounted) return;
    final group = _resolve();
    if (!identical(group, _lastGroup)) setState(() {});
  }

  PersonGroup? _resolve() {
    final personal = _personal;
    if (personal == null) return null;
    final valid = InboxProjection(personal).groupById(widget.groupId);
    if (valid != null) return valid;
    // A group with a member that is currently unavailable still opens; the
    // merged page lists that source as unavailable and retryable.
    return personal.groups.firstWhereOrNull((g) => g.id == widget.groupId);
  }

  @override
  Widget build(BuildContext context) {
    final personal = _personal!;
    final group = _lastGroup = _resolve();
    if (group != null) {
      return MergedChatPage(
        personal: personal,
        group: group,
        initialSourceRoomId: widget.sourceRoomId,
        initialEventId: widget.eventId,
      );
    }
    if (!_loaded) {
      // Local groups usually load within a frame or two: no spinner flash.
      return const Scaffold(
        body: Center(child: NotionDelayedSpinner(size: NotionSize.touchTarget)),
      );
    }
    final source = widget.sourceRoomId;
    if (source != null &&
        personal.client.getRoomById(source) != null &&
        !_redirected) {
      _redirected = true;
      final event = widget.eventId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go(
          Uri(
            path: '/rooms/$source',
            queryParameters: event == null ? null : {'event': event},
          ).toString(),
        );
      });
    }
    return NotionScaffold(
      title: 'Conversation',
      onBack: () => Navigator.maybePop(context),
      body: NotionEmptyState(
        icon: Icons.people_outline,
        title: 'This merged conversation is not available',
        message:
            'It may have been unmerged or belong to another account. The source chats are still in the inbox.',
        action: NotionButton(
          label: 'Back to chats',
          onPressed: () => context.go('/rooms'),
        ),
      ),
    );
  }
}
