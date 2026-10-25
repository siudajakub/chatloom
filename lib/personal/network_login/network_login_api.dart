// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:flutter/foundation.dart';

// In-app "Add network" (wave 8): the bridgev2 provisioning login API
// (mautrix-go `bridgev2/matrix/provisioninglogin.go`, `bridgev2/login.go`).
//
//   GET  /v3/login/flows
//   POST /v3/login/start/{flow}[?login_id=<re-login>]   → {login_id, step}
//   POST /v3/login/step/{process}/{step_id}/{type}?txn_id=…
//          user_input / cookies: body = {field id: value}
//          display_and_wait:     long poll until the network advances
//   POST /v3/login/step/{process}/{step_id}/cancel?txn_id=…  (go back)
//   POST /v3/login/cancel/{process}
//   POST /v3/logout/{login}
//   GET  /v3/logins
//
// Requests go through the same [BridgeProvisioningTransport] as contact
// search: Beeper's hungryserv `exec/http_proxy` today, a direct
// `CHATLOOM_BRIDGE_PROVISIONING_URL` on an own homeserver.
//
// Privacy: QR data, pairing codes, emoji, typed values and cookies live only
// in memory for the step that needs them. Nothing in this file logs, and no
// model overrides `toString` with its data.

/// One way to sign in that a bridge offers (`LoginFlow`).
@immutable
class NetworkLoginFlow {
  const NetworkLoginFlow({
    required this.id,
    required this.name,
    this.description = '',
  });

  final String id;
  final String name;
  final String description;

  static NetworkLoginFlow? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final name = json['name'];
    final description = json['description'];
    return NetworkLoginFlow(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : id,
      description: description is String ? description.trim() : '',
    );
  }

  static List<NetworkLoginFlow> listFromJson(Object? json) => [
    if (json is List)
      for (final item in json) ?NetworkLoginFlow.fromJson(item),
  ];
}

/// What a `display_and_wait` step shows.
enum NetworkLoginDisplay { qr, code, emoji, nothing, unknown }

/// The kind of a `user_input` field (`LoginInputFieldType`).
enum NetworkLoginFieldType {
  username,
  password,
  phoneNumber,
  email,
  twoFactorCode,
  token,
  url,
  domain,
  select,
  captchaCode,
  text;

  static NetworkLoginFieldType parse(Object? raw) => switch (raw) {
    'username' => username,
    'password' => password,
    'phone_number' => phoneNumber,
    'email' => email,
    '2fa_code' => twoFactorCode,
    'token' => token,
    'url' => url,
    'domain' => domain,
    'select' => select,
    'captcha_code' => captchaCode,
    _ => text,
  };

  /// Typed values the screen hides by default.
  bool get secret => this == password || this == token;
}

/// One field of a `user_input` step (`LoginInputDataField`).
@immutable
class NetworkLoginField {
  const NetworkLoginField({
    required this.id,
    required this.type,
    this.name = '',
    this.description = '',
    this.defaultValue = '',
    this.optional = false,
    this.pattern,
    this.minLength = 0,
    this.maxLength = 0,
    this.options = const [],
  });

  final String id;
  final NetworkLoginFieldType type;
  final String name;
  final String description;
  final String defaultValue;
  final bool optional;
  final String? pattern;
  final int minLength;
  final int maxLength;
  final List<String> options;

  /// The label above the field.
  String get label => name.isNotEmpty ? name : id;

  static NetworkLoginField? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    String text(String key) {
      final value = json[key];
      return value is String ? value : '';
    }

    int number(String key) {
      final value = json[key];
      return value is int && value > 0 ? value : 0;
    }

    final options = json['options'];
    final pattern = json['pattern'];
    return NetworkLoginField(
      id: id,
      type: NetworkLoginFieldType.parse(json['type']),
      name: text('name').trim(),
      description: text('description').trim(),
      defaultValue: text('default_value'),
      optional: json['optional'] == true,
      pattern: pattern is String && pattern.isNotEmpty ? pattern : null,
      minLength: number('min_length'),
      maxLength: number('max_length'),
      options: [if (options is List) ...options.whereType<String>()],
    );
  }

  static final _numberCleaner = RegExp(r'[\s\-()]');

  /// Checks [raw] like the bridge will (`FillDefaultValidate`) and returns
  /// the cleaned value, or a sentence saying what is wrong. The bridge
  /// checks again; this only saves a round trip.
  ({String? value, String? error}) validate(String raw) {
    final input = type.secret ? raw : raw.trim();
    if (input.isEmpty) {
      return optional
          ? (value: '', error: null)
          : (
              value: null,
              error: type == NetworkLoginFieldType.select
                  ? 'Choose one of the options.'
                  : 'Enter ${label.toLowerCase()}.',
            );
    }
    if (minLength > 0 && input.length < minLength) {
      return (value: null, error: 'Use at least $minLength characters.');
    }
    if (maxLength > 0 && input.length > maxLength) {
      return (value: null, error: 'Use at most $maxLength characters.');
    }
    switch (type) {
      case NetworkLoginFieldType.phoneNumber:
        final phone = input.replaceAll(_numberCleaner, '');
        if (!RegExp(r'^\+[0-9]+$').hasMatch(phone)) {
          return (
            value: null,
            error:
                'Enter the number with its country code, like +48 600 100 200.',
          );
        }
        return (value: phone, error: null);
      case NetworkLoginFieldType.email:
        if (!input.contains('@')) {
          return (value: null, error: 'Enter an email address.');
        }
        return (value: input, error: null);
      case NetworkLoginFieldType.select:
        if (options.isNotEmpty && !options.contains(input)) {
          return (value: null, error: 'Choose one of the options.');
        }
        return (value: input, error: null);
      default:
        final pattern = this.pattern;
        if (pattern != null) {
          RegExp? regex;
          try {
            regex = RegExp(pattern);
          } on FormatException {
            regex = null; // Go syntax Dart can't read: the bridge decides.
          }
          if (regex != null && !regex.hasMatch(input)) {
            return (value: null, error: 'Check ${label.toLowerCase()}.');
          }
        }
        return (value: input, error: null);
    }
  }
}

/// An image or file a `user_input` step shows beside its fields (a captcha).
@immutable
class NetworkLoginAttachment {
  const NetworkLoginAttachment({
    required this.type,
    required this.bytes,
    this.mimeType = '',
  });

  final String type;
  final Uint8List bytes;
  final String mimeType;

  bool get isImage => type == 'm.image' || mimeType.startsWith('image/');

  static NetworkLoginAttachment? fromJson(Object? json) {
    if (json is! Map) return null;
    final content = json['content'];
    if (content is! String || content.isEmpty) return null;
    final Uint8List bytes;
    try {
      bytes = base64.decode(base64.normalize(content));
    } on FormatException {
      return null;
    }
    final type = json['type'];
    final info = json['info'];
    final mime = info is Map ? info['mimetype'] : null;
    return NetworkLoginAttachment(
      type: type is String ? type : '',
      bytes: bytes,
      mimeType: mime is String ? mime : '',
    );
  }
}

/// Where a cookie-step value can be found (`LoginCookieFieldSource`).
@immutable
class NetworkCookieSource {
  const NetworkCookieSource({
    required this.type,
    required this.name,
    this.cookieDomain = '',
  });

  /// `cookie`, `local_storage`, `request_header`, `request_body`, `special`.
  final String type;
  final String name;
  final String cookieDomain;

  static NetworkCookieSource? fromJson(Object? json) {
    if (json is! Map) return null;
    final type = json['type'];
    final name = json['name'];
    if (type is! String || name is! String || name.isEmpty) return null;
    final domain = json['cookie_domain'];
    return NetworkCookieSource(
      type: type,
      name: name,
      cookieDomain: domain is String ? domain : '',
    );
  }

  /// "Cookie c_user on facebook.com", "Request header x-csrf-token".
  String get describe => switch (type) {
    'cookie' =>
      cookieDomain.isEmpty
          ? 'Cookie $name'
          : 'Cookie $name on ${cookieDomain.replaceFirst(RegExp(r'^\.'), '')}',
    'local_storage' => 'Local storage key $name',
    'request_header' => 'Request header $name',
    'request_body' => 'Request field $name',
    _ => name,
  };
}

/// One value a `cookies` step needs (`LoginCookieField`).
@immutable
class NetworkCookieField {
  const NetworkCookieField({
    required this.id,
    this.required = true,
    this.sources = const [],
    this.pattern,
  });

  final String id;
  final bool required;
  final List<NetworkCookieSource> sources;
  final String? pattern;

  /// The cookie name to look for in a pasted `Cookie:` header, if any.
  Iterable<String> get cookieNames => sources
      .where((source) => source.type == 'cookie')
      .map((source) => source.name);

  static NetworkCookieField? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final sources = json['sources'];
    final pattern = json['pattern'];
    return NetworkCookieField(
      id: id,
      required: json['required'] != false,
      sources: [
        if (sources is List)
          for (final source in sources) ?NetworkCookieSource.fromJson(source),
      ],
      pattern: pattern is String && pattern.isNotEmpty ? pattern : null,
    );
  }

  String? check(String value) {
    if (value.isEmpty) return required ? 'Paste $id.' : null;
    final pattern = this.pattern;
    if (pattern == null) return null;
    try {
      if (!RegExp(pattern).hasMatch(value)) return 'This doesn’t look right.';
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// Splits a pasted `Cookie:` header (or `name=value` lines) into values for
/// [fields], matched by cookie name or field id. Nothing is kept or logged.
Map<String, String> parseCookieHeader(
  String pasted,
  List<NetworkCookieField> fields,
) {
  var text = pasted.trim();
  final header = RegExp(r'^cookie\s*:\s*', caseSensitive: false);
  text = text.replaceFirst(header, '');
  final pairs = <String, String>{};
  for (final part in text.split(RegExp(r'[;\n]'))) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    final name = part.substring(0, eq).trim();
    var value = part.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (name.isNotEmpty && value.isNotEmpty) pairs[name] = value;
  }
  return {
    for (final field in fields)
      for (final name in [...field.cookieNames, field.id])
        field.id: ?pairs[name],
  };
}

/// The step types a bridge can answer with (`LoginStepType`).
enum NetworkLoginStepType {
  displayAndWait('display_and_wait'),
  userInput('user_input'),
  cookies('cookies'),
  complete('complete'),

  /// `client_http`, `webauthn` or anything newer: ChatLoom cannot do it.
  unsupported('');

  const NetworkLoginStepType(this.wire);
  final String wire;
}

/// One step of a running sign-in (`LoginStep`).
@immutable
class NetworkLoginStep {
  const NetworkLoginStep({
    required this.type,
    required this.stepId,
    this.txnId = '',
    this.instructions = '',
    this.rawType = '',
    this.display = NetworkLoginDisplay.unknown,
    this.displayData = '',
    this.canCancel = false,
    this.fields = const [],
    this.attachments = const [],
    this.cookieUrl,
    this.cookieFields = const [],
    this.userLoginId,
  });

  final NetworkLoginStepType type;
  final String stepId;

  /// Echoed on submit so a retried request is answered, not repeated.
  final String txnId;
  final String instructions;

  /// The wire type (shown nowhere; tells an unsupported step apart).
  final String rawType;

  // display_and_wait
  final NetworkLoginDisplay display;

  /// QR payload, pairing code or emoji. Shown, never logged.
  final String displayData;

  /// The user may go back from this step (display_and_wait, user_input).
  final bool canCancel;

  // user_input
  final List<NetworkLoginField> fields;
  final List<NetworkLoginAttachment> attachments;

  // cookies
  final Uri? cookieUrl;
  final List<NetworkCookieField> cookieFields;

  // complete
  final String? userLoginId;

  static NetworkLoginStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawType = json['type'];
    final stepId = json['step_id'];
    if (rawType is! String || stepId is! String) return null;
    final txn = json['txn_id'];
    final instructions = json['instructions'];
    final type = NetworkLoginStepType.values.firstWhere(
      (value) => value.wire == rawType && value.wire.isNotEmpty,
      orElse: () => NetworkLoginStepType.unsupported,
    );
    final base = (
      txnId: txn is String ? txn : '',
      instructions: instructions is String ? instructions.trim() : '',
    );
    switch (type) {
      case NetworkLoginStepType.displayAndWait:
        final params = json['display_and_wait'];
        final kind = params is Map ? params['type'] : null;
        final data = params is Map ? params['data'] : null;
        return NetworkLoginStep(
          type: type,
          stepId: stepId,
          txnId: base.txnId,
          instructions: base.instructions,
          rawType: rawType,
          display: switch (kind) {
            'qr' => NetworkLoginDisplay.qr,
            'code' => NetworkLoginDisplay.code,
            'emoji' => NetworkLoginDisplay.emoji,
            'nothing' => NetworkLoginDisplay.nothing,
            _ => NetworkLoginDisplay.unknown,
          },
          displayData: data is String ? data : '',
          canCancel: params is Map && params['can_cancel'] == true,
        );
      case NetworkLoginStepType.userInput:
        final params = json['user_input'];
        final fields = params is Map ? params['fields'] : null;
        final attachments = params is Map ? params['attachments'] : null;
        return NetworkLoginStep(
          type: type,
          stepId: stepId,
          txnId: base.txnId,
          instructions: base.instructions,
          rawType: rawType,
          canCancel: params is Map && params['can_cancel'] == true,
          fields: [
            if (fields is List)
              for (final field in fields) ?NetworkLoginField.fromJson(field),
          ],
          attachments: [
            if (attachments is List)
              for (final item in attachments)
                ?NetworkLoginAttachment.fromJson(item),
          ],
        );
      case NetworkLoginStepType.cookies:
        final params = json['cookies'];
        final url = params is Map ? params['url'] : null;
        final fields = params is Map ? params['fields'] : null;
        final uri = url is String ? Uri.tryParse(url) : null;
        return NetworkLoginStep(
          type: type,
          stepId: stepId,
          txnId: base.txnId,
          instructions: base.instructions,
          rawType: rawType,
          cookieUrl:
              uri != null && (uri.scheme == 'https' || uri.scheme == 'http')
              ? uri
              : null,
          cookieFields: [
            if (fields is List)
              for (final field in fields) ?NetworkCookieField.fromJson(field),
          ],
        );
      case NetworkLoginStepType.complete:
        final params = json['complete'];
        final id = params is Map ? params['user_login_id'] : null;
        return NetworkLoginStep(
          type: type,
          stepId: stepId,
          txnId: base.txnId,
          instructions: base.instructions,
          rawType: rawType,
          userLoginId: id is String && id.isNotEmpty ? id : null,
        );
      case NetworkLoginStepType.unsupported:
        return NetworkLoginStep(
          type: type,
          stepId: stepId,
          txnId: base.txnId,
          instructions: base.instructions,
          rawType: rawType,
        );
    }
  }
}

/// A started sign-in: the bridge's process id and its current step.
@immutable
class NetworkLoginProgress {
  const NetworkLoginProgress(this.processId, this.step);

  /// `login_id` of `RespSubmitLogin` (the process, not the remote login).
  final String processId;
  final NetworkLoginStep step;

  static NetworkLoginProgress parse(Object? json) {
    final process = json is Map ? json['login_id'] : null;
    final step = NetworkLoginStep.fromJson(json);
    if (process is! String || process.isEmpty || step == null) {
      throw const BridgeProvisioningException(
        200,
        errcode: 'CHATLOOM_NOT_A_LOGIN_STEP',
      );
    }
    return NetworkLoginProgress(process, step);
  }
}

/// Why a sign-in request failed, in the app's words.
enum NetworkLoginErrorKind {
  /// The bridge rejected what was entered or the network refused; the
  /// bridge's own sentence is shown.
  rejected,

  /// The process expired, was cancelled or is unknown: start again.
  expired,

  /// The bridge allows no more accounts.
  tooManyLogins,

  /// The account may not sign in to this bridge.
  forbidden,

  /// The bridge has no such endpoint (older bridge, not bridgev2).
  unsupported,

  /// No answer, no route, or the token was not accepted.
  unreachable,
}

/// A failed login request. [message] is the bridge's own sentence, shown to
/// the user and never logged.
class NetworkLoginException implements Exception {
  const NetworkLoginException(this.kind, {this.message, this.cause});

  final NetworkLoginErrorKind kind;
  final String? message;

  /// The transport error (status and errcode only).
  final BridgeProvisioningException? cause;

  static NetworkLoginException from(BridgeProvisioningException error) {
    final code = error.errcode;
    final kind = switch (code) {
      'FI.MAU.BRIDGE.LOGIN_CANCELLED' ||
      'FI.MAU.BRIDGE.LOGIN_TIMED_OUT' ||
      'FI.MAU.BRIDGE.LOGIN_ALREADY_FINISHED' => NetworkLoginErrorKind.expired,
      'FI.MAU.BRIDGE.TOO_MANY_LOGINS' => NetworkLoginErrorKind.tooManyLogins,
      'M_UNRECOGNIZED' => NetworkLoginErrorKind.unsupported,
      // "Login not found": the bridge restarted or the process ended.
      'M_NOT_FOUND' => NetworkLoginErrorKind.expired,
      'M_FORBIDDEN' when error.status == 403 => NetworkLoginErrorKind.forbidden,
      'COM.BEEPER.WEBAUTHN_UNSUPPORTED' => NetworkLoginErrorKind.unsupported,
      _ when error.status == 410 => NetworkLoginErrorKind.expired,
      _ when error.unreachable => NetworkLoginErrorKind.unreachable,
      _ when error.status >= 500 && code == null =>
        NetworkLoginErrorKind.unreachable,
      _ when error.status == 200 => NetworkLoginErrorKind.unsupported,
      _ => NetworkLoginErrorKind.rejected,
    };
    final message = error.message?.trim();
    return NetworkLoginException(
      kind,
      message: message == null || message.isEmpty ? null : message,
      cause: error,
    );
  }

  /// One sentence for the screen.
  String describe(String network) => switch (kind) {
    NetworkLoginErrorKind.rejected =>
      message ?? '$network didn’t accept this. Check it and try again.',
    NetworkLoginErrorKind.expired =>
      'This sign-in expired or was stopped. Start again.',
    NetworkLoginErrorKind.tooManyLogins =>
      'The $network bridge doesn’t allow another account. Sign out of one '
          'first.',
    NetworkLoginErrorKind.forbidden =>
      'Your account isn’t allowed to sign in to this bridge.',
    NetworkLoginErrorKind.unsupported =>
      'This bridge can’t sign in from the app. Use the bridge chat instead.',
    NetworkLoginErrorKind.unreachable =>
      'ChatLoom can’t reach the $network bridge right now. Check your '
          'connection and try again.',
  };

  /// Status and errcode only, for diagnostics.
  @override
  String toString() => 'NetworkLoginException(${kind.name} ${cause?.reason})';
}

/// The bridgev2 login endpoints. Long polls ([wait]) use [waitTransport]
/// with a longer timeout; everything else uses [transport].
class NetworkLoginApi {
  NetworkLoginApi(this.transport, {BridgeProvisioningTransport? waitTransport})
    : waitTransport = waitTransport ?? transport;

  final BridgeProvisioningTransport transport;
  final BridgeProvisioningTransport waitTransport;

  static String _seg(String value) => Uri.encodeComponent(value);

  Future<Object?> _send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request, {
    bool long = false,
  }) async {
    try {
      return await (long ? waitTransport : transport).send(bridge, request);
    } on BridgeProvisioningException catch (error) {
      throw NetworkLoginException.from(error);
    }
  }

  /// The ways to sign in (`GET /v3/login/flows`).
  Future<List<NetworkLoginFlow>> flows(BridgeEndpoint bridge) async {
    final json = await _send(
      bridge,
      const BridgeProvisioningRequest('GET', '/v3/login/flows'),
    );
    return NetworkLoginFlow.listFromJson(json is Map ? json['flows'] : null);
  }

  /// Starts [flowId]; [relogin] re-authenticates that existing login.
  /// Waits for the first step (the bridge may connect to the network first).
  Future<NetworkLoginProgress> start(
    BridgeEndpoint bridge,
    String flowId, {
    String? relogin,
  }) async => NetworkLoginProgress.parse(
    await _send(
      bridge,
      BridgeProvisioningRequest(
        'POST',
        '/v3/login/start/${_seg(flowId)}',
        query: {'login_id': ?relogin},
        body: const {},
      ),
      long: true,
    ),
  );

  BridgeProvisioningRequest _step(
    String processId,
    NetworkLoginStep step,
    String action,
    Map<String, Object?> body,
  ) => BridgeProvisioningRequest(
    'POST',
    '/v3/login/step/${_seg(processId)}/${_seg(step.stepId)}/$action',
    query: {if (step.txnId.isNotEmpty) 'txn_id': step.txnId},
    body: body,
  );

  /// Sends a `user_input` step's values (field id → value).
  Future<NetworkLoginProgress> submitInput(
    BridgeEndpoint bridge,
    String processId,
    NetworkLoginStep step,
    Map<String, String> values,
  ) async => NetworkLoginProgress.parse(
    await _send(
      bridge,
      _step(processId, step, NetworkLoginStepType.userInput.wire, values),
      long: true,
    ),
  );

  /// Sends a `cookies` step's values (field id → value).
  Future<NetworkLoginProgress> submitCookies(
    BridgeEndpoint bridge,
    String processId,
    NetworkLoginStep step,
    Map<String, String> values,
  ) async => NetworkLoginProgress.parse(
    await _send(
      bridge,
      _step(processId, step, NetworkLoginStepType.cookies.wire, values),
      long: true,
    ),
  );

  /// Long-polls a `display_and_wait` step until the network moves on (a
  /// scanned QR, a new QR, the next step). Repeating it after a timeout
  /// joins the same wait (the bridge keys it by step and txn id).
  Future<NetworkLoginProgress> wait(
    BridgeEndpoint bridge,
    String processId,
    NetworkLoginStep step,
  ) async => NetworkLoginProgress.parse(
    await _send(
      bridge,
      _step(
        processId,
        step,
        NetworkLoginStepType.displayAndWait.wire,
        const {},
      ),
      long: true,
    ),
  );

  /// Goes back from a step that allows it ([NetworkLoginStep.canCancel]);
  /// returns the step to show next.
  Future<NetworkLoginProgress> cancelStep(
    BridgeEndpoint bridge,
    String processId,
    NetworkLoginStep step,
  ) async => NetworkLoginProgress.parse(
    await _send(bridge, _step(processId, step, 'cancel', const {})),
  );

  /// Stops the whole sign-in.
  Future<void> cancel(BridgeEndpoint bridge, String processId) => _send(
    bridge,
    BridgeProvisioningRequest(
      'POST',
      '/v3/login/cancel/${_seg(processId)}',
      body: const {},
    ),
  );

  /// Signs out of one remote login.
  Future<void> logout(BridgeEndpoint bridge, String loginId) => _send(
    bridge,
    BridgeProvisioningRequest(
      'POST',
      '/v3/logout/${_seg(loginId)}',
      body: const {},
    ),
  );

  /// The account's login ids on this bridge.
  Future<List<String>> logins(BridgeEndpoint bridge) async {
    final json = await _send(
      bridge,
      const BridgeProvisioningRequest('GET', '/v3/logins'),
    );
    final ids = json is Map ? json['login_ids'] : null;
    return [if (ids is List) ...ids.whereType<String>()];
  }
}
