// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

const personalPushGateway = 'https://push.example.org/_matrix/push/v1/notify';
const personalPushRegistration =
    'https://push.example.org/_personal/push/v1/register';

bool usesAutomaticPush(String gateway) =>
    gateway.isEmpty || gateway == personalPushGateway;

String pushAccountDigest(String user) =>
    sha256.convert(utf8.encode(user)).toString();

String newPushNonce() {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

class PushEnrollmentFailure implements Exception {
  const PushEnrollmentFailure({this.forbidden = false, this.status});
  final bool forbidden;

  /// HTTP status of the gateway's reply; null when the reply was not usable.
  final int? status;
  @override
  String toString() => 'Notification setup could not be completed.';
}

/// Content-free name of why a push setup step failed, for diagnostics: a
/// fixed word or an HTTP status, never a message, token, URL or account.
String pushSetupFailureDetail(Object error) {
  if (error is PushEnrollmentFailure) {
    final status = error.status;
    if (error.forbidden) return 'forbidden';
    if (status == null) return 'bad_response';
    if (status == 503) return 'gateway_unavailable';
    return 'http_$status';
  }
  if (error is TimeoutException) return 'timeout';
  if (error is PlatformException) {
    return switch (error.code) {
      // fcm_shared_isolate: FirebaseMessaging.getInstance() threw, which
      // happens when the APK was built without google-services.json.
      'fcm_unavailable' => firebaseNotConfiguredDetail,
      'fcm_get_token_failed' => 'token_failed',
      _ => 'platform_error',
    };
  }
  if (error is MatrixException) {
    final code = error.errcode.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_]'),
      '',
    );
    return code.isEmpty ? 'matrix_error' : 'matrix_$code';
  }
  if (error is SocketException ||
      error is HandshakeException ||
      error is http.ClientException) {
    return 'network';
  }
  return 'error';
}

/// [pushSetupFailureDetail] of a build without Firebase configuration.
const firebaseNotConfiguredDetail = 'firebase_not_configured';

/// What a plain GET of the notify URL said about the gateway. Answers "is the
/// domain configured?" from the phone itself, without sending anything.
enum PushGatewayReachability { online, unexpected, unreachable }

class PushGatewayProbe {
  const PushGatewayProbe(this.reachability, [this.status]);
  final PushGatewayReachability reachability;
  final int? status;
}

/// GET without a body, credentials or redirects. A Matrix push gateway answers
/// 405 (POST only); a UnifiedPush-style gateway answers 200 with a discovery
/// document. Anything else means the address does not lead to a gateway.
Future<PushGatewayProbe> probePushGateway(
  http.Client transport,
  String url,
) async {
  try {
    final request = http.Request('GET', Uri.parse(url))
      ..followRedirects = false;
    final response = await transport
        .send(request)
        .timeout(const Duration(seconds: 10));
    // Only the status matters; drain at most a little of the body.
    await response.stream
        .take(4)
        .drain<void>()
        .timeout(const Duration(seconds: 5))
        .catchError((Object _) {});
    final status = response.statusCode;
    return PushGatewayProbe(
      status == 405 || status == 200
          ? PushGatewayReachability.online
          : PushGatewayReachability.unexpected,
      status,
    );
  } catch (_) {
    return const PushGatewayProbe(PushGatewayReachability.unreachable);
  }
}

/// Only a short-lived OpenID proof is shared with the fixed private gateway.
/// Never send the Matrix session token or follow a redirect with this payload.
Future<bool> enrollAutomaticPush({
  required http.Client transport,
  required String user,
  required String appId,
  required String token,
  required String nonce,
  required Future<Map<String, Object?>> Function() openId,
  required bool Function() current,
}) async {
  if (!current()) return false;
  final proof = await openId().timeout(const Duration(seconds: 15));
  if (!current()) return false;
  final request = http.Request('POST', Uri.parse(personalPushRegistration))
    ..followRedirects = false
    ..headers['content-type'] = 'application/json'
    ..body = jsonEncode({
      'app_id': appId,
      'pushkey': token,
      'nonce': nonce,
      'account_sha256': pushAccountDigest(user),
      'openid': proof,
    });
  final response = await transport
      .send(request)
      .timeout(const Duration(seconds: 20));
  final bytes = await response.stream
      .expand((chunk) => chunk)
      .take(4097)
      .toList()
      .timeout(const Duration(seconds: 20));
  if (!current()) return false;
  if (response.statusCode != 200 || bytes.length > 4096) {
    throw PushEnrollmentFailure(
      forbidden: response.statusCode == 403,
      status: response.statusCode == 200 ? null : response.statusCode,
    );
  }
  try {
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map || body['registered'] != true) {
      throw const PushEnrollmentFailure();
    }
  } on FormatException {
    throw const PushEnrollmentFailure();
  }
  return true;
}
