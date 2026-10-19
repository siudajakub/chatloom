// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:matrix/matrix.dart';

/// Per-account values the settings screens show on open: profile, recovery
/// state, account-management link and password capability.
///
/// Each value is read synchronously from the last result, so a settings page
/// renders complete on its first frame. A stale or missing value is refreshed
/// in the background; callers decide when (usually after the page
/// transition). Nothing here is secret: no tokens or keys are cached, only
/// display data and booleans, and only in memory for the client object.
final class SettingsAccountCache {
  SettingsAccountCache._(this.client);

  static final _byClient = Expando<SettingsAccountCache>('settings cache');

  /// The cache of [client]. A different client object never shares values.
  static SettingsAccountCache of(Client client) =>
      _byClient[client] ??= SettingsAccountCache._(client);

  static const profileLifetime = Duration(minutes: 10);
  static const recoveryLifetime = Duration(minutes: 1);
  static const serverLifetime = Duration(minutes: 30);

  final Client client;

  Profile? profile;
  DateTime? _profileAt;
  Future<Profile>? _profileLoading;

  /// Bumped per profile request; only the newest request may store its
  /// result, so an older answer can never overwrite a forced refresh.
  int _profileGeneration = 0;

  bool? recoveryConnected;
  DateTime? _recoveryAt;

  ({Uri? uri})? management;
  DateTime? _managementAt;
  Future<Uri?>? _managementLoading;

  bool? passwordChange;
  DateTime? _passwordAt;
  Future<bool>? _passwordLoading;

  static bool _fresh(DateTime? at, Duration lifetime) =>
      at != null && DateTime.now().difference(at) < lifetime;

  bool get profileFresh =>
      profile != null && _fresh(_profileAt, profileLifetime);
  bool get recoveryFresh =>
      recoveryConnected != null && _fresh(_recoveryAt, recoveryLifetime);

  /// The profile. A fresh cached profile completes without a request;
  /// otherwise one shared request refreshes it. [force] (after a profile
  /// edit) never joins a request that may have started before the edit: it
  /// starts a new one, and callers of the superseded request get its answer.
  Future<Profile> loadProfile({bool force = false}) {
    final cached = profile;
    if (!force && cached != null && profileFresh) return Future.value(cached);
    final userId = client.userID;
    if (userId == null) {
      return Future.error(StateError('The account is not logged in.'));
    }
    final pending = _profileLoading;
    if (!force && pending != null) return pending;
    final generation = ++_profileGeneration;
    late final Future<Profile> request;
    request = client
        .getProfileFromUserId(userId)
        .then<Profile>((value) {
          if (generation != _profileGeneration) {
            // Superseded: answer with the newer request (or its result).
            return _profileLoading ?? profile ?? value;
          }
          if (client.userID == userId) {
            profile = value;
            _profileAt = DateTime.now();
          }
          return value;
        })
        .whenComplete(() {
          if (identical(_profileLoading, request)) _profileLoading = null;
        });
    return _profileLoading = request;
  }

  void rememberRecovery(bool? connected) {
    recoveryConnected = connected;
    _recoveryAt = connected == null ? null : DateTime.now();
  }

  /// Account management page of the homeserver, if any.
  Future<Uri?> loadManagement({bool force = false}) {
    final cached = management;
    if (!force && cached != null && _fresh(_managementAt, serverLifetime)) {
      return Future.value(cached.uri);
    }
    return _managementLoading ??= client
        .getAuthMetadata()
        .timeout(const Duration(seconds: 10))
        .then((metadata) {
          final uri = metadata.accountManagementUri;
          management = (uri: uri);
          _managementAt = DateTime.now();
          return uri;
        })
        .whenComplete(() => _managementLoading = null);
  }

  /// Whether this account may change its password.
  Future<bool> loadPasswordChange({bool force = false}) {
    final cached = passwordChange;
    if (!force && cached != null && _fresh(_passwordAt, serverLifetime)) {
      return Future.value(cached);
    }
    return _passwordLoading ??= client
        .getCapabilities()
        .timeout(const Duration(seconds: 10))
        .then((caps) {
          final enabled = caps.mChangePassword?.enabled != false;
          passwordChange = enabled;
          _passwordAt = DateTime.now();
          return enabled;
        })
        .whenComplete(() => _passwordLoading = null);
  }
}
