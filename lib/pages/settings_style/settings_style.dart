// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
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

  static const _accountDataKey =
      ApplicationAccountConfigExtension.accountDataKey;

  // Keep acknowledged changes visible until the next wallpaper sync arrives.
  // Slider drafts are local and cover the time before the request completes.
  ({Client account, BasicEvent? previous, ApplicationAccountConfig settings})?
  _savedWallpaper;
  Future<void> _sliderWrites = Future.value();
  double? _wallpaperOpacity;
  double? _wallpaperBlur;
  bool wallpaperBusy = false;

  ApplicationAccountConfig _wallpaperFor(Client account) {
    final saved = _savedWallpaper;
    if (saved != null &&
        identical(saved.account, account) &&
        identical(saved.previous, account.accountData[_accountDataKey])) {
      return saved.settings;
    }
    return account.applicationAccountConfig;
  }

  Uri? get wallpaperUrl => _wallpaperFor(_client).wallpaperUrl;
  double get wallpaperOpacity =>
      _wallpaperOpacity ?? _wallpaperFor(_client).wallpaperOpacity ?? .5;
  double get wallpaperBlur =>
      _wallpaperBlur ?? _wallpaperFor(_client).wallpaperBlur ?? 0;

  ApplicationAccountConfig get wallpaperPreview => ApplicationAccountConfig(
    wallpaperUrl: wallpaperUrl,
    wallpaperOpacity: wallpaperOpacity,
    wallpaperBlur: wallpaperBlur,
  );

  Future<void> _saveWallpaper(
    Client account,
    ApplicationAccountConfig settings,
  ) async {
    final previous = account.accountData[_accountDataKey];
    await account.setApplicationAccountConfig(settings);
    _savedWallpaper = (
      account: account,
      previous: previous,
      settings: settings,
    );
  }

  void _explain(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> setWallpaper() async {
    final account = _client;
    await _editPhoto(
      account,
      () async {
        final picked = await selectFiles(context, type: FileType.image);
        final file = picked.firstOrNull;
        if (file == null || !mounted || !identical(account, _client)) return;
        final bytes = await file.readAsBytes();
        if (!mounted || !identical(account, _client)) return;
        final url = await account.uploadContent(bytes, filename: file.name);
        if (!mounted || !identical(account, _client)) return;
        final previous = _wallpaperFor(account);
        await _saveWallpaper(
          account,
          ApplicationAccountConfig(
            wallpaperUrl: url,
            wallpaperOpacity: previous.wallpaperUrl == null
                ? .5
                : previous.wallpaperOpacity,
            wallpaperBlur: previous.wallpaperBlur,
          ),
        );
        if (!mounted || !identical(account, _client)) return;
        await setDisplayPreferences(
          displayPreferences.copyWith(accountWallpaperEnabled: true),
        );
      },
      failure: 'Could not set the photo. Check your connection and try again.',
    );
  }

  Future<void> removeWallpaper() {
    final account = _client;
    return _editPhoto(
      account,
      () => _saveWallpaper(account, const ApplicationAccountConfig()),
      failure:
          'Could not remove the photo. Check your connection and try again.',
    );
  }

  Future<void> _editPhoto(
    Client account,
    Future<void> Function() operation, {
    required String failure,
  }) async {
    if (wallpaperBusy) return;
    setState(() => wallpaperBusy = true);
    try {
      await _sliderWrites;
      if (!mounted || !identical(account, _client)) return;
      await operation();
    } catch (_) {
      if (mounted && identical(account, _client)) _explain(failure);
    } finally {
      if (mounted) setState(() => wallpaperBusy = false);
    }
  }

  void updateWallpaperOpacity(double value) {
    if (!wallpaperBusy) setState(() => _wallpaperOpacity = value);
  }

  void updateWallpaperBlur(double value) {
    if (!wallpaperBusy) setState(() => _wallpaperBlur = value);
  }

  Future<void> saveWallpaperOpacity(double opacity) =>
      _saveWallpaperSlider(opacity: opacity);

  Future<void> saveWallpaperBlur(double blur) =>
      _saveWallpaperSlider(blur: blur);

  Future<void> _saveWallpaperSlider({double? opacity, double? blur}) {
    if (wallpaperBusy) return Future.value();
    final account = _client;
    _sliderWrites = _sliderWrites.then((_) async {
      if (!mounted || !identical(account, _client)) return;
      final previous = _wallpaperFor(account);
      if (previous.wallpaperUrl == null) return;
      try {
        await _saveWallpaper(
          account,
          ApplicationAccountConfig(
            wallpaperUrl: previous.wallpaperUrl,
            wallpaperOpacity: opacity ?? previous.wallpaperOpacity,
            wallpaperBlur: blur ?? previous.wallpaperBlur,
          ),
        );
      } catch (_) {
        if (mounted && identical(account, _client)) {
          _explain('Could not save the change. Check your connection.');
        }
      } finally {
        if (mounted && identical(account, _client)) {
          setState(() {
            if (opacity == _wallpaperOpacity) _wallpaperOpacity = null;
            if (blur == _wallpaperBlur) _wallpaperBlur = null;
          });
        }
      }
    });
    return _sliderWrites;
  }

  @override
  Widget build(BuildContext context) => SettingsStyleView(this);
}
