// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

extension ApplicationAccountConfigExtension on Client {
  static const String accountDataKey = 'im.fluffychat.account_config';

  ApplicationAccountConfig get applicationAccountConfig =>
      ApplicationAccountConfig.fromJson(
        accountData[accountDataKey]?.content ?? {},
      );

  Future<void> setApplicationAccountConfig(ApplicationAccountConfig config) =>
      setAccountData(userID!, accountDataKey, config.toJson());

  /// Only updates the specified values in ApplicationAccountConfig
  Future<void> updateApplicationAccountConfig(ApplicationAccountConfig config) {
    final currentConfig = applicationAccountConfig;
    return setAccountData(
      userID!,
      accountDataKey,
      ApplicationAccountConfig(
        wallpaperUrl: config.wallpaperUrl ?? currentConfig.wallpaperUrl,
        wallpaperOpacity:
            config.wallpaperOpacity ?? currentConfig.wallpaperOpacity,
        wallpaperBlur: config.wallpaperBlur ?? currentConfig.wallpaperBlur,
      ).toJson(),
    );
  }
}

class ApplicationAccountConfig {
  final Uri? wallpaperUrl;
  final double? wallpaperOpacity;
  final double? wallpaperBlur;

  const ApplicationAccountConfig({
    this.wallpaperUrl,
    this.wallpaperOpacity,
    this.wallpaperBlur,
  });

  static double? _number(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;

  factory ApplicationAccountConfig.fromJson(Map<String, dynamic> json) =>
      ApplicationAccountConfig(
        wallpaperUrl: json['wallpaper_url'] is String
            ? Uri.tryParse(json['wallpaper_url'])
            : null,
        wallpaperOpacity:
            _number(json['wallpaper_opacity'])?.clamp(0.0, 1.0) ?? 1,
        wallpaperBlur: _number(json['wallpaper_blur'])?.clamp(0.0, 10.0),
      );

  Map<String, dynamic> toJson() => {
    'wallpaper_url': wallpaperUrl?.toString(),
    'wallpaper_opacity': wallpaperOpacity,
    'wallpaper_blur': wallpaperBlur,
  };
}
