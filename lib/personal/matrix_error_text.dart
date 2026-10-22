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
///
/// [network] names the bridged network ("WhatsApp") when the failure came
/// from one of its bridge's requests, so known bridge texts can say where.
String humanErrorText(
  Object error, {
  ErrorAction action = ErrorAction.generic,
  String? network,
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
  if (error is BridgeProvisioningException) {
    return _bridgeText(error, network);
  }
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

String _bridgeText(BridgeProvisioningException error, String? network) {
  // mautrix bridges write their `error` for people ("Phone number is not
  // on WhatsApp"); ChatLoom's own reasons travel here too. Known bridgev2
  // texts get ChatLoom's wording, code-shaped text is treated like no
  // message.
  if (error.errcode == 'FI.MAU.NOT_LOGGED_IN') return _signedOut(network);
  final message = bridgeMessageText(error.message, network: network);
  if (message != null) return message;
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

// ---------------------------------------------------------------------------
// Texts written by bridges
// ---------------------------------------------------------------------------

/// Words for a failure text a bridge wrote: the `message` of a
/// `com.beeper.message_send_status` report, or the `error` of a provisioning
/// answer. Returns null when nothing a person can read is left, so the caller
/// words its own fallback (from the reason code).
///
/// * Known mautrix-go bridgev2 strings (`bridgev2/errors.go`, `portal.go`,
///   `matrix/provisioning.go`; lower case, no period, Go error chains such as
///   "media too large: 30.0 MiB is larger than …"), connector strings of the
///   Meta, Slack and WhatsApp bridges, and the ChatLoom Telegram fork's
///   `Round video rejected: <code>` / `Telegram media operation: <code>`
///   become sentences that name [network].
/// * Telegram's literal `{seconds}` templates become "wait a moment".
/// * Any other human-looking text is kept, cleaned up: technical tails
///   (`: <cause>`, `(<detail>)`) dropped, first letter capitalised, a final
///   period added. Code-shaped text (`encode_timeout`, `M_UNKNOWN`,
///   `HTTP 500`) gives null.
String? bridgeMessageText(String? message, {String? network}) {
  final raw = message?.trim();
  if (raw == null || raw.isEmpty) return null;
  final net = _networkName(network);
  final key = raw
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceFirst(RegExp(r'[.!]+$'), '');
  final fork = _forkCode.firstMatch(key);
  if (fork != null) return _roundText(fork.group(2)!);
  if (_notLoggedIn.hasMatch(key)) {
    return network == null
        ? 'You’re signed out of this network. Sign in on the Networks page, '
              'then try again.'
        : 'You’re signed out of $network. Sign in on the Networks page, then '
              'try again.';
  }
  if (_placeholder.hasMatch(raw)) {
    return key.contains('wait')
        ? '${_capital(net)} asks you to wait a moment before trying again.'
        : null;
  }
  for (final (pattern, text) in _bridgeTexts) {
    if (pattern.hasMatch(key)) return text(net);
  }
  final unsupported = _unsupportedFeature.firstMatch(key);
  if (unsupported != null) {
    return '${_capital(net)} doesn’t support ${unsupported.group(1)}.';
  }
  return _cleanBridgeSentence(raw);
}

/// A plain-language reason for a bridge's delivery failure report
/// (`com.beeper.message_send_status`), for the "Not delivered" sheet.
/// [message] is the report's display text, [reason] its code; [retriable]
/// says whether sending again can work, [uncertain] that the message may
/// still have arrived (an echo or ack timeout).
String bridgeDeliveryText({
  required bool retriable,
  String? reason,
  String? message,
  String? network,
}) {
  final net = _networkName(network);
  final uncertain = reason == 'm.event_too_old';
  final fallback = switch (reason) {
    'm.foreign_network_error' => '${_capital(net)} didn’t accept this message.',
    'm.no_permission' => 'You don’t have permission to send this here.',
    'com.beeper.unsupported_event' =>
      '${_capital(net)} doesn’t support this message.',
    'com.beeper.undecryptable_event' =>
      'The bridge couldn’t decrypt this message.',
    'm.event_too_old' => _unconfirmed(net),
    'm.bridge_unavailable' =>
      network == null
          ? 'The bridge isn’t running.'
          : 'The $network bridge isn’t running.',
    _ => 'The bridge couldn’t deliver this message.',
  };
  // An echo/ack timeout may have arrived: its own words, never "send again".
  final text = uncertain
      ? fallback
      : bridgeMessageText(message, network: network) ?? fallback;
  if (!retriable || uncertain || text.contains('again')) return text;
  return '$text Try sending it again.';
}

/// Whether [message] (a bridge delivery text) says the account is signed
/// out of the network, so the fix is signing in, not sending again.
bool bridgeMessageMeansSignedOut(String? message) {
  final key = message?.trim().toLowerCase().replaceAll('’', "'") ?? '';
  return _notLoggedIn.hasMatch(key);
}

String _networkName(String? network) =>
    network == null || network.trim().isEmpty
    ? 'the other network'
    : network.trim();

String _capital(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

String _signedOut(String? network) => network == null
    ? 'You’re signed out of this network. Sign in on the Networks page.'
    : 'You’re signed out of $network. Sign in on the Networks page.';

String _unconfirmed(String net) =>
    '${_capital(net)} didn’t confirm this message in time. It may still have '
    'arrived; check before sending it again.';

final _notLoggedIn = RegExp(
  r"^(you're )?not logged in\b|^login is not logged in|^login not found|"
  r'^no matching user login found',
);

/// `{seconds}` and the like: an unfilled template.
final _placeholder = RegExp(r'\{[a-z_]+\}', caseSensitive: false);

/// The Telegram fork's coded texts (`handlematrix.go` `humaniseSendError`).
final _forkCode = RegExp(
  r'^(round video rejected|telegram media operation): ([a-z0-9_]+)',
);

final _unsupportedFeature = RegExp(r'^this bridge does not support (.+)$');

/// Known bridgev2 and connector strings, matched on the folded text
/// (lower case, straight apostrophes, no final period).
final List<(RegExp, String Function(String net))> _bridgeTexts = [
  (
    RegExp(r'^failed to get login to handle event'),
    (net) =>
        'The bridge couldn’t find your $net account. Check it on the '
        'Networks page.',
  ),
  (RegExp(r'^not connected$'), _notConnected),
  // Media.
  (
    RegExp(r'^media too large\b|^too large file\b|^file too large\b'),
    (net) => 'This file is too large for $net.',
  ),
  (
    RegExp(r'^voice message too long'),
    (net) => 'This voice message is too long for $net.',
  ),
  (
    RegExp(r'^media duration too long'),
    (net) => 'This video or recording is too long for $net.',
  ),
  (
    RegExp(r'^unsupported media type'),
    (net) => '${_capital(net)} doesn’t support this kind of file.',
  ),
  (
    RegExp(r'^unsupported view-limited type'),
    (net) => '${_capital(net)} doesn’t support this view-once message.',
  ),
  (
    RegExp(r'^failed to download media'),
    (_) => 'The bridge couldn’t download the file. Send it again.',
  ),
  (
    RegExp(r'^failed to reupload media'),
    (net) => 'The bridge couldn’t upload the file to $net. Send it again.',
  ),
  (
    RegExp(r'^failed to convert media'),
    (net) => 'The bridge couldn’t convert this file for $net.',
  ),
  (
    RegExp(r'^public media|^failed to generate public media'),
    (net) => 'The bridge can’t send this kind of file to $net.',
  ),
  // Message kinds and edits.
  (
    RegExp(r'^unsupported message type'),
    (net) => '${_capital(net)} doesn’t support this kind of message.',
  ),
  (
    RegExp(r'^captions are not supported'),
    (_) =>
        'Captions aren’t supported in this chat. Send the file without '
        'text.',
  ),
  (
    RegExp(r'^location messages are not supported'),
    (_) => 'Locations can’t be sent to this chat.',
  ),
  (
    RegExp(r'^the message is too old to be edited'),
    (net) => 'This message is too old to edit on $net.',
  ),
  (
    RegExp(r'^the message has been edited too many times'),
    (net) => 'This message can’t be edited again on $net.',
  ),
  (
    RegExp(r'^this bridge does not support edits|^edits are not allowed'),
    (_) => 'Messages in this chat can’t be edited.',
  ),
  (
    RegExp(r'^vote target poll not found'),
    (_) => 'This poll is no longer available.',
  ),
  (
    RegExp(r'^target message not found'),
    (net) => 'The original message is no longer on $net.',
  ),
  (
    RegExp(r'^changes are not allowed here'),
    (_) => 'You can’t change this chat.',
  ),
  // Echo and ack timeouts (`ErrRemoteEchoTimeout`, `ErrRemoteAckTimeout`).
  (RegExp(r'^remote (echo|ack) timed out'), _unconfirmed),
  // Connector texts (Meta, Slack, WhatsApp).
  (
    RegExp(r'^rate limited|^too many requests|flood'),
    (net) =>
        '${_capital(net)} asks you to slow down. Wait a moment and try '
        'again.',
  ),
  (
    RegExp(r'^message is too long'),
    (net) => 'This message is too long for $net.',
  ),
  (
    RegExp(r'^server rejected message'),
    (net) => '${_capital(net)} didn’t accept this message.',
  ),
  (
    RegExp(r'^failed to convert message'),
    (net) => 'The bridge couldn’t convert this message for $net.',
  ),
  // Provisioning (`matrix/provisioning.go`, `provisionutil`).
  (
    RegExp(r'^identifier not found'),
    (net) => 'No one on $net has that number or username.',
  ),
  (
    RegExp(r'^failed to (get|create) portal'),
    (_) => 'The bridge couldn’t open the chat. Try again.',
  ),
  (
    RegExp(r'^user does not have login permissions'),
    (_) => 'Your account isn’t allowed to use this bridge.',
  ),
  // Internal bridge failures: nothing the person can do but try later.
  (
    RegExp(
      r'^(internal database error|database error|panic in event handler|'
      r'unexpected parsed content type|failed to decode request body|'
      r'unrecognized endpoint|invalid method for endpoint|'
      r'provisioning api is disabled|missing auth token|invalid auth token|'
      r'room is not a portal|portal is deleted)',
    ),
    (_) => 'The bridge had a problem. Try again later.',
  ),
];

String _notConnected(String net) =>
    '${_capital(net)} isn’t connected right now. Try again in a moment.';

/// Words for the Telegram fork's round-video failure [code] (`roundmessage.go`
/// `RoundMediaError` codes and Telegram RPC errors), per the fork review
/// (TF-03): the fallback for bridge binaries that still send the code.
String _roundText(String code) {
  const retry =
      'Telegram couldn’t process this video message. Try sending it again.';
  const unsupported = 'This video can’t be sent as a Telegram video message.';
  switch (code) {
    case 'encode_timeout' ||
        'transfer_timeout' ||
        'temporary_storage' ||
        'media_download_failed' ||
        'upload_failed' ||
        'upload_limit_unknown' ||
        'transport_unavailable' ||
        'round_permission_unknown':
      return retry;
    case 'dispatch_in_progress':
      return 'This video message is still being sent.';
    case 'round_ack_missing':
      return 'Telegram didn’t confirm this video message. It may still '
          'appear in the chat.';
    case 'duration_limit':
      return 'Video messages can be up to 60 seconds long.';
    case 'file_size_limit':
      return 'This video message is too large for Telegram.';
    case 'caption_not_supported':
      return 'Telegram video messages can’t have a caption.';
    case 'editing_not_supported':
      return 'Telegram video messages can’t be edited.';
    case 'restricted_options_unsupported' ||
        'scheduled_send_not_supported' ||
        'scheduling_unsupported':
      return 'Scheduled and view-once video messages aren’t supported yet.';
    case 'round_permission_denied' ||
        'round_forbidden' ||
        'chat_send_roundvideos_forbidden':
      return 'You can’t send video messages in this chat.';
    case 'voice_messages_forbidden':
      return 'This person doesn’t accept voice and video messages.';
    case 'chat_write_forbidden' || 'chat_restricted' || 'chat_admin_required':
      return 'You can’t send messages in this chat.';
    case 'random_id_duplicate' || 'round_already_sent_unmapped':
      return 'This video message was already sent to Telegram.';
  }
  if (code.startsWith('flood_wait') || code.startsWith('slowmode_wait')) {
    return 'Telegram asks you to wait a moment before sending again.';
  }
  if (code.startsWith('invalid_') ||
      code.startsWith('thumbnail_') ||
      const {
        'probe_failed',
        'encode_failed',
        'truncated_encode',
        'unsupported_stream',
        'unsanitized_thumbnail',
      }.contains(code)) {
    return unsupported;
  }
  return 'Telegram didn’t accept this video message.';
}

/// A lower-case snake_case token (`encode_timeout`): a code, not words.
final _snakeCode = RegExp(r'\b[a-z0-9]+_[a-z0-9_]+\b');

/// Keeps a human-looking bridge text: the head of a Go error chain, no
/// parenthetical detail, capitalised, ending with a period.
String? _cleanBridgeSentence(String raw) {
  var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  // "failed to send: context deadline exceeded" → the part before the cause.
  final colon = text.indexOf(': ');
  if (colon > 0) {
    final head = text.substring(0, colon).trim();
    if (head.contains(' ')) text = head;
  }
  text = text.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
  if (!_isSentence(text) ||
      _snakeCode.hasMatch(text) ||
      text.contains(RegExp(r'https?://|[{}<>]'))) {
    return null;
  }
  text = _capital(text);
  return RegExp(r'[.!?…]$').hasMatch(text) ? text : '$text.';
}

String _fallback(ErrorAction action) => switch (action) {
  ErrorAction.send => 'Couldn’t send. Try again.',
  ErrorAction.upload => 'Couldn’t upload this file. Try again.',
  ErrorAction.join => 'Couldn’t join this chat. Try again.',
  ErrorAction.load => 'Couldn’t load this. Try again.',
  ErrorAction.generic => 'Something went wrong. Try again.',
};
