// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:material_ui/material_ui.dart';

class SettingsSwitchListTile extends StatefulWidget {
  /// Non-nullable, so an unwritten setting reads its enum default
  /// (CC-09: `AppSettings<bool?>` resolved to the raw nullable read and
  /// showed default-on toggles as off).
  final AppSettings<bool> setting;
  final String title;
  final String? subtitle;
  final Function(bool)? onChanged;

  const SettingsSwitchListTile.adaptive({
    super.key,
    required this.setting,
    required this.title,
    this.subtitle,
    this.onChanged,
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
      value: widget.setting.value,
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
