// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chatloom/personal/storage/sql_cipher_json_database.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS native crypto, Keychain and encrypted restart', (_) async {
    expect(Platform.isMacOS, isTrue);
    await vod.init();
    const storage = FlutterSecureStorage();
    final marker = 'chatloom-ci-${DateTime.now().microsecondsSinceEpoch}';
    final cipher = base64Url.encode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final temporary = await getTemporaryDirectory();
    final directory = await Directory('${temporary.path}/$marker').create();
    final path = '${directory.path}/smoke.db';
    SqlCipherJsonDatabase? database;
    try {
      await storage.write(key: marker, value: cipher);
      expect(await storage.read(key: marker), cipher);
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
    } finally {
      await database?.close();
      await storage.delete(key: marker);
      await directory.delete(recursive: true);
    }
  });
}
