// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'package:fluffychat/personal/ui/notion_network_filter.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

IconData notionNetworkIcon(String? network) => switch (network) {
  null => Icons.hub_outlined,
  'slack' => Icons.tag,
  'instagram' => Icons.camera_alt_outlined,
  'telegram' => Icons.send_outlined,
  'whatsapp' ||
  'messenger' ||
  'facebook' ||
  'signal' => Icons.chat_bubble_outline,
  'discord' => Icons.headset_mic_outlined,
  'sms' || 'imessage' => Icons.sms_outlined,
  _ => Icons.language_outlined,
};

/// Restrained monochrome identifiers, with the actual network kept in text.
class NotionNetworkGlyph extends StatelessWidget {
  final String? network;
  final double size;
  const NotionNetworkGlyph({super.key, this.network, this.size = 24});
  @override
  Widget build(BuildContext context) {
    if (![
      'whatsapp',
      'slack',
      'instagram',
      'messenger',
      'facebook',
    ].contains(network)) {
      return Icon(notionNetworkIcon(network), size: size);
    }
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _NetworkGlyphPainter(
          network!,
          Theme.of(context).colorScheme.onSurface,
          Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
    );
  }
}

class _NetworkGlyphPainter extends CustomPainter {
  final String network;
  final Color color;
  final Color background;
  const _NetworkGlyphPainter(this.network, this.color, this.background);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (network == 'slack') {
      stroke.strokeWidth = 5;
      for (final endpoints in [
        [const Offset(13, 3), const Offset(13, 14)],
        [const Offset(21, 18), const Offset(21, 29)],
        [const Offset(18, 13), const Offset(29, 13)],
        [const Offset(3, 21), const Offset(14, 21)],
      ]) {
        canvas.drawLine(endpoints[0], endpoints[1], stroke);
      }
      final dot = Paint()..color = color;
      for (final center in [
        const Offset(5, 13),
        const Offset(21, 5),
        const Offset(27, 21),
        const Offset(13, 27),
      ]) {
        canvas.drawCircle(center, 2.5, dot);
      }
    } else if (network == 'instagram') {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(3, 3, 26, 26),
          const Radius.circular(7),
        ),
        stroke,
      );
      canvas.drawCircle(const Offset(16, 16), 6, stroke);
      canvas.drawCircle(const Offset(24, 8), 1.2, Paint()..color = color);
    } else {
      final filled = network == 'messenger' || network == 'facebook';
      final outline = Path()
        ..moveTo(5, 24)
        ..lineTo(3, 29)
        ..lineTo(10, 27)
        ..arcTo(const Rect.fromLTWH(3, 2, 26, 26), 2.05, -5.75, false)
        ..close();
      canvas.drawPath(outline, filled ? (Paint()..color = color) : stroke);
      if (filled) {
        final bolt = Path()
          ..moveTo(8, 20)
          ..lineTo(15, 11)
          ..lineTo(19, 15)
          ..lineTo(25, 10)
          ..lineTo(18, 21)
          ..lineTo(14, 17)
          ..close();
        canvas.drawPath(bolt, Paint()..color = background);
      } else {
        final phone = Path()
          ..moveTo(11, 8)
          ..lineTo(9, 10)
          ..quadraticBezierTo(8, 15, 16, 22)
          ..quadraticBezierTo(21, 26, 24, 20)
          ..lineTo(19, 17)
          ..lineTo(17, 19)
          ..quadraticBezierTo(12, 16, 12, 13)
          ..lineTo(14, 12)
          ..close();
        canvas.drawPath(phone, Paint()..color = color);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NetworkGlyphPainter oldDelegate) =>
      oldDelegate.network != network ||
      oldDelegate.color != color ||
      oldDelegate.background != background;
}

class _MenuPointerPainter extends CustomPainter {
  final Color fill;
  final Color border;
  const _MenuPointerPainter(this.fill, this.border);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width / 2, size.height)
        ..lineTo(size.width, 0),
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _MenuPointerPainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.border != border;
}

/// Production selector; the modal route's barrier consumes the outside tap.
Future<String?> showNotionNetworkSelector(
  BuildContext context, {
  required Rect anchor,
  required List<String> networks,
  required String? selected,
  required ValueChanged<String?> onSelected,
}) => showGeneralDialog<String>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Dismiss network selector',
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      final width = math.min(
        constraints.maxWidth - 32,
        scale > 1.4 ? 300.0 : 196.0,
      );
      final bottom = math.max(16.0, constraints.maxHeight - anchor.top + 12);
      final right = math.max(16.0, constraints.maxWidth - anchor.right);
      final maxHeight = math.max(
        96.0,
        constraints.maxHeight - bottom - MediaQuery.paddingOf(context).top - 16,
      );
      return Stack(
        children: [
          Positioned(
            right: right,
            bottom: bottom,
            width: width,
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
              },
              child: Actions(
                actions: {
                  DismissIntent: CallbackAction<DismissIntent>(
                    onInvoke: (_) {
                      Navigator.of(context).pop();
                      return null;
                    },
                  ),
                },
                child: Focus(
                  autofocus: true,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Material(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                          side: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: maxHeight),
                          child: SingleChildScrollView(
                            child: NotionNetworkMenu(
                              networks: networks,
                              selected: selected,
                              onSelected: (network) {
                                onSelected(network);
                                Navigator.of(context).pop(network);
                              },
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: -9,
                        right:
                            (constraints.maxWidth -
                                    right -
                                    anchor.center.dx -
                                    9)
                                .clamp(12.0, width - 30),
                        child: CustomPaint(
                          size: const Size(18, 9),
                          painter: _MenuPointerPainter(
                            Theme.of(context).colorScheme.surfaceContainer,
                            Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  ),
);

class NotionNetworkMenu extends StatelessWidget {
  final List<String> networks;
  final String? selected;
  final ValueChanged<String?> onSelected;
  const NotionNetworkMenu({
    super.key,
    required this.networks,
    required this.selected,
    required this.onSelected,
  });
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 13, 12, 12),
        child: Text(
          'Show chats',
          style: NotionTokens.body.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      _option(context, null),
      for (final network in networks) _option(context, network),
      const SizedBox(height: 4),
    ],
  );

  Widget _option(BuildContext context, String? network) {
    final active = selected == network;
    final name = network == null ? 'All chats' : notionNetworkLabel(network);
    return Semantics(
      selected: active,
      button: true,
      label: name,
      child: Material(
        color: active
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Colors.transparent,
        child: InkWell(
          onTap: () => onSelected(network),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                NotionNetworkGlyph(network: network, size: 23),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(name, style: const TextStyle(fontSize: 15)),
                ),
                const SizedBox(width: 6),
                if (active) const Icon(Icons.check, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
