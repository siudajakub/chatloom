// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/new_group/new_group.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/layouts/login_scaffold.dart';
import 'package:material_ui/material_ui.dart';

class NewGroupView extends StatelessWidget {
  final NewGroupController controller;

  const NewGroupView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final avatar = controller.avatar;
    final error = controller.error;
    return NotionScaffold(
      title: l10n.createGroup,
      // No way back while the group is being created.
      onBack: controller.loading ? null : Navigator.of(context).pop,
      children: NotionEntrance.stagger(<Widget>[
        const SizedBox(height: NotionSpace.md),
        Center(
          child: NotionPressable(
            scale: NotionMotion.pressIcon,
            enabled: !controller.loading,
            child: Semantics(
              button: true,
              label: 'Choose a group photo',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: controller.loading ? null : controller.selectPhoto,
                child: CircleAvatar(
                  radius: Avatar.defaultSize,
                  backgroundColor: context.notion.colors.surface,
                  foregroundColor: context.notion.colors.textSecondary,
                  // The picked photo fades through the camera glyph.
                  child: NotionFadeThrough(
                    alignment: Alignment.center,
                    child: avatar == null
                        ? const Icon(
                            Icons.add_a_photo_outlined,
                            key: ValueKey('empty'),
                          )
                        : ClipOval(
                            key: ObjectKey(avatar),
                            child: Image.memory(
                              avatar,
                              width: Avatar.defaultSize * 2,
                              height: Avatar.defaultSize * 2,
                              fit: BoxFit.cover,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: NotionSpace.xl),
        NotionTextField(
          autofocus: true,
          controller: controller.nameController,
          autocorrect: false,
          readOnly: controller.loading,
          prefixIcon: Icons.people_outlined,
          label: l10n.groupName,
        ),
        const SizedBox(height: NotionSpace.md),
        NotionSettingsToggle(
          title: l10n.groupIsPublic,
          value: controller.publicGroup,
          onChanged: controller.loading ? null : controller.setPublicGroup,
        ),
        NotionSizeReveal(
          visible: controller.publicGroup,
          child: NotionSettingsToggle(
            title: l10n.groupCanBeFoundViaSearch,
            value: controller.groupCanBeFound,
            onChanged: controller.loading
                ? null
                : controller.setGroupCanBeFound,
          ),
        ),
        // Read-only: private groups are always encrypted.
        NotionSettingsToggle(
          title: l10n.enableEncryption,
          subtitle: controller.publicGroup
              ? 'Public groups are not encrypted'
              : 'Private groups are always encrypted',
          value: !controller.publicGroup,
          onChanged: null,
        ),
        const SizedBox(height: NotionSpace.md),
        NotionButton.primary(
          expand: true,
          busy: controller.loading,
          onPressed: controller.submitAction,
          label: l10n.createGroupAndInviteUsers,
        ),
        // A failure reveals and shakes once per new error.
        NotionSizeReveal(
          visible: error != null,
          child: Padding(
            padding: const EdgeInsets.only(top: NotionSpace.md),
            child: ErrorShake(
              error: error,
              child: NotionCallout(
                icon: Icons.error_outline,
                tone: NotionCalloutTone.danger,
                title: 'Couldn’t create the group',
                message: error?.toLocalizedString(context),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
