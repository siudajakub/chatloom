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
  }) : _sessionHttpClient = sessionHttpClient,
       super(httpClient: sessionHttpClient);

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
