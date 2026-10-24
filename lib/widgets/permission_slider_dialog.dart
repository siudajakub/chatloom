// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/adaptive_dialogs/dialog_text_field.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_notion_adaptive_dialog.dart';
import 'package:material_ui/material_ui.dart';

Future<int?> showPermissionChooser(
  BuildContext context, {
  int currentLevel = 0,
  int maxLevel = 100,
}) async {
  final controller = TextEditingController(text: currentLevel.toString());
  final error = ValueNotifier(const DialogValidation());
  return await showNotionAdaptiveDialog<int>(
    context: context,
    builder: (context) {
      void submit() {
        final level = int.tryParse(controller.text.trim());
        if (level == null) {
          error.value = error.value.reject(L10n.of(context).pleaseEnterANumber);
          return;
        }
        if (level > maxLevel) {
          error.value = error.value.reject(L10n.of(context).noPermission);
          return;
        }
        Navigator.of(context).pop<int>(level);
      }

      return NotionDialog(
        title: L10n.of(context).chatPermissions,
        message: L10n.of(context).setPowerLevelDescription,
        content: DialogValidationFeedback(
          validation: error,
          builder: (context, errorText) => DialogTextField(
            controller: controller,
            hintText: currentLevel.toString(),
            keyboardType: TextInputType.number,
            labelText: L10n.of(context).custom,
            errorText: errorText,
            maxLines: 1,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          NotionButton.ghost(
            label: L10n.of(context).cancel,
            onPressed: () => Navigator.of(context).pop<int>(null),
          ),
          NotionButton.primary(
            label: L10n.of(context).setPowerLevel,
            onPressed: submit,
          ),
        ],
      );
    },
  );
}
