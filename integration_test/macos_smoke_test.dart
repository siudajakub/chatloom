// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/storage/sql_cipher_json_database.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:ogg_caf_converter/ogg_caf_converter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'fixtures/macos_media.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS native crypto, Keychain and encrypted restart', (_) async {
    expect(Platform.isMacOS, isTrue);
    await vod.init();
    const storage = personalSecureStorage;
    const otherService = FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    );
    final marker = 'chatloom-ci-${DateTime.now().microsecondsSinceEpoch}';
    final cipher = base64Url.encode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final temporary = await getTemporaryDirectory();
    final directory = await Directory(
      '${temporary.path}/$marker',
    ).create(recursive: true);
    final path = '${directory.path}/smoke.db';
    SqlCipherJsonDatabase? database;
    try {
      await otherService.write(key: marker, value: 'synthetic-other-service');
      expect(await storage.read(key: marker), isNull);
      await storage.write(key: marker, value: cipher);
      expect(await storage.read(key: marker), cipher);
      expect(await otherService.read(key: marker), 'synthetic-other-service');
      database = await SqlCipherJsonDatabase.open(path: path, cipher: cipher);
      await database.put('fixture', {'value': 'synthetic-ci-canary'});
      await database.close();
      database = null;
      expect(
        utf8.decode(await File(path).readAsBytes(), allowMalformed: true),
        isNot(contains('synthetic-ci-canary')),
      );
      database = await SqlCipherJsonDatabase.open(path: path, cipher: cipher);
      expect(await database.get('fixture'), {'value': 'synthetic-ci-canary'});
      await database.close();
      database = null;
      final beforeWrongKey = await File(path).readAsBytes();
      final wrongCipher = base64Url.encode(List<int>.filled(32, 7));
      await expectLater(
        SqlCipherJsonDatabase.open(path: path, cipher: wrongCipher),
        throwsA(isA<StorageFailure>()),
      );
      expect(await File(path).readAsBytes(), beforeWrongKey);
      database = await SqlCipherJsonDatabase.open(path: path, cipher: cipher);
      expect(await database.get('fixture'), {'value': 'synthetic-ci-canary'});
    } finally {
      await database?.close();
      await storage.delete(key: marker);
      await otherService.delete(key: marker);
      await directory.delete(recursive: true);
    }
  });

  testWidgets('macOS native audio and video decode private media fixtures', (
    _,
  ) async {
    final temporary = await getTemporaryDirectory();
    final directory = Directory(
      '${temporary.path}/chatloom-media-ci-${DateTime.now().microsecondsSinceEpoch}',
    );
    final access = await MediaAccess.open(directory: directory);
    final voice = await access.create(
      base64Decode(macosOpusFixture),
      extension: '.ogg',
    );
    final video = await access.create(
      base64Decode(macosVideoFixture),
      extension: '.mp4',
    );
    final audioPlayer = AudioPlayer();
    final videoPlayer = VideoPlayerController.file(video.file);
    try {
      final caf = voice.derivedFile('.caf');
      await OggCafConverter().convertOggToCaf(
        input: voice.file.path,
        output: caf.path,
      );
      final audioDuration = await audioPlayer.setFilePath(caf.path);
      expect(audioDuration!.inMilliseconds, greaterThanOrEqualTo(800));
      await videoPlayer.initialize();
      expect(
        videoPlayer.value.duration.inMilliseconds,
        greaterThanOrEqualTo(800),
      );
      expect(videoPlayer.value.size.width, 64);
      expect(videoPlayer.value.size.height, 64);
    } finally {
      await audioPlayer.dispose();
      await videoPlayer.dispose();
      await voice.close();
      await video.close();
      await directory.delete(recursive: true);
    }
  });
}
