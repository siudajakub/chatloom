// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:chatloom/config/app_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Width and height from a PNG header.
(int, int) _pngSize(Uint8List bytes) {
  expect(bytes.sublist(1, 4), 'PNG'.codeUnits, reason: 'not a PNG');
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

const _res = 'android/app/src/main/res';
const _densities = {
  'mdpi': 1.0,
  'hdpi': 1.5,
  'xhdpi': 2.0,
  'xxhdpi': 3.0,
  'xxxhdpi': 4.0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the in-app logo assets are bundled', () async {
    for (final asset in [AppConfig.logoAsset, AppConfig.logoSilhouetteAsset]) {
      final data = await rootBundle.load(asset);
      expect(_pngSize(data.buffer.asUint8List()), (512, 512), reason: asset);
    }
  });

  test('Android has every launcher, notification and splash density', () {
    const sizes = {
      'mipmap-%/ic_launcher.png': 48,
      'drawable-%/ic_launcher_foreground.png': 108,
      'drawable-%/ic_launcher_background.png': 108,
      'drawable-%/ic_launcher_monochrome.png': 108,
      'drawable-%/notifications_icon.png': 24,
      'drawable-%/splash.png': 160,
      'drawable-%/splash_icon.png': 240,
    };
    for (final MapEntry(key: density, value: scale) in _densities.entries) {
      for (final MapEntry(key: pattern, value: dp) in sizes.entries) {
        final path = '$_res/${pattern.replaceFirst('%', density)}';
        final px = (dp * scale).round();
        expect(
          _pngSize(File(path).readAsBytesSync()),
          (px, px),
          reason: path,
        );
      }
    }
  });

  test('the adaptive icon has a monochrome layer and no inset', () {
    final xml = File(
      '$_res/mipmap-anydpi-v26/ic_launcher.xml',
    ).readAsStringSync();
    expect(xml, contains('@drawable/ic_launcher_monochrome'));
    expect(xml, isNot(contains('inset')));
  });

  test('Android 12 splash attributes exist in day and night themes', () {
    for (final dir in ['values-v31', 'values-night-v31']) {
      final xml = File('$_res/$dir/styles.xml').readAsStringSync();
      expect(
        xml,
        contains('windowSplashScreenAnimatedIcon">@drawable/splash_icon'),
        reason: dir,
      );
      expect(xml, contains('windowSplashScreenBackground'), reason: dir);
    }
  });

  test('the foreground service icon meta-data points at the silhouette', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final service = File(
      'lib/utils/start_push_foreground_service.dart',
    ).readAsStringSync();
    const name = 'pl.personal.chatloom.notification_icon';
    expect(service, contains("metaDataName: '$name'"));
    expect(
      manifest,
      matches(
        RegExp(
          'android:name="${RegExp.escape(name)}"\\s+'
          'android:resource="@drawable/notifications_icon"',
        ),
      ),
    );
  });
}
