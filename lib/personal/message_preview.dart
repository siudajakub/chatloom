// SPDX-License-Identifier: AGPL-3.0-or-later

/// Short English one-line previews of Matrix events, shared by the inbox,
/// chat search, thread summaries and notifications.
///
/// Stable API:
/// ```dart
/// // Full preview with the sender prefix decided for you:
/// personalEventPreview(event);              // "You: Sticker", "Anna: Photo"
/// // Explicit control (notification titles that already show the sender):
/// personalPreview(event, own: false, group: false); // "Voice message"
/// personalPreview(event, own: true, group: true);   // "You: Photo: caption"
/// personalPreviewLabel(event);              // label only, never a prefix
/// ```
/// Rules: sticker → "Sticker"; image → "Photo" / "Photo: caption"; round
/// video note → "Video message"; GIF → "GIF"; other video → "Video" /
/// "Video: caption"; voice → "Voice message"; other audio → "Audio"; file →
/// "File" / "File: caption"; location → "Location"; poll → "Poll: question";
/// emote → "* text"; text/notice → the plain body. "You: " prefixes every
/// type for own messages (account or own bridge ghost, see
/// [OwnSenderResolver]); other senders get "`<name>`: " in groups and no prefix
/// in DMs. Undecryptable, redacted, state and unknown events keep the SDK's
/// localized fallback without an extra prefix.
library;

import 'package:chatloom/personal/own_sender.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show RoundVideoDescriptor;

const _pollStartTypes = {'org.matrix.msc3381.poll.start', 'm.poll.start'};
const _defaultI18n = MatrixDefaultLocalizations();

String _oneLine(String text) =>
    text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

String? _caption(Event event) {
  final content = event.content;
  final body = content['body'];
  final filename = content['filename'];
  if (body is! String || body.trim().isEmpty) return null;
  // MSC2530: body is a caption only when a separate filename exists.
  if (filename is! String || filename.isEmpty || filename == body) return null;
  return _oneLine(
    event.calcUnlocalizedBody(
      hideReply: true,
      hideEdit: true,
      plaintextBody: true,
      removeMarkdown: true,
    ),
  );
}

String _withCaption(String label, Event event) {
  final caption = _caption(event);
  return caption == null || caption.isEmpty ? label : '$label: $caption';
}

String? _pollQuestion(Map<String, Object?> content) {
  for (final key in _pollStartTypes) {
    final start = content[key];
    if (start is! Map) continue;
    final question = start['question'];
    if (question is! Map) continue;
    for (final field in ['org.matrix.msc1767.text', 'm.text', 'body']) {
      final value = question[field];
      if (value is String && value.trim().isNotEmpty) return _oneLine(value);
      if (value is List) {
        for (final item in value) {
          final text = item is Map ? item['body'] : null;
          if (text is String && text.trim().isNotEmpty) return _oneLine(text);
        }
      }
    }
  }
  return null;
}

bool _isGif(Event event) {
  final info = event.content['info'];
  return info is Map && (info['fi.mau.gif'] == true);
}

/// Label for message-like events; null means "use the SDK fallback".
String? _label(Event event) {
  if (event.redacted) return null;
  if (event.type == EventTypes.Sticker) return 'Sticker';
  if (_pollStartTypes.contains(event.type)) {
    final question = _pollQuestion(event.content);
    return question == null ? 'Poll' : 'Poll: $question';
  }
  if (event.type != EventTypes.Message) return null;
  switch (event.messageType) {
    case MessageTypes.Sticker:
      return 'Sticker';
    case MessageTypes.Image:
      return _withCaption('Photo', event);
    case MessageTypes.Video:
      if (RoundVideoDescriptor.fromContent(event.content) != null) {
        return 'Video message';
      }
      if (_isGif(event)) return _withCaption('GIF', event);
      return _withCaption('Video', event);
    case MessageTypes.Audio:
      return event.content['org.matrix.msc3245.voice'] is Map
          ? 'Voice message'
          : _withCaption('Audio', event);
    case MessageTypes.File:
      return _withCaption('File', event);
    case MessageTypes.Location:
      return 'Location';
    case MessageTypes.Emote:
      return '* ${_body(event)}';
    case MessageTypes.Text:
    case MessageTypes.Notice:
      return _body(event);
    default:
      return null;
  }
}

String _body(Event event) => _oneLine(
  event.calcUnlocalizedBody(
    hideReply: true,
    hideEdit: true,
    plaintextBody: true,
    removeMarkdown: true,
  ),
);

String _fallback(Event event, MatrixLocalizations i18n) => _oneLine(
  event.calcLocalizedBodyFallback(
    i18n,
    hideReply: true,
    hideEdit: true,
    plaintextBody: true,
    removeMarkdown: true,
  ),
);

/// Label only ("Sticker", "Photo: caption", message text, SDK fallback).
String personalPreviewLabel(Event event, {MatrixLocalizations? i18n}) =>
    _label(event) ?? _fallback(event, i18n ?? _defaultI18n);

/// Preview with an explicit prefix decision.
///
/// [own]: sent by the account or an own bridge ghost → "You: ".
/// [group]: show "`<senderName>`: " for other senders (groups, or a DM message
/// from somebody other than the partner). [senderName] defaults to the
/// sender's loaded display name.
String personalPreview(
  Event event, {
  required bool own,
  required bool group,
  String? senderName,
  MatrixLocalizations? i18n,
}) {
  final label = _label(event);
  if (label == null) return _fallback(event, i18n ?? _defaultI18n);
  if (own) return 'You: $label';
  if (!group) return label;
  final name =
      senderName ??
      event.senderFromMemoryOrFallback.calcDisplayname(
        i18n: i18n ?? _defaultI18n,
      );
  return '$name: $label';
}

/// Whether an event's preview needs a sender prefix in its room: always in
/// groups, and in DMs for anybody but the DM partner.
bool personalPreviewShowsSender(Event event) {
  final partner = event.room.directChatMatrixIDForDisplay;
  return partner == null || event.senderId != partner;
}

/// Full preview with own-ghost detection and the room's prefix rule.
String personalEventPreview(
  Event event, {
  String? senderName,
  MatrixLocalizations? i18n,
  OwnSenderResolver? resolver,
}) => personalPreview(
  event,
  own: (resolver ?? OwnSenderResolver.of(event.room.client)).isOwnEvent(event),
  group: personalPreviewShowsSender(event),
  senderName: senderName,
  i18n: i18n,
);
