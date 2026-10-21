// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/new_group/new_group.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/layouts/login_scaffold.dart';
import 'package:chatloom/widgets/layouts/max_width_body.dart';
import 'package:material_ui/material_ui.dart';

class NewGroupView extends StatelessWidget {
  final NewGroupController controller;

  const NewGroupView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final avatar = controller.avatar;
    final error = controller.error;
    return Scaffold(
      appBar: AppBar(
        leading: Center(
          child: BackButton(
            onPressed: controller.loading ? null : Navigator.of(context).pop,
          ),
        ),
        title: NotionFadeThrough(
          alignment: AlignmentDirectional.centerStart,
          child: Text(L10n.of(context).createGroup),
        ),
      ),
      body: MaxWidthBody(
        child: Column(
          mainAxisSize: .min,
          children: NotionEntrance.stagger(<Widget>[
            const SizedBox(height: 16),
            NotionPressable(
              scale: NotionMotion.pressIcon,
              enabled: !controller.loading,
              child: InkWell(
                borderRadius: BorderRadius.circular(90),
                onTap: controller.loading ? null : controller.selectPhoto,
                child: CircleAvatar(
                  radius: Avatar.defaultSize,
                  // The picked photo fades through the camera glyph.
                  child: NotionFadeThrough(
                    alignment: Alignment.center,
                    child: avatar == null
                        ? const Icon(
                            Icons.add_a_photo_outlined,
                            key: ValueKey('empty'),
                          )
                        : ClipRRect(
                            key: ObjectKey(avatar),
                            borderRadius: BorderRadius.circular(90),
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
            const SizedBox(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: TextField(
                autofocus: true,
                controller: controller.nameController,
                autocorrect: false,
                readOnly: controller.loading,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.people_outlined),
                  labelText: L10n.of(context).groupName,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(horizontal: 32),
              secondary: const Icon(Icons.public_outlined),
              title: Text(L10n.of(context).groupIsPublic),
              value: controller.publicGroup,
              onChanged: controller.loading ? null : controller.setPublicGroup,
            ),
            NotionSizeReveal(
              visible: controller.publicGroup,
              child: SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 32),
                secondary: const Icon(Icons.search_outlined),
                title: Text(L10n.of(context).groupCanBeFoundViaSearch),
                value: controller.groupCanBeFound,
                onChanged: controller.loading
                    ? null
                    : controller.setGroupCanBeFound,
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(horizontal: 32),
              secondary: Icon(
                Icons.lock_outlined,
                color: theme.colorScheme.onSurface,
              ),
              title: Text(
                L10n.of(context).enableEncryption,
                style: TextStyle(color: theme.colorScheme.onSurface),
              ),
              value: !controller.publicGroup,
              onChanged: null,
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity,
                child: NotionButton.primary(
                  expand: true,
                  busy: controller.loading,
                  onPressed: controller.submitAction,
                  label: L10n.of(context).createGroupAndInviteUsers,
                ),
              ),
            ),
            // A failure reveals and shakes once per new error.
            NotionSizeReveal(
              visible: error != null,
              child: ErrorShake(
                error: error,
                child: ListTile(
                  leading: Icon(
                    Icons.warning_outlined,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    error?.toLocalizedString(context) ?? '',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
