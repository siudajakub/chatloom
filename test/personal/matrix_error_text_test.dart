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
        'Phone number is not on WhatsApp.',
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

  group('bridgeMessageText', () {
    // Every bridgev2 / connector / fork text known to reach the app, with
    // the sentence it becomes (BR-04, BR-15).
    const known = {
      'media too large': 'This file is too large for WhatsApp.',
      'media too large: 30.0 MiB is larger than the maximum of 16.0 MiB':
          'This file is too large for WhatsApp.',
      'too large file (25 MiB)': 'This file is too large for WhatsApp.',
      'unsupported message type':
          'WhatsApp doesn’t support this kind of message.',
      'unsupported media type': 'WhatsApp doesn’t support this kind of file.',
      'unsupported view-limited type':
          'WhatsApp doesn’t support this view-once message.',
      'captions are not supported here':
          'Captions aren’t supported in this chat. Send the file without text.',
      'location messages are not supported here':
          'Locations can’t be sent to this chat.',
      'the message is too old to be edited':
          'This message is too old to edit on WhatsApp.',
      'the message has been edited too many times':
          'This message can’t be edited again on WhatsApp.',
      'this bridge does not support edits':
          'Messages in this chat can’t be edited.',
      'edits are not allowed in this chat':
          'Messages in this chat can’t be edited.',
      'this bridge does not support reactions':
          'WhatsApp doesn’t support reactions.',
      'this bridge does not support polls': 'WhatsApp doesn’t support polls.',
      'this bridge does not support deleting messages':
          'WhatsApp doesn’t support deleting messages.',
      'vote target poll not found': 'This poll is no longer available.',
      'media duration too long':
          'This video or recording is too long for WhatsApp.',
      'voice message too long': 'This voice message is too long for WhatsApp.',
      'failed to download media':
          'The bridge couldn’t download the file. Send it again.',
      'failed to reupload media':
          'The bridge couldn’t upload the file to WhatsApp. Send it again.',
      'failed to convert media':
          'The bridge couldn’t convert this file for WhatsApp.',
      'target message not found':
          'The original message is no longer on WhatsApp.',
      'internal database error': 'The bridge had a problem. Try again later.',
      'panic in event handler': 'The bridge had a problem. Try again later.',
      "You're not logged in (receiver login is not logged in)":
          'You’re signed out of WhatsApp. Sign in on the Networks page, then '
          'try again.',
      'You’re not logged in (no usable logins found)':
          'You’re signed out of WhatsApp. Sign in on the Networks page, then '
          'try again.',
      'Failed to get login to handle event':
          'The bridge couldn’t find your WhatsApp account. Check it on the '
          'Networks page.',
      'not connected':
          'WhatsApp isn’t connected right now. Try again in a moment.',
      'remote echo timed out':
          'WhatsApp didn’t confirm this message in time. It may still have '
          'arrived; check before sending it again.',
      'remote ack timed out':
          'WhatsApp didn’t confirm this message in time. It may still have '
          'arrived; check before sending it again.',
      'rate limited by Slack':
          'WhatsApp asks you to slow down. Wait a moment and try again.',
      'message is too long for Slack': 'This message is too long for WhatsApp.',
      'server rejected message: blocked':
          'WhatsApp didn’t accept this message.',
      'failed to convert message: bad html':
          'The bridge couldn’t convert this message for WhatsApp.',
      'Identifier not found': 'No one on WhatsApp has that number or username.',
      'Failed to decode request body':
          'The bridge had a problem. Try again later.',
    };

    test('known bridge strings become sentences naming the network', () {
      for (final MapEntry(:key, :value) in known.entries) {
        expect(bridgeMessageText(key, network: 'WhatsApp'), value, reason: key);
        expect(value, isNot(matches(_raw)), reason: key);
      }
    });

    test('the Telegram fork codes and placeholders are worded', () {
      const fork = {
        'Round video rejected: encode_timeout':
            'Telegram couldn’t process this video message. Try sending it '
            'again.',
        'Telegram media operation: transfer_timeout':
            'Telegram couldn’t process this video message. Try sending it '
            'again.',
        'Round video rejected: duration_limit':
            'Video messages can be up to 60 seconds long.',
        'Round video rejected: file_size_limit':
            'This video message is too large for Telegram.',
        'Round video rejected: invalid_video_profile':
            'This video can’t be sent as a Telegram video message.',
        'Round video rejected: round_permission_denied':
            'You can’t send video messages in this chat.',
        'Telegram media operation: CHAT_WRITE_FORBIDDEN':
            'You can’t send messages in this chat.',
        'Round video rejected: VOICE_MESSAGES_FORBIDDEN':
            'This person doesn’t accept voice and video messages.',
        'Round video rejected: round_ack_missing':
            'Telegram didn’t confirm this video message. It may still appear '
            'in the chat.',
        'Telegram media operation: FLOOD_WAIT_30':
            'Telegram asks you to wait a moment before sending again.',
        'Round video rejected: something_new':
            'Telegram didn’t accept this video message.',
        'A wait of {seconds} seconds is required':
            'Telegram asks you to wait a moment before trying again.',
      };
      for (final MapEntry(:key, :value) in fork.entries) {
        final text = bridgeMessageText(key, network: 'Telegram');
        expect(text, value, reason: key);
        expect(text, isNot(contains('_')));
        expect(text, isNot(contains('{')));
      }
    });

    test('other human text is cleaned up, codes give null', () {
      expect(
        bridgeMessageText('the recipient blocked you', network: 'Signal'),
        'The recipient blocked you.',
      );
      expect(
        bridgeMessageText(
          'failed to send: context deadline exceeded',
          network: 'Signal',
        ),
        'Failed to send.',
      );
      for (final code in [
        'encode_timeout',
        'M_UNKNOWN',
        'HTTP 500',
        'Request failed {code}',
        '',
        null,
      ]) {
        expect(
          bridgeMessageText(code, network: 'Signal'),
          isNull,
          reason: code,
        );
      }
      expect(
        bridgeMessageText('media too large'),
        contains('the other network'),
      );
      expect(
        bridgeMessageMeansSignedOut(
          "You're not logged in (receiver login is not logged in)",
        ),
        isTrue,
      );
      expect(bridgeMessageMeansSignedOut('media too large'), isFalse);
    });
  });

  group('bridgeDeliveryText', () {
    test('reason codes are the fallback; retry advice only when it helps', () {
      String text(String? reason, {bool retriable = false, String? message}) =>
          bridgeDeliveryText(
            retriable: retriable,
            reason: reason,
            message: message,
            network: 'WhatsApp',
          );
      expect(
        text('m.foreign_network_error'),
        'WhatsApp didn’t accept this message.',
      );
      expect(
        text('m.foreign_network_error', retriable: true),
        'WhatsApp didn’t accept this message. Try sending it again.',
      );
      expect(
        text('m.no_permission'),
        'You don’t have permission to send this here.',
      );
      expect(
        text('m.bridge_unavailable'),
        'The WhatsApp bridge isn’t running.',
      );
      expect(
        text(
          'm.event_too_old',
          retriable: true,
          message: 'remote echo timed out',
        ),
        allOf(contains('may still have arrived'), isNot(contains('too old'))),
      );
      expect(
        text('m.event_not_handled', retriable: true),
        'The bridge couldn’t deliver this message. Try sending it again.',
      );
      expect(
        text('com.beeper.unsupported_event', message: 'media too large'),
        'This file is too large for WhatsApp.',
      );
      // Advice already in the sentence is not repeated.
      expect(
        text(
          'm.event_not_handled',
          retriable: true,
          message: 'failed to download media',
        ),
        'The bridge couldn’t download the file. Send it again.',
      );
      expect(
        text('m.foreign_network_error', message: 'encode_timeout'),
        'WhatsApp didn’t accept this message.',
      );
    });
  });
}
