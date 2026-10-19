// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/archive/archive.dart';
import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ArchiveView extends StatelessWidget {
  final ArchiveController controller;

  const ArchiveView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ArchivedRoom>>(
      future: controller.getArchive(context),
      builder: (BuildContext context, snapshot) => Scaffold(
        appBar: AppBar(
          leading: const Center(child: BackButton()),
          title: Text(L10n.of(context).archive),
          actions: [
            if (snapshot.data?.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.all(NotionSpace.xs),
                child: NotionPop(
                  bounce: false,
                  child: TextButton.icon(
                    onPressed: controller.forgetAllAction,
                    label: Text(L10n.of(context).clearArchive),
                    icon: const Icon(Icons.cleaning_services_outlined),
                  ),
                ),
              ),
          ],
        ),
        body: MaxWidthBody(
          withScrolling: false,
          // Loading skeleton → archive (or its empty state) fade through;
          // the first screenful of rooms rises in.
          child: NotionFadeThrough(
            child: snapshot.hasError
                ? Center(
                    key: const ValueKey('error'),
                    child: Text(
                      L10n.of(context).oopsSomethingWentWrong,
                      textAlign: TextAlign.center,
                    ),
                  )
                : !snapshot.hasData
                ? NotionSkeleton(
                    key: const ValueKey('loading'),
                    child: ListView(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: NotionSpace.md,
                      ),
                      children: [
                        for (var i = 0; i < 8; i++) const NotionSkeletonRow(),
                      ],
                    ),
                  )
                : controller.archive.isEmpty
                ? NotionEmptyState(
                    key: const ValueKey('empty'),
                    icon: Icons.archive_outlined,
                    title: 'No archived chats',
                  )
                : NotionEntranceScope(
                    key: const ValueKey('rooms'),
                    child: ListView.builder(
                      itemCount: controller.archive.length,
                      itemBuilder: (BuildContext context, int i) =>
                          NotionEntrance(
                            playKey: controller.archive[i].room.id,
                            rise: NotionMotion.riseList,
                            child: ChatListItem(
                              controller.archive[i].room,
                              onForget: () => controller.forgetRoomAction(i),
                              onTap: () => context.go(
                                '/rooms/archive/${controller.archive[i].room.id}',
                                extra: controller.archive[i].timeline,
                              ),
                            ),
                          ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
