// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:material_ui/material_ui.dart';

import '../../widgets/matrix.dart';
import 'settings_ignore_list.dart';

class SettingsIgnoreListView extends StatelessWidget {
  final SettingsIgnoreListController controller;

  const SettingsIgnoreListView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final tokens = context.notion;
    return NotionSettingsScaffold(
      title: L10n.of(context).blockedUsers,
      // Opened from Security (or a chat), also in the two-column layout.
      showBack: true,
      withScrolling: false,
      child: StreamBuilder(
        stream: client.onSync.stream.where(
          (syncUpdate) =>
              syncUpdate.accountData?.any(
                (accountData) => accountData.type == 'm.ignored_user_list',
              ) ??
              false,
        ),
        builder: (context, asyncSnapshot) {
          if (client.prevBatch == null) {
            return const Center(child: NotionDelayedSpinner());
          }
          final ignored = client.ignoredUsers;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: NotionSpace.xxs),
                child: Text(
                  L10n.of(context).blockUsername,
                  style: tokens.typography.sectionLabel,
                ),
              ),
              TextField(
                controller: controller.controller,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => controller.ignoreUser(context),
                style: tokens.typography.callout,
                decoration: InputDecoration(
                  errorText: controller.errorText,
                  hintText: '@bad_guy:domain.abc',
                  suffixIcon: NotionIconButton(
                    label: L10n.of(context).block,
                    icon: Icons.add,
                    onPressed: () => controller.ignoreUser(context),
                  ),
                ),
              ),
              const SizedBox(height: NotionSpace.sm),
              Text(
                L10n.of(context).blockListDescription,
                style: tokens.typography.footnoteMuted,
              ),
              const SizedBox(height: NotionSpace.md),
              const Divider(height: 1),
              Expanded(
                child: ignored.isEmpty
                    ? const NotionEmptyState(
                        icon: Icons.block_outlined,
                        title: 'No blocked users',
                      )
                    : ListView.builder(
                        itemCount: ignored.length,
                        itemBuilder: (c, i) => NotionListRow(
                          title: ignored[i],
                          trailing: NotionIconButton(
                            label: L10n.of(context).delete,
                            icon: Icons.delete_outlined,
                            onPressed: () => showFutureLoadingDialog(
                              context: context,
                              future: () => client.unignoreUser(ignored[i]),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
