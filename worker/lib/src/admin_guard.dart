// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ports.dart';

/// Defense in depth for headless pairing: only an inspected self-only journal
/// may receive encrypted events. Reading sources never sends receipts/activity.
class JournalAdminHttpClient extends http.BaseClient {
  final http.Client inner;
  final Set<String> journals = {};
  int encryptedJournalWrites = 0;
  int blockedActivity = 0;
  JournalAdminHttpClient({http.Client? inner}) : inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final s = request.url.pathSegments;
    var forbidden =
        s.contains('receipt') ||
        s.contains('read_markers') ||
        s.contains('typing') ||
        s.contains('presence') ||
        request.method != 'GET' && (s.contains('join') || s.contains('invite'));
    if (s.contains('send')) {
      final i = s.indexOf('rooms');
      final send = s.indexOf('send');
      forbidden |=
          i < 0 ||
          i + 1 >= s.length ||
          !journals.contains(s[i + 1]) ||
          send + 1 >= s.length ||
          s[send + 1] != 'm.room.encrypted';
      if (!forbidden) encryptedJournalWrites++;
    }
    if (s.lastOrNull == 'createRoom') {
      if (request is! http.Request) {
        forbidden = true;
      } else {
        final b = jsonDecode(request.body) as Map;
        final initial = b['initial_state'] as List? ?? [];
        forbidden |=
            b['preset'] != 'private_chat' ||
            (b['invite'] as List? ?? []).isNotEmpty ||
            (b['invite_3pid'] as List? ?? []).isNotEmpty ||
            (b['creation_content'] as Map?)?['m.federate'] != false ||
            !initial.any(
              (e) =>
                  e['type'] == 'm.room.encryption' &&
                  e['content']['algorithm'] == 'm.megolm.v1.aes-sha2',
            ) ||
            !initial.any(
              (e) =>
                  e['type'] == 'pl.personal.client.journal.v1' &&
                  e['content']['schema'] == 1,
            );
      }
    }
    if (forbidden) {
      blockedActivity++;
      throw const WorkerFailure('headless_forbidden_activity');
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}
