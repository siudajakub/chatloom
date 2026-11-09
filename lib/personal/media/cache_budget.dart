// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:shared_preferences/shared_preferences.dart';

/// File caches are shared by the device; the SQL media allowance is per
/// account. These are cache limits, never limits on history or pending sends.
enum MediaCacheBudget {
  compact('Compact', 48, 128, 32, 48),
  standard('Standard', 128, 512, 96, 256),
  generous('Generous', 256, 1024, 192, 512);

  const MediaCacheBudget(
    this.label,
    this.mediaMiB,
    this.videoMiB,
    this.avatarMiB,
    this.stickerMiB,
  );

  final String label;
  final int mediaMiB, videoMiB, avatarMiB, stickerMiB;
  static const _miB = 1024 * 1024;
  static const preferenceKey = 'pl.personal.media.cache_budget';
  int get mediaBytes => mediaMiB * _miB;
  int get videoBytes => videoMiB * _miB;
  int get avatarBytes => avatarMiB * _miB;
  int get stickerBytes => stickerMiB * _miB;
  int get singleAccountMiB => mediaMiB + videoMiB + avatarMiB + stickerMiB;

  static MediaCacheBudget parse(String? value) => values.firstWhere(
    (budget) => budget.name == value,
    orElse: () => standard,
  );

  static Future<MediaCacheBudget> read() async {
    try {
      return parse(
        (await SharedPreferences.getInstance()).getString(preferenceKey),
      );
    } catch (_) {
      // A preference failure must not disable encrypted storage or startup.
      return standard;
    }
  }

  Future<void> save() async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      preferenceKey,
      name,
    );
    if (!saved) throw StateError('cache_budget_save_failed');
  }
}
