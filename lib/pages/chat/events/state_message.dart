// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_service_chip.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class StateMessage extends StatelessWidget {
  final Event event;
  final void Function()? onExpand;
  final bool isCollapsed;
  const StateMessage(
    this.event, {
    this.onExpand,
    this.isCollapsed = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // A ticker only once the row collapses or expands (UI-11): rows that
    // never toggle cost no controller, and reduced motion snaps.
    return NotionSizeReveal(
      visible: !isCollapsed,
      alignment: Alignment.center,
      child: ConversationServiceChip(
        strikeThrough: event.redacted,
        text: TextSpan(
          children: [
            // Undecryptable messages are bubbles (UndecryptableMessage); a
            // redacted encrypted event is a plain state line like the rest.
            TextSpan(
              text: event.calcLocalizedBodyFallback(
                MatrixLocals(L10n.of(context)),
              ),
            ),
            if (onExpand != null) ...[
              const TextSpan(text: '\n'),
              ConversationServiceChip.link(
                context,
                recognizer: TapGestureRecognizer()..onTap = onExpand,
                text: L10n.of(context).moreEvents,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
