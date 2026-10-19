// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/matrix_api_lite/utils/sync_body_decoder.dart';

Uint8List _encode(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// A catch-up style response well above the isolate threshold.
Map<String, Object?> _largeSync() {
  final base = jsonDecode(jsonEncode(FakeMatrixApi.syncResponse)) as Map;
  final join = (base['rooms'] as Map)['join'] as Map;
  final room = join.values.first as Map;
  final timeline = room['timeline'] as Map;
  timeline['events'] = [
    for (var i = 0; i < 1500; i++)
      {
        'type': 'm.room.message',
        'event_id': '\$synthetic$i:example.org',
        'sender': '@alice:example.org',
        'origin_server_ts': 1432735824653 + i,
        'content': {'msgtype': 'm.text', 'body': 'synthetic body $i ' * 8},
        'unsigned': {'age': i},
      },
  ];
  return base.cast<String, Object?>();
}

void main() {
  test(
    'isolate decode matches inline decode on the SDK sync fixture',
    () async {
      final body = _encode(FakeMatrixApi.syncResponse);
      final inline = parseSyncUpdateBody(body);
      // Threshold 0 forces Isolate.run: the full model graph must be sendable.
      final isolated = await decodeSyncUpdateBody(body, threshold: 0);
      expect(isolated.toJson(), inline.toJson());
    },
  );

  test(
    'large /sync bodies decode off-isolate through MatrixApi.sync',
    () async {
      final body = _encode(_largeSync());
      expect(body.length, greaterThan(largeSyncBodyBytes));
      final api = MatrixApi(
        homeserver: Uri.parse('https://example.org'),
        accessToken: 'synthetic',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/_matrix/client/v3/sync');
          expect(request.url.queryParameters['since'], 's1');
          return http.Response.bytes(body, 200);
        }),
      );
      final update = await api.sync(since: 's1', timeout: 0);
      expect(update.toJson(), parseSyncUpdateBody(body).toJson());
      expect(update.rooms?.join?.values.first.timeline?.events?.length, 1500);
    },
  );

  test('decode failures still fail the sync future on both paths', () async {
    final invalid = Uint8List.fromList(utf8.encode('{"next_batch": '));
    await expectLater(decodeSyncUpdateBody(invalid), throwsFormatException);
    await expectLater(
      decodeSyncUpdateBody(invalid, threshold: 0),
      throwsFormatException,
    );
  });
}
