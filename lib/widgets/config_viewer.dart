// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// Why [value] cannot be stored in [setting], or null when it can.
@visibleForTesting
String? configValueError(AppSettings setting, String value) {
  final text = value.trim();
  if (setting is AppSettings<int>) {
    return int.tryParse(text) == null ? 'Enter a whole number.' : null;
  }
  if (setting is AppSettings<double>) {
    final parsed = double.tryParse(text);
    return parsed == null || !parsed.isFinite ? 'Enter a number.' : null;
  }
  return null;
}

/// Settings › Advanced › Developer › App configuration: every stored app
/// setting by key. A developer tool; reset asks first and keeps the account
/// registry and push registration (see [AppSettings.resetPreferences]).
class ConfigViewer extends StatefulWidget {
  const ConfigViewer({super.key});

  @override
  State<ConfigViewer> createState() => _ConfigViewerState();
}

class _ConfigViewerState extends State<ConfigViewer> {
  String _searchQuery = '';

  void _saveFailed() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Couldn’t save this value. Try again.')),
    );
  }

  Future<void> _changeSetting(AppSettings appSetting, String current) async {
    try {
      if (appSetting is AppSettings<bool>) {
        final next = current != 'true';
        if (appSetting == AppSettings.personalDeveloperOptions) {
          await DeveloperOptions.setEnabled(next);
        } else {
          await appSetting.setItem(next);
        }
        if (mounted) setState(() {});
        return;
      }
      final value = await showTextInputDialog(
        context: context,
        title: appSetting.name,
        hintText: appSetting.defaultValue.toString(),
        initialText: current,
        okLabel: 'Save',
        cancelLabel: 'Cancel',
        keyboardType: appSetting is AppSettings<String>
            ? null
            : const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
        validator: (input) => configValueError(appSetting, input),
      );
      if (value == null || configValueError(appSetting, value) != null) {
        return;
      }
      if (appSetting is AppSettings<String>) {
        await appSetting.setItem(value);
      } else if (appSetting is AppSettings<int>) {
        await appSetting.setItem(int.parse(value.trim()));
      } else if (appSetting is AppSettings<double>) {
        await appSetting.setItem(double.parse(value.trim()));
      }
      if (mounted) setState(() {});
    } catch (_) {
      _saveFailed();
    }
  }

  Future<void> _reset() async {
    final confirmed = await showNotionConfirmDialog(
      context: context,
      title: 'Reset all app settings?',
      message:
          'Appearance, chat, notification preview and privacy settings return '
          'to their defaults. Your account, chats and keys are not affected.',
      confirmLabel: 'Reset',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await AppSettings.resetPreferences();
      await DeveloperOptions.setEnabled(false);
      if (mounted) setState(() {});
    } catch (_) {
      _saveFailed();
    }
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(DeveloperOptions.route);
    }
  }

  String _valueOf(AppSettings setting) {
    if (setting is AppSettings<String>) return setting.value;
    if (setting is AppSettings<int>) return setting.value.toString();
    if (setting is AppSettings<double>) return setting.value.toString();
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _searchQuery.trim().toLowerCase();
    final filteredSettings = AppSettings.values
        .where((setting) {
          if (normalizedQuery.isEmpty) return true;
          return setting.name.toLowerCase().contains(normalizedQuery);
        })
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('App configuration'),
        leading: BackButton(onPressed: _back),
        actions: [
          TextButton(onPressed: _reset, child: const Text('Reset')),
          const SizedBox(width: NotionSpace.xxs),
        ],
      ),
      body: Column(
        crossAxisAlignment: .stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(NotionSpace.md),
            child: NotionCallout(
              icon: Icons.warning_amber_outlined,
              tone: NotionCalloutTone.warning,
              title: 'For troubleshooting only',
              message:
                  'Changing these values can break the app. Reset returns '
                  'every setting to its default.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NotionSpace.md),
            child: TextField(
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: const InputDecoration(
                hintText: 'Search setting',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: NotionSpace.xs),
          Expanded(
            child: ListView.builder(
              itemCount: filteredSettings.length,
              itemBuilder: (context, i) {
                final appSetting = filteredSettings[i];
                if (appSetting is AppSettings<bool>) {
                  final value = appSetting.value;
                  return SwitchListTile.adaptive(
                    title: Text(appSetting.name),
                    subtitle: Text(value.toString()),
                    value: value,
                    onChanged: (_) =>
                        _changeSetting(appSetting, value.toString()),
                  );
                }
                final value = _valueOf(appSetting);
                return ListTile(
                  title: Text(appSetting.name),
                  subtitle: Text(value),
                  onTap: () => _changeSetting(appSetting, value),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
