// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final values = <String, String>{};
  final calls = <MethodCall>[];
  final fixtureKey = base64UrlEncode(List<int>.filled(32, 19));
  var unavailable = false;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    values.clear();
    calls.clear();
    unavailable = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (unavailable) throw PlatformException(code: 'locked');
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          final key = arguments['key']! as String;
          switch (call.method) {
            case 'read':
              return values[key];
            case 'write':
              values[key] = arguments['value']! as String;
              return null;
            default:
              throw StateError('Unexpected secure-storage operation');
          }
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('existing database key uses only the private iOS namespace', () async {
    values['database_password'] = fixtureKey;
    expect(await getDatabaseCipher(requireExisting: true), fixtureKey);
    expect(calls.map((call) => call.method), ['read']);
    final arguments = calls.single.arguments as Map;
    final options = arguments['options'] as Map;
    expect(options.containsKey('groupId'), isFalse);
    expect(options['accessibility'], 'unlocked');
    expect(options['synchronizable'], 'false');
  });

  test('missing key for an existing database is never regenerated', () async {
    await expectLater(
      getDatabaseCipher(requireExisting: true),
      throwsA(
        isA<StorageFailure>().having(
          (failure) => failure.code,
          'code',
          StorageFailureCode.keyUnavailable,
        ),
      ),
    );
    expect(calls.map((call) => call.method), ['read']);
    expect(values, isEmpty);
  });

  test('unavailable Keychain preserves the saved key', () async {
    values['database_password'] = fixtureKey;
    unavailable = true;
    await expectLater(getDatabaseCipher(), throwsA(isA<StorageFailure>()));
    expect(values['database_password'], fixtureKey);
    expect(calls.map((call) => call.method), ['read']);
  });
}
