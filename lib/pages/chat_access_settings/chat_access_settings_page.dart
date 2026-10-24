// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_access_settings/chat_access_settings_controller.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' hide Visibility;
import 'package:matrix/matrix.dart';

/// Access & visibility, Notion style: glass header, section headers and
/// single-choice rows with a check (Telegram's group type / history pages).
/// Every option applies at once, as before.
class ChatAccessSettingsPageView extends StatelessWidget {
  final ChatAccessSettingsController controller;
  const ChatAccessSettingsPageView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final room = controller.room;
    return NotionScaffold(
      title: l10n.accessAndVisibility,
      onBack: () => Navigator.of(context).maybePop(),
      children: [
        StreamBuilder<Object>(
          stream: room.client.onRoomState.stream.where(
            (update) => update.roomId == controller.room.id,
          ),
          builder: (context, snapshot) {
            final canonicalAlias = room.canonicalAlias;
            final altAliases =
                room
                    .getState(EventTypes.RoomCanonicalAlias)
                    ?.content
                    .tryGetList<String>('alt_aliases') ??
                [];
            final canEditAliases = room.canChangeStateEvent(
              EventTypes.RoomCanonicalAlias,
            );
            final canHistory =
                !controller.historyVisibilityLoading &&
                room.canChangeHistoryVisibility;
            final canJoinRules =
                !controller.joinRulesLoading && room.canChangeJoinRules;
            final canGuests =
                !controller.guestAccessLoading && room.canChangeGuestAccess;
            return NotionSettingsBody.staggered(
              Column(
                mainAxisSize: .min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NotionSectionHeader(title: l10n.visibilityOfTheChatHistory),
                  Column(
                    mainAxisSize: .min,
                    children: [
                      for (final historyVisibility in HistoryVisibility.values)
                        NotionChoiceRow(
                          title: historyVisibility.getLocalizedString(
                            MatrixLocals(l10n),
                          ),
                          selected: room.historyVisibility == historyVisibility,
                          onTap: canHistory
                              ? () => controller.setHistoryVisibility(
                                  historyVisibility,
                                )
                              : null,
                        ),
                    ],
                  ),
                  NotionSectionHeader(title: l10n.whoIsAllowedToJoinThisGroup),
                  Column(
                    mainAxisSize: .min,
                    children: [
                      for (final joinRule in controller.availableJoinRules)
                        if (joinRule != JoinRules.private)
                          NotionChoiceRow(
                            title: joinRule.localizedString(
                              l10n,
                              controller.knownSpaceParents,
                            ),
                            selected: room.joinRules == joinRule,
                            onTap: canJoinRules
                                ? () => controller.setJoinRule(joinRule)
                                : null,
                          ),
                    ],
                  ),
                  // Guest access and addresses open only for joinable rooms.
                  NotionSizeReveal(
                    visible: {
                      JoinRules.public,
                      JoinRules.knock,
                    }.contains(room.joinRules),
                    child: Column(
                      mainAxisSize: .min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        NotionSectionHeader(title: l10n.areGuestsAllowedToJoin),
                        for (final guestAccess in GuestAccess.values)
                          NotionChoiceRow(
                            title: guestAccess.getLocalizedString(
                              MatrixLocals(l10n),
                            ),
                            selected: room.guestAccess == guestAccess,
                            onTap: canGuests
                                ? () => controller.setGuestAccess(guestAccess)
                                : null,
                          ),
                        NotionSectionHeader(
                          title: l10n.publicChatAddresses,
                          trailing: NotionIconButton(
                            icon: Icons.add_outlined,
                            label: l10n.createNewAddress,
                            onPressed: controller.addAlias,
                          ),
                        ),
                        if (canonicalAlias.isNotEmpty)
                          _AliasListTile(
                            alias: canonicalAlias,
                            onDelete: canEditAliases
                                ? () => controller.deleteAlias(canonicalAlias)
                                : null,
                            isCanonicalAlias: true,
                          ),
                        for (final alias in altAliases)
                          _AliasListTile(
                            alias: alias,
                            onDelete: canEditAliases
                                ? () => controller.deleteAlias(alias)
                                : null,
                          ),
                        FutureBuilder(
                          future: room.client.getLocalAliases(room.id),
                          builder: (context, snapshot) {
                            final localAddresses = snapshot.data;
                            if (localAddresses == null) {
                              return const SizedBox.shrink();
                            }
                            localAddresses.remove(room.canonicalAlias);
                            localAddresses.removeWhere(altAliases.contains);
                            return Column(
                              mainAxisSize: .min,
                              children: localAddresses
                                  .map(
                                    (alias) => _AliasListTile(
                                      alias: alias,
                                      published: false,
                                      onDelete: () =>
                                          controller.deleteAlias(alias),
                                    ),
                                  )
                                  .toList(),
                            );
                          },
                        ),
                        FutureBuilder(
                          future: room.client.getRoomVisibilityOnDirectory(
                            room.id,
                          ),
                          builder: (context, snapshot) => NotionSettingsToggle(
                            value: snapshot.data == Visibility.public,
                            title: l10n.chatCanBeDiscoveredViaSearchOnServer(
                              room.client.userID!.domain!,
                            ),
                            onChanged: controller.setChatVisibilityOnDirectory,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const NotionSectionHeader(title: 'Advanced'),
                  NotionListRow(
                    title: l10n.globalChatId,
                    subtitle: room.id,
                    trailing: NotionIconButton(
                      icon: Icons.copy_outlined,
                      label: 'Copy chat ID',
                      onPressed: () => _copy(context, room.id),
                    ),
                  ),
                  NotionListRow(
                    title: l10n.roomVersion,
                    subtitle:
                        room
                            .getState(EventTypes.RoomCreate)
                            ?.content
                            .tryGet<String>('room_version') ??
                        'Unknown',
                    trailing: room.canSendEvent(EventTypes.RoomTombstone)
                        ? NotionIconButton(
                            icon: Icons.upgrade_outlined,
                            label: l10n.replaceRoomWithNewerVersion,
                            onPressed: controller.updateRoomAction,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Copies [text] (an address or the chat ID) instead of opening the share
/// sheet, and confirms unless the system already does (Android 13+).
Future<void> _copy(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  await showCopiedNotice(context, L10n.of(context).copiedToClipboard);
}

class _AliasListTile extends StatelessWidget {
  const _AliasListTile({
    required this.alias,
    required this.onDelete,
    this.isCanonicalAlias = false,
    this.published = true,
  });

  final String alias;
  final void Function()? onDelete;
  final bool isCanonicalAlias;
  final bool published;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return NotionListRow(
      leading: Icon(
        isCanonicalAlias ? Icons.star_outline : Icons.link_outlined,
        size: NotionSize.icon,
      ),
      title: alias,
      subtitle: isCanonicalAlias
          ? 'Main address'
          : published
          ? null
          : 'Not published',
      onTap: () => _copy(context, 'https://matrix.to/#/$alias'),
      trailing: onDelete != null
          ? NotionIconButton(
              icon: Icons.delete_outlined,
              label: l10n.delete,
              onPressed: onDelete,
            )
          : const SizedBox.shrink(),
    );
  }
}

extension JoinRulesDisplayString on JoinRules {
  String localizedString(L10n l10n, Set<Room> spaceParents) {
    switch (this) {
      case JoinRules.public:
        return l10n.anyoneCanJoin;
      case JoinRules.invite:
        return l10n.invitedUsersOnly;
      case JoinRules.knock:
        return l10n.usersMustKnock;
      case JoinRules.private:
        return l10n.noOneCanJoin;
      case JoinRules.restricted:
        return l10n.spaceMemberOf(
          spaceParents
              .map((space) => space.getLocalizedDisplayname(MatrixLocals(l10n)))
              .join(', '),
        );
      case JoinRules.knockRestricted:
        return l10n.spaceMemberOfCanKnock(
          spaceParents
              .map((space) => space.getLocalizedDisplayname(MatrixLocals(l10n)))
              .join(', '),
        );
    }
  }
}
