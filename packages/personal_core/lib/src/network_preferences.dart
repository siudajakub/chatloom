// SPDX-License-Identifier: AGPL-3.0-or-later

enum ChatPlacement { inbox, groups, ignored }

enum PersonalNotificationMode { all, mentionsOnly, muted }

T? preferenceEnum<T extends Enum>(Iterable<T> values, Object? value) {
  for (final item in values) {
    if (item.name == value) return item;
  }
  return null;
}

/// Private display/notification defaults; never a source routing identifier.
class NetworkPreferences {
  final ChatPlacement groupPlacement;
  final bool showInGroups;
  final PersonalNotificationMode? notifications;
  final PersonalNotificationMode? groupNotifications;
  const NetworkPreferences({
    this.groupPlacement = ChatPlacement.inbox,
    this.showInGroups = true,
    this.notifications,
    this.groupNotifications,
  });

  factory NetworkPreferences.defaults(String network) => NetworkPreferences(
    showInGroups: network != 'telegram',
    groupPlacement: network == 'telegram'
        ? ChatPlacement.groups
        : ChatPlacement.inbox,
  );

  factory NetworkPreferences.fromJson(
    Map<String, dynamic> json,
    String network,
  ) => NetworkPreferences(
    showInGroups: json['showInGroups'] is bool
        ? json['showInGroups'] as bool
        : NetworkPreferences.defaults(network).showInGroups,
    groupPlacement:
        preferenceEnum(ChatPlacement.values, json['groupPlacement']) ??
        NetworkPreferences.defaults(network).groupPlacement,
    notifications: preferenceEnum(
      PersonalNotificationMode.values,
      json['notifications'],
    ),
    groupNotifications: preferenceEnum(
      PersonalNotificationMode.values,
      json['groupNotifications'],
    ),
  );

  Map<String, dynamic> toJson() => {
    'groupPlacement': groupPlacement.name,
    'showInGroups': showInGroups,
    'notifications': notifications?.name,
    'groupNotifications': groupNotifications?.name,
  };
}
