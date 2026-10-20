// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'undecryptable_messages.dart';

/// Local view of this device's end-to-end encryption health, built only
/// from state the SDK already holds. Nothing here talks to the server or
/// changes keys; fixes are the existing, user-driven recovery screens.
@immutable
class E2eeSnapshot {
  const E2eeSnapshot({
    this.encryptionAvailable = true,
    this.backupEnabled = true,
    this.backupConnected = true,
    this.crossSigningConnected = true,
    this.sessionVerified = true,
    this.unverifiedDevices = const [],
    this.undecryptableChats = 0,
    this.privateSync,
  });

  final bool encryptionAvailable;

  /// The account has an online key backup.
  final bool backupEnabled;

  /// This device holds the backup key (recovery is connected).
  final bool backupConnected;

  /// This device holds the cross-signing keys.
  final bool crossSigningConnected;

  /// This session is cross-signed (`!Client.isUnknownSession`).
  final bool sessionVerified;

  /// Other sessions of this account that are neither verified nor blocked.
  /// Only hashed into [E2eeIssue.signature]; never shown or logged.
  final List<String> unverifiedDevices;

  /// Joined chats whose latest message this device cannot decrypt.
  final int undecryptableChats;

  final PrivateSyncFailure? privateSync;

  /// Waits for the stored account state, then reads it. Call after the first
  /// sync so account data and device lists are current.
  static Future<E2eeSnapshot> load(
    Client client, {
    PrivateSyncFailure? privateSync,
  }) async {
    await client.roomsLoading;
    await client.accountDataLoading;
    await client.userDeviceKeysLoading;
    final encryption = client.encryption;
    if (!client.encryptionEnabled || encryption == null) {
      return E2eeSnapshot(encryptionAvailable: false, privateSync: privateSync);
    }
    final keys = encryption.keyManager;
    final crossSigning = encryption.crossSigning;
    final backupEnabled = keys.enabled;
    final backupConnected = backupEnabled && await keys.isCached();
    final crossSigningConnected =
        crossSigning.enabled && await crossSigning.isCached();
    final sessionVerified = !client.isUnknownSession;
    final own = client.userDeviceKeys[client.userID]?.deviceKeys;
    final unverified = [
      for (final entry in (own ?? const <String, DeviceKeys>{}).entries)
        if (entry.key != client.deviceID &&
            !entry.value.verified &&
            !entry.value.blocked)
          entry.key,
    ]..sort();
    var undecryptable = 0;
    for (final room in client.rooms) {
      final last = room.lastEvent;
      if (room.membership != Membership.join ||
          room.isSpace ||
          last == null ||
          PersonalPrivacy.isJournal(room)) {
        continue;
      }
      if (isUndecryptable(last)) undecryptable++;
    }
    return E2eeSnapshot(
      backupEnabled: backupEnabled,
      backupConnected: backupConnected,
      crossSigningConnected: crossSigningConnected,
      sessionVerified: sessionVerified,
      unverifiedDevices: unverified,
      undecryptableChats: undecryptable,
      privateSync: privateSync,
    );
  }
}

enum E2eeIssueKind {
  encryptionOff,
  recovery,
  session,
  privateSync,
  undecryptable,
  devices,
}

/// What the one-tap fix of an issue does.
enum E2eeFix {
  /// Encryption & recovery settings (status and "Set up recovery").
  openRecoverySettings,

  /// The recovery-key flow (`/backup`): connects key backup on this device
  /// and cross-signs this session.
  connectRecovery,

  /// Devices list, to verify or remove sessions.
  openDevices,
  retryPrivateSync,
  openPrivateSync,

  /// Ask key backup and other devices again for undecryptable messages.
  retryKeys,
}

@immutable
class E2eeIssue {
  const E2eeIssue({
    required this.kind,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.fix,
    required this.signature,
  });

  final E2eeIssueKind kind;
  final String title;
  final String message;
  final String actionLabel;
  final E2eeFix fix;

  /// Stable identity for "dismissed until it changes". A new device set or a
  /// different private sync failure produces a new signature.
  final String signature;
}

/// The recovery step that helps this device most, or `null` when key backup
/// and this session are both fine.
E2eeFix? recoveryFixFor(E2eeSnapshot snapshot) {
  if (!snapshot.encryptionAvailable) return E2eeFix.openRecoverySettings;
  // Setting up a new backup is never one tap away: the settings screen
  // explains it first.
  if (!snapshot.backupEnabled) return E2eeFix.openRecoverySettings;
  if (!snapshot.backupConnected) return E2eeFix.connectRecovery;
  if (!snapshot.sessionVerified) {
    return snapshot.crossSigningConnected
        ? E2eeFix.openDevices
        : E2eeFix.connectRecovery;
  }
  return null;
}

/// Issues in priority order: encryption and recovery first (they also fix
/// most undecryptable messages), then private sync, locked chats and other
/// unverified sessions.
List<E2eeIssue> e2eeIssues(
  E2eeSnapshot s, {
  bool includePrivateSync = !kIsWeb,
}) {
  final issues = <E2eeIssue>[];
  if (!s.encryptionAvailable) {
    issues.add(
      const E2eeIssue(
        kind: E2eeIssueKind.encryptionOff,
        title: 'Encryption is off on this device',
        message: 'Encrypted chats can’t be read or sent from here.',
        actionLabel: 'Details',
        fix: E2eeFix.openRecoverySettings,
        signature: 'encryption:off',
      ),
    );
  } else if (!s.backupEnabled) {
    issues.add(
      const E2eeIssue(
        kind: E2eeIssueKind.recovery,
        title: 'Key backup isn’t set up',
        message:
            'If you lose this device, your message history can’t be '
            'restored.',
        actionLabel: 'Set up',
        fix: E2eeFix.openRecoverySettings,
        signature: 'recovery:none',
      ),
    );
  } else if (!s.backupConnected) {
    issues.add(
      E2eeIssue(
        kind: E2eeIssueKind.recovery,
        title: 'Connect this device to key backup',
        message: s.sessionVerified
            ? 'Enter your recovery key to unlock older messages.'
            : 'Enter your recovery key to unlock older messages and verify '
                  'this session.',
        actionLabel: 'Connect',
        fix: E2eeFix.connectRecovery,
        signature: 'recovery:disconnected',
      ),
    );
  }
  if (s.encryptionAvailable && s.backupConnected && !s.sessionVerified) {
    issues.add(
      E2eeIssue(
        kind: E2eeIssueKind.session,
        title: 'This session isn’t verified',
        message:
            'Your other devices won’t share message keys with it until you '
            'verify it.',
        actionLabel: 'Verify',
        fix: recoveryFixFor(s) ?? E2eeFix.openDevices,
        signature: 'session:unverified',
      ),
    );
  }
  final sync = s.privateSync;
  if (includePrivateSync &&
      sync != null &&
      sync != PrivateSyncFailure.offline) {
    final (message, label, fix) = switch (sync) {
      PrivateSyncFailure.storageUnavailable => (
        'Encrypted private storage couldn’t be opened. Your data is kept.',
        'Retry',
        E2eeFix.retryPrivateSync,
      ),
      PrivateSyncFailure.offline || PrivateSyncFailure.timeout => (
        'Private sync timed out. Pending changes are kept.',
        'Retry',
        E2eeFix.retryPrivateSync,
      ),
      PrivateSyncFailure.journalMissing => (
        'Private sync isn’t set up on this account yet.',
        'Set up',
        E2eeFix.openPrivateSync,
      ),
      PrivateSyncFailure.journalInvalid => (
        'Its encrypted journal is invalid. Local data is kept.',
        'Review',
        E2eeFix.openPrivateSync,
      ),
      PrivateSyncFailure.membershipUntrusted => (
        'The private room has members it shouldn’t have.',
        'Review',
        E2eeFix.openPrivateSync,
      ),
      PrivateSyncFailure.journalUnavailable => (
        'Its encrypted journal couldn’t be read. Local data is kept.',
        'Retry',
        E2eeFix.retryPrivateSync,
      ),
    };
    issues.add(
      E2eeIssue(
        kind: E2eeIssueKind.privateSync,
        title: 'Private sync isn’t working',
        message: message,
        actionLabel: label,
        fix: fix,
        signature: 'sync:${sync.name}',
      ),
    );
  }
  if (s.encryptionAvailable && s.undecryptableChats > 0) {
    final n = s.undecryptableChats;
    issues.add(
      E2eeIssue(
        kind: E2eeIssueKind.undecryptable,
        title: n == 1
            ? '1 chat has a message that couldn’t be decrypted'
            : '$n chats have messages that couldn’t be decrypted',
        message: 'Ask your key backup and other devices for the keys again.',
        actionLabel: 'Try again',
        fix: E2eeFix.retryKeys,
        signature: 'undecryptable',
      ),
    );
  }
  // An unverified session sees every other session as unverified; that
  // case is covered by the session issue above.
  if (s.encryptionAvailable &&
      s.sessionVerified &&
      s.unverifiedDevices.isNotEmpty) {
    final n = s.unverifiedDevices.length;
    issues.add(
      E2eeIssue(
        kind: E2eeIssueKind.devices,
        title: n == 1
            ? '1 of your sessions isn’t verified'
            : '$n of your sessions aren’t verified',
        message:
            'Verify the ones you use and sign out of any you don’t '
            'recognise.',
        actionLabel: 'Review',
        fix: E2eeFix.openDevices,
        signature: 'devices:${fnv1a(s.unverifiedDevices.join(','))}',
      ),
    );
  }
  return issues;
}

/// 32-bit FNV-1a as hex: a stable, non-reversible tag for stored signatures.
String fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// "Dismissed until it changes": the dismissed issue signatures, tagged with
/// a hash of the account so another account never inherits a dismissal.
abstract final class E2eeNoticeDismissal {
  static String encode(String account, Iterable<E2eeIssue> issues) {
    final signatures = issues.map((issue) => issue.signature).toSet().toList()
      ..sort();
    return [fnv1a(account), ...signatures].join('\n');
  }

  /// True when every current issue was already dismissed. A new issue (or a
  /// changed one) shows the notice again; a resolved one never does.
  static bool covers(
    String stored,
    String account,
    Iterable<E2eeIssue> issues,
  ) {
    if (stored.isEmpty) return false;
    final lines = stored.split('\n');
    if (lines.first != fnv1a(account)) return false;
    final dismissed = lines.skip(1).toSet();
    return issues.every((issue) => dismissed.contains(issue.signature));
  }
}

/// Routes for the one-tap fixes. Pushed, so back returns to where the user
/// was (inbox or chat).
String? e2eeFixRoute(E2eeFix fix) => switch (fix) {
  E2eeFix.openRecoverySettings => '/rooms/settings/recovery',
  E2eeFix.connectRecovery => '/backup',
  E2eeFix.openDevices => '/rooms/settings/devices',
  E2eeFix.openPrivateSync => '/rooms/settings/sync',
  E2eeFix.retryPrivateSync || E2eeFix.retryKeys => null,
};

/// Opens the recovery step that helps this device most (chat bubble and
/// header "Fix"); falls back to Encryption & recovery settings.
Future<void> openEncryptionRecovery(BuildContext context, Client client) async {
  final router = GoRouter.of(context);
  E2eeFix? fix;
  try {
    fix = recoveryFixFor(await E2eeSnapshot.load(client));
  } catch (_) {
    fix = null;
  }
  await router.push(e2eeFixRoute(fix ?? E2eeFix.openRecoverySettings)!);
}

/// Keeps the inbox E2EE notice current: recomputes on sync, private sync
/// changes and key arrivals (throttled), and remembers dismissals.
class E2eeHealthController extends ChangeNotifier {
  E2eeHealthController(
    this.client, {
    PersonalClient? personal,
    Future<E2eeSnapshot> Function()? load,
    this.throttle = const Duration(seconds: 3),
  }) : personal = personal ?? PersonalClient.of(client),
       _load = load;

  final Client client;
  final PersonalClient personal;
  final Duration throttle;
  final Future<E2eeSnapshot> Function()? _load;

  List<E2eeIssue> _issues = const [];
  E2eeSnapshot? _snapshot;
  bool _dismissed = false;
  E2eeFix? _busy;
  bool _disposed = false;
  int _generation = 0;
  Timer? _pending;
  StreamSubscription<Object?>? _sync;
  UndecryptableMessages? _keys;

  /// Every current issue, dismissed or not (details sheet).
  List<E2eeIssue> get issues => _issues;

  /// What the inbox shows: nothing once the current issues were dismissed.
  List<E2eeIssue> get visible => _dismissed ? const [] : _issues;
  E2eeSnapshot? get snapshot => _snapshot;
  E2eeFix? get busy => _busy;

  String get _account => client.userID ?? client.clientName;

  void start() {
    personal.addListener(_schedule);
    _keys = UndecryptableMessages.of(client)..addListener(_schedule);
    // Device lists, account data and room previews all arrive with a sync.
    _sync = client.onSync.stream.listen((_) => _schedule());
    unawaited(_firstLoad());
  }

  Future<void> _firstLoad() async {
    try {
      // Before the first sync, account data and device lists may be stale;
      // a false "not connected" at launch is exactly what this replaces.
      if (_load == null && client.prevBatch == null) {
        await client.onSync.stream.first;
      }
    } catch (_) {
      return;
    }
    if (!_disposed) await refresh();
  }

  void _schedule() {
    if (_disposed || _pending != null) return;
    _pending = Timer(throttle, () {
      _pending = null;
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    E2eeSnapshot snapshot;
    try {
      snapshot =
          await (_load?.call() ??
              E2eeSnapshot.load(client, privateSync: personal.syncFailure));
    } catch (error) {
      Logs().w('[Personal] E2EE status unavailable: ${error.runtimeType}');
      return;
    }
    if (_disposed || generation != _generation) return;
    final issues = e2eeIssues(snapshot);
    final dismissed = E2eeNoticeDismissal.covers(
      AppSettings.personalE2eeNoticeDismissed.value,
      _account,
      issues,
    );
    final changed =
        dismissed != _dismissed ||
        !listEquals(
          issues.map((i) => (i.signature, i.title, i.message)).toList(),
          _issues.map((i) => (i.signature, i.title, i.message)).toList(),
        );
    _snapshot = snapshot;
    _issues = issues;
    _dismissed = dismissed;
    if (changed) notifyListeners();
  }

  Future<void> dismiss() async {
    if (_issues.isEmpty) return;
    _dismissed = true;
    notifyListeners();
    await AppSettings.personalE2eeNoticeDismissed.setItem(
      E2eeNoticeDismissal.encode(_account, _issues),
    );
  }

  /// Runs [issue]'s one-tap fix, then re-reads the state.
  Future<void> fix(BuildContext context, E2eeIssue issue) async {
    if (_busy != null) return;
    final route = e2eeFixRoute(issue.fix);
    if (route != null) {
      await GoRouter.of(context).push(route);
      await refresh();
      return;
    }
    _busy = issue.fix;
    notifyListeners();
    try {
      switch (issue.fix) {
        case E2eeFix.retryPrivateSync:
          await personal.retry();
        case E2eeFix.retryKeys:
          UndecryptableMessages.of(client).retryAll([
            for (final room in client.rooms)
              if (room.membership == Membership.join && room.lastEvent != null)
                room.lastEvent!,
          ]);
        default:
          break;
      }
    } catch (error) {
      Logs().w('[Personal] E2EE fix failed: ${error.runtimeType}');
    } finally {
      _busy = null;
      if (!_disposed) {
        notifyListeners();
        await refresh();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    unawaited(_sync?.cancel());
    personal.removeListener(_schedule);
    _keys?.removeListener(_schedule);
    super.dispose();
  }
}
