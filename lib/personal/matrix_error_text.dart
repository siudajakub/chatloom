// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/privacy_transport.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

/// Human-readable error text: the single place that turns an exception into
/// words a person can act on.
///
/// Rules (Telegram/Messenger): a raw Matrix `errcode`, HTTP status, server
/// message or exception text never reaches the screen. Failures of work the
/// user did not start (sync, read markers, typing, pushers, probes, key
/// backup) go to [logBackgroundError] and stay out of the UI; a failed user
/// action shows [humanErrorText], with a retry when [isRetryableError].
///
/// The app is English-only, so nothing here needs a `BuildContext`.

/// What the user was doing, to word the generic case ("Couldn't send…").
enum ErrorAction { generic, send, upload, join, load }

/// A short sentence for [error], never containing an errcode or server text.
String humanErrorText(
  Object error, {
  ErrorAction action = ErrorAction.generic,
}) {
  if (error is PersonalCapabilityUnavailable) return error.reason;
  if (error is StorageFailure) {
    return 'Couldn’t open encrypted storage. Your data is preserved. '
        'Unlock your device and try again.';
  }
  if (error is TimeoutException) {
    return 'The server took too long to answer. Try again.';
  }
  if (_isConnectionFailure(error)) {
    return 'No connection. Check your internet and try again.';
  }
  if (error is BridgeProvisioningException) return _bridgeText(error);
  if (error is FileTooBigMatrixException) {
    return 'This file is too large for the server.';
  }
  if (error is MatrixException) return _matrixText(error, action);
  if (error is PlatformException && error.code == 'CANCELED') {
    return 'Cancelled.';
  }
  return _fallback(action);
}

/// Whether trying the same action again can succeed (offline, timeout,
/// rate limit, a transient server failure). Permission, size and
/// "not found" failures are final.
bool isRetryableError(Object error) {
  if (error is TimeoutException || _isConnectionFailure(error)) return true;
  if (error is BridgeProvisioningException) {
    return error.status == 0 || error.status >= 500;
  }
  if (error is FileTooBigMatrixException) return false;
  if (error is MatrixException) {
    final status = error.response?.statusCode;
    if (status != null && status >= 500) return true;
    return switch (error.errcode) {
      'M_LIMIT_EXCEEDED' || 'M_UNKNOWN' => true,
      _ => false,
    };
  }
  return false;
}

/// Server or connection failures: expected noise of background work. They
/// are logged, never shown as a dialog or snackbar without a user action.
bool isServerOrConnectionError(Object error) =>
    error is MatrixException ||
    error is TimeoutException ||
    error is BridgeProvisioningException ||
    _isConnectionFailure(error);

/// Logs a failure of work the user did not start. Only a fixed diagnostic
/// code leaves the app: no errcode text, server message, IDs or URLs.
void logBackgroundError(String task, Object error, [StackTrace? stack]) {
  if (error is PrivacySuppressed) return;
  final code = PersonalDiagnostic.from(error, PersonalFailurePhase.action).code;
  // A bridge failure's status and errcode carry no account data.
  final detail = error is BridgeProvisioningException ? ' ${error.reason}' : '';
  Logs().w('background_failed $task $code$detail');
}

/// Why a key verification stopped, for its dialog. [code] is the
/// `m.key.verification.cancel` code; the free-text reason is never shown.
String verificationCancelText(String? code) => switch (code) {
  'm.user' => 'Verification was cancelled.',
  'm.timeout' => 'Verification timed out. Start it again.',
  'm.accepted' => 'Another of your devices answered this request.',
  'm.key_mismatch' ||
  'm.mismatched_sas' ||
  'm.mismatched_commitment' ||
  'm.invalid_key' ||
  'm.user_mismatch' =>
    'The security codes didn’t match, so verification stopped. '
        'Your devices stay as they were.',
  'm.unknown_method' =>
    'The other device can’t verify this way. Try from the other device.',
  'm.unexpected_message' ||
  'm.invalid_message' ||
  'm.unknown_transaction' => 'Verification got out of step. Start it again.',
  'im.fluffychat.unknown_device' =>
    'The other device isn’t known yet. Try again in a moment.',
  _ => 'Verification was cancelled.',
};

bool _isConnectionFailure(Object error) =>
    isPersonalNetworkFailure(error) || error is SyncConnectionException;

String _matrixText(MatrixException error, ErrorAction action) {
  switch (error.errcode) {
    case 'M_FORBIDDEN':
    case 'M_GUEST_ACCESS_FORBIDDEN':
      return action == ErrorAction.join
          ? 'You can’t join this chat.'
          : 'You don’t have permission to do that.';
    case 'M_LIMIT_EXCEEDED':
      return 'Too many requests. Wait a moment and try again.';
    case 'M_UNKNOWN_TOKEN':
    case 'M_MISSING_TOKEN':
      return 'Your session has ended. Sign in again.';
    case 'M_NOT_FOUND':
      return action == ErrorAction.join
          ? 'This chat no longer exists.'
          : 'This is no longer available.';
    case 'M_TOO_LARGE':
      return 'This file is too large for the server.';
    case 'M_UNRECOGNIZED':
      return 'Your server doesn’t support this.';
    case 'M_RESOURCE_LIMIT_EXCEEDED':
      return 'The server is over its limit. Try again later.';
  }
  return _fallback(action);
}

/// An errcode (`M_UNKNOWN`, `FI.MAU.BRIDGE.X`) or an HTTP status anywhere.
final _technical = RegExp(r'\b[A-Z][A-Z0-9]*(?:[_.][A-Z0-9]+)+\b|\bHTTP\b');

/// Text written for people: a few words, lower-case letters, no errcode.
bool _isSentence(String text) =>
    text.length <= 160 &&
    text.contains(' ') &&
    text.contains(RegExp('[a-z]')) &&
    !_technical.hasMatch(text);

String _bridgeText(BridgeProvisioningException error) {
  // mautrix bridges write their `error` for people ("Phone number is not
  // on WhatsApp"); ChatLoom's own reasons travel here too. Code-shaped
  // text is treated like no message.
  final message = error.message?.trim();
  if (message != null && _isSentence(message)) return message;
  if (error.unsupported) return 'This network doesn’t support that.';
  if (error.status == 0) {
    return 'No connection. Check your internet and try again.';
  }
  if (error.status >= 500) {
    return 'The bridge had a problem. Try again later.';
  }
  if (error.unreachable) return 'ChatLoom can’t reach this bridge right now.';
  return 'The bridge couldn’t do that.';
}

String _fallback(ErrorAction action) => switch (action) {
  ErrorAction.send => 'Couldn’t send. Try again.',
  ErrorAction.upload => 'Couldn’t upload this file. Try again.',
  ErrorAction.join => 'Couldn’t join this chat. Try again.',
  ErrorAction.load => 'Couldn’t load this. Try again.',
  ErrorAction.generic => 'Something went wrong. Try again.',
};
