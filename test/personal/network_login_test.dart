// SPDX-License-Identifier: AGPL-3.0-or-later
// In-app "Add network" (wave 8): the bridgev2 provisioning login client,
// the sign-in state machine, the bridge catalog, API sign-out and the
// wizard screen. A fake transport answers every request; no real bridge,
// network or account is involved and all ids and codes are fictional.
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/network_login/network_login_api.dart';
import 'package:chatloom/personal/network_login/network_login_catalog.dart';
import 'package:chatloom/personal/network_login/network_login_session.dart';
import 'package:chatloom/personal/network_sign_out.dart';
import 'package:chatloom/personal/ui/add_network_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

const _bot = '@sh-whatsappbot:beeper.local';
const _bridge = BridgeEndpoint(
  botId: _bot,
  network: 'whatsapp',
  label: 'WhatsApp',
);

/// One request as the fake saw it.
typedef _Seen = ({
  String bot,
  String method,
  String path,
  Map<String, String> query,
  Map<String, Object?>? body,
});

typedef _Handler =
    FutureOr<Object?> Function(
      BridgeEndpoint bridge,
      BridgeProvisioningRequest r,
    );

class _FakeTransport implements BridgeProvisioningTransport {
  _FakeTransport(this.handler);

  _Handler handler;
  final seen = <_Seen>[];

  List<String> get paths => [for (final r in seen) '${r.method} ${r.path}'];

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) async {
    seen.add((
      bot: bridge.botId,
      method: request.method,
      path: request.path,
      query: request.query,
      body: request.body,
    ));
    return handler(bridge, request);
  }
}

Map<String, Object?> _step(
  String type,
  String id, {
  String txn = 'bls_1',
  String instructions = '',
  Map<String, Object?>? params,
  String process = 'proc-1',
}) => {
  'login_id': process,
  'type': type,
  'step_id': id,
  'txn_id': txn,
  'instructions': instructions,
  type: ?params,
};

Map<String, Object?> _qr(String data, {String txn = 'bls_qr'}) => _step(
  'display_and_wait',
  'fi.mau.whatsapp.qr',
  txn: txn,
  instructions: 'Scan the QR code.',
  params: {'type': 'qr', 'data': data},
);

Map<String, Object?> _complete({String login = 'login-new'}) => _step(
  'complete',
  'fi.mau.whatsapp.complete',
  params: {'user_login_id': login},
);

Never _fail(int status, [String? errcode, String? message]) =>
    throw BridgeProvisioningException(
      status,
      errcode: errcode,
      message: message,
    );

class _NoDb implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

Client _client(String name) => Client(name, database: _NoDb());

Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 50),
);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.tap(finder);
}

Future<void> _enterVisible(
  WidgetTester tester,
  Finder finder,
  String text,
) async {
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.enterText(finder, text);
}

void main() {
  group('models', () {
    test('steps parse per type and unknown types are unsupported', () {
      final qr = NetworkLoginProgress.parse(_qr('2@fictional'));
      expect(qr.processId, 'proc-1');
      expect(qr.step.type, NetworkLoginStepType.displayAndWait);
      expect(qr.step.display, NetworkLoginDisplay.qr);
      expect(qr.step.displayData, '2@fictional');
      expect(qr.step.txnId, 'bls_qr');

      final input = NetworkLoginStep.fromJson(
        _step(
          'user_input',
          'fi.mau.telegram.phone',
          params: {
            'can_cancel': true,
            'fields': [
              {'type': 'phone_number', 'id': 'phone', 'name': 'Phone number'},
              {
                'type': 'select',
                'id': 'mode',
                'name': 'Mode',
                'options': ['a', 'b'],
              },
              {'type': '2fa_code', 'id': 'code', 'optional': true},
              {'type': 'something_new', 'id': 'x'},
              {'type': 'password'}, // no id: dropped
            ],
          },
        ),
      )!;
      expect(input.type, NetworkLoginStepType.userInput);
      expect(input.canCancel, isTrue);
      expect(input.fields.map((f) => f.type), [
        NetworkLoginFieldType.phoneNumber,
        NetworkLoginFieldType.select,
        NetworkLoginFieldType.twoFactorCode,
        NetworkLoginFieldType.text,
      ]);
      expect(input.fields[1].options, ['a', 'b']);
      expect(input.fields[2].optional, isTrue);

      final cookies = NetworkLoginStep.fromJson(
        _step(
          'cookies',
          'fi.mau.meta.cookies',
          params: {
            'url': 'https://www.example.invalid/login',
            'fields': [
              {
                'id': 'c_user',
                'required': true,
                'sources': [
                  {
                    'type': 'cookie',
                    'name': 'c_user',
                    'cookie_domain': '.example.invalid',
                  },
                ],
              },
              {
                'id': 'xs',
                'sources': [
                  {'type': 'cookie', 'name': 'xs'},
                ],
              },
            ],
          },
        ),
      )!;
      expect(cookies.cookieUrl?.host, 'www.example.invalid');
      expect(cookies.cookieFields.map((f) => f.id), ['c_user', 'xs']);
      expect(
        cookies.cookieFields.first.sources.single.describe,
        'Cookie c_user on example.invalid',
      );

      final unsafe = NetworkLoginStep.fromJson(
        _step(
          'cookies',
          'x',
          params: {'url': 'javascript:alert(1)', 'fields': []},
        ),
      )!;
      expect(unsafe.cookieUrl, isNull);

      expect(
        NetworkLoginStep.fromJson(_step('webauthn', 'x'))!.type,
        NetworkLoginStepType.unsupported,
      );
      expect(
        NetworkLoginStep.fromJson(_step('client_http', 'x'))!.type,
        NetworkLoginStepType.unsupported,
      );
      expect(
        () => NetworkLoginProgress.parse({'type': 'complete'}),
        throwsA(isA<BridgeProvisioningException>()),
      );
    });

    test('field validation mirrors the bridge', () {
      const phone = NetworkLoginField(
        id: 'phone',
        type: NetworkLoginFieldType.phoneNumber,
        name: 'Phone number',
      );
      expect(phone.validate('+48 600-100 (200)').value, '+48600100200');
      expect(phone.validate('600100200').error, isNotNull);
      expect(phone.validate('').error, 'Enter phone number.');
      const optional = NetworkLoginField(
        id: 'x',
        type: NetworkLoginFieldType.text,
        optional: true,
      );
      expect(optional.validate('').value, '');
      const email = NetworkLoginField(
        id: 'e',
        type: NetworkLoginFieldType.email,
      );
      expect(email.validate('nobody').error, isNotNull);
      const select = NetworkLoginField(
        id: 's',
        type: NetworkLoginFieldType.select,
        options: ['a'],
      );
      expect(select.validate('b').error, isNotNull);
      expect(select.validate('a').value, 'a');
      const code = NetworkLoginField(
        id: 'c',
        type: NetworkLoginFieldType.twoFactorCode,
        pattern: r'^\d{6}$',
        maxLength: 6,
      );
      expect(code.validate('12345a').error, isNotNull);
      expect(code.validate('1234567').error, isNotNull);
      expect(code.validate('123456').value, '123456');
      // A password keeps its spaces.
      const password = NetworkLoginField(
        id: 'p',
        type: NetworkLoginFieldType.password,
      );
      expect(password.validate(' pass word ').value, ' pass word ');
      // A pattern Dart can't compile is left to the bridge.
      const odd = NetworkLoginField(
        id: 'o',
        type: NetworkLoginFieldType.token,
        pattern: '(?P<x>a',
      );
      expect(odd.validate('anything').value, 'anything');
    });

    test('a pasted Cookie header fills the fields it names', () {
      const fields = [
        NetworkCookieField(
          id: 'c_user',
          sources: [NetworkCookieSource(type: 'cookie', name: 'c_user')],
        ),
        NetworkCookieField(
          id: 'xs',
          sources: [NetworkCookieSource(type: 'cookie', name: 'xs')],
        ),
        NetworkCookieField(
          id: 'csrf',
          required: false,
          sources: [
            NetworkCookieSource(type: 'request_header', name: 'x-csrf'),
          ],
        ),
      ];
      expect(
        parseCookieHeader(
          'Cookie: datr=zzz; c_user=1000; xs="abc%3Adef"; other=1',
          fields,
        ),
        {'c_user': '1000', 'xs': 'abc%3Adef'},
      );
      expect(parseCookieHeader('nothing here', fields), isEmpty);
      expect(fields[2].check(''), isNull);
      expect(fields[0].check(''), isNotNull);
    });

    test('errors map to kinds with human text', () {
      NetworkLoginErrorKind kind(int status, [String? code]) =>
          NetworkLoginException.from(
            BridgeProvisioningException(status, errcode: code),
          ).kind;
      expect(
        kind(410, 'FI.MAU.BRIDGE.LOGIN_CANCELLED'),
        NetworkLoginErrorKind.expired,
      );
      expect(
        kind(410, 'FI.MAU.BRIDGE.LOGIN_TIMED_OUT'),
        NetworkLoginErrorKind.expired,
      );
      expect(kind(404, 'M_NOT_FOUND'), NetworkLoginErrorKind.expired);
      expect(
        kind(403, 'FI.MAU.BRIDGE.TOO_MANY_LOGINS'),
        NetworkLoginErrorKind.tooManyLogins,
      );
      expect(kind(403, 'M_FORBIDDEN'), NetworkLoginErrorKind.forbidden);
      expect(kind(404, 'M_UNRECOGNIZED'), NetworkLoginErrorKind.unsupported);
      expect(kind(401, 'M_UNKNOWN_TOKEN'), NetworkLoginErrorKind.unreachable);
      expect(kind(0), NetworkLoginErrorKind.unreachable);
      expect(kind(502), NetworkLoginErrorKind.unreachable);
      expect(
        kind(400, 'FI.MAU.WHATSAPP.BAD_CODE'),
        NetworkLoginErrorKind.rejected,
      );
      final rejected = NetworkLoginException.from(
        const BridgeProvisioningException(
          400,
          errcode: 'X',
          message: 'Invalid code',
        ),
      );
      expect(rejected.describe('WhatsApp'), 'Invalid code');
      // Diagnostics carry status and errcode only, never the message.
      expect(rejected.toString(), isNot(contains('Invalid code')));
    });
  });

  group('api', () {
    test('requests follow the bridgev2 routes', () async {
      final transport = _FakeTransport((bridge, r) {
        if (r.path == '/v3/login/flows') {
          return {
            'flows': [
              {'id': 'qr', 'name': 'QR', 'description': 'Scan'},
              {'id': 'phone', 'name': 'Pairing code'},
              {'name': 'no id'},
            ],
          };
        }
        if (r.path.startsWith('/v3/login/start/')) return _qr('2@a');
        if (r.path.endsWith('/user_input')) return _complete();
        if (r.path.endsWith('/cancel')) return _qr('2@b');
        if (r.path == '/v3/logins') {
          return {
            'login_ids': ['a', 'b', 3],
          };
        }
        return const {};
      });
      final api = NetworkLoginApi(transport);
      final flows = await api.flows(_bridge);
      expect(flows.map((f) => f.id), ['qr', 'phone']);
      final started = await api.start(_bridge, 'qr', relogin: 'old');
      final step = NetworkLoginStep.fromJson(
        _step('user_input', 'fi.mau.x/y', txn: 'bls_9'),
      )!;
      await api.submitInput(_bridge, 'proc-1', step, {'phone': '+1'});
      await api.cancelStep(_bridge, 'proc-1', started.step);
      await api.cancel(_bridge, 'proc-1');
      await api.logout(_bridge, 'login a');
      expect(await api.logins(_bridge), ['a', 'b']);
      expect(transport.paths, [
        'GET /v3/login/flows',
        'POST /v3/login/start/qr',
        'POST /v3/login/step/proc-1/fi.mau.x%2Fy/user_input',
        'POST /v3/login/step/proc-1/fi.mau.whatsapp.qr/cancel',
        'POST /v3/login/cancel/proc-1',
        'POST /v3/logout/login%20a',
        'GET /v3/logins',
      ]);
      expect(transport.seen[1].query, {'login_id': 'old'});
      expect(transport.seen[2].query, {'txn_id': 'bls_9'});
      expect(transport.seen[2].body, {'phone': '+1'});
    });

    test('long polls use the wait transport', () async {
      final short = _FakeTransport((_, _) => _complete());
      final long = _FakeTransport((_, _) => _complete());
      final api = NetworkLoginApi(short, waitTransport: long);
      final step = NetworkLoginProgress.parse(_qr('x')).step;
      await api.wait(_bridge, 'proc-1', step);
      await api.flows(_bridge);
      expect(long.paths, [
        'POST /v3/login/step/proc-1/fi.mau.whatsapp.qr/display_and_wait',
      ]);
      expect(short.paths, ['GET /v3/login/flows']);
    });
  });

  group('session', () {
    NetworkLoginSession session(
      _FakeTransport transport, {
      NetworkLoginCompleted? onComplete,
      int retries = 4,
    }) => NetworkLoginSession(
      api: NetworkLoginApi(transport),
      bridge: _bridge,
      onComplete: onComplete,
      maxWaitRetries: retries,
      retryDelay: Duration.zero,
    );

    test('QR: refreshed codes are shown, a scan completes', () async {
      var polls = 0;
      final shown = <String>[];
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) return _qr('code-1');
        if (r.path.endsWith('/display_and_wait')) {
          polls++;
          if (polls == 1) return _qr('code-2', txn: 'bls_qr2');
          if (polls == 2) _fail(0); // proxy dropped the long poll
          return _complete();
        }
        return const {};
      });
      String? completedLogin;
      final login = session(
        transport,
        onComplete: (bridge, id) async {
          completedLogin = id;
          return 'Fictional Name';
        },
      );
      login.addListener(() {
        final data = login.step?.displayData;
        if (data != null && data.isNotEmpty && !shown.contains(data)) {
          shown.add(data);
        }
      });
      await login.loadFlows(
        known: const [NetworkLoginFlow(id: 'qr', name: 'QR')],
      );
      expect(login.phase, NetworkLoginPhase.complete);
      expect(shown, ['code-1', 'code-2']);
      expect(login.loginId, 'login-new');
      expect(completedLogin, 'login-new');
      expect(login.accountName, 'Fictional Name');
      expect(login.running, isFalse);
      // The repeated poll after the drop carried the refreshed txn id.
      final waits = transport.seen
          .where((r) => r.path.endsWith('/display_and_wait'))
          .map((r) => r.query['txn_id'])
          .toList();
      expect(waits, ['bls_qr', 'bls_qr2', 'bls_qr2']);
      login.dispose();
    });

    test(
      'a long poll failing too often fails and closes the process',
      () async {
        final transport = _FakeTransport((_, r) {
          if (r.path.startsWith('/v3/login/start/')) return _qr('code');
          if (r.path.endsWith('/display_and_wait')) _fail(504);
          return const {};
        });
        final login = session(transport, retries: 2);
        await login.start(const NetworkLoginFlow(id: 'qr', name: 'QR'));
        expect(login.phase, NetworkLoginPhase.failed);
        expect(login.error!.kind, NetworkLoginErrorKind.unreachable);
        expect(
          transport.paths.where((p) => p.endsWith('/display_and_wait')).length,
          3,
        );
        await pumpEventQueue();
        expect(transport.paths.last, 'POST /v3/login/cancel/proc-1');
        login.dispose();
      },
    );

    test('pairing code and emoji steps are shown while waiting', () async {
      // One completer per long poll, handed out in order.
      final polls = <Completer<Object?>>[];
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) {
          return _step(
            'user_input',
            'fi.mau.whatsapp.phone',
            params: {
              'fields': [
                {'type': 'phone_number', 'id': 'phone', 'name': 'Phone'},
              ],
            },
          );
        }
        if (r.path.endsWith('/user_input')) {
          return _step(
            'display_and_wait',
            'fi.mau.whatsapp.code',
            params: {'type': 'code', 'data': 'ABCD-EFGH'},
          );
        }
        if (r.path.endsWith('/display_and_wait')) {
          final poll = Completer<Object?>();
          polls.add(poll);
          return poll.future;
        }
        return const {};
      });
      final login = session(transport);
      await login.start(const NetworkLoginFlow(id: 'phone', name: 'Code'));
      expect(login.step!.type, NetworkLoginStepType.userInput);
      unawaited(login.submit({'phone': '+48600100200'}));
      await pumpEventQueue();
      expect(login.step!.display, NetworkLoginDisplay.code);
      expect(login.step!.displayData, 'ABCD-EFGH');
      expect(login.busy, isTrue);
      expect(polls, hasLength(1));
      polls.single.complete(
        _step(
          'display_and_wait',
          'fi.mau.x.emoji',
          txn: 'bls_e',
          params: {'type': 'emoji', 'data': '🐱🐶'},
        ),
      );
      await pumpEventQueue();
      expect(login.step!.display, NetworkLoginDisplay.emoji);
      expect(polls, hasLength(2));
      // Cancel while the emoji long poll runs: the late answer is dropped.
      await login.cancel();
      expect(login.phase, NetworkLoginPhase.cancelled);
      expect(transport.paths.last, 'POST /v3/login/cancel/proc-1');
      polls.last.complete(_complete());
      await pumpEventQueue();
      expect(login.phase, NetworkLoginPhase.cancelled);
      expect(polls, hasLength(2));
      login.dispose();
    });

    test('form: code then 2FA password; an error ends the process', () async {
      var submits = 0;
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) {
          return _step(
            'user_input',
            'fi.mau.telegram.code',
            params: {
              'fields': [
                {'type': '2fa_code', 'id': 'code', 'name': 'Code'},
              ],
            },
          );
        }
        if (r.path.endsWith('/user_input')) {
          submits++;
          if (submits == 1) {
            return _step(
              'user_input',
              'fi.mau.telegram.password',
              txn: 'bls_2',
              params: {
                'fields': [
                  {'type': 'password', 'id': 'password', 'name': 'Password'},
                ],
              },
            );
          }
          if (submits == 2) {
            _fail(400, 'FI.MAU.TELEGRAM.BAD_PASSWORD', 'Wrong password');
          }
          return _complete();
        }
        return const {};
      });
      final login = session(transport);
      await login.start(const NetworkLoginFlow(id: 'phone', name: 'Phone'));
      await login.submit({'code': '123456'});
      expect(login.step!.stepId, 'fi.mau.telegram.password');
      expect(transport.seen.last.query, {'txn_id': 'bls_1'});
      await login.submit({'password': 'fictional'});
      expect(login.phase, NetworkLoginPhase.failed);
      expect(login.error!.kind, NetworkLoginErrorKind.rejected);
      expect(login.error!.describe('Telegram'), 'Wrong password');
      expect(login.running, isFalse);
      // Try again opens a new process from the same option.
      await login.retry();
      expect(login.step!.stepId, 'fi.mau.telegram.code');
      await login.submit({'code': '123456'});
      expect(login.phase, NetworkLoginPhase.complete);
      login.dispose();
    });

    test('cookies are submitted to the cookies route', () async {
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) {
          return _step(
            'cookies',
            'fi.mau.meta.cookies',
            params: {
              'url': 'https://www.example.invalid/',
              'fields': [
                {'id': 'xs'},
              ],
            },
          );
        }
        if (r.path.endsWith('/cookies')) return _complete();
        return const {};
      });
      final login = session(transport);
      await login.start(const NetworkLoginFlow(id: 'cookies', name: 'Cookies'));
      expect(login.step!.type, NetworkLoginStepType.cookies);
      await login.submit({'xs': 'fictional'});
      expect(login.phase, NetworkLoginPhase.complete);
      expect(transport.seen.last.body, {'xs': 'fictional'});
      login.dispose();
    });

    test('back: a cancellable step returns the previous one', () async {
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) {
          return _step(
            'user_input',
            'phone',
            params: {
              'can_cancel': true,
              'fields': [
                {'type': 'phone_number', 'id': 'phone'},
              ],
            },
          );
        }
        if (r.path.endsWith('/cancel')) return _qr('again');
        return Completer<Object?>().future; // the QR wait never ends here
      });
      final login = session(transport);
      await login.start(const NetworkLoginFlow(id: 'phone', name: 'Phone'));
      unawaited(login.back());
      await pumpEventQueue();
      expect(
        transport.paths,
        contains('POST /v3/login/step/proc-1/phone/cancel'),
      );
      expect(login.step!.display, NetworkLoginDisplay.qr);
      login.dispose();
    });

    test('back without step cancel returns to the options', () async {
      final transport = _FakeTransport((_, r) {
        if (r.path == '/v3/login/flows') {
          return {
            'flows': [
              {'id': 'qr', 'name': 'QR'},
              {'id': 'phone', 'name': 'Code'},
            ],
          };
        }
        if (r.path.startsWith('/v3/login/start/')) {
          return _step(
            'user_input',
            'phone',
            params: {
              'fields': [
                {'type': 'phone_number', 'id': 'phone'},
              ],
            },
          );
        }
        return const {};
      });
      final login = session(transport);
      await login.loadFlows();
      expect(login.phase, NetworkLoginPhase.flows);
      await login.start(login.flows.last);
      await login.back();
      expect(login.phase, NetworkLoginPhase.flows);
      expect(transport.paths.last, 'POST /v3/login/cancel/proc-1');
      login.dispose();
    });

    test('expired, unsupported and too many logins end the sign-in', () async {
      Future<NetworkLoginSession> run(_Handler handler) async {
        final login = session(_FakeTransport(handler));
        await login.start(const NetworkLoginFlow(id: 'qr', name: 'QR'));
        return login;
      }

      final expired = await run((_, r) {
        if (r.path.startsWith('/v3/login/start/')) return _qr('x');
        _fail(410, 'FI.MAU.BRIDGE.LOGIN_TIMED_OUT', 'Login process timed out');
      });
      expect(expired.phase, NetworkLoginPhase.failed);
      expect(expired.error!.kind, NetworkLoginErrorKind.expired);
      expect(expired.running, isFalse);
      expired.dispose();

      final tooMany = await run(
        (_, _) => _fail(403, 'FI.MAU.BRIDGE.TOO_MANY_LOGINS'),
      );
      expect(tooMany.error!.kind, NetworkLoginErrorKind.tooManyLogins);
      tooMany.dispose();

      final transport = _FakeTransport(
        (_, r) => r.path.startsWith('/v3/login/start/')
            ? _step('webauthn', 'passkey')
            : const {},
      );
      final passkey = session(transport);
      await passkey.start(const NetworkLoginFlow(id: 'qr', name: 'QR'));
      await pumpEventQueue();
      expect(passkey.phase, NetworkLoginPhase.unsupported);
      expect(transport.paths.last, 'POST /v3/login/cancel/proc-1');
      passkey.dispose();
    });

    test('retry starts a fresh process; dispose cancels an open one', () async {
      var starts = 0;
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) {
          starts++;
          if (starts == 1) _fail(0);
          return _step(
            'user_input',
            'phone',
            process: 'proc-2',
            params: {'fields': []},
          );
        }
        return const {};
      });
      final login = session(transport);
      await login.start(const NetworkLoginFlow(id: 'phone', name: 'Phone'));
      expect(login.phase, NetworkLoginPhase.failed);
      await login.retry();
      expect(login.phase, NetworkLoginPhase.step);
      expect(login.running, isTrue);
      login.dispose();
      await pumpEventQueue();
      expect(transport.paths.last, 'POST /v3/login/cancel/proc-2');
    });

    test('no flows means the bridge can\'t sign in from the app', () async {
      final login = session(_FakeTransport((_, _) => {'flows': []}));
      await login.loadFlows();
      expect(login.phase, NetworkLoginPhase.failed);
      expect(login.error!.kind, NetworkLoginErrorKind.unsupported);
      login.dispose();
    });
  });

  group('catalog', () {
    test('candidates: discovered first, then bbctl or standard names', () {
      final beeper = addNetworkCandidates(
        discovered: const [_bridge],
        userId: '@someone:beeper.com',
        hungryserv: true,
        extraBots: '@sh-linkedinbot:beeper.local, not-an-id',
      );
      expect(beeper.first, _bridge);
      expect(
        beeper.map((b) => b.botId),
        contains('@sh-telegrambot:beeper.local'),
      );
      expect(
        beeper.where((b) => b.botId == _bot).length,
        1,
        reason: 'one entry per bot',
      );
      final own = addNetworkCandidates(
        discovered: const [],
        userId: '@someone:chat.example.invalid',
        hungryserv: false,
        extraBots: '@sh-customgobot:chat.example.invalid',
      );
      expect(
        own.map((b) => b.botId),
        containsAll([
          '@whatsappbot:chat.example.invalid',
          '@metabot:chat.example.invalid',
          '@sh-customgobot:chat.example.invalid',
        ]),
      );
      expect(
        own
            .firstWhere((b) => b.botId == '@metabot:chat.example.invalid')
            .network,
        'messenger',
      );
    });

    test('probe keeps answering bridges and discovered ones', () async {
      const telegram = BridgeEndpoint(
        botId: '@sh-telegrambot:beeper.local',
        network: 'telegram',
        label: 'Telegram',
      );
      const meta = BridgeEndpoint(
        botId: '@sh-metabot:beeper.local',
        network: 'messenger',
        label: 'Messenger',
      );
      const cloud = BridgeEndpoint(
        botId: '@signalbot:beeper.com',
        network: 'signal',
        label: 'Signal',
      );
      final transport = _FakeTransport((bridge, r) {
        expect(r.path, '/v3/whoami');
        return switch (bridge.botId) {
          _bot => {
            'bridge_bot': _bot,
            'network': {'displayname': 'WhatsApp', 'network_id': 'whatsapp'},
            'login_flows': [
              {'id': 'qr', 'name': 'QR'},
            ],
            'logins': [
              {
                'id': 'l1',
                'name': 'Fictional',
                'state': {'state_event': 'CONNECTED'},
              },
            ],
          },
          '@sh-metabot:beeper.local' => {
            'bridge_bot': '@sh-metabot:beeper.local',
            'network': {'displayname': 'Instagram', 'network_id': 'instagram'},
            'logins': [],
          },
          _ => _fail(404),
        };
      });
      final backend = NetworkLoginBackend(
        transport: transport,
        loginTransport: transport,
        userId: '@someone:beeper.com',
        hungryserv: true,
        reaches: (bridge) => bridge.domain == 'beeper.local',
      );
      final list = await loadAddableBridges(
        backend: backend,
        discovered: const [_bridge, cloud],
        candidates: const [_bridge, cloud, telegram, meta],
      );
      expect(list.map((e) => (e.label, e.status)), [
        ('Instagram', AddableBridgeStatus.ready),
        ('Signal', AddableBridgeStatus.unreachable),
        ('WhatsApp', AddableBridgeStatus.ready),
      ]);
      final whatsapp = list.last;
      expect(whatsapp.flows.single.id, 'qr');
      expect(whatsapp.accounts, ['Fictional']);
      // The cloud bridge was never asked; the silent Telegram guess is gone.
      expect(transport.seen.map((r) => r.bot), isNot(contains(cloud.botId)));
    });
  });

  group('sign-out', () {
    test('API logout first, command as fallback', () async {
      final client = _client('network login sign-out');
      final monitor = BridgeHealthMonitor(
        client,
        whoami: (_) async => null,
        bridges: () => const [],
        watchLifecycle: false,
      );
      final whoami = BridgeWhoami.fromJson({
        'bridge_bot': _bot,
        'network': {'displayname': 'WhatsApp', 'network_id': 'whatsapp'},
        'logins': [
          {
            'id': 'login-a',
            'state': {'state_event': 'CONNECTED'},
          },
          {
            'id': 'login-b',
            'state': {'state_event': 'LOGGED_OUT'},
          },
        ],
      })!;
      final api = <List<String>>[];
      final sent = <String>[];
      await NetworkSignOut(
        client: client,
        monitor: monitor,
        whoami: (_) async => whoami,
        send: (_, body) async => sent.add(body),
        apiLogout: (network, ids) async {
          api.add(ids);
          return true;
        },
      ).signOut('whatsapp');
      expect(api, [
        ['login-a'],
      ]);
      expect(sent, isEmpty);

      // The API can't: the command path decides (here: no bridge chat).
      await expectLater(
        NetworkSignOut(
          client: client,
          monitor: monitor,
          whoami: (_) async => whoami,
          send: (_, body) async => sent.add(body),
          apiLogout: (_, _) async => false,
        ).signOut('whatsapp'),
        throwsA(isA<PersonalCapabilityUnavailable>()),
      );
      monitor.dispose();
    });
  });

  group('wizard', () {
    Widget host(Widget page) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: NotionTheme.build(Brightness.dark),
      home: page,
    );

    AddableBridge ready({List<NetworkLoginFlow> flows = const []}) =>
        AddableBridge(
          bridge: _bridge,
          status: AddableBridgeStatus.ready,
          whoami: BridgeWhoami.fromJson({
            'bridge_bot': _bot,
            'network': {'displayname': 'WhatsApp', 'network_id': 'whatsapp'},
            'logins': [],
          }),
          flows: flows,
        );

    NetworkLoginBackend backend(_FakeTransport transport) =>
        NetworkLoginBackend(
          transport: transport,
          loginTransport: transport,
          userId: '@someone:beeper.com',
        );

    testWidgets('pick, QR, scan, connected', (tester) async {
      final scanned = Completer<Object?>();
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) return _qr('2@fictional');
        if (r.path.endsWith('/display_and_wait')) return scanned.future;
        return const {};
      });
      String? refreshed;
      await tester.pumpWidget(
        host(
          AddNetworkPage(
            client: _client('wizard qr'),
            backend: backend(transport),
            retryDelay: Duration.zero,
            loadBridges: () async => [
              ready(
                flows: const [NetworkLoginFlow(id: 'qr', name: 'QR')],
              ),
              AddableBridge(
                bridge: const BridgeEndpoint(
                  botId: '@signalbot:beeper.com',
                  network: 'signal',
                  label: 'Signal',
                ),
                status: AddableBridgeStatus.unreachable,
              ),
            ],
            onComplete: (bridge, id) async {
              refreshed = id;
              return 'Fictional Name';
            },
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('Add network'), findsWidgets);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Sign in through the bridge chat'), findsOneWidget);
      await _tapVisible(tester, find.text('WhatsApp'));
      await _settle(tester);
      expect(find.text('Scan the QR code.'), findsOneWidget);
      expect(find.byType(PrettyQrView), findsOneWidget);
      expect(find.text('Waiting for WhatsApp…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('add-network-bot-chat')),
        findsOneWidget,
      );
      scanned.complete(_complete());
      await _settle(tester);
      expect(find.text('WhatsApp is connected'), findsOneWidget);
      expect(
        find.textContaining('Signed in as Fictional Name'),
        findsOneWidget,
      );
      expect(refreshed, 'login-new');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('form validates, clears secrets, shows bridge errors', (
      tester,
    ) async {
      var submits = 0;
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) {
          return _step(
            'user_input',
            'fi.mau.telegram.login',
            instructions: 'Enter your details.',
            params: {
              'fields': [
                {'type': 'phone_number', 'id': 'phone', 'name': 'Phone number'},
                {'type': 'password', 'id': 'password', 'name': 'Password'},
                {
                  'type': 'select',
                  'id': 'dc',
                  'name': 'Server',
                  'options': ['One', 'Two'],
                },
              ],
            },
          );
        }
        if (r.path.endsWith('/user_input')) {
          submits++;
          _fail(400, 'FI.MAU.TELEGRAM.BAD', 'That password is wrong.');
        }
        return const {};
      });
      await tester.pumpWidget(
        host(
          AddNetworkPage(
            client: _client('wizard form'),
            network: 'whatsapp',
            backend: backend(transport),
            loadBridges: () async => [
              ready(
                flows: const [NetworkLoginFlow(id: 'p', name: 'Phone')],
              ),
            ],
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('Enter your details.'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('add-network-submit')),
      );
      await _settle(tester);
      expect(find.text('Enter phone number.'), findsOneWidget);
      expect(find.text('Choose one of the options.'), findsOneWidget);
      expect(submits, 0);
      await _enterVisible(
        tester,
        find.byKey(const ValueKey('add-network-field-phone')),
        '+48 600 100 200',
      );
      await _enterVisible(
        tester,
        find.byKey(const ValueKey('add-network-field-password')),
        'fictional-secret',
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('add-network-option-dc-Two')),
      );
      await tester.pump();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('add-network-submit')),
      );
      await _settle(tester);
      expect(submits, 1);
      expect(transport.seen.last.body, {
        'phone': '+48600100200',
        'password': 'fictional-secret',
        'dc': 'Two',
      });
      expect(find.text('That password is wrong.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('fictional-secret'), findsNothing);
      // Try again starts over; Cancel then stops the new process.
      await _tapVisible(tester, find.text('Try again'));
      await _settle(tester);
      expect(find.text('Enter your details.'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('add-network-cancel')),
      );
      await _settle(tester);
      expect(transport.paths.last, 'POST /v3/login/cancel/proc-1');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('cookies fill from the clipboard and submit', (tester) async {
      final transport = _FakeTransport((_, r) {
        if (r.path.startsWith('/v3/login/start/')) {
          return _step(
            'cookies',
            'fi.mau.meta.cookies',
            params: {
              'url': 'https://www.example.invalid/',
              'fields': [
                {
                  'id': 'c_user',
                  'sources': [
                    {'type': 'cookie', 'name': 'c_user'},
                  ],
                },
                {
                  'id': 'xs',
                  'sources': [
                    {'type': 'cookie', 'name': 'xs'},
                  ],
                },
              ],
            },
          );
        }
        if (r.path.endsWith('/cookies')) return _complete();
        return const {};
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'Cookie: c_user=1000; xs=fictional'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        host(
          AddNetworkPage(
            client: _client('wizard cookies'),
            backend: backend(transport),
            loadBridges: () async => [
              ready(
                flows: const [NetworkLoginFlow(id: 'c', name: 'Cookies')],
              ),
            ],
            onComplete: (_, _) async => null,
          ),
        ),
      );
      await _settle(tester);
      await _tapVisible(tester, find.text('WhatsApp'));
      await _settle(tester);
      expect(find.text('Open www.example.invalid'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('add-network-paste-cookies')),
      );
      await _settle(tester);
      expect(find.text('Filled 2 of 2.'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('add-network-submit')),
      );
      await _settle(tester);
      expect(transport.seen.last.body, {'c_user': '1000', 'xs': 'fictional'});
      expect(find.text('WhatsApp is connected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failure offers retry and the bridge chat', (tester) async {
      final transport = _FakeTransport(
        (_, _) => _fail(403, 'FI.MAU.BRIDGE.TOO_MANY_LOGINS'),
      );
      final opened = <String>[];
      await tester.pumpWidget(
        host(
          AddNetworkPage(
            client: _client('wizard failure'),
            backend: backend(transport),
            loadBridges: () async => [
              ready(
                flows: const [NetworkLoginFlow(id: 'qr', name: 'QR')],
              ),
            ],
            startBridgeChat: (bot) async => '!bridge-chat:example.invalid',
            onOpenRoom: opened.add,
          ),
        ),
      );
      await _settle(tester);
      await _tapVisible(tester, find.text('WhatsApp'));
      await _settle(tester);
      expect(find.text('Couldn’t sign in to WhatsApp'), findsOneWidget);
      expect(
        find.textContaining('doesn’t allow another account'),
        findsOneWidget,
      );
      await _tapVisible(tester, find.text('Open bridge chat'));
      await _settle(tester);
      expect(opened, ['!bridge-chat:example.invalid']);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
