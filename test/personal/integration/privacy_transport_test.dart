// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../../lib/personal/privacy_transport.dart';

class Recorder extends http.BaseClient {
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls.add(request);
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
  }
}

void check(bool ok, String label) {
  if (!ok) throw StateError(label);
}

Future<void> main() async {
  final recorder = Recorder();
  var hidden = true;
  final client = PrivacyHttpClient(recorder, incognito: () => hidden);
  final server = Uri.parse('https://fixture.invalid');
  http.Request request(String path, Map<String, Object?> body) =>
      http.Request('POST', server.resolve('/_matrix/client/v3/$path'))
        ..body = jsonEncode(body);
  Future<void> denied(http.Request req) async {
    final count = recorder.calls.length;
    try {
      await client.send(req);
      throw StateError('privacy request emitted');
    } on PrivacySuppressed {}
    check(recorder.calls.length == count, 'Suppression reached transport');
  }

  for (final receipt in ['m.read', 'm.read.private', 'm.fully_read']) {
    await denied(request('rooms/fixture/receipt/$receipt/fixture-event', {}));
  }
  await denied(
    request('rooms/fixture/read_markers', {
      'm.fully_read': 'fixture-event',
      'm.read': 'fixture-event',
    }),
  );
  await denied(request('rooms/fixture/typing/fixture-user', {'typing': true}));
  await denied(request('presence/fixture-user/status', {'presence': 'online'}));
  await client.send(
    http.Request(
      'GET',
      server.resolve('/_matrix/client/v3/presence/other/status'),
    ),
  );
  await client.send(
    http.Request('GET', server.resolve('/_matrix/client/v3/sync')),
  );
  check(
    recorder.calls.last.url.queryParameters['set_presence'] == 'offline',
    'Default sync leaked presence',
  );
  await client.send(
    request('rooms/fixture/typing/fixture-user', {'typing': false}),
  );
  await client.send(
    http.Request(
      'GET',
      server.resolve(
        '/_matrix/client/v3/sync?set_presence=online&since=opaque',
      ),
    ),
  );
  check(
    recorder.calls.last.url.queryParameters['set_presence'] == 'offline',
    'Sync leaked online',
  );
  check(
    recorder.calls.last.url.queryParameters['since'] == 'opaque',
    'Sync lost cursor',
  );
  await withReadGrant('fixture', 'fixture-event', server, () async {
    await client.send(
      request('rooms/fixture/read_markers', {
        'm.fully_read': 'fixture-event',
        'm.read.private': 'fixture-event',
      }),
    );
    await denied(
      request('rooms/other/read_markers', {'m.read': 'fixture-event'}),
    );
    await denied(
      request('rooms/fixture/read_markers', {'m.read': 'newer-unseen'}),
    );
    await denied(request('rooms/fixture/receipt/m.read/newer-unseen', {}));
  });
  final media = http.Request(
    'GET',
    server.resolve(
      '/_matrix/client/v1/media/download/fixture/rooms/read_markers',
    ),
  );
  await client.send(media);
  check(identical(recorder.calls.last, media), 'Media path treated as receipt');
  final mediaSync = http.Request(
    'GET',
    server.resolve('/_matrix/client/v1/media/download/fixture/sync'),
  );
  await client.send(mediaSync);
  check(
    recorder.calls.last.url.queryParameters.isEmpty,
    'Media path treated as sync',
  );
  hidden = false;
  final queued = request('rooms/fixture/read_markers', {
    'm.read': 'fixture-event',
  });
  hidden = true;
  await denied(queued);
  await client.send(
    request('rooms/fixture/send/m.room.message/fixture-tx', {
      'body': 'synthetic',
    }),
  );
  check(
    recorder.calls.last.url.path.contains('/send/'),
    'Normal send suppressed',
  );
  hidden = false;
  await client.send(queued);
  client.close();
  stdout.writeln(
    'PASS final HTTP privacy recorder: foreground/background request guard, public/private/fully read, typing/presence, exact manual grant, late request and unchanged sends',
  );
}
