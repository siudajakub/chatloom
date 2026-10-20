// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:chatloom/personal/ui/conversation_content_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    int? limit,
    bool includeSending = false,
  }) async => [];
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    int? limit,
    bool onlySending = false,
  }) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  final List<(String, String)> requests;
  _Client(this.requests)
    : super(
        'synthetic content transport',
        database: _Database(),
        httpClient: MockClient((request) async {
          requests.add((request.method, request.url.path));
          return http.Response(
            jsonEncode({
              'start': 'initial',
              'end': 'older',
              'chunk': [
                {
                  'event_id': r'$visible',
                  'type': EventTypes.Message,
                  'sender': '@fixture:example.invalid',
                  'origin_server_ts': 1,
                  'content': {
                    'msgtype': MessageTypes.Text,
                    'body': 'https://example.org/reference',
                  },
                },
                {
                  'event_id': r'$encrypted',
                  'type': EventTypes.Encrypted,
                  'sender': '@fixture:example.invalid',
                  'origin_server_ts': 2,
                  'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
                },
              ],
            }),
            200,
          );
        }),
      );
  @override
  Uri get baseUri => Uri.parse('https://fixture.example.invalid/');
  @override
  String get bearerToken => 'synthetic-not-a-credential';
  @override
  String get userID => '@fixture:example.invalid';
}

void main() {
  test(
    'SDK history adapter issues only explicit GET messages; local search and retry never send conversation mutations',
    () async {
      final requests = <(String, String)>[];
      final client = _Client(requests);
      final room = Room(
        id: '!fixture:example.invalid',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(room);
      final c = ConversationContentController([
        MatrixContentSource(room),
      ], unlocked: () => true);
      await c.load();
      expect(requests, isEmpty);
      await c.load(remote: true);
      expect(c.events.length, 2);
      expect(c.encrypted, 1);
      expect(c.remoteEnd, isFalse);
      for (final e in c.events) {
        sharedLinks(e);
      }
      await c.retryEncrypted();
      expect(c.encrypted, 1);
      expect(requests.length, 1);
      expect(requests.single.$1, 'GET');
      expect(requests.single.$2, endsWith('/messages'));
      await c.load(remote: true);
      expect(c.sources.single.error, isNotNull); // Same cursor stops.
      expect(
        requests.every((r) => r.$1 == 'GET' && r.$2.endsWith('/messages')),
        isTrue,
      );
      expect(c.events.length, 2);
      c.dispose();
    },
  );
}
