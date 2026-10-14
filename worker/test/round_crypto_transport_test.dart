// SPDX-License-Identifier: AGPL-3.0-or-later
// Real Matrix SDK attachment + Megolm crypto, fake HTTP only, synthetic content.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import '../../lib/personal/media/immediate_media_outbox.dart';
import '../../lib/personal/media/pending_media_store.dart';
import '../../lib/personal/privacy_transport.dart';

class _RecordedFakeApi extends FakeMatrixApi {
  final uploaded = <String, Uint8List>{};
  final wire = <Map<String, dynamic>>[];
  final wirePaths = <String>[];
  final acceptedByTxid = <String, String>{};
  bool loseAck = false;
  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    if (request.method == 'POST' && request.url.path.contains('/keys/upload')) {
      final body = jsonDecode(request.body) as Map;
      return http.Response(
        jsonEncode({
          'one_time_key_counts': {
            'signed_curve25519': (body['one_time_keys'] as Map?)?.length ?? 0,
          },
        }),
        200,
      );
    }
    if (request.method == 'POST' && request.url.path.endsWith('/upload')) {
      final key = 'media-${uploaded.length}';
      uploaded[key] = Uint8List.fromList(request.bodyBytes);
      return http.Response(
        jsonEncode({'content_uri': 'mxc://fakeServer.notExisting/$key'}),
        200,
      );
    }
    if (request.method == 'PUT' && request.url.path.contains('/send/')) {
      wirePaths.add(request.url.path);
      wire.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      final txn = request.url.pathSegments.last;
      final id = acceptedByTxid.putIfAbsent(
        txn,
        () => '\$fixture-${acceptedByTxid.length}',
      );
      if (loseAck) {
        loseAck = false;
        throw TimeoutException('synthetic lost ACK');
      }
      return http.Response(jsonEncode({'event_id': id}), 200);
    }
    return super.mockIntercept(request);
  }
}

Map<String, dynamic> _fileJson(EncryptedFile file) => {
  'v': 'v2',
  'iv': file.iv,
  'key': {
    'kty': 'oct',
    'alg': 'A256CTR',
    'k': file.k,
    'ext': true,
    'key_ops': ['encrypt', 'decrypt'],
  },
  'hashes': {'sha256': file.sha256},
};

Future<Client> _client(
  _RecordedFakeApi api,
  DatabaseFactory factory,
  String cipher,
  bool Function() incognito,
) async {
  final db = await factory.openDatabase(
    ':memory:',
    options: OpenDatabaseOptions(
      singleInstance: false,
      onConfigure: (db) async {
        await db.execute("PRAGMA key = '$cipher'");
      },
    ),
  );
  final client = Client(
    'synthetic round crypto',
    httpClient: PrivacyHttpClient(api, incognito: incognito),
    database: await MatrixSdkDatabase.init(
      'synthetic-round',
      database: db,
      sqfliteFactory: factory,
      maxFileSize: 0,
    ),
    shareKeysWith: ShareKeysWith.directlyVerifiedOnly,
    receiptsPublicByDefault: false,
    logLevel: Level.error,
    sendTimelineEventTimeout: const Duration(seconds: 2),
  );
  FakeMatrixApi.client = client;
  client.syncPresence = PresenceType.offline;
  await client.checkHomeserver(
    Uri.parse('https://fakeServer.notExisting'),
    checkWellKnown: false,
  );
  await client.init(
    newToken: 'synthetic-no-account-token',
    newUserID: '@test:fakeServer.notExisting',
    newDeviceID: 'ROUND_FIXTURE',
    newHomeserver: client.homeserver,
  );
  await client.roomsLoading;
  await client.accountDataLoading;
  await client.abortSync();
  return client;
}

void main() {
  test(
    'real SDK round attachments + E2EE stable outbox + custom played source',
    () async {
      await vod.init(
        libraryPath: '${Directory.current.path}/build/native/bundle/lib/',
      );
      final temp = await Directory.systemTemp.createTemp(
        'round_real_sdk_fixture_',
      );
      final cipher = base64UrlEncode(List<int>.filled(32, 71));
      final factory = createDatabaseFactoryFfi(noIsolate: true);
      final api = _RecordedFakeApi();
      var private = true;
      final client = await _client(api, factory, cipher, () => private);
      var store = await PendingMediaStore.open(
        path: '${temp.path}/pending.sqlite',
        cipher: cipher,
        factory: factory,
      );
      try {
        expect(client.encryptionEnabled, isTrue);
        final room = Room(
          id: '!round-fixture:fakeServer.notExisting',
          client: client,
          membership: Membership.join,
        );
        client.rooms.add(room);
        void state(
          String type,
          Map<String, dynamic> content, {
          String key = '',
        }) => room.setState(
          Event(
            room: room,
            type: type,
            stateKey: key,
            content: content,
            senderId: client.userID!,
            eventId: r'$fixture-state',
            originServerTs: DateTime.utc(2026),
          ),
        );
        state(EventTypes.RoomMember, {
          'membership': 'join',
        }, key: client.userID!);
        state('m.room.encryption', {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
        });
        expect(room.encrypted, isTrue);
        var acceptedReplyHooks = 0, encryptionCount = 0;
        var togglePrivateAtPlayedRequest = false;
        var currentSession = true;
        final originals = <String>[];
        client.captureOutgoingContext = (_, type) =>
            type == EventTypes.Message ? 'fixture-context' : null;
        client.onOutgoingAccepted = (_, _, _) async {
          acceptedReplyHooks++;
        };
        client.authorizeOutgoingEvent = (_, type, content) {
          if (type == EventTypes.Message) {
            expect((content['info'] as Map)[roundMessageMarker], isTrue);
            expect(content['file'], isA<Map>());
          } else {
            expect(type, telegramMediaPlayedEventType);
            expect((content['source'] as Map)['event_id'], r'$source-round');
            authorizeMediaPlayed(content, private);
          }
        };
        client.wrapOutgoingRequest = (room, type, content, txn, send) async {
          originals.add(type);
          if (type == telegramMediaPlayedEventType &&
              togglePrivateAtPlayedRequest) {
            private = true;
          }
          return withOutgoingPrivacyContext(
            roomId: room.id,
            type: type,
            transactionId: txn,
            server: client.homeserver!,
            content: content,
            requireEncrypted: true,
            isCurrent: () => currentSession,
            action: send,
          );
        };
        final raw = Uint8List.fromList(
          utf8.encode('synthetic_round_original_bytes_20261012'),
        );
        final thumbnail = Uint8List.fromList(
          utf8.encode('synthetic_round_thumbnail_bytes'),
        );
        final target = RoundSendTarget(
          accountId: client.userID!,
          deviceId: client.deviceID!,
          roomId: room.id,
          network: 'telegram',
          replyEventId: r'$source-round',
        );
        final descriptor = RoundVideoDescriptor(
          sizeBytes: raw.length,
          width: 384,
          height: 384,
          durationMs: 5000,
          videoCodec: 'h264',
          audioCodec: 'aac',
          cornersSanitized: true,
        );
        ImmediateMediaOutbox outbox() => ImmediateMediaOutbox(
          accountId: target.accountId,
          deviceId: target.deviceId,
          store: store,
          newActionId: () => 'real-sdk-round',
          guard: (_, _) async {},
          encrypt: (bytes, thumb) async {
            encryptionCount++;
            final file = await MatrixFile(
              bytes: bytes,
              name: 'round.mp4',
              mimeType: 'video/mp4',
            ).encrypt();
            final preview = await MatrixFile(
              bytes: thumb!,
              name: 'round.jpg',
              mimeType: 'image/jpeg',
            ).encrypt();
            return RoundEncryptionResult(
              bytes: file.data,
              fileDescriptor: _fileJson(file),
              thumbnailBytes: preview.data,
              thumbnailDescriptor: _fileJson(preview),
            );
          },
          upload: (_, bytes, part) => client.uploadContent(
            bytes,
            contentType: 'application/octet-stream',
            filename: 'round-$part.enc',
          ),
          sendEvent: (_, content, txn) => room.sendEvent(
            Map<String, dynamic>.from(jsonDecode(jsonEncode(content)) as Map),
            txid: txn,
            displayPendingEvent: false,
            retryOnTransportFailure: false,
          ),
        );
        var sender = outbox();
        final staged = await sender.stage(
          target: target,
          descriptor: descriptor,
          profile: const RoundEncodingProfile(maxSizeBytes: 100000),
          bytes: raw,
          thumbnailBytes: thumbnail,
        );
        api.loseAck = true;
        final unknown = await sender.dispatch(staged.actionId);
        expect(unknown.state, ImmediateMediaState.unknown);
        final persisted = (await store.get(staged.actionId))!;
        final fileCipher = Uint8List.fromList(persisted.encryptedBytes!);
        final thumbCipher = Uint8List.fromList(
          persisted.encryptedThumbnailBytes!,
        );
        final descriptors = jsonEncode([
          persisted.metadata['fileDescriptor'],
          persisted.metadata['thumbnailDescriptor'],
          persisted.metadata['finalContent'],
        ]);
        expect(fileCipher, isNot(orderedEquals(raw)));
        expect(thumbCipher, isNot(orderedEquals(thumbnail)));
        expect(api.uploaded.length, 2);
        expect(
          api.uploaded.values.any((v) => base64Encode(v) == base64Encode(raw)),
          isFalse,
        );
        await store.close();
        store = await PendingMediaStore.open(
          path: '${temp.path}/pending.sqlite',
          cipher: cipher,
          factory: factory,
        );
        sender = outbox();
        final accepted = await sender.dispatch(staged.actionId);
        expect(accepted.state, ImmediateMediaState.matrixAccepted);
        expect(accepted.transactionId, unknown.transactionId);
        expect(api.acceptedByTxid.length, 1);
        expect(api.uploaded.length, 2);
        expect(encryptionCount, 1);
        final restored = (await store.get(staged.actionId))!;
        expect(restored.encryptedBytes, orderedEquals(fileCipher));
        expect(restored.encryptedThumbnailBytes, orderedEquals(thumbCipher));
        expect(
          jsonEncode([
            restored.metadata['fileDescriptor'],
            restored.metadata['thumbnailDescriptor'],
            restored.metadata['finalContent'],
          ]),
          descriptors,
        );
        expect(
          api.wirePaths.every((p) => p.contains('/send/m.room.encrypted/')),
          isTrue,
        );
        expect(
          api.wire.every(
            (v) =>
                v['ciphertext'] is String &&
                v['msgtype'] == null &&
                v['file'] == null,
          ),
          isTrue,
        );
        final decrypted = await client.encryption!.decryptRoomEvent(
          Event(
            room: room,
            type: EventTypes.Encrypted,
            content: api.wire.last,
            eventId: accepted.eventId!,
            senderId: client.userID!,
            originServerTs: DateTime.utc(2026),
          ),
        );
        expect(decrypted.type, EventTypes.Message);
        expect(
          decrypted.content.containsKey(telegramSendOptionsKey),
          isFalse,
          reason: 'Normal round must not acquire silent/schedule options',
        );
        expect((decrypted.content['info'] as Map)[roundMessageMarker], isTrue);
        expect(
          ((decrypted.content['m.relates_to'] as Map)['m.in_reply_to']
              as Map)['event_id'],
          r'$source-round',
        );
        final loaded = await decrypted.downloadAndDecryptAttachment(
          cacheAttachment: false,
          downloadCallback: (_) async => fileCipher,
        );
        final loadedThumbnail = await decrypted.downloadAndDecryptAttachment(
          getThumbnail: true,
          cacheAttachment: false,
          downloadCallback: (_) async => thumbCipher,
        );
        expect(loaded.bytes, orderedEquals(raw));
        expect(loadedThumbnail.bytes, orderedEquals(thumbnail));
        final damaged = Uint8List.fromList(fileCipher)..[0] ^= 1;
        await expectLater(
          decrypted.downloadAndDecryptAttachment(
            cacheAttachment: false,
            downloadCallback: (_) async => damaged,
          ),
          throwsA(anything),
        );
        await Future<void>.delayed(Duration.zero);
        final hooksBeforePlayed = acceptedReplyHooks;
        Map<String, dynamic> playedContent(String id, bool explicit) => {
          'version': 1,
          'request_id': id,
          'created_at_ms': DateTime.utc(2026).millisecondsSinceEpoch,
          'manual': true,
          'incognito': private,
          'explicit_grant': explicit,
          'source': {
            'account_id': 'fixture-bridge-login',
            'room_id': room.id,
            'event_id': r'$source-round',
          },
        };
        Future<String?> sendPlayed(String id, bool explicit) => room.sendEvent(
          playedContent(id, explicit),
          type: telegramMediaPlayedEventType,
          txid: id,
          displayPendingEvent: false,
          retryOnTransportFailure: false,
        );
        final wiresBeforePlayed = api.wire.length;
        await expectLater(
          sendPlayed('ungranted-played', false),
          throwsA(isA<PrivacySuppressed>()),
        );
        expect(api.wire.length, wiresBeforePlayed);
        await withMediaPlayedGrant(
          roomId: room.id,
          eventId: r'$source-round',
          sourceAccountId: 'fixture-bridge-login',
          requestId: 'played-fixture',
          server: client.homeserver!,
          explicit: true,
          isCurrent: () => true,
          action: () => sendPlayed('played-fixture', true),
        );
        await Future<void>.delayed(Duration.zero);
        expect(acceptedReplyHooks, hooksBeforePlayed);
        expect(originals.last, telegramMediaPlayedEventType);
        expect(api.wirePaths.last, contains('/send/m.room.encrypted/'));
        final played = await client.encryption!.decryptRoomEvent(
          Event(
            room: room,
            type: EventTypes.Encrypted,
            content: api.wire.last,
            eventId: r'$played',
            senderId: client.userID!,
            originServerTs: DateTime.utc(2026),
          ),
        );
        expect(played.type, telegramMediaPlayedEventType);
        expect((played.content['source'] as Map)['event_id'], r'$source-round');
        expect(played.content['msgtype'], isNull);
        currentSession = false;
        final beforeSessionChange = api.wire.length;
        await expectLater(
          withMediaPlayedGrant(
            roomId: room.id,
            eventId: r'$source-round',
            sourceAccountId: 'fixture-bridge-login',
            requestId: 'changed-session',
            server: client.homeserver!,
            explicit: true,
            isCurrent: () => true,
            action: () => sendPlayed('changed-session', true),
          ),
          throwsA(isA<PrivacySuppressed>()),
        );
        expect(api.wire.length, beforeSessionChange);
        currentSession = true;
        private = false;
        togglePrivateAtPlayedRequest = true;
        final beforeToggle = api.wire.length;
        await expectLater(
          withMediaPlayedGrant(
            roomId: room.id,
            eventId: r'$source-round',
            sourceAccountId: 'fixture-bridge-login',
            requestId: 'late-played',
            server: client.homeserver!,
            explicit: false,
            isCurrent: () => true,
            action: () => sendPlayed('late-played', false),
          ),
          throwsA(isA<PrivacySuppressed>()),
        );
        expect(
          api.wire.length,
          beforeToggle,
          reason: 'Incognito changed after encryption still reached transport',
        );
        private = false;
        togglePrivateAtPlayedRequest = false;
        await Future<void>.delayed(Duration.zero);
        expect(
          api.wire.length,
          beforeToggle,
          reason: 'Suppressed played flushed after OFF',
        );
        expect(
          FakeMatrixApi.calledEndpoints.keys.any(
            (p) =>
                p.contains('/receipt/') ||
                p.contains('/read_markers') ||
                p.contains('/typing/'),
          ),
          isFalse,
        );
      } finally {
        await store.close();
        await client.dispose(closeDatabase: true);
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
