// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/copy_notice.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/network_action_flows.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The contact card of a person seen through a bridge (FX-05; Telegram's and
/// Messenger's profile): name, photo, network, the network's own phone
/// number or username, and what can be done with them. A bridged person's
/// Matrix ID is the bridge's ghost account, so it is neither shown (unless
/// developer options are on) nor shared as a `matrix.to` link.

enum ContactIdentifierKind { phone, username }

@immutable
class ContactIdentifier {
  final ContactIdentifierKind kind;

  /// What the user reads and copies: `+48…` or `@name`.
  final String value;
  const ContactIdentifier(this.kind, this.value);

  @override
  bool operator ==(Object other) =>
      other is ContactIdentifier && other.kind == kind && other.value == value;
  @override
  int get hashCode => Object.hash(kind, value);
  @override
  String toString() => 'ContactIdentifier(${kind.name}, redacted)';
}

/// The network identifiers a bridge put in [userId]'s member state in
/// [room] (`com.beeper.bridge.identifiers`: `tel:+…`, `telegram:<name>`,
/// `instagram:<name>`); internal ids (`slack-internal:…`) are left out.
/// Local state only, nothing is fetched.
List<ContactIdentifier> contactIdentifiers(Room room, String userId) {
  final content = room.getState(EventTypes.RoomMember, userId)?.content;
  final raw = content?['com.beeper.bridge.identifiers'];
  if (raw is! List) return const [];
  final result = <ContactIdentifier>[];
  for (final value in raw.whereType<String>()) {
    final split = value.indexOf(':');
    if (split <= 0 || split == value.length - 1) continue;
    final scheme = value.substring(0, split).toLowerCase();
    final rest = value.substring(split + 1).trim();
    if (rest.isEmpty) continue;
    final ContactIdentifier identifier;
    if (scheme == 'tel') {
      final digits = rest.replaceAll(RegExp(r'[^\d+]'), '');
      if (digits.replaceAll('+', '').length < 5) continue;
      identifier = ContactIdentifier(
        ContactIdentifierKind.phone,
        digits.startsWith('+') ? digits : '+$digits',
      );
    } else if (scheme.endsWith('-internal') ||
        scheme == 'mxid' ||
        rest.contains(' ')) {
      continue;
    } else {
      identifier = ContactIdentifier(
        ContactIdentifierKind.username,
        '@${rest.replaceFirst(RegExp('^@'), '')}',
      );
    }
    if (!result.contains(identifier)) result.add(identifier);
    if (result.length == 6) break;
  }
  return result;
}

/// Whether [userId] is a bridge bot of [room] (never a contact).
bool isBridgeBotMember(Room room, String userId) =>
    bridgeBotsOf(room).contains(userId) ||
    room
            .getState(EventTypes.RoomMember, userId)
            ?.content['com.beeper.bridge.is_bridge_bot'] ==
        true;

/// A joined bridged room that shows [userId] as a remote person, the DM
/// portal first; null for native Matrix users and bridge bots.
Room? bridgedContactRoom(Client client, String userId) {
  if (userId == client.userID) return null;
  Room? found;
  for (final room in client.rooms) {
    if (room.membership != Membership.join || !isBridgedRoom(room)) continue;
    if (room.getState(EventTypes.RoomMember, userId) == null) continue;
    if (isBridgeBotMember(room, userId)) return null;
    if (room.directChatMatrixIDForDisplay == userId) return room;
    found ??= room;
  }
  return found;
}

/// The joined one-to-one portal with [userId], if this device has one.
Room? directPortalWith(Client client, String userId) =>
    client.rooms.firstWhereOrNull(
      (room) =>
          room.membership == Membership.join &&
          room.isDirectChatForDisplay &&
          room.directChatMatrixIDForDisplay == userId,
    );

/// Opens the contact sheet of [userId] as seen in [room].
Future<void> showContactSheet(
  BuildContext context, {
  required Room room,
  required String userId,
}) => showNotionSheet<void>(
  context: context,
  builder: (sheet) => ContactSheet(room: room, userId: userId, host: context),
);

class ContactSheet extends StatelessWidget {
  final Room room;
  final String userId;

  /// The page that opened the sheet: actions navigate from it after the
  /// sheet closed.
  final BuildContext host;
  const ContactSheet({
    super.key,
    required this.room,
    required this.userId,
    required this.host,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final client = room.client;
    final user = room.unsafeGetUserFromMemoryOrFallback(userId);
    final name = user.calcDisplayname();
    final bridged = isBridgedRoom(room);
    final network = bridged
        ? NetworkChatFeatures.of(room).network ??
              canonicalNetwork(PersonalClient.networkOf(room))
        : 'matrix';
    final networkLabel = network == null
        ? 'Bridged contact'
        : notionNetworkLabel(network);
    final identifiers = bridged
        ? contactIdentifiers(room, userId)
        : const <ContactIdentifier>[];
    final showMatrixId = !bridged || DeveloperOptions.enabled;
    final direct = directPortalWith(client, userId);
    final features = direct == null
        ? NetworkChatFeatures.none
        : NetworkChatFeatures.of(direct);
    final own = userId == client.userID;

    void close() => Navigator.of(context).pop();
    Future<void> copy(String value, String label) async {
      await Clipboard.setData(ClipboardData(text: value));
      if (host.mounted) await showCopiedNotice(host, label);
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(
                client: client,
                mxContent: user.avatarUrl,
                name: name,
                size: NotionSize.avatarLg,
              ),
              const SizedBox(width: NotionSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.typography.headline,
                      ),
                    ),
                    const SizedBox(height: NotionSpace.xxs),
                    Row(
                      children: [
                        IconTheme.merge(
                          data: IconThemeData(
                            color: tokens.colors.textSecondary,
                          ),
                          child: NotionNetworkGlyph(
                            network: network,
                            size: NotionSize.iconSm,
                          ),
                        ),
                        const SizedBox(width: NotionSpace.xxs),
                        Flexible(
                          child: Text(
                            features.userBlocked
                                ? '$networkLabel · Blocked'
                                : networkLabel,
                            style: tokens.typography.footnoteMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: NotionSpace.sm),
          for (final identifier in identifiers)
            NotionListRow(
              key: ValueKey('contact-${identifier.kind.name}'),
              leading: Icon(
                identifier.kind == ContactIdentifierKind.phone
                    ? Icons.phone_outlined
                    : Icons.alternate_email,
              ),
              title: identifier.value,
              subtitle: identifier.kind == ContactIdentifierKind.phone
                  ? 'Phone'
                  : 'Username on $networkLabel',
              trailing: Icon(
                Icons.copy_outlined,
                size: NotionSize.icon,
                color: tokens.colors.textSecondary,
              ),
              onTap: () => copy(
                identifier.value,
                identifier.kind == ContactIdentifierKind.phone
                    ? 'Phone number copied'
                    : 'Username copied',
              ),
            ),
          if (showMatrixId)
            NotionListRow(
              key: const ValueKey('contact-matrix-id'),
              leading: const Icon(Icons.tag),
              title: userId,
              subtitle: bridged ? 'Bridge account (developer)' : 'Matrix ID',
              trailing: Icon(
                Icons.copy_outlined,
                size: NotionSize.icon,
                color: tokens.colors.textSecondary,
              ),
              onTap: () => copy(userId, 'Matrix ID copied'),
            ),
          if (!own && direct != null && direct.id != room.id)
            NotionListRow(
              key: const ValueKey('contact-message'),
              leading: const Icon(Icons.chat_bubble_outline),
              title: 'Message',
              onTap: () {
                final router = GoRouter.of(host);
                close();
                router.go('/rooms/${direct.id}');
              },
            ),
          if (direct != null)
            NotionListRow(
              key: const ValueKey('contact-media'),
              leading: const Icon(Icons.photo_library_outlined),
              title: 'Media & files',
              onTap: () {
                final navigator = Navigator.of(host);
                close();
                unawaited(
                  navigator.push<void>(
                    MaterialPageRoute(
                      builder: (_) => NotionConversationContentPage(
                        rooms: [direct],
                        name: name,
                        initialMedia: true,
                      ),
                    ),
                  ),
                );
              },
            ),
          if (!own && direct != null && features.blockUser)
            NotionListRow(
              key: const ValueKey('contact-block'),
              leading: Icon(
                features.userBlocked
                    ? Icons.lock_open_outlined
                    : Icons.block_outlined,
                color: features.userBlocked ? null : tokens.colors.danger,
              ),
              title: features.userBlocked
                  ? 'Unblock on $networkLabel'
                  : 'Block on $networkLabel',
              subtitle: features.userBlocked
                  ? null
                  : 'They can’t message or call you there',
              onTap: () {
                close();
                unawaited(
                  blockNetworkUserFlow(
                    host,
                    direct,
                    name: name,
                    block: !features.userBlocked,
                  ),
                );
              },
            ),
          if (!own)
            NotionListRow(
              key: const ValueKey('contact-ignore'),
              leading: const Icon(Icons.visibility_off_outlined),
              title: client.ignoredUsers.contains(userId)
                  ? 'Ignored here'
                  : 'Ignore here',
              subtitle: bridged
                  ? 'Hides their messages in ChatLoom and other Beeper apps. '
                        '$networkLabel isn’t told.'
                  : 'Hides their messages in ChatLoom and other Matrix apps.',
              onTap: () {
                final router = GoRouter.of(host);
                close();
                router.go('/rooms/settings/security/ignorelist', extra: userId);
              },
            ),
        ],
      ),
    );
  }
}
