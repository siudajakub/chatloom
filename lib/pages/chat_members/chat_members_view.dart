// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/ui/contact_sheet.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/matrix.dart';
import '../chat_details/participant_list_item.dart';
import 'chat_members.dart';

/// Participants of a chat, Notion style (UI-06): a search field and
/// membership pills over the member rows; the bridge bot is not a person
/// and is left out (FX-05).
class ChatMembersView extends StatelessWidget {
  final ChatMembersController controller;

  const ChatMembersView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final room = Matrix.of(
      context,
    ).client.getRoomById(controller.widget.roomId);
    if (room == null) {
      return NotionScaffold(
        onBack: () => Navigator.of(context).maybePop(),
        body: NotionEmptyState(
          icon: Icons.people_outline,
          title: l10n.oopsSomethingWentWrong,
          message: l10n.youAreNoLongerParticipatingInThisChat,
        ),
      );
    }

    final members = controller.filteredMembers
        ?.where((member) => !isBridgeBotMember(room, member.id))
        .toList();
    final everyone = controller.members
        ?.where((member) => !isBridgeBotMember(room, member.id))
        .toList();

    final roomCount =
        (room.summary.mJoinedMemberCount ?? 0) +
        (room.summary.mInvitedMemberCount ?? 0);

    final error = controller.error;

    return NotionScaffold(
      title: l10n.countParticipants(roomCount),
      onBack: () => Navigator.of(context).maybePop(),
      actions: [
        if (room.canInvite)
          NotionIconButton(
            icon: Icons.person_add_outlined,
            label: l10n.invite,
            onPressed: () => context.go('/rooms/${room.id}/invite'),
          ),
      ],
      body: error != null
          ? NotionEmptyState(
              icon: Icons.error_outline,
              title: error.toLocalizedString(context),
              action: NotionButton(
                label: l10n.tryAgain,
                icon: Icons.refresh_outlined,
                onPressed: controller.refreshMembers,
              ),
            )
          : members == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(NotionSpace.md),
                child: NotionDelayedSpinner(),
              ),
            )
          // The first screenful of members rises in once; rows built by
          // scrolling or filtering appear without animation.
          : NotionEntranceScope(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                  NotionSpace.inset,
                  NotionSpace.xs,
                  NotionSpace.inset,
                  NotionSpace.xxl,
                ),
                itemCount: members.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return NotionEntrance(
                      playKey: 'filters',
                      afterRoute: false,
                      rise: NotionMotion.riseList,
                      child: _Filters(
                        controller: controller,
                        room: room,
                        members: everyone ?? const [],
                      ),
                    );
                  }
                  i--;
                  return NotionEntrance(
                    playKey: members[i].id,
                    afterRoute: false,
                    rise: NotionMotion.riseList,
                    child: ParticipantListItem(members[i]),
                  );
                },
              ),
            ),
    );
  }
}

class _Filters extends StatelessWidget {
  final ChatMembersController controller;
  final Room room;
  final List<User> members;
  const _Filters({
    required this.controller,
    required this.room,
    required this.members,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final available =
        Membership.values
            .where((value) => members.any((m) => m.membership == value))
            .toList()
          ..sort((a, b) => a == Membership.join ? -1 : 1);
    int count(Membership value) =>
        members.where((member) => member.membership == value).length;
    String label(Membership value) => switch (value) {
      Membership.ban => l10n.banned,
      Membership.invite => l10n.countInvited(
        room.summary.mInvitedMemberCount ?? count(Membership.invite),
      ),
      Membership.join => l10n.countParticipants(count(Membership.join)),
      Membership.knock => l10n.knocking,
      Membership.leave => l10n.leftTheChat,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: NotionSpace.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NotionTextField(
            controller: controller.filterController,
            onChanged: controller.setFilter,
            hint: l10n.search,
            prefixIcon: Icons.search_outlined,
          ),
          if (available.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: NotionSpace.sm),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (index, value) in available.indexed) ...[
                      if (index > 0) const SizedBox(width: NotionSpace.xs),
                      NotionGlassPill(
                        key: ValueKey('members-filter-${value.name}'),
                        label: label(value),
                        selected: controller.membershipFilter == value,
                        onPressed: () => controller.setMembershipFilter(value),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
