// SPDX-License-Identifier: AGPL-3.0-or-later

bool validGatewayNonce(String? value) =>
    value != null && RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value);

enum PushRegistrationPhase {
  unknown,
  tokenUnavailable,
  gatewayRequired,
  registering,
  pusherConfigured,
  failed,
}

/// Token revisions invalidate asynchronous registration work. No token appears
/// in status text, exceptions or diagnostics.
class PushRegistration {
  String? _token;
  int _revision = 0;
  int _updates = 0;
  bool get updating => _updates > 0;
  PushRegistrationPhase phase = PushRegistrationPhase.unknown;
  bool rotated = false;
  String? get token => _token;
  int get revision => _revision;

  bool observe(String token) {
    if (token.isEmpty || token == _token) return false;
    rotated = _token != null;
    _token = token;
    _revision++;
    phase = PushRegistrationPhase.gatewayRequired;
    return true;
  }

  void beginUpdate() {
    _updates++;
    invalidate();
  }

  void endUpdate() {
    if (_updates > 0) _updates--;
    invalidate();
  }

  void invalidate() {
    _revision++;
    phase = PushRegistrationPhase.gatewayRequired;
  }

  bool current(int revision, String? token, bool accountCurrent) =>
      !updating && accountCurrent && revision == _revision && token == _token;

  String get description => switch (phase) {
    PushRegistrationPhase.unknown =>
      'Notification registration has not been checked.',
    PushRegistrationPhase.tokenUnavailable =>
      'The device notification token is unavailable. Retry notification setup.',
    PushRegistrationPhase.gatewayRequired =>
      rotated
          ? 'The device token changed. Copy the current registration into your private gateway configuration, then retry setup.'
          : 'Copy this device registration into your private gateway configuration, then retry setup.',
    PushRegistrationPhase.registering =>
      'Registering the Matrix pusher. Private gateway registration is still unverified.',
    PushRegistrationPhase.pusherConfigured =>
      rotated
          ? 'Matrix pusher updated. The token changed: update the private gateway registration. Phone delivery is unverified.'
          : 'Matrix pusher configured. Private gateway registration and phone delivery are unverified.',
    PushRegistrationPhase.failed =>
      'Notification registration failed. Check private gateway configuration and retry setup.',
  };
}

/// Execute a registration only while its token and account remain current.
/// Network requests already in flight cannot be recalled; no follow-up mutation
/// or success state is allowed after invalidation.
Future<bool> registerCurrentPush({
  required bool Function() current,
  required Future<void> Function() prepare,
  required Future<void> Function() post,
  required Future<void> Function() finish,
}) async {
  if (!current()) return false;
  await prepare();
  if (!current()) return false;
  await post();
  if (!current()) return false;
  await finish();
  return current();
}
