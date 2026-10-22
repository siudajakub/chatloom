// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_lazy_switcher.dart';
import 'notion_tokens.dart';

/// How far an own message got, as its ticks show it.
enum NotionDeliveryState {
  /// Still on its way to the server (Telegram's clock).
  sending,

  /// The server has it: one tick.
  sent,

  /// The bridged network accepted it: two ticks in the metadata colour.
  delivered,

  /// Someone on the other side read it: two ticks in the accent.
  read,
}

/// Telegram/Signal delivery ticks beside the time of an own message and
/// before the time of an inbox row whose last message is own: a clock while
/// sending, ✓ sent, ✓✓ delivered, ✓✓ in the accent once read.
///
/// Quiet by design: a glyph in the metadata colour, only "read" takes the
/// accent. A change of state cross-fades once in place
/// ([NotionLazySwitcher]); the first build and rows built while scrolling
/// never animate and cost no ticker.
///
/// ```dart
/// NotionDeliveryTick(state: NotionDeliveryState.delivered, color: muted)
/// ```
class NotionDeliveryTick extends StatelessWidget {
  const NotionDeliveryTick({
    super.key,
    required this.state,
    this.color,
    this.readColor,
    this.size = NotionDeliveryTick.defaultSize,
  });

  final NotionDeliveryState state;

  /// Colour of the clock, ✓ and ✓✓; defaults to `textSecondary`. Pass the
  /// row's readable metadata colour on custom backgrounds.
  final Color? color;

  /// Colour of the read ✓✓; defaults to `colors.accent`.
  final Color? readColor;
  final double size;

  /// A hair larger than the 11–13 pt time it sits beside, like Telegram's.
  static const double defaultSize = 14;

  /// Screen-reader word for [state].
  static String labelOf(NotionDeliveryState state) => switch (state) {
    NotionDeliveryState.sending => 'Sending',
    NotionDeliveryState.sent => 'Sent',
    NotionDeliveryState.delivered => 'Delivered',
    NotionDeliveryState.read => 'Read',
  };

  static IconData glyphOf(NotionDeliveryState state) => switch (state) {
    NotionDeliveryState.sending => Icons.schedule,
    NotionDeliveryState.sent => Icons.done,
    NotionDeliveryState.delivered || NotionDeliveryState.read => Icons.done_all,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final tint = state == NotionDeliveryState.read
        ? readColor ?? colors.accent
        : color ?? colors.textSecondary;
    // The clock is drawn a little smaller so its circle matches the ticks'
    // optical weight.
    final glyphSize = state == NotionDeliveryState.sending ? size - 2 : size;
    return Semantics(
      label: labelOf(state),
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: NotionLazySwitcher(
          alignment: AlignmentDirectional.center,
          child: Icon(
            glyphOf(state),
            key: ValueKey(state),
            size: glyphSize,
            color: tint,
          ),
        ),
      ),
    );
  }
}
