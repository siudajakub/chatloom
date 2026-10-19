// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:material_ui/material_ui.dart';

class SettingsSwitchListTile extends StatefulWidget {
  final AppSettings<bool?> setting;
  final String title;
  final String? subtitle;
  final Function(bool)? onChanged;
  final bool? defaultValue;

  const SettingsSwitchListTile.adaptive({
    super.key,
    required this.setting,
    required this.title,
    this.subtitle,
    this.onChanged,
    this.defaultValue,
  });

  @override
  SettingsSwitchListTileState createState() => SettingsSwitchListTileState();
}

class SettingsSwitchListTileState extends State<SettingsSwitchListTile> {
  bool _pending = false;

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.subtitle;
    return NotionSettingsToggle(
      value: widget.setting.value ?? widget.defaultValue ?? false,
      title: widget.title,
      subtitle: subtitle,
      onChanged: _pending
          ? null
          : (bool newValue) async {
              setState(() => _pending = true);
              try {
                await widget.setting.setItem(newValue);
                if (mounted) widget.onChanged?.call(newValue);
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(
                      content: Text('Could not save this setting. Try again.'),
                    ),
                  );
                }
              } finally {
                if (mounted) setState(() => _pending = false);
              }
            },
    );
  }
}
