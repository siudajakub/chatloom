// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// A centred service line in the timeline (Telegram's "Anna joined the
/// group"): state events and the unverified-devices notice. The same
/// opaque `surface` block and muted caption as `ConversationDayChip`, so it
/// reads on the plain page, private palettes and wallpapers alike; `lg`
/// corners (a pill on one line, a rounded block when it wraps).
class ConversationServiceChip extends StatelessWidget {
  final InlineSpan text;
  final bool strikeThrough;

  const ConversationServiceChip({
    super.key,
    required this.text,
    this.strikeThrough = false,
  });

  /// An inline action inside a service line ("Check", "more events"): the
  /// accent, no underline (Telegram's service links).
  static TextSpan link(
    BuildContext context, {
    required String text,
    required GestureRecognizer recognizer,
  }) => TextSpan(
    text: text,
    recognizer: recognizer,
    style: TextStyle(
      color: context.notion.palette.accent,
      fontWeight: FontWeight.w500,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.xs,
        vertical: NotionSpace.xxs,
      ),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: notion.colors.surface,
            borderRadius: NotionRadius.lgAll,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NotionSpace.sm,
              vertical: NotionSpace.xxs,
            ),
            child: Text.rich(
              text,
              textAlign: TextAlign.center,
              style: notion.typography.captionMuted.copyWith(
                decoration: strikeThrough ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
