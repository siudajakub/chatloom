// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

/// Real state supplied by room/person adapters. No transport in presentation.
class NotionConversationDetailsData {
  final String name;
  final String network;
  final Widget avatar;
  final String? label;
  final String? nickname;
  final String notifications;
  final bool pinned;
  final bool incognito;
  final bool pending;
  final String? status;
  final Widget? sharedContent;
  final List<Widget> sourceRows;
  const NotionConversationDetailsData({
    required this.name,
    required this.network,
    required this.avatar,
    this.label,
    this.nickname,
    this.notifications = 'Choose a source',
    this.pinned = false,
    required this.incognito,
    this.pending = false,
    this.status,
    this.sharedContent,
    this.sourceRows = const [],
  });
}

class NotionConversationDetailsActions {
  final VoidCallback? search;
  final VoidCallback? mute;
  final VoidCallback? notifications;
  final ValueChanged<bool>? pin;
  final VoidCallback? privacy;
  final VoidCallback? appearance;
  final VoidCallback? preferences;
  final VoidCallback? nickname;
  final VoidCallback? media;
  final VoidCallback? archive;
  final VoidCallback? contact;
  final VoidCallback? overflow;
  const NotionConversationDetailsActions({
    this.search,
    this.mute,
    this.notifications,
    this.pin,
    this.privacy,
    this.appearance,
    this.preferences,
    this.nickname,
    this.media,
    this.archive,
    this.contact,
    this.overflow,
  });
}
