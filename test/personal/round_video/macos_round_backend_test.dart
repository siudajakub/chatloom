// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/round_video/round_capture_backend.dart';
import 'package:chatloom/personal/round_video/round_media_preparer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'macOS recorder uses a private lease and retains only validated output',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final directory = await Directory.systemTemp.createTemp(
        'macos-round-test-',
      );
      const channel = MethodChannel('macos-round-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late Map<Object?, Object?> initialized;
      var nativeDisposed = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        switch (call.method) {
          case 'initialize':
            initialized = args;
            expect(
              await Directory(args['directory']! as String).exists(),
              isTrue,
            );
            return {
              'captureId': args['captureId'],
              'textureId': 1,
              'width': 640,
              'height': 480,
              'rotation': 0,
              'mirrored': true,
              'canSwitchDuringRecording': false,
            };
          case 'finish':
            await File(
              initialized['outputPath']! as String,
            ).writeAsBytes([1, 2, 3]);
            return {
              'captureId': args['captureId'],
              'path': initialized['outputPath'],
              'width': 384,
              'height': 384,
              'durationMs': 1000,
              'sizeBytes': 3,
              'videoCodec': 'h264',
              'audioCodec': 'aac',
              'cornersSanitized': true,
              'fastStart': true,
            };
          case 'dispose':
            nativeDisposed = true;
            return null;
        }
        return null;
      });
      PreparedRoundMedia? media;
      MacOSRoundCaptureBackend? backend;
      try {
        final access = await MediaAccess.open(directory: directory);
        backend = MacOSRoundCaptureBackend(access, channel: channel);
        final preview = await backend.initialize(
          const RoundCaptureProfile(maxBytes: 100000),
        );
        expect(preview.width, 640);
        expect(preview.canSwitchDuringRecording, isFalse);
        media = await backend.finish();
        await backend.dispose(keepPrepared: true);
        expect(nativeDisposed, isTrue);
        expect(await File(media.path).exists(), isTrue);
        await media.close();
        expect(await File(media.path).exists(), isFalse);
      } finally {
        await backend?.dispose();
        await media?.close();
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
