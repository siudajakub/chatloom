// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_display_preferences.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/utils/file_selector.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/matrix.dart';
import 'settings_style_view.dart';

/// Settings → Appearance: colour intensity, accent, theme mode and the chat
/// wallpaper. Colour changes re-theme the app in the same frame (no restart).
/// Nothing here blocks the screen: wallpaper changes apply optimistically
/// and only a failure is explained.
class SettingsStyle extends StatefulWidget {
  const SettingsStyle({super.key});

  @override
  SettingsStyleController createState() => SettingsStyleController();
}

class SettingsStyleController extends State<SettingsStyle> {
  NotionAppearance get appearance => ThemeController.of(context).appearance;

  NotionDisplayPreferences get displayPreferences =>
      ThemeController.of(context).displayPreferences;

  Future<void> setDisplayPreferences(NotionDisplayPreferences value) async {
    await ThemeController.of(context).setDisplayPreferences(value);
    if (mounted) setState(() {});
  }

  Future<void> resetDisplayPreferences() =>
      setDisplayPreferences(NotionDisplayPreferences.standard);

  /// Accent, custom colour and intensity back to a new install's.
  Future<void> resetAppearance() async {
    await ThemeController.of(context).setAppearance(NotionAppearance.standard);
    if (mounted) setState(() {});
  }

  // The theme rebuilds at once, but this page is a const route child: it
  // rebuilds itself so the selected card and swatch follow in the same frame.
  void setIntensity(NotionIntensity intensity) =>
      _setAppearance(appearance.copyWith(intensity: intensity));

  void setAccent(NotionAccent accent) =>
      _setAppearance(appearance.copyWith(accent: accent, clearCustom: true));

  void _setAppearance(NotionAppearance value) {
    unawaited(ThemeController.of(context).setAppearance(value));
    setState(() {});
  }

  /// Opens the colour picker; a picked colour replaces the preset's hue.
  Future<void> pickCustomAccent() async {
    final picked = await showCustomAccentSheet(
      context,
      initial: appearance.seed ?? NotionAccent.blue.seed!,
    );
    if (picked == null || !mounted) return;
    await ThemeController.of(
      context,
    ).setAppearance(appearance.copyWith(custom: picked));
    if (mounted) setState(() {});
  }

  ThemeMode get currentTheme => ThemeController.of(context).themeMode;

  Future<void> switchTheme(ThemeMode? newTheme) async {
    if (newTheme == null) return;
    await ThemeController.of(context).setThemeMode(newTheme);
    notionSettingsRevision.value++;
    if (mounted) setState(() {});
  }

  Client get _client => Matrix.of(context).client;

  /// The stored wallpaper, unless a removal is on its way to the server.
  Uri? get wallpaperUrl =>
      _removingWallpaper ? null : _client.applicationAccountConfig.wallpaperUrl;
  bool _removingWallpaper = false;

  /// True while a picked wallpaper uploads (inline progress on the row).
  bool wallpaperBusy = false;

  void _explain(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> setWallpaper() async {
    final picked = await selectFiles(context, type: FileType.image);
    final pickedFile = picked.firstOrNull;
    if (pickedFile == null || !mounted) return;
    final client = _client;
    setState(() => wallpaperBusy = true);
    try {
      final url = await client.uploadContent(
        await pickedFile.readAsBytes(),
        filename: pickedFile.name,
      );
      await client.updateApplicationAccountConfig(
        ApplicationAccountConfig(wallpaperUrl: url),
      );
    } catch (e, s) {
      Logs().w('Could not set the chat wallpaper', e, s);
      _explain(
        'Could not set the wallpaper. Check your connection and try again.',
      );
    } finally {
      if (mounted) setState(() => wallpaperBusy = false);
    }
  }

  Future<void> removeWallpaper() async {
    final client = _client;
    setState(() => _removingWallpaper = true);
    try {
      await client.setApplicationAccountConfig(
        const ApplicationAccountConfig(wallpaperUrl: null, wallpaperBlur: null),
      );
    } catch (e, s) {
      Logs().w('Could not remove the chat wallpaper', e, s);
      _explain(
        'Could not remove the wallpaper. Check your connection and try again.',
      );
    } finally {
      if (mounted) setState(() => _removingWallpaper = false);
    }
  }

  double get wallpaperOpacity =>
      _wallpaperOpacity ??
      _client.applicationAccountConfig.wallpaperOpacity ??
      0.5;
  double? _wallpaperOpacity;

  void updateWallpaperOpacity(double opacity) =>
      setState(() => _wallpaperOpacity = opacity);

  Future<void> saveWallpaperOpacity(double opacity) => _saveWallpaperValue(
    ApplicationAccountConfig(wallpaperOpacity: opacity),
    revert: () => _wallpaperOpacity = null,
  );

  double get wallpaperBlur =>
      _wallpaperBlur ?? _client.applicationAccountConfig.wallpaperBlur ?? 0.5;
  double? _wallpaperBlur;

  void updateWallpaperBlur(double blur) =>
      setState(() => _wallpaperBlur = blur);

  Future<void> saveWallpaperBlur(double blur) => _saveWallpaperValue(
    ApplicationAccountConfig(wallpaperBlur: blur),
    revert: () => _wallpaperBlur = null,
  );

  /// The slider already shows the new value; the save runs in the
  /// background and a failure returns the slider to the stored value.
  Future<void> _saveWallpaperValue(
    ApplicationAccountConfig config, {
    required VoidCallback revert,
  }) async {
    try {
      await _client.updateApplicationAccountConfig(config);
    } catch (e, s) {
      Logs().w('Could not save the chat wallpaper setting', e, s);
      if (!mounted) return;
      setState(revert);
      _explain('Could not save the change. Check your connection.');
    }
  }

  @override
  Widget build(BuildContext context) => SettingsStyleView(this);
}
