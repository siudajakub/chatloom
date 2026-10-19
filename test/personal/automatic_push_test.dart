// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/personal/automatic_push.dart';
import 'package:fluffychat/personal/push_registration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const user = '@synthetic:matrix.beeper.com';
  const token = 'synthetic-device-token';
  final nonce = 'n' * 43;
  final proof = <String, Object?>{
    'access_token': 'synthetic-short-lived-proof',
    'matrix_server_name': 'matrix.beeper.com',
    'token_type': 'Bearer',
    'expires_in': 3600,
  };

  Future<bool> enroll(
    http.Client transport, {
    Future<Map<String, Object?>> Function()? openId,
    bool Function()? current,
  }) => enrollAutomaticPush(
    transport: transport,
    user: user,
    appId: 'pl.personal.chat.FIXTURE',
    token: token,
    nonce: nonce,
    openId: openId ?? () async => proof,
    current: current ?? () => true,
  );

  test('default and legacy empty configuration use automatic setup', () {
    expect(usesAutomaticPush(''), isTrue);
    expect(usesAutomaticPush(personalPushGateway), isTrue);
    expect(usesAutomaticPush('https://custom.invalid/notify'), isFalse);
    final values = List.generate(20, (_) => newPushNonce());
    expect(values.every(validGatewayNonce), isTrue);
    expect(values.toSet().length, values.length);
  });

  test(
    'fixed HTTPS endpoint receives only short-lived identity proof',
    () async {
      var posts = 0;
      final transport = MockClient((request) async {
        posts++;
        expect(request.url.toString(), personalPushRegistration);
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(request.body) as Map;
        expect(body.keys.toSet(), {
          'app_id',
          'pushkey',
          'nonce',
          'account_sha256',
          'openid',
        });
        expect(body['account_sha256'], pushAccountDigest(user));
        expect(body['openid'], proof);
        expect(body['pushkey'], token);
        expect(body['nonce'], nonce);
        expect(request.body.contains(user), isFalse);
        return http.Response('{"registered":true}', 200);
      });
      addTearDown(transport.close);
      expect(await enroll(transport), isTrue);
      expect(posts, 1);
    },
  );

  test(
    'invalidated ownership prevents identity request and enrollment',
    () async {
      var proofs = 0, posts = 0;
      final transport = MockClient((_) async {
        posts++;
        return http.Response('{"registered":true}', 200);
      });
      addTearDown(transport.close);
      expect(
        await enroll(
          transport,
          current: () => false,
          openId: () async {
            proofs++;
            return proof;
          },
        ),
        isFalse,
      );
      expect(proofs, 0);
      expect(posts, 0);
    },
  );

  test('logout or token rotation during OpenID prevents POST', () async {
    var current = true, posts = 0;
    final pending = Completer<Map<String, Object?>>();
    final transport = MockClient((_) async {
      posts++;
      return http.Response('{"registered":true}', 200);
    });
    addTearDown(transport.close);
    final task = enroll(
      transport,
      current: () => current,
      openId: () => pending.future,
    );
    current = false;
    pending.complete(proof);
    expect(await task, isFalse);
    expect(posts, 0);
  });

  test('a stale HTTP success never becomes configured state', () async {
    var current = true;
    final transport = MockClient((_) async {
      current = false;
      return http.Response('{"registered":true}', 200);
    });
    addTearDown(transport.close);
    expect(await enroll(transport, current: () => current), isFalse);
  });

  test(
    'redirect, offline, unprovisioned gateway and bad ACK fail closed',
    () async {
      for (final response in [
        http.Response('', 302, headers: {'location': 'https://other.invalid'}),
        http.Response('{"errcode":"M_REGISTRATION_DISABLED"}', 503),
        http.Response('{}', 200),
        http.Response('{"registered":"true"}', 200),
        http.Response('not-json', 200),
        http.Response('x' * 4097, 200),
      ]) {
        final transport = MockClient((_) async => response);
        addTearDown(transport.close);
        await expectLater(
          enroll(transport),
          throwsA(isA<PushEnrollmentFailure>()),
        );
      }
      final offline = MockClient(
        (_) async => throw http.ClientException('synthetic offline'),
      );
      addTearDown(offline.close);
      await expectLater(enroll(offline), throwsA(isA<http.ClientException>()));
    },
  );

  test('authorization failure has safe actionable state', () async {
    final transport = MockClient((_) async => http.Response('{}', 403));
    addTearDown(transport.close);
    await expectLater(
      enroll(transport),
      throwsA(
        isA<PushEnrollmentFailure>()
            .having((e) => e.forbidden, 'forbidden', isTrue)
            .having(
              (e) => e.toString().contains(token),
              'safe diagnostic',
              isFalse,
            ),
      ),
    );
    final state = PushRegistration()
      ..phase = PushRegistrationPhase.automaticallyConfigured;
    expect(state.description, contains('delivery has not been tested'));
    state.phase = PushRegistrationPhase.permissionRequired;
    expect(state.description, contains('Android settings'));
  });
}
