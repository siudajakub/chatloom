// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:fluffychat/personal/ui/notion_network_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'conversation_motion.dart';

/// Presentation only: the caller retains the editor, controller, focus and IME.
///
/// Only the source changes slots at the compact breakpoint. In particular the
/// editor's ancestors and child index stay identical through a resize.
class CompactComposer extends StatelessWidget {
  final Widget input;
  final Widget source;
  final Widget addAction;
  final Widget primaryAction;
  final double sourceWidth;
  final Widget? contextPreview;

  const CompactComposer({
    super.key,
    required this.input,
    required this.source,
    required this.addAction,
    required this.primaryAction,
    this.sourceWidth = 130,
    this.contextPreview,
  }) : assert(sourceWidth >= 0);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final chip = source;
      final measuredSourceWidth = math.max(
        sourceWidth,
        chip is ConversationSourceChip ? chip.preferredWidth(context) : 0.0,
      );
      // Insets + both 48dp actions + gaps + divider + editor padding.
      final inline = constraints.maxWidth >= measuredSourceWidth + 253;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Keep both slots present, including when there is no preview.
            contextPreview ?? const SizedBox.shrink(),
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: 52,
                end: 52,
                bottom: inline ? 0 : 4,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: inline ? const SizedBox.shrink() : source,
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox.square(dimension: 48, child: addAction),
                const SizedBox(width: 4),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 50),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: inline ? measuredSourceWidth : 0,
                            child: inline ? source : const SizedBox.shrink(),
                          ),
                          SizedBox(
                            width: inline ? 1 : 0,
                            height: 24,
                            child: ColoredBox(color: colors.outlineVariant),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: input,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox.square(
                  dimension: 48,
                  child: AnimatedSwitcher(
                    duration: ConversationMotion.reduced(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 140),
                    child: primaryAction,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// A persistent sending-source label. It never owns or changes a send target.
class ConversationSourceChip extends StatelessWidget {
  final String network;
  final String? label;
  final bool locked;
  final VoidCallback? onPressed;
  final bool available;

  const ConversationSourceChip({
    super.key,
    required this.network,
    this.label,
    this.locked = false,
    this.onPressed,
    this.available = true,
  });

  String get _name => label ?? notionNetworkLabel(network);
  bool get _selectable => available && !locked && onPressed != null;
  TextStyle get _style =>
      const TextStyle(fontSize: 13, fontWeight: FontWeight.w500);

  /// Includes the actual label and system text scaling, rather than guessing
  /// from the network identifier or clipping the name to an icon.
  double preferredWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: _name,
        style: DefaultTextStyle.of(context).style.merge(_style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width =
        painter.width + 16 + 20 + 6 + (locked || _selectable ? 22 : 0);
    painter.dispose();
    return width.ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final description = locked
        ? 'Replying via $_name'
        : !available
        ? '$_name, source unavailable'
        : _selectable
        ? '$_name, choose sending source'
        : 'Sending via $_name';
    return Semantics(
      label: description,
      button: onPressed != null && !locked,
      enabled: onPressed != null && !locked ? available : null,
      onTap: _selectable ? onPressed : null,
      excludeSemantics: true,
      child: Tooltip(
        message: description,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: _selectable ? onPressed : null,
            borderRadius: BorderRadius.circular(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: IconTheme.merge(
                  data: IconThemeData(
                    color: available
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).disabledColor,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NotionNetworkGlyph(
                        network: network.toLowerCase(),
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _name,
                          style: _style.copyWith(
                            color: available
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context).disabledColor,
                          ),
                        ),
                      ),
                      if (locked || _selectable) ...[
                        const SizedBox(width: 6),
                        Icon(
                          locked ? Icons.lock_outline : Icons.expand_more,
                          size: 16,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Leave room for the header, source and reply while the keyboard is visible.
int conversationComposerMaxLines(
  BuildContext context, {
  bool hasContext = false,
}) {
  final media = MediaQuery.of(context);
  final available =
      media.size.height -
      media.viewInsets.bottom -
      media.padding.vertical -
      56 -
      (hasContext ? 150 : 90);
  return (available / media.textScaler.scale(24)).floor().clamp(1, 4);
}
