// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_lazy_switcher.dart';
import 'notion_motion.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

/// How a [NotionDeliveryTick] in the sending state shows its clock.
enum NotionSendingClock {
  /// At once (an inbox row).
  shown,

  /// After [NotionMotion.loaderGrace] (a bubble being sent right now).
  delayed,

  /// Not at all: something else shows the progress (an upload ring).
  hidden,
}

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
/// accent. A new glyph morphs in place (the clock shrinks away and the ✓
/// grows in, ✓ → ✓✓ the same way, [NotionLazySwitcher]); "read" only
/// cross-fades the colour. The first build and rows built while scrolling
/// never animate and cost no ticker. [sendingClock] can hold the clock
/// back for [NotionMotion.loaderGrace] (a fast send goes straight from
/// nothing to ✓) or leave it out (an upload shows its own ring); the slot
/// is reserved throughout.
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
    this.sendingClock = NotionSendingClock.shown,
  });

  final NotionDeliveryState state;

  /// Colour of the clock, ✓ and ✓✓; defaults to `textSecondary`. Pass the
  /// row's readable metadata colour on custom backgrounds.
  final Color? color;

  /// Colour of the read ✓✓; defaults to `colors.accent`.
  final Color? readColor;
  final double size;

  /// How [NotionDeliveryState.sending] shows its clock.
  final NotionSendingClock sendingClock;

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
    final icon = Icon(glyphOf(state), size: glyphSize, color: tint);
    return Semantics(
      label: labelOf(state),
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: NotionLazySwitcher(
          // ✓ → ✓✓ in the accent is the same glyph: only the colour fades.
          style: state == NotionDeliveryState.read
              ? NotionLazySwitch.fade
              : NotionLazySwitch.morph,
          alignment: AlignmentDirectional.center,
          child: switch (state == NotionDeliveryState.sending
              ? sendingClock
              : NotionSendingClock.shown) {
            NotionSendingClock.shown => KeyedSubtree(
              key: ValueKey(state),
              child: icon,
            ),
            NotionSendingClock.delayed => NotionDelayedReveal(
              key: ValueKey(state),
              child: icon,
            ),
            NotionSendingClock.hidden => SizedBox.shrink(key: ValueKey(state)),
          },
        ),
      ),
    );
  }
}
