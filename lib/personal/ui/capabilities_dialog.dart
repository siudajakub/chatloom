// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/bridge_capabilities.dart';

/// The round video label of a Messenger chat: Messenger has no round type,
/// so the recipient sees a square video with the circle in it.
const messengerRoundVideoLabel =
    'Round videos (sent as a square video on Messenger)';

/// A person-readable name of a bridge feature (never the enum identifier).
/// Features added later fall back to their identifier until named here.
/// [network] is the chat's `m.bridge` protocol id, when known.
String bridgeFeatureLabel(BridgeFeature feature, {String? network}) =>
    switch (feature.name) {
      'roundVideo' when network == 'facebook' => messengerRoundVideoLabel,
      'reply' => 'Replies',
      'reaction' => 'Reactions',
      'edit' => 'Editing messages',
      'delete' => 'Deleting messages',
      'audio' => 'Audio files',
      'voice' => 'Voice messages',
      'upload' => 'Files',
      'image' => 'Photos',
      'video' => 'Videos',
      'gif' => 'GIFs',
      'roundVideo' => 'Round videos',
      'sticker' => 'Stickers',
      'poll' => 'Polls',
      'thread' => 'Threads',
      'disappearing' => 'Disappearing messages',
      'location' => 'Location',
      final other => other,
    };

/// Conversation details → "Conversation capabilities": what this chat's
/// network supports, one row per feature, in a glass [NotionDialog].
Future<void> showConversationCapabilitiesDialog(
  BuildContext context, {
  required String Function(BridgeFeature feature) reasonOf,
  String? network,
}) => showNotionCustomDialog<void>(
  context: context,
  builder: (context) => NotionDialog(
    title: 'Conversation capabilities',
    content: SizedBox(
      width: double.infinity,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final feature in BridgeFeature.values)
            NotionListRow(
              title: bridgeFeatureLabel(feature, network: network),
              subtitle: reasonOf(feature),
            ),
        ],
      ),
    ),
    actions: [
      NotionButton.ghost(
        label: 'Close',
        onPressed: () => Navigator.pop(context),
      ),
    ],
  ),
);
