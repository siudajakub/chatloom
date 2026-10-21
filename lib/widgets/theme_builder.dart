// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion_appearance.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the theme mode and the colour appearance (accent preset and
/// intensity) and rebuilds the app theme live when either changes.
class ThemeBuilder extends StatefulWidget {
  final Widget Function(
    BuildContext context,
    ThemeMode themeMode,
    NotionAppearance appearance,
  )
  builder;

  final String themeModeSettingsKey;

  /// Already loaded preferences: the stored theme applies to the first frame
  /// instead of after an asynchronous load (no dark/light flash at startup).
  final SharedPreferences? preferences;

  const ThemeBuilder({
    required this.builder,
    this.themeModeSettingsKey = 'theme_mode',
    this.preferences,
    super.key,
  });

  /// The colour picker of FluffyChat stored an ARGB seed here. It is read
  /// to pick the closest accent preset until the user chooses one.
  static const legacyPrimaryColorKey = 'primary_color';

  /// The stored appearance, or the default for a new install.
  static NotionAppearance readAppearance(SharedPreferences preferences) {
    final accentName = preferences.getString(AppSettings.appearanceAccent.key);
    final legacy = preferences.getInt(legacyPrimaryColorKey);
    final accent = accentName == null && legacy != null
        ? NotionAccent.nearest(Color(legacy))
        : NotionAccent.parse(accentName);
    return NotionAppearance(
      accent: accent,
      intensity: NotionIntensity.parse(
        preferences.getString(AppSettings.appearanceIntensity.key),
      ),
    );
  }

  @override
  State<ThemeBuilder> createState() => ThemeController();
}

class ThemeController extends State<ThemeBuilder> {
  SharedPreferences? _sharedPreferences;
  ThemeMode? _themeMode;
  NotionAppearance _appearance = NotionAppearance.standard;

  ThemeMode get themeMode => _themeMode ?? ThemeMode.dark;

  /// Accent preset and colour intensity of the current theme.
  NotionAppearance get appearance => _appearance;

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
    _themeMode = ThemeMode.values.singleWhereOrNull(
      (value) => value.name == rawThemeMode,
    );
    _appearance = ThemeBuilder.readAppearance(preferences);
  }

  Future<void> setThemeMode(ThemeMode newThemeMode) async {
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    await preferences.setString(widget.themeModeSettingsKey, newThemeMode.name);
    if (!mounted) return;
    setState(() {
      _themeMode = newThemeMode;
    });
  }

  /// Applies [newAppearance] at once (the whole app re-themes in the same
  /// frame, no restart) and stores it.
  Future<void> setAppearance(NotionAppearance newAppearance) async {
    if (newAppearance == _appearance) return;
    if (mounted) {
      setState(() => _appearance = newAppearance);
    } else {
      _appearance = newAppearance;
    }
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    await preferences.setString(
      AppSettings.appearanceAccent.key,
      newAppearance.accent.name,
    );
    await preferences.setString(
      AppSettings.appearanceIntensity.key,
      newAppearance.intensity.name,
    );
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
      child: widget.builder(context, themeMode, appearance),
    );
  }
}
