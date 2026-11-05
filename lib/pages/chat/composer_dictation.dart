// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/text_split.dart';
import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart';

/// An acknowledgement from the ordinary send path. Editor changes alone do
/// not prove a send: another action may clear or replace the draft while a
/// trust prompt is open. Bumped only when a message becomes durable (or an
/// explicitly requested formatting command succeeds).
abstract interface class ComposerDictationSendReceiptHost {
  int get durableComposerSends;
}

/// Freezes the destination and composer before opening voice-to-text.
///
/// Audio never enters the message send path. On an explicit Send, only the
/// reviewed text is borrowed by the existing composer, which retains trust,
/// encryption and durable-outbox behaviour. Failed preparation restores only
/// the value this session inserted, never a draft changed by another action.
class ComposerDictationSession {
  ComposerDictationSession({
    required this.host,
    required this.currentHost,
    required this.activeClient,
    required this.mounted,
  }) : room = host.room,
       _client = host.sendingClient,
       _user = host.sendingClient.userID,
       _controller = host.sendController,
       _draft = host.sendController.value,
       _reply = host.replyEvent,
       _edit = host.editEvent,
       _thread = host.activeThreadId,
       _threadLast = host.threadLastEventId,
       _privacyGeneration = PersonalPrivacy.surfaceLockGeneration {
    _lastComposerText = _draft.text;
    _controller.addListener(_draftChanged);
  }

  final ConversationComposerHost host;
  final ConversationComposerHost Function() currentHost;
  final Client Function() activeClient;
  final bool Function() mounted;
  final Room room;
  final Client _client;
  final String? _user;
  final TextEditingController _controller;
  final TextEditingValue _draft;
  final Event? _reply;
  final Event? _edit;
  final String? _thread;
  final String? _threadLast;
  final int _privacyGeneration;
  bool _revoked = false;
  bool _writing = false;
  bool _sending = false;
  bool _disposed = false;
  bool _sent = false;
  int? _sendGeneration;
  late String _lastComposerText;

  void _draftChanged() {
    // The dialog owns its separate editor. Any outside edit before Send
    // permanently revokes this session, even if that edit is later undone.
    if (_writing) return;
    final text = _controller.text;
    if (text == _lastComposerText) return;
    _lastComposerText = text;
    final receipts = host is ComposerDictationSendReceiptHost
        ? host as ComposerDictationSendReceiptHost
        : null;
    if (_sending && receipts != null) {
      if (receipts.durableComposerSends == _sendGeneration) _revoked = true;
    } else if (_controller.text != _draft.text) {
      _revoked = true;
    }
  }

  bool get _sameDestination =>
      !_disposed &&
      mounted() &&
      identical(currentHost(), host) &&
      identical(host.room, room) &&
      identical(host.sendController, _controller) &&
      identical(host.sendingClient, _client) &&
      identical(activeClient(), _client) &&
      _client.userID == _user;

  /// Checked before recording, uploading and sending. A changed destination
  /// cannot become valid again by switching back to it.
  bool get valid {
    if (_revoked || _sent) return false;
    if (!_sameDestination) {
      _revoked = true;
      return false;
    }
    final same =
        identical(host.replyEvent, _reply) &&
        identical(host.editEvent, _edit) &&
        host.activeThreadId == _thread &&
        host.threadLastEventId == _threadLast &&
        PersonalPrivacy.surfaceUnlocked &&
        PersonalPrivacy.surfaceLockGeneration == _privacyGeneration &&
        (_sending || host.composerEnabled) &&
        (_sending || _controller.text == _draft.text);
    if (!same) _revoked = true;
    return same;
  }

  /// The ordinary long-message flow asks asynchronously through a snackbar.
  /// The modal keeps this text for editing instead of creating a deferred
  /// resend that could outlive its destination or duplicate a later draft.
  String? validateText(String text, {bool polish = false}) {
    final limit = maxTextLengthOf(room);
    if (limit == null || text.length <= limit) return null;
    return polish
        ? 'Skróć wiadomość do $limit znaków przed wysłaniem.'
        : 'Shorten this message to $limit characters before sending.';
  }

  Future<bool> send(String text) async {
    if (_sending || !valid || text.trim().isEmpty) return false;
    if (validateText(text) != null) return false;
    if (host is! ComposerDictationSendReceiptHost) return false;
    final receipts = host as ComposerDictationSendReceiptHost;
    final generation = receipts.durableComposerSends;
    _sendGeneration = generation;
    _sending = true;
    try {
      _write(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      if (!valid) return false;
      await host.send();
      // A successful send may already have freed the composer for a new
      // draft. Do not inspect or restore that draft after a durable receipt.
      if (receipts.durableComposerSends != generation) {
        _sent = true;
        return true;
      }
      return false;
    } finally {
      if (!_sent && _sameDestination && _controller.text == text) {
        _write(_draft);
      }
      _sending = false;
    }
  }

  void _write(TextEditingValue value) {
    _writing = true;
    try {
      _lastComposerText = value.text;
      _controller.value = value;
      // This is a temporary value for the send path, not a composer edit.
      // Its normal change callback would schedule draft persistence, emit
      // typing and, on restoring an empty merged draft, release its source.
      // The durable send path already updates/persists the remaining draft.
    } finally {
      _writing = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _controller.removeListener(_draftChanged);
    _disposed = true;
  }
}
