// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/message_deletion.dart'
    show bridgedNetworkLabel;
import 'package:chatloom/personal/capabilities.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Long texts on networks with a message length limit (BR-05):
/// `max_text_length` in the bridge's declaration (Telegram 4,096,
/// Instagram 1,000, Messenger 20,000, Slack 40,000, WhatsApp 65,536).
/// bridgev2 does not check it, so an over-long text used to end as "Not
/// delivered". Telegram's own apps split such a text into several messages;
/// ChatLoom offers the same split and sends the parts in order.
///
/// Lengths are UTF-16 code units, the unit Telegram counts in (an emoji
/// outside the BMP counts twice), so the count never undershoots a network
/// that counts code points.

/// Where the first part of [text] ends when no part may be longer than
/// [limit]: the end offset (exclusive) of the longest prefix that ends at a
/// paragraph break, else a line break, else the end of a sentence, else a
/// space, and never inside a grapheme or (when avoidable) an open Markdown
/// code block. Breaks in the first third of the window are skipped, so a
/// part is never tiny. Returns [text]'s length when it fits.
int firstTextPartEnd(String text, int limit) {
  assert(limit > 0);
  if (text.length <= limit) return text.length;
  // The longest grapheme-safe window.
  var window = 0;
  for (final grapheme in text.characters) {
    if (window + grapheme.length > limit) break;
    window += grapheme.length;
  }
  if (window == 0) {
    // A single grapheme longer than the limit: cut at code points.
    window = limit;
    final unit = text.codeUnitAt(window - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) window--;
    return window <= 0 ? 1 : window;
  }
  final minimum = window ~/ 3;
  final prefix = text.substring(0, window);

  final fences = [for (final m in '```'.allMatches(prefix)) m.start];
  bool outsideCode(int end) =>
      fences.where((start) => start + 3 <= end).length.isEven;

  int? lastBreak(RegExp pattern, {bool keepMatch = false, bool code = false}) {
    int? best;
    for (final match in pattern.allMatches(prefix)) {
      final end = keepMatch ? match.end : match.start;
      if (end < minimum || end == 0) continue;
      if (code || outsideCode(end)) best = end;
    }
    return best;
  }

  return lastBreak(RegExp(r'\n[ \t]*\n')) ??
      lastBreak(RegExp(r'\n')) ??
      // The sentence's closing mark stays with its sentence.
      lastBreak(RegExp(r'[.!?…。！？]["”’)\]]*(?=\s)'), keepMatch: true) ??
      lastBreak(RegExp(r'\s')) ??
      // A code block longer than the limit: at least between its lines.
      lastBreak(RegExp(r'\n'), code: true) ??
      lastBreak(RegExp(r'\s'), code: true) ??
      window;
}

/// [text] as consecutive parts of at most [limit] UTF-16 units, split by
/// [firstTextPartEnd]; whitespace at the breaks is dropped. Concatenating
/// the parts with the dropped whitespace gives [text] back.
List<String> splitLongText(String text, int limit) {
  final parts = <String>[];
  var rest = text.trim();
  while (rest.isNotEmpty) {
    final end = firstTextPartEnd(rest, limit);
    final part = rest.substring(0, end).trimRight();
    if (part.isNotEmpty) parts.add(part);
    rest = rest.substring(end).trimLeft();
  }
  return parts;
}

/// The longest text message [room]'s network takes, or null.
int? maxTextLengthOf(Room room) => RoomCapabilities.maxTextLength(room);

String _count(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// One composer's long-message flow: the first send of an over-long text
/// offers the split (a snackbar with "Send as N messages"; the draft stays
/// as it is, so there is nothing to undo), the approved send takes the
/// first part, and each following part goes once the previous one is
/// durable in the outbox, in order. Anything the user changes in the
/// remaining text stops the sequence; the rest stays in the composer.
class LongMessageSplitter {
  /// The composer text the user agreed to send in parts.
  String? _approved;

  /// The text expected in the composer after the current part.
  String? _remainder;

  /// What to send now for the composer's [text] in [room]: [text] itself
  /// when it fits (or is an edit or a command, left to the network), its
  /// first part when splitting is approved, or null when the user is asked
  /// first ([resend] runs on approval) or the edit is too long.
  String? prepare(
    BuildContext context,
    Room room,
    String text, {
    required bool editing,
    required bool command,
    required VoidCallback resend,
  }) {
    _remainder = null;
    final limit = maxTextLengthOf(room);
    if (limit == null || text.length <= limit || command) {
      if (_approved == text || limit == null || text.length <= limit) {
        _approved = null;
      }
      return text;
    }
    final network = bridgedNetworkLabel(room) ?? 'This network';
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (editing) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '$network allows ${_count(limit)} characters in a message; '
            'this edit has ${_count(text.length)}. Shorten it to save it.',
          ),
        ),
      );
      return null;
    }
    if (_approved == text) {
      final trimmed = text.trimLeft();
      final end = firstTextPartEnd(trimmed, limit);
      final part = text
          .substring(0, text.length - trimmed.length + end)
          .trimRight();
      _remainder = text.substring(part.length).trimLeft();
      if (_remainder!.isEmpty) _remainder = null;
      return part;
    }
    final parts = splitLongText(text, limit).length;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '$network allows ${_count(limit)} characters in a message. '
            'Send this as $parts messages?',
          ),
          action: SnackBarAction(
            label: 'Send as $parts',
            onPressed: () {
              _approved = text;
              resend();
            },
          ),
        ),
      );
    return null;
  }

  /// After a part became durable: when the composer now holds the expected
  /// rest (whitespace at the break aside), [next] gets it to put back
  /// without that whitespace and send. Otherwise the sequence ends.
  void continueWith(String composer, void Function(String rest) next) {
    final rest = _remainder;
    _remainder = null;
    if (rest == null) {
      _approved = null;
      return;
    }
    if (composer.trimLeft() != rest) {
      _approved = null;
      return;
    }
    _approved = rest;
    // After the current send has fully returned, so the next part runs
    // through the ordinary send path (and the outbox keeps the order).
    unawaited(Future<void>(() => next(rest)));
  }
}
