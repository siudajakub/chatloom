// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' show channelBuffers;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:fcm_shared_isolate/fcm_shared_isolate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  _Client() : super('synthetic push setup', database: _UnusedDatabase());
  @override
  bool isLogged() => true;
  @override
  String? get userID => '@synthetic-owner:example.invalid';
  @override
  String? get deviceID => 'SYNTHETIC';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fcm = MethodChannel(BackgroundPush.fcmChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await PushDiagnostics.clear();
    BackgroundPush.tokenRetryDelay = Duration.zero;
  });

  tearDown(() => messenger.setMockMethodCallHandler(fcm, null));

  test('FCM messages that arrive before the push listener exists are all '
      'kept, not only the last one', () async {
    const codec = StandardMethodCodec();
    ByteData message(int i) => codec.encodeMethodCall(
      MethodCall('message', {'event_id': '\$synthetic-$i'}),
    );
    // Flutter's default: one buffered message per channel.
    const other = 'synthetic_unresized_channel';
    for (var i = 0; i < 3; i++) {
      channelBuffers.push(other, message(i), (_) {});
    }
    var plain = 0;
    channelBuffers.setListener(other, (_, _) => plain++);
    await pumpEventQueue();
    expect(plain, 1);

    BackgroundPush.bufferEarlyMessages();
    for (var i = 0; i < 3; i++) {
      channelBuffers.push(BackgroundPush.fcmChannel, message(i), (_) {});
    }
    final received = <Map<String, Object?>>[];
    FcmSharedIsolate().setListeners(onMessage: received.add);
    await pumpEventQueue();
    expect(received.map((data) => data['event_id']), [
      r'$synthetic-0',
      r'$synthetic-1',
      r'$synthetic-2',
    ]);
  });

  test('a build without Firebase reports it once and is never retried; a '
      'transient token failure is retried when the app returns', () async {
    final client = _Client();
    final push = BackgroundPush.clientOnly([client]);
    await push.ready;
    push.firebaseEnabled = true;

    var requests = 0;
    var code = 'fcm_unavailable';
    messenger.setMockMethodCallHandler(fcm, (call) async {
      if (call.method != 'getToken') return null;
      requests++;
      throw PlatformException(code: code, message: 'synthetic');
    });

    await push.setupFirebase(client);
    // No point asking five times: FirebaseMessaging cannot start at all.
    expect(requests, 1);
    expect(
      push.registrationPhase(client),
      PushRegistrationPhase.firebaseUnavailable,
    );
    expect(push.firebaseConfigured, isFalse);
    expect(
      push.registrationDescription(client),
      contains('no Firebase push configuration'),
    );
    var setup = (await PushDiagnostics.read()).setup[PushSetupStep.token]!;
    expect(setup.ok, isFalse);
    expect(setup.detail, 'firebase_not_configured');
    push.setRegistrationForeground(true);
    await pumpEventQueue(times: 200);
    expect(requests, 1, reason: 'a build problem is not retried');

    code = 'fcm_get_token_failed';
    requests = 0;
    await push.setupFirebase(client);
    expect(requests, 5);
    expect(
      push.registrationPhase(client),
      PushRegistrationPhase.tokenUnavailable,
    );
    expect(push.firebaseConfigured, isTrue);
    setup = (await PushDiagnostics.read()).setup[PushSetupStep.token]!;
    expect(setup.detail, 'token_failed');

    // Returning to the app starts a fresh attempt once, then waits.
    push.setRegistrationForeground(false);
    push.setRegistrationForeground(true);
    await pumpEventQueue(times: 200);
    expect(requests, 10);
    push.setRegistrationForeground(false);
    push.setRegistrationForeground(true);
    await pumpEventQueue(times: 200);
    expect(requests, 10);
    push.setRegistrationForeground(false);
  });
}
