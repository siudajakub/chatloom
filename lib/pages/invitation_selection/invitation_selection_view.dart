// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/invitation_selection/invitation_selection.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/adaptive_dialogs/user_dialog.dart';

class InvitationSelectionView extends StatelessWidget {
  final InvitationSelectionController controller;

  const InvitationSelectionView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final room = Matrix.of(
      context,
    ).client.getRoomById(controller.widget.roomId);
    if (room == null) {
      return NotionScaffold(
        title: L10n.of(context).inviteContact,
        onBack: () => Navigator.of(context).maybePop(),
        body: NotionEmptyState(
          icon: Icons.group_off_outlined,
          title: L10n.of(context).youAreNoLongerParticipatingInThisChat,
        ),
      );
    }

    final groupName = room.name.isEmpty ? L10n.of(context).group : room.name;
    return NotionScaffold(
      title: L10n.of(context).inviteContact,
      onBack: () => Navigator.of(context).maybePop(),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: NotionSpace.sm),
          child: NotionTextField(
            textInputAction: TextInputAction.search,
            hint: L10n.of(context).inviteContactToGroup(groupName),
            prefixIcon: Icons.search_outlined,
            // The lookup's progress sits at the end of the field.
            suffix: NotionMorphSwitcher(
              rotate: false,
              child: controller.loading
                  ? const SizedBox.square(
                      key: ValueKey('busy'),
                      dimension: NotionSize.touchTarget,
                      child: Center(child: NotionDelayedSpinner()),
                    )
                  : const SizedBox.shrink(key: ValueKey('idle')),
            ),
            onChanged: controller.searchUserWithCoolDown,
          ),
        ),
        Column(
          children: [
            StreamBuilder<Object>(
              stream: room.client.onRoomState.stream.where(
                (update) => update.roomId == room.id,
              ),
              builder: (context, snapshot) {
                final participants = room
                    .getParticipants()
                    .map((user) => user.id)
                    .toSet();
                // Contacts ↔ search results fade through; rows rise in once.
                return NotionFadeThrough(
                  child: controller.foundProfiles.isNotEmpty
                      ? NotionEntranceScope(
                          key: ValueKey(controller.foundProfiles),
                          child: ListView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            itemCount: controller.foundProfiles.length,
                            itemBuilder: (BuildContext context, int i) =>
                                _FirstScreenEntrance(
                                  index: i,
                                  playKey: controller.foundProfiles[i].userId,
                                  rise: NotionMotion.riseList,
                                  child: _InviteContactListTile(
                                    profile: controller.foundProfiles[i],
                                    isMember: participants.contains(
                                      controller.foundProfiles[i].userId,
                                    ),
                                    onTap: () => controller.inviteAction(
                                      context,
                                      controller.foundProfiles[i].userId,
                                      controller.foundProfiles[i].displayName ??
                                          controller
                                              .foundProfiles[i]
                                              .userId
                                              .localpart ??
                                          L10n.of(context).user,
                                    ),
                                  ),
                                ),
                          ),
                        )
                      : FutureBuilder<List<User>>(
                          key: const ValueKey('contacts'),
                          future: controller.getContacts(context),
                          builder: (BuildContext context, snapshot) {
                            if (!snapshot.hasData) {
                              return NotionSkeleton(
                                child: Column(
                                  children: [
                                    for (var i = 0; i < 6; i++)
                                      const NotionSkeletonRow(),
                                  ],
                                ),
                              );
                            }
                            final contacts = snapshot.data!;
                            return NotionEntranceScope(
                              child: ListView.builder(
                                physics: const NeverScrollableScrollPhysics(),
                                shrinkWrap: true,
                                itemCount: contacts.length,
                                itemBuilder: (BuildContext context, int i) =>
                                    _FirstScreenEntrance(
                                      index: i,
                                      playKey: contacts[i].id,
                                      rise: NotionMotion.riseList,
                                      child: _InviteContactListTile(
                                        user: contacts[i],
                                        profile: Profile(
                                          avatarUrl: contacts[i].avatarUrl,
                                          displayName:
                                              contacts[i].displayName ??
                                              contacts[i].id.localpart ??
                                              L10n.of(context).user,
                                          userId: contacts[i].id,
                                        ),
                                        isMember: participants.contains(
                                          contacts[i].id,
                                        ),
                                        onTap: () => controller.inviteAction(
                                          context,
                                          contacts[i].id,
                                          contacts[i].displayName ??
                                              contacts[i].id.localpart ??
                                              L10n.of(context).user,
                                        ),
                                      ),
                                    ),
                              ),
                            );
                          },
                        ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _InviteContactListTile extends StatelessWidget {
  final Profile profile;
  final User? user;
  final bool isMember;
  final void Function() onTap;

  const _InviteContactListTile({
    required this.profile,
    this.user,
    required this.isMember,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final name = profile.displayName ?? profile.userId.localpart ?? l10n.user;
    return NotionListRow(
      leading: Avatar(
        mxContent: profile.avatarUrl,
        name: profile.displayName,
        presenceUserId: profile.userId,
        onTap: () => UserDialog.show(context: context, profile: profile),
      ),
      title: name,
      subtitle: profile.userId,
      // Invite → participant morphs once the invite lands.
      trailing: NotionButton(
        variant: isMember
            ? NotionButtonVariant.ghost
            : NotionButtonVariant.secondary,
        label: isMember ? l10n.participant : l10n.invite,
        onPressed: isMember ? null : onTap,
      ),
    );
  }
}

/// Rises in with the first screenful only: these lists are shrink-wrapped,
/// so every row is built up front and later rows must stay still.
class _FirstScreenEntrance extends StatelessWidget {
  final int index;
  final Object playKey;
  final double rise;
  final Widget child;
  const _FirstScreenEntrance({
    required this.index,
    required this.playKey,
    required this.rise,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => index < NotionMotion.staggerCap
      ? NotionEntrance(playKey: playKey, rise: rise, child: child)
      : child;
}
