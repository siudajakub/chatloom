// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

MatrixException _matrix(String errcode, {String? error, int status = 400}) =>
    MatrixException(
      http.Response(
        '{"errcode":"$errcode"${error == null ? '' : ',"error":"$error"'}}',
        status,
      ),
    );

/// Nothing shown may look like protocol vocabulary.
final _raw = RegExp(r'M_[A-Z_]+|\bm\.[a-z_]+|HTTP|Exception|errcode');

void main() {
  group('humanErrorText', () {
    test('M_UNKNOWN never shows its errcode or the server text', () {
      for (final action in ErrorAction.values) {
        final text = humanErrorText(
          _matrix('M_UNKNOWN', error: 'M_UNKNOWN'),
          action: action,
        );
        expect(text, isNot(matches(_raw)));
        expect(text, isNotEmpty);
      }
      expect(
        humanErrorText(_matrix('M_UNKNOWN')),
        'Something went wrong. Try again.',
      );
      expect(
        humanErrorText(_matrix('M_UNKNOWN'), action: ErrorAction.send),
        'Couldn’t send. Try again.',
      );
    });

    test('known errcodes get their own sentence', () {
      expect(
        humanErrorText(_matrix('M_FORBIDDEN', error: 'private detail')),
        'You don’t have permission to do that.',
      );
      expect(
        humanErrorText(_matrix('M_FORBIDDEN'), action: ErrorAction.join),
        'You can’t join this chat.',
      );
      expect(
        humanErrorText(_matrix('M_LIMIT_EXCEEDED', status: 429)),
        'Too many requests. Wait a moment and try again.',
      );
      expect(
        humanErrorText(_matrix('M_UNKNOWN_TOKEN', status: 401)),
        'Your session has ended. Sign in again.',
      );
      expect(
        humanErrorText(_matrix('M_TOO_LARGE', status: 413)),
        'This file is too large for the server.',
      );
      expect(
        humanErrorText(_matrix('M_UNRECOGNIZED', status: 404)),
        'Your server doesn’t support this.',
      );
      // An errcode the app does not know reads like M_UNKNOWN.
      expect(
        humanErrorText(_matrix('COM.EXAMPLE.CUSTOM', error: 'secret')),
        'Something went wrong. Try again.',
      );
    });

    test('connection, timeout, storage and capability failures', () {
      expect(
        humanErrorText(const SocketException('private host')),
        'No connection. Check your internet and try again.',
      );
      expect(
        humanErrorText(http.ClientException('private url')),
        'No connection. Check your internet and try again.',
      );
      expect(
        humanErrorText(SyncConnectionException(Object())),
        'No connection. Check your internet and try again.',
      );
      expect(
        humanErrorText(TimeoutException('x')),
        'The server took too long to answer. Try again.',
      );
      expect(
        humanErrorText(const StorageFailure(StorageFailureCode.keyUnavailable)),
        startsWith('Couldn’t open encrypted storage.'),
      );
      expect(
        humanErrorText(const PersonalCapabilityUnavailable('Fixed reason.')),
        'Fixed reason.',
      );
      expect(
        humanErrorText(StateError('private state detail')),
        'Something went wrong. Try again.',
      );
      expect(
        humanErrorText(Exception('private'), action: ErrorAction.upload),
        'Couldn’t upload this file. Try again.',
      );
    });

    test('bridge failures keep sentences and drop codes', () {
      expect(
        humanErrorText(
          const BridgeProvisioningException(
            400,
            errcode: 'FI.MAU.BRIDGE.X',
            message: 'Phone number is not on WhatsApp',
          ),
        ),
        'Phone number is not on WhatsApp',
      );
      for (final message in ['M_UNKNOWN', 'M_UNKNOWN: M_UNKNOWN', 'HTTP 500']) {
        final text = humanErrorText(
          BridgeProvisioningException(
            500,
            errcode: 'M_UNKNOWN',
            message: message,
          ),
        );
        expect(text, 'The bridge had a problem. Try again later.');
      }
      expect(
        humanErrorText(
          const BridgeProvisioningException(404, errcode: 'M_UNRECOGNIZED'),
        ),
        'This network doesn’t support that.',
      );
      expect(
        humanErrorText(const BridgeProvisioningException(401)),
        'ChatLoom can’t reach this bridge right now.',
      );
      expect(
        humanErrorText(const BridgeProvisioningException(0)),
        'No connection. Check your internet and try again.',
      );
    });
  });

  test('isRetryableError', () {
    expect(isRetryableError(TimeoutException('x')), isTrue);
    expect(isRetryableError(const SocketException('x')), isTrue);
    expect(isRetryableError(_matrix('M_UNKNOWN')), isTrue);
    expect(isRetryableError(_matrix('M_LIMIT_EXCEEDED', status: 429)), isTrue);
    expect(isRetryableError(_matrix('M_NOT_FOUND', status: 502)), isTrue);
    expect(isRetryableError(_matrix('M_FORBIDDEN', status: 403)), isFalse);
    expect(isRetryableError(_matrix('M_TOO_LARGE', status: 413)), isFalse);
    expect(isRetryableError(StateError('x')), isFalse);
    expect(isRetryableError(const BridgeProvisioningException(503)), isTrue);
    expect(isRetryableError(const BridgeProvisioningException(404)), isFalse);
  });

  test('server and connection failures are background noise', () {
    expect(isServerOrConnectionError(_matrix('M_UNKNOWN')), isTrue);
    expect(isServerOrConnectionError(TimeoutException('x')), isTrue);
    expect(isServerOrConnectionError(const SocketException('x')), isTrue);
    expect(isServerOrConnectionError(StateError('x')), isFalse);
    expect(
      isServerOrConnectionError(
        const StorageFailure(StorageFailureCode.keyUnavailable),
      ),
      isFalse,
    );
  });

  test('verification cancel codes read as sentences', () {
    // The reported dialog said "Error m.unknown: m.unknown".
    for (final code in [
      null,
      'm.unknown',
      'm.user',
      'm.timeout',
      'm.accepted',
      'm.key_mismatch',
      'm.mismatched_sas',
      'm.unknown_method',
      'm.invalid_message',
      'im.fluffychat.unknown_device',
      'com.example.private',
    ]) {
      final text = verificationCancelText(code);
      expect(text, isNot(matches(_raw)), reason: '$code');
      expect(text, isNot(contains('null')));
    }
    expect(verificationCancelText('m.unknown'), 'Verification was cancelled.');
    expect(
      verificationCancelText('m.mismatched_sas'),
      startsWith('The security codes didn’t match'),
    );
  });

  test('Matrix diagnostics carry only the spec errcode', () {
    expect(
      PersonalDiagnostic.from(
        _matrix('M_UNKNOWN', error: 'private server text'),
        PersonalFailurePhase.action,
      ).code,
      'matrix_m_unknown',
    );
    expect(
      PersonalDiagnostic.from(
        _matrix('M_LIMIT_EXCEEDED'),
        PersonalFailurePhase.action,
      ).code,
      'matrix_m_limit_exceeded',
    );
    // Free-form codes from a server never reach the log verbatim.
    expect(
      PersonalDiagnostic.from(
        _matrix('PRIVATE.CUSTOM_CODE'),
        PersonalFailurePhase.action,
      ).code,
      'matrix_m_unknown',
    );
  });
}
