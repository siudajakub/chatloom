// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/utils/color_value.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeBuilder extends StatefulWidget {
  final Widget Function(
    BuildContext context,
    ThemeMode themeMode,
    Color? primaryColor,
  )
  builder;

  final String themeModeSettingsKey;
  final String primaryColorSettingsKey;

  /// Already loaded preferences: the stored theme applies to the first frame
  /// instead of after an asynchronous load (no dark/light flash at startup).
  final SharedPreferences? preferences;

  const ThemeBuilder({
    required this.builder,
    this.themeModeSettingsKey = 'theme_mode',
    this.primaryColorSettingsKey = 'primary_color',
    this.preferences,
    super.key,
  });

  @override
  State<ThemeBuilder> createState() => ThemeController();
}

class ThemeController extends State<ThemeBuilder> {
  SharedPreferences? _sharedPreferences;
  ThemeMode? _themeMode;
  Color? _primaryColor;

  ThemeMode get themeMode => _themeMode ?? ThemeMode.dark;

  Color? get primaryColor => _primaryColor;

  static ThemeController of(BuildContext context) =>
      Provider.of<ThemeController>(context, listen: false);

  Future<void> _loadData(_) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _read(preferences));
  }

  void _read(SharedPreferences preferences) {
    final rawThemeMode = preferences.getString(widget.themeModeSettingsKey);
    final rawColor = preferences.getInt(widget.primaryColorSettingsKey);
    _themeMode = ThemeMode.values.singleWhereOrNull(
      (value) => value.name == rawThemeMode,
    );
    _primaryColor = rawColor == null ? null : Color(rawColor);
  }

  Future<void> setThemeMode(ThemeMode newThemeMode) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    await preferences.setString(widget.themeModeSettingsKey, newThemeMode.name);
    setState(() {
      _themeMode = newThemeMode;
    });
  }

  Future<void> setPrimaryColor(Color? newPrimaryColor) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    if (newPrimaryColor == null) {
      await preferences.remove(widget.primaryColorSettingsKey);
    } else {
      await preferences.setInt(
        widget.primaryColorSettingsKey,
        newPrimaryColor.hexValue,
      );
    }
    setState(() {
      _primaryColor = newPrimaryColor;
    });
  }

  @override
  void initState() {
    super.initState();
    final preferences = widget.preferences;
    if (preferences == null) {
      WidgetsBinding.instance.addPostFrameCallback(_loadData);
    } else {
      _read(_sharedPreferences = preferences);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Provider(
      create: (_) => this,
      child: widget.builder(context, themeMode, primaryColor),
    );
  }
}
