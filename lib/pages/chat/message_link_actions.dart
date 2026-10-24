// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/events/link_preview.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The first web link of [display] (FX-20): the first `http(s)` URL in its
/// text or caption, else the link of its bridged preview (`matched_url`).
/// Null for redacted messages and messages without a link. Detected with
/// the bubbles' own linkify options, so it copies what is shown as a link.
String? messageFirstLink(Event display) {
  if (display.redacted) return null;
  final body = display.body;
  if (body.contains('.')) {
    final elements = const UrlLinkifier().parse([
      TextElement(body),
    ], const LinkifyOptions(humanize: false));
    for (final element in elements) {
      if (element is! UrlElement) continue;
      final uri = Uri.tryParse(element.url);
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        return element.url;
      }
    }
  }
  return BridgedLinkPreview.fromContent(display.content).firstOrNull?.url;
}

/// "Copy link" in a message's long-press menu when it carries a link
/// (Telegram's link sheet offers Open / Copy; the bubble already opens a
/// link on tap). [noticeContext] must outlive the menu (the chat page).
List<ConversationMessageAction> messageLinkActions(
  BuildContext noticeContext,
  Event display,
) {
  final link = messageFirstLink(display);
  if (link == null) return const [];
  return [
    ConversationMessageAction(
      icon: Icons.link,
      label: 'Copy link',
      onSelected: () {
        unawaited(Clipboard.setData(ClipboardData(text: link)));
        if (noticeContext.mounted) {
          unawaited(showCopiedNotice(noticeContext, 'Link copied'));
        }
      },
    ),
  ];
}
