// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/round_video/round_capture_backend.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

RoundCaptureProfile bridge({
  int maxSide = 640,
  int recommendedSide = 384,
  int videoBitrate = 1000000,
  int audioBitrate = 64000,
  bool highQuality = false,
  bool stabilize = true,
  bool noiseReduction = false,
}) => RoundCaptureProfile.fromBridge(
  maxBytes: 25000000,
  maxSide: maxSide,
  recommendedSide: recommendedSide,
  maxDurationMs: 60000,
  videoBitrate: videoBitrate,
  audioBitrate: audioBitrate,
  highQuality: highQuality,
  stabilize: stabilize,
  noiseReduction: noiseReduction,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('RoundCaptureProfile.fromBridge', () {
    test('default stays 384 px at about 1 Mbps with 64 kbps audio', () {
      final profile = bridge();
      expect(profile.side, 384);
      expect(profile.videoBitrate, 1000000);
      expect(profile.audioBitrate, 64000);
      expect(profile.highQuality, isFalse);
      expect(profile.stabilize, isTrue);
      expect(profile.noiseReduction, isFalse);
      expect(profile.isValid, isTrue);
    });

    test('rounds record from the plain microphone unless asked', () {
      // Telegram's InstantCameraView uses AudioSource.DEFAULT; the call
      // path (VOICE_COMMUNICATION) is the opt-in noise reduction.
      final plain = RoundCaptureProfile.fromBridge(
        maxBytes: 25000000,
        maxSide: 640,
        recommendedSide: 384,
        maxDurationMs: 60000,
        videoBitrate: 1000000,
        audioBitrate: 64000,
      );
      expect(plain.noiseReduction, isFalse);
      expect(bridge(noiseReduction: true).noiseReduction, isTrue);
    });

    test('high quality uses 480 px, 2 Mbps and 96 kbps', () {
      final profile = bridge(highQuality: true);
      expect(profile.side, 480);
      expect(profile.videoBitrate, 2000000);
      expect(profile.audioBitrate, 96000);
      expect(profile.highQuality, isTrue);
      expect(profile.isValid, isTrue);
    });

    test('high quality never exceeds the bridge side and stays even', () {
      final profile = bridge(highQuality: true, maxSide: 441);
      expect(profile.side, 440);
      expect(profile.side.isEven, isTrue);
      final small = bridge(
        highQuality: true,
        maxSide: 300,
        recommendedSide: 300,
      );
      expect(small.side, 300);
      expect(small.isValid, isTrue);
    });

    test('odd recommended side is made even like before', () {
      expect(bridge(recommendedSide: 383).side, 382);
    });

    test('settings flags pass through unchanged', () {
      final profile = bridge(stabilize: false, noiseReduction: false);
      expect(profile.stabilize, isFalse);
      expect(profile.noiseReduction, isFalse);
    });

    test('bitrates are clamped to the native validation limits', () {
      final profile = bridge(videoBitrate: 50000000, audioBitrate: 1000000);
      expect(profile.videoBitrate, RoundCaptureProfile.maxVideoBitrate);
      expect(profile.audioBitrate, RoundCaptureProfile.maxAudioBitrate);
      expect(profile.isValid, isTrue);
    });
  });

  test('legacy constructor keeps the previous native behaviour', () {
    const profile = RoundCaptureProfile(maxBytes: 25000000);
    expect(profile.stabilize, isFalse);
    expect(profile.noiseReduction, isFalse);
    expect(profile.highQuality, isFalse);
    expect(
      const RoundCaptureProfile(maxBytes: 1, videoBitrate: 8000001).isValid,
      isFalse,
    );
    expect(
      const RoundCaptureProfile(maxBytes: 1, audioBitrate: 256001).isValid,
      isFalse,
    );
  });

  test('initialize forwards quality flags to the native channel', () async {
    final directory = await Directory.systemTemp.createTemp(
      'round-profile-args-',
    );
    const channel = MethodChannel('round-profile-args-test');
    Map<Object?, Object?>? initialize;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'initialize') return null;
          initialize = Map<Object?, Object?>.from(call.arguments as Map);
          return {
            'captureId': initialize!['captureId'],
            'textureId': 1,
            'width': 480,
            'height': 480,
            'rotation': 0,
            'cameraRevision': 1,
            'minZoom': 1,
            'maxZoom': 1,
            'zoom': 1,
          };
        });
    try {
      final access = await MediaAccess.open(directory: directory);
      final backend = AndroidRoundCaptureBackend(access, channel: channel);
      await backend.initialize(
        bridge(highQuality: true, stabilize: false, noiseReduction: true),
      );
      expect(initialize!['side'], 480);
      expect(initialize!['videoBitrate'], 2000000);
      expect(initialize!['audioBitrate'], 96000);
      expect(initialize!['highQuality'], isTrue);
      expect(initialize!['stabilize'], isFalse);
      expect(initialize!['noiseReduction'], isTrue);
      await backend.dispose();
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
      await directory.delete(recursive: true);
    }
  });
}
