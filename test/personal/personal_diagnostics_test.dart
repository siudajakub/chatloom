// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('safe report contains fixed codes and project source locations only', () {
    final report =
        PersonalDiagnostic.from(
          StateError('secret-message https://host/?token=secret @private:host'),
          PersonalFailurePhase.accountRestore,
        ).report(
          StackTrace.fromString('''
#0 secretSymbol (package:chatloom/utils/client_manager.dart:42:9)
#1 @private:host (https://host/private.dart:99:1)
#2 secret (file:///private/secret.dart:12:1)
#3 secret (package:other/credentials.dart:12:1)
#4 secret (package:chatloom/private.dart?token=secret:12:1)
'''),
        );
    expect(
      report,
      'ChatLoom: invalid_state [accountRestore]\nutils/client_manager.dart:42:9',
    );
    for (final secret in [
      'secret',
      '@private',
      'https:',
      'file:',
      'other/',
      'token=',
    ]) {
      expect(report, isNot(contains(secret)));
    }
  });

  test('compiled web frames retain only allowlisted asset coordinates', () {
    final report =
        const PersonalDiagnostic(
          'operation_failed',
          PersonalFailurePhase.action,
        ).report(
          StackTrace.fromString('''
Error: synthetic-private-message
    at minifiedPrivateSymbol (https://fictional-private.invalid/nested/main.dart.js:123:45)
    at anotherPrivateSymbol (native_executor.js:77:8)
    at duplicateSymbol (https://fictional-private.invalid/nested/main.dart.js:123:45)
'''),
        );
    expect(
      report,
      'ChatLoom: operation_failed [action]\n'
      'main.dart.js:123:45\nnative_executor.js:77:8',
    );
    for (final private in [
      'synthetic-private',
      'PrivateSymbol',
      'https:',
      'fictional-private.invalid',
      'nested/',
      'duplicateSymbol',
    ]) {
      expect(report, isNot(contains(private)));
    }
  });

  test(
    'compiled web frame query suffix prefix and URL spoofs are rejected',
    () {
      final report =
          const PersonalDiagnostic(
            'operation_failed',
            PersonalFailurePhase.action,
          ).report(
            StackTrace.fromString('''
at privateSymbol (https://fictional.invalid/main.dart.js?token=fiction:12:3)
at privateSymbol (https://fictional.invalid/main.dart.js:12:3?token=fiction)
at privateSymbol (https://fictional.invalid/main.dart.js#fiction:12:3)
at privateSymbol (https://fictional.invalid/prefixmain.dart.js:12:3)
at privateSymbol (https://fictional.invalid/main.dart.js.map:12:3)
at privateSymbol (https://fictional.invalid/native_executor.js.extra:12:3)
at privateSymbol (https://fictional.invalid/native_executor.js/extra:12:3)
at privateSymbol (prefixnative_executor.js:12:3)
at privateSymbol (main.dart.js:12:3_private)
at privateSymbol (file:///fictional/private/main.dart.js:12:3)
at privateSymbol (blob:https://fictional.invalid/native_executor.js:12:3)
'''),
          );
      expect(report, 'ChatLoom: operation_failed [action]');
    },
  );

  test(
    'package and compiled web frames share the eight unique frame limit',
    () {
      final frames = [
        '#0 privateSymbol (package:chatloom/utils/client_manager.dart:42:9)',
        'at privateSymbol (main.dart.js:100:1)',
        'at privateSymbol (main.dart.js:100:1)',
        for (var line = 101; line <= 109; line++)
          'at privateSymbol (https://fictional.invalid/main.dart.js:$line:1)',
      ];
      final report = const PersonalDiagnostic(
        'operation_failed',
        PersonalFailurePhase.action,
      ).report(StackTrace.fromString(frames.join('\n')));
      expect(report.split('\n'), [
        'ChatLoom: operation_failed [action]',
        'utils/client_manager.dart:42:9',
        for (var line = 100; line <= 106; line++) 'main.dart.js:$line:1',
      ]);
    },
  );

  test(
    'storage, transport, absent, invalid and untrusted journal remain distinct',
    () {
      final cases = <Object, PrivateSyncFailure>{
        const StorageFailure(StorageFailureCode.keyUnavailable):
            PrivateSyncFailure.storageUnavailable,
        const SocketException('private endpoint'): PrivateSyncFailure.offline,
        TimeoutException('private endpoint'): PrivateSyncFailure.timeout,
        StateError('Private journal is not configured'):
            PrivateSyncFailure.journalMissing,
        StateError('Invalid encrypted journal'):
            PrivateSyncFailure.journalInvalid,
        StateError('Unsafe journal membership'):
            PrivateSyncFailure.membershipUntrusted,
        StateError('Journal history pagination stalled'):
            PrivateSyncFailure.journalUnavailable,
      };
      for (final entry in cases.entries) {
        expect(
          privateSyncFailure(entry.key, PersonalFailurePhase.journalReplay),
          entry.value,
        );
        expect(entry.value.message, isNot(contains('private endpoint')));
      }
    },
  );
}
