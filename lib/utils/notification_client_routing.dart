// SPDX-License-Identifier: AGPL-3.0-or-later

/// A legacy payload without an account is unambiguous only on a single-account
/// installation. An explicit stale account can never fall back to another one.
T? selectNotificationClient<T>(
  Iterable<T> clients,
  String? account,
  String Function(T) name,
) {
  if (account == null) {
    final available = clients.toList();
    return available.length == 1 ? available.single : null;
  }
  for (final client in clients) {
    if (name(client) == account) return client;
  }
  return null;
}
