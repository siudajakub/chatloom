// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_settings_adapter.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'settings.dart';

class SettingsView extends StatelessWidget {
  final SettingsController controller;
  const SettingsView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) => NotionSettingsAdapter(
    key: ObjectKey(Matrix.of(context).client),
    controller: controller,
  );
}
