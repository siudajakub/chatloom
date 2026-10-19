// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

class NotionPinnedShortcut {
  final String name;
  final Widget avatar;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int order;
  final bool isGroup;
  const NotionPinnedShortcut({
    required this.name,
    required this.avatar,
    required this.onTap,
    required this.order,
    this.onLongPress,
    this.isGroup = false,
  });
}

class NotionPinnedShortcuts extends StatelessWidget {
  final List<NotionPinnedShortcut> pins;
  const NotionPinnedShortcuts({super.key, required this.pins});
  @override
  Widget build(BuildContext context) {
    if (pins.isEmpty) return const SizedBox.shrink();
    final ordered = List<NotionPinnedShortcut>.of(pins)
      ..sort((a, b) => a.order.compareTo(b.order));
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final height = 58.0 + math.max(44.0, 28 * scale + 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pinned',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = (constraints.maxWidth - 12) / 2;
              return PageView.builder(
                itemCount: (ordered.length + 1) ~/ 2,
                itemBuilder: (context, page) => Row(
                  children: [
                    SizedBox(
                      width: cardWidth,
                      child: _PinnedCard(pin: ordered[page * 2]),
                    ),
                    const SizedBox(width: 12),
                    if (page * 2 + 1 < ordered.length)
                      SizedBox(
                        width: cardWidth,
                        child: _PinnedCard(pin: ordered[page * 2 + 1]),
                      )
                    else
                      SizedBox(width: cardWidth),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PinnedCard extends StatelessWidget {
  final NotionPinnedShortcut pin;
  const _PinnedCard({required this.pin});
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Pinned chat, ${pin.name}',
    child: NotionPressable(
      scale: NotionMotion.pressButton,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: pin.onTap,
          onLongPress: pin.onLongPress,
          onSecondaryTap: pin.onLongPress,
          child: Column(
            children: [
              Container(
                height: 58,
                width: double.infinity,
                color: NotionTokens.cover,
                child: Center(
                  child: SvgPicture.asset(
                    pin.isGroup
                        ? 'assets/notion/pinned/desk.svg'
                        : 'assets/notion/pinned/coffee.svg',
                    height: 48,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      ExcludeSemantics(
                        child: SizedBox.square(
                          dimension: 28,
                          child: pin.avatar,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          pin.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
