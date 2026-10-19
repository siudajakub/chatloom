// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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
  const PushEnrollmentFailure({this.forbidden = false});
  final bool forbidden;
  @override
  String toString() => 'Notification setup could not be completed.';
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
    throw PushEnrollmentFailure(forbidden: response.statusCode == 403);
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
