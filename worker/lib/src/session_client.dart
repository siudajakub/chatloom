// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

/// Owns the underlying HTTP transport, which SDK dispose does not close.
class WorkerSessionClient extends Client {
  final http.Client _sessionHttpClient;
  bool _networkClosed = false;

  WorkerSessionClient(
    super.clientName, {
    required super.database,
    required http.Client sessionHttpClient,
    super.logLevel,
    super.receiptsPublicByDefault,
    super.shareKeysWith,
    super.sendTimelineEventTimeout,
    super.onSoftLogout,
    super.importantStateEvents,
    super.syncFilter,
  }) : _sessionHttpClient = sessionHttpClient,
       super(httpClient: sessionHttpClient);

  String? _redefinedFilterId;

  /// The SDK defines its sync filter once per login and keeps that id; the
  /// sync loop reads it through this getter on every request.
  @override
  String? get syncFilterId => _redefinedFilterId ?? super.syncFilterId;

  /// Defines [syncFilter] again and uses it from the next sync request on
  /// (stored, so a restart loads the new id). Used once when the worker's
  /// filter changes; no SDK change needed.
  Future<void> redefineSyncFilter() async {
    final userId = userID;
    if (userId == null) throw StateError('Not logged in');
    final id = await defineFilter(userId, syncFilter);
    await database.storeSyncFilterId(id);
    _redefinedFilterId = id;
  }

  /// Interrupt network waits before awaiting the active cycle and database.
  /// Closing the SDK's timeout wrapper would not close its inner transport.
  void stopNetwork() {
    backgroundSync = false;
    if (_networkClosed) return;
    _networkClosed = true;
    _sessionHttpClient.close();
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {
    stopNetwork();
    await super.dispose(closeDatabase: closeDatabase);
  }
}
