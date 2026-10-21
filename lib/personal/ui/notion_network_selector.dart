// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

String? _networkGlyphKey(String? network) => switch (network?.toLowerCase()) {
  'facebookgo' || 'facebook' => 'messenger',
  'instagramgo' => 'instagram',
  final value => value,
};

IconData notionNetworkIcon(String? network) =>
    switch (_networkGlyphKey(network)) {
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
    final glyph = _networkGlyphKey(network);
    if (![
      'whatsapp',
      'slack',
      'instagram',
      'messenger',
      'facebook',
    ].contains(glyph)) {
      return Icon(notionNetworkIcon(network), size: size);
    }
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _NetworkGlyphPainter(
          glyph!,
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

/// Production selector; the modal route's barrier consumes the outside tap.
Future<String?> showNotionNetworkSelector(
  BuildContext context, {
  required Rect anchor,
  required List<String> networks,
  required String? selected,
  required ValueChanged<String?> onSelected,
  InboxFilter selectedView = InboxFilter.inbox,
  ValueChanged<InboxFilter>? onViewSelected,
  VoidCallback? onManageNetworks,
}) {
  // Grow from the dock pill: the scale origin is the middle of the pill's
  // top edge, in the root navigator's coordinates (the same space as
  // [anchor]).
  final root = Navigator.of(context, rootNavigator: true).context;
  final window =
      (root.findRenderObject() as RenderBox?)?.size ??
      MediaQuery.sizeOf(context);
  final origin = Offset(anchor.center.dx, anchor.top);
  return showNotionPopover<String>(
    context: context,
    alignment: window.isEmpty
        ? Alignment.bottomRight
        : Alignment(
            (origin.dx / window.width * 2 - 1).clamp(-1.0, 1.0),
            (origin.dy / window.height * 2 - 1).clamp(-1.0, 1.0),
          ),
    builder: (context) => LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final width = math.min(
          constraints.maxWidth - 32,
          scale > 1.4 ? 300.0 : 196.0,
        );
        final bottom = math.max(
          16.0,
          constraints.maxHeight - anchor.top + NotionSpace.xs,
        );
        final right = math.max(16.0, constraints.maxWidth - anchor.right);
        final maxHeight = math.max(
          96.0,
          constraints.maxHeight -
              bottom -
              MediaQuery.paddingOf(context).top -
              16,
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
                    // One glass surface: tint, hairline and blur once the
                    // popover has grown (DESIGN.md "Glass"). No pointer, like
                    // Telegram and Messenger menus: the panel grows from the
                    // dock pill, and a separate pointer could not share the
                    // panel's blur (it painted a translucent, unblurred patch
                    // over the dock).
                    child: NotionGlassPanel(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxHeight),
                        child: SingleChildScrollView(
                          child: NotionNetworkMenu(
                            networks: networks,
                            selected: selected,
                            selectedView: selectedView,
                            onViewSelected: onViewSelected == null
                                ? null
                                : (view) {
                                    Navigator.of(context).pop();
                                    onViewSelected(view);
                                  },
                            onManageNetworks: onManageNetworks == null
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    onManageNetworks();
                                  },
                            onSelected: (network) {
                              onSelected(network);
                              Navigator.of(context).pop(network);
                            },
                          ),
                        ),
                      ),
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
}

class NotionNetworkMenu extends StatelessWidget {
  final List<String> networks;
  final String? selected;
  final ValueChanged<String?> onSelected;
  final InboxFilter selectedView;
  final ValueChanged<InboxFilter>? onViewSelected;
  final VoidCallback? onManageNetworks;
  const NotionNetworkMenu({
    super.key,
    required this.networks,
    required this.selected,
    required this.onSelected,
    this.selectedView = InboxFilter.inbox,
    this.onViewSelected,
    this.onManageNetworks,
  });
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    // Rows settle in one after another while the popover grows.
    children: NotionEntrance.stagger(
      _children(context),
      rise: NotionMotion.rise / 2,
      afterRoute: false,
    ),
  );

  List<Widget> _children(BuildContext context) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(12, 13, 12, 12),
      child: Text(
        'Show chats',
        style: NotionTokens.body.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    if (onViewSelected != null) ...[
      for (final view in [
        InboxFilter.inbox,
        InboxFilter.groups,
        InboxFilter.ignored,
        InboxFilter.technical,
      ])
        NotionGlassMenuRow(
          selected: selectedView == view,
          title: view == InboxFilter.inbox ? 'Main list' : inboxViewLabel(view),
          leading: Icon(switch (view) {
            InboxFilter.groups => Icons.group_outlined,
            InboxFilter.ignored => Icons.visibility_off_outlined,
            InboxFilter.technical => Icons.build_outlined,
            _ => Icons.chat_bubble_outline,
          }),
          trailing: selectedView == view
              ? const Icon(Icons.check, size: NotionSize.icon)
              : null,
          onTap: () => onViewSelected!(view),
        ),
      const NotionGlassDivider(vertical: false),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          NotionSpace.sm,
          NotionSpace.xs,
          NotionSpace.sm,
          NotionSpace.xxs,
        ),
        child: Text('Networks', style: context.notion.typography.sectionLabel),
      ),
    ],
    _option(context, null),
    for (final network in networks.toSet()) _option(context, network),
    if (onManageNetworks != null) ...[
      const NotionGlassDivider(vertical: false),
      NotionGlassMenuRow(
        leading: const Icon(Icons.tune),
        title: 'Manage networks',
        onTap: onManageNetworks,
      ),
    ],
    const SizedBox(height: NotionSpace.xxs + 2),
  ];

  Widget _option(BuildContext context, String? network) {
    final active = selected == network;
    final name = network == null ? 'All networks' : notionNetworkLabel(network);
    return NotionGlassMenuRow(
      selected: active,
      leading: NotionNetworkGlyph(network: network, size: 23),
      title: name,
      trailing: active ? const Icon(Icons.check, size: NotionSize.icon) : null,
      onTap: () => onSelected(network),
    );
  }
}
