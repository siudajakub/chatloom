// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Read receipts under the newest message. The row grows in when the first
/// receipt arrives (a new newest message starts collapsed without
/// animating its predecessor's row away), and avatars of readers who join
/// later pop in.
class SeenByRow extends StatelessWidget {
  final Event event;
  const SeenByRow({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    const maxAvatars = 7;
    return StreamBuilder(
      stream: event.room.client.onSync.stream.where(
        (syncUpdate) =>
            syncUpdate.rooms?.join?[event.room.id]?.ephemeral?.any(
              (ephemeral) => ephemeral.type == 'm.receipt',
            ) ??
            false,
      ),
      builder: (context, asyncSnapshot) {
        final seenByUsers = event.receipts
            .map((r) => r.user)
            .where(
              (user) =>
                  user.id != event.room.client.userID &&
                  user.id != event.senderId,
            )
            .toList();
        final own = event.senderId == Matrix.of(context).client.userID;
        return Container(
          width: double.infinity,
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: FluffyThemes.maxTimelineWidth,
            ),
            child: NotionSizeReveal(
              // Per message: the next newest message starts collapsed.
              key: ValueKey(event.eventId),
              visible: seenByUsers.isNotEmpty,
              alignment: own ? Alignment.topRight : Alignment.topLeft,
              child: Align(
                alignment: own ? Alignment.topRight : Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(
                    bottom: NotionSpace.xxs,
                    top: 1,
                    left: NotionSpace.xs,
                    right: NotionSpace.xs,
                  ),
                  child: SizedBox(
                    height: 19,
                    child: _SeenAvatars(
                      users: seenByUsers.length > maxAvatars
                          ? seenByUsers.sublist(0, maxAvatars)
                          : seenByUsers,
                      more: seenByUsers.length > maxAvatars
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: Material(
                                color: theme.colorScheme.surface,
                                borderRadius: BorderRadius.circular(32),
                                child: Center(
                                  child: Text(
                                    '+${seenByUsers.length - maxAvatars}',
                                    style: const TextStyle(fontSize: 9),
                                  ),
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SeenAvatars extends StatefulWidget {
  final List<User> users;
  final Widget? more;
  const _SeenAvatars({required this.users, this.more});

  @override
  State<_SeenAvatars> createState() => _SeenAvatarsState();
}

class _SeenAvatarsState extends State<_SeenAvatars> {
  /// Readers present at first build appear still; later ones pop.
  late final Set<String> _initial = {for (final u in widget.users) u.id};

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    children: [
      for (final user in widget.users)
        NotionPop(
          key: ValueKey(user.id),
          playOnMount: !_initial.contains(user.id),
          child: Avatar(
            client: user.room.client,
            mxContent: user.avatarUrl,
            name: user.calcDisplayname(),
            size: 16,
          ),
        ),
      ?widget.more,
    ],
  );
}
