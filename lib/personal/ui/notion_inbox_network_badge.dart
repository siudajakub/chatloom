// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Diameter of one network badge on a 40 pt inbox avatar (UX-17, FT-12).
const double notionInboxBadgeSize = 18;

/// Glyph inside the badge.
const double _glyph = 12;

/// Ring of page colour that separates the badge from the avatar.
const double _ring = 2;

/// How far a second (merged person) badge peeks out from under the first.
const double _stackShift = 9;

/// Networks worth a badge, in a stable order: "other"/"unknown" carry no
/// identity, so they get none.
List<String> notionBadgeNetworks(Iterable<String> networks) {
  final shown = {
    for (final network in networks)
      if (!const {'other', 'unknown', ''}.contains(network.toLowerCase()))
        network.toLowerCase(),
  }.toList();
  shown.sort((a, b) => notionNetworkLabel(a).compareTo(notionNetworkLabel(b)));
  return shown;
}

/// "On WhatsApp" / "On WhatsApp and Telegram" / "On WhatsApp, Telegram and
/// Signal" for the row announcement; null without networks.
String? notionNetworksAnnouncement(List<String> networks) {
  if (networks.isEmpty) return null;
  final labels = networks.map(notionNetworkLabel).toList();
  if (labels.length == 1) return 'On ${labels.single}';
  return 'On ${labels.sublist(0, labels.length - 1).join(', ')} '
      'and ${labels.last}';
}

/// The network mark at the bottom-end corner of an inbox avatar. One badge
/// for a chat; a merged person on several networks shows two stacked badges
/// (the first two networks), so a merged row never looks like a plain chat.
/// Decorative: the row announces [notionNetworksAnnouncement] instead.
class NotionInboxNetworkBadge extends StatelessWidget {
  const NotionInboxNetworkBadge({super.key, required this.networks});

  final List<String> networks;

  @override
  Widget build(BuildContext context) {
    if (networks.isEmpty) return const SizedBox.shrink();
    final shown = networks.take(2).toList();
    return ExcludeSemantics(
      child: SizedBox(
        key: const ValueKey('notion_inbox_network_badge'),
        width: notionInboxBadgeSize + _stackShift * (shown.length - 1),
        height: notionInboxBadgeSize,
        child: Stack(
          children: [
            // The second network sits behind, towards the start.
            for (final (index, network) in shown.reversed.indexed)
              PositionedDirectional(
                start: index == 0 && shown.length > 1 ? 0 : null,
                end: index == 0 && shown.length > 1 ? null : 0,
                child: _Badge(network: network),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.network});

  final String network;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return Container(
      width: notionInboxBadgeSize,
      height: notionInboxBadgeSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: colors.background, width: _ring),
      ),
      // Monochrome (brand colour only in Vivid), like the dock.
      child: NotionNetworkGlyph(network: network, size: _glyph),
    );
  }
}
