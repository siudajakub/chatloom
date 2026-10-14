// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../../../lib/personal/privacy_transport.dart';
import '../../../lib/personal/round_video/telegram_media_protocol.dart';

Future<void> main() async {
  var calls = 0, private = true, current = true;
  final server = Uri.parse('https://fixture.invalid');
  final transport = PrivacyHttpClient(
    MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }),
    incognito: () => private,
  );
  final content = <String, dynamic>{
    'version': 1,
    'request_id': 'request-fixture',
    'manual': true,
    'incognito': true,
    'explicit_grant': true,
    'source': {
      'account_id': 'fixture-login',
      'room_id': '!fixture',
      'event_id': r'$fixture',
    },
  };
  Future<void> send({
    String room = '!fixture',
    String wire = 'm.room.encrypted',
    String txid = 'fixture-tx',
  }) async {
    await transport.send(
      http.Request(
        'PUT',
        server.replace(
          pathSegments: [
            '_matrix',
            'client',
            'v3',
            'rooms',
            room,
            'send',
            wire,
            txid,
          ],
        ),
      )..body = jsonEncode({'ciphertext': 'fixture'}),
    );
  }

  Future<void> context(Future<void> Function() action) =>
      withOutgoingPrivacyContext(
        roomId: '!fixture',
        type: telegramMediaPlayedType,
        transactionId: 'fixture-tx',
        server: server,
        content: content,
        action: action,
      );
  Future<void> grant(Future<void> Function() action, {bool explicit = true}) =>
      withMediaPlayedGrant(
        roomId: '!fixture',
        eventId: r'$fixture',
        sourceAccountId: 'fixture-login',
        requestId: 'request-fixture',
        server: server,
        explicit: explicit,
        isCurrent: () => current,
        action: action,
      );
  Future<void> blocked(Future<void> Function() action) async {
    final before = calls;
    var denied = false;
    try {
      await action();
    } on PrivacySuppressed {
      denied = true;
    }
    if (!denied || calls != before)
      throw StateError('Sensitive request escaped final guard');
  }

  await blocked(() => send(wire: telegramMediaPlayedType));
  private = false;
  await blocked(() => send(wire: telegramMediaPlayedType));
  private = true;
  await blocked(() => context(() => send()));
  Future<void> forwardContext(Future<void> Function() action) =>
      withOutgoingPrivacyContext(
        roomId: '!fixture',
        type: telegramMediaForwardType,
        transactionId: 'fixture-tx',
        server: server,
        content: content,
        requireEncrypted: true,
        isCurrent: () => current,
        action: action,
      );
  await blocked(() => send(wire: telegramMediaForwardType));
  await blocked(() => forwardContext(() => send(wire: 'm.room.message')));
  await blocked(() => forwardContext(() => send(room: '!foreign')));
  current = false;
  await blocked(() => forwardContext(() => send()));
  current = true;
  await blocked(
    () => grant(() => context(() => send(wire: telegramMediaPlayedType))),
  );
  await grant(
    () => context(() async {
      await send();
      await blocked(() => send()); // same exact grant cannot be replayed.
    }),
  );
  if (calls != 1) throw StateError('Exact explicit grant count');
  await blocked(() => grant(() => context(() => send(room: '!foreign'))));
  await blocked(() => grant(() => context(() => send(txid: 'foreign-tx'))));
  current = false;
  await blocked(() => grant(() => context(() => send())));
  current = true;
  await blocked(
    () => grant(
      () => context(() async {
        private = false;
        await send(); // payload/privacy snapshot cannot change in flight.
      }),
    ),
  );
  private = true;
  content['explicit_grant'] = false;
  content['incognito'] = false;
  private = false;
  await grant(
    () => context(() async {
      private = true;
      await blocked(() => send());
      private = false;
    }),
    explicit: false,
  );
  // A suppressed grant was never queued; OFF does not send anything itself.
  if (calls != 1) throw StateError('Toggle flushed a played receipt');
  transport.close();
  print(
    'PASS round privacy: ciphertext context, exact source/txid, one request, foreground/session, toggle and no flush',
  );
}
