// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

/// A one-line muted status under a header title or name (connection
/// status in the inbox and chat headers, as Telegram shows it).
/// Grows in when [status] appears and shrinks away when it clears.
///
/// [busy] puts a small spinner before the text while the app works on it
/// ("Connecting…", "Updating…"). It shows with the line at once: callers
/// show the line itself only after their own grace, so the spinner never
/// flashes on fast work, and it rests after [NotionMotion.loopCap] like
/// every loop; under reduced motion the text says it alone. [onTap] makes
/// the whole line a button (retry while offline); [tapHint] is what a
/// screen reader announces for it.
class NotionStatusLine extends StatefulWidget {
  const NotionStatusLine({
    super.key,
    this.status,
    this.busy = false,
    this.onTap,
    this.tapHint,
  });

  final String? status;
  final bool busy;
  final VoidCallback? onTap;
  final String? tapHint;

  /// Diameter of the [busy] spinner: the cap height of the caption line.
  static const double spinnerSize = 10;

  @override
  State<NotionStatusLine> createState() => _NotionStatusLineState();
}

class _NotionStatusLineState extends State<NotionStatusLine> {
  String? _last;
  bool _lastBusy = false;

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    if (status != null) {
      _last = status;
      _lastBusy = widget.busy;
    }
    final shown = _last;
    if (shown == null) return const SizedBox.shrink();
    final style = context.notion.typography.captionMuted;
    final onTap = status == null ? null : widget.onTap;
    final spinner = _lastBusy && !NotionMotion.reduced(context);
    return NotionSizeReveal(
      visible: status != null,
      revealOnMount: true,
      duration: NotionMotion.short,
      child: NotionFadeThrough(
        duration: NotionMotion.short,
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          key: ValueKey((shown, _lastBusy)),
          liveRegion: true,
          button: onTap != null,
          onTap: onTap,
          onTapHint: onTap == null ? null : widget.tapHint,
          child: NotionTapTarget(
            // The whole line, not only the glyphs, takes the tap; a line
            // without one lets taps through to its header.
            behavior: onTap == null
                ? HitTestBehavior.deferToChild
                : HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: onTap,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              heightFactor: 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (spinner)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: NotionSpace.xxs + NotionSpace.xxs / 2,
                      ),
                      child: NotionDelayedSpinner(
                        size: NotionStatusLine.spinnerSize,
                        strokeWidth: 1.5,
                        delay: Duration.zero,
                        color: style.color,
                      ),
                    ),
                  Flexible(
                    child: Text(
                      shown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
