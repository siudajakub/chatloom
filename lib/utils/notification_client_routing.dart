// SPDX-License-Identifier: AGPL-3.0-or-later

/// Picks the account a push or notification action belongs to.
///
/// The Personal gateway never forwards pusher data, so its pushes carry no
/// account name: then the single signed-in account is the target (accounts
/// that are signed out or still restoring are not candidates). With several
/// signed-in accounts a payload without an account is ambiguous and dropped.
/// An explicit stale account never falls back to another one.
T? selectNotificationClient<T>(
  Iterable<T> clients,
  String? account,
  String Function(T) name, {
  bool Function(T)? isLoggedIn,
}) {
  if (account == null) {
    final candidates = isLoggedIn == null
        ? clients.toList()
        : clients.where(isLoggedIn).toList();
    return candidates.length == 1 ? candidates.single : null;
  }
  for (final client in clients) {
    if (name(client) == account) return client;
  }
  return null;
}

/// One notification per chat and account. Push, cancel and summary code must
/// all derive the id from the selected account's name, never from the push
/// payload, which may not carry an account.
int messageNotificationId(String clientName, String roomId) =>
    '${clientName}_$roomId'.hashCode;

/// The group summary notification of one account.
int summaryNotificationId(String clientName) => clientName.hashCode;

/// One notification per reminder entity.
int reminderNotificationId(Object? entityId) => 'reminder_$entityId'.hashCode;
