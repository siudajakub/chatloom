// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatloom/personal/media/media_preparation_exception.dart';
import 'package:chatloom/personal/media/media_quality.dart';
import 'package:chatloom/utils/resize_video.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _UnreadVideo extends XFile {
  final int size = 20000000;
  int reads = 0;
  _UnreadVideo(super.path) : super(mimeType: 'video/mp4');

  @override
  Future<int> length() async => size;

  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    return Uint8List(32);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('light_compressor');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late _UnreadVideo source;
  late List<MethodCall> calls;

  Map<String, Object> metadata() => {
    'width': 3840,
    'height': 2160,
    'durationMs': 60000,
    'bitrate': 50000000,
    'frameRate': 60.0,
    'mimeType': 'video/mp4',
  };

  setUp(() async {
    debugVideoTranscodeSupported = true;
    temporary = await Directory.systemTemp.createTemp('video-prepare-');
    source = _UnreadVideo('${temporary.path}/source.mp4');
    await File(source.path).writeAsBytes([1, 2, 3]);
    calls = [];
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    debugVideoTranscodeSupported = null;
    await temporary.delete(recursive: true);
  });

  test('codec failure never reads or sends the original', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getMediaInfo') return metadata();
      if (call.method == 'startCompression') {
        return jsonEncode({'onFailure': 'failed'});
      }
      return null;
    });
    await expectLater(
      source.prepareVideo(compress: true, maxUploadSize: 100000000),
      throwsA(isA<MediaPreparationException>()),
    );
    expect(source.reads, 0);
    expect(calls.map((c) => c.method), ['getMediaInfo', 'startCompression']);
  });

  test(
    'unknown large video metadata never triggers an original upload',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object>{};
      });
      await expectLater(
        source.prepareVideo(compress: true, maxUploadSize: 100000000),
        throwsA(isA<MediaPreparationException>()),
      );
      expect(source.reads, 0);
      expect(calls.map((c) => c.method), ['getMediaInfo']);
    },
  );

  test('larger output fails and deletes only the generated output', () async {
    final output = File('${temporary.path}/encoded.mp4');
    await output.create();
    final handle = await output.open(mode: FileMode.write);
    await handle.truncate(source.size + 1);
    await handle.close();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getMediaInfo') return metadata();
      return jsonEncode({
        'onSuccess': output.path,
        'originalSize': source.size,
        'compressedSize': source.size + 1,
      });
    });
    await expectLater(
      source.prepareVideo(compress: true, maxUploadSize: 100000000),
      throwsA(isA<MediaPreparationException>()),
    );
    expect(source.reads, 0);
    expect(await output.exists(), isFalse);
    expect(await File(source.path).exists(), isTrue);
  });

  test(
    'oversize uncompressed files are refused before native work or reads',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await expectLater(
        source.prepareVideo(compress: false, maxUploadSize: 1000000),
        throwsA(isA<FileTooBigMatrixException>()),
      );
      expect(source.reads, 0);
      expect(calls, isEmpty);
    },
  );

  test(
    'economy sends encoded output and keeps original when thumbnail fails',
    () async {
      final output = File('${temporary.path}/encoded.mp4');
      await output.writeAsBytes([8, 9, 10, 11]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'getMediaInfo') return metadata();
        if (call.method == 'getVideoThumbnail') {
          throw PlatformException(code: 'FAILED');
        }
        return jsonEncode({
          'onSuccess': output.path,
          'originalSize': source.size,
          'compressedSize': 4,
        });
      });
      final (video, thumbnail) = await source.prepareVideo(
        compress: true,
        maxUploadSize: 100000000,
        profile: MediaProfile.economy,
      );
      expect(video.bytes, [8, 9, 10, 11]);
      expect(thumbnail, isNull);
      final arguments =
          calls.firstWhere((c) => c.method == 'startCompression').arguments
              as Map;
      expect(arguments['videoWidth'], 854);
      expect(arguments['videoHeight'], 480);
      expect(arguments['audioBitrate'], 96000);
      expect(source.reads, 0);
      expect(await output.exists(), isFalse);
      expect(await File(source.path).exists(), isTrue);
    },
  );

  test(
    'cancellation during thumbnail generation stops the file read',
    () async {
      final thumbnailStarted = Completer<void>();
      final thumbnailGate = Completer<String?>();
      final job = VideoPrepareJob();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getMediaInfo') {
          return {
            'width': 1280,
            'height': 720,
            'durationMs': 60000,
            'bitrate': 2000000,
            'frameRate': 30.0,
            'mimeType': 'video/mp4',
          };
        }
        if (call.method == 'getVideoThumbnail') {
          thumbnailStarted.complete();
          return thumbnailGate.future;
        }
        return null;
      });
      final prepared = source.prepareVideo(
        compress: true,
        maxUploadSize: 100000000,
        job: job,
      );
      final failed = expectLater(
        prepared,
        throwsA(isA<VideoPrepareCancelled>()),
      );
      await thumbnailStarted.future;
      await job.cancel();
      thumbnailGate.complete(null);
      await failed;
      expect(source.reads, 0);
    },
  );
}
