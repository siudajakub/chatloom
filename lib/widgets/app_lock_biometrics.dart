// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// What one biometric prompt of the app lock ended with.
///
/// local_auth 3 throws a [LocalAuthException] for every outcome except
/// success (Android even for "Use PIN" and a cancel), so the app lock maps
/// every failure to one of these instead of letting it escape: the lock
/// screen stays, the PIN field stays usable, and only a failure the person
/// can act on is explained.
enum AppLockBiometricOutcome {
  success,

  /// The prompt answered, but the finger or face was not recognised
  /// (Apple platforms report this as `false`).
  notRecognised,

  /// Cancelled, "Use PIN" tapped, dismissed by the system or another prompt
  /// is already showing: nothing to explain, the PIN field takes over.
  cancelled,

  /// No biometrics enrolled, no hardware, no device credential: biometric
  /// unlock cannot work on this device until the person changes that.
  unavailable,

  /// Too many attempts (temporary or until the device is unlocked).
  lockedOut,

  timedOut,

  /// Any other device or plugin failure.
  failed,
}

/// The result of a biometric prompt, with the sentence the lock screen shows.
class AppLockBiometricResult {
  const AppLockBiometricResult(this.outcome);

  static const success = AppLockBiometricResult(
    AppLockBiometricOutcome.success,
  );

  final AppLockBiometricOutcome outcome;

  bool get unlocked => outcome == AppLockBiometricOutcome.success;

  /// The automatic prompt is pointless for the rest of this run.
  bool get disablesAutoPrompt => outcome == AppLockBiometricOutcome.unavailable;

  /// A short sentence for the lock screen; null when nothing needs saying.
  /// The PIN always remains the fallback (ChatLoom has its own PIN, so the
  /// device credential is deliberately not offered: it would let anyone who
  /// knows the phone's PIN open the app).
  String? get message => switch (outcome) {
    AppLockBiometricOutcome.success ||
    AppLockBiometricOutcome.cancelled => null,
    AppLockBiometricOutcome.notRecognised =>
      'Not recognised. Try again or enter your PIN.',
    AppLockBiometricOutcome.unavailable =>
      'Biometric unlock isn’t set up on this device. Enter your PIN.',
    AppLockBiometricOutcome.lockedOut => 'Too many attempts. Enter your PIN.',
    AppLockBiometricOutcome.timedOut =>
      'Biometric unlock timed out. Try again or enter your PIN.',
    AppLockBiometricOutcome.failed =>
      'Couldn’t use biometric unlock. Enter your PIN or try again.',
  };

  /// The same outcome when turning biometric unlock on in settings (the PIN
  /// is not on screen there).
  String? get enableMessage => switch (outcome) {
    AppLockBiometricOutcome.success ||
    AppLockBiometricOutcome.cancelled => null,
    AppLockBiometricOutcome.notRecognised => 'Not recognised. Try again.',
    AppLockBiometricOutcome.unavailable =>
      'Set up a fingerprint or face unlock in your device settings first.',
    AppLockBiometricOutcome.lockedOut => 'Too many attempts. Try again later.',
    AppLockBiometricOutcome.timedOut => 'Timed out. Try again.',
    AppLockBiometricOutcome.failed =>
      'Couldn’t use biometric unlock. Try again.',
  };

  /// Maps anything a prompt can throw. Never rethrows: the caller stays
  /// locked (fail closed) and shows [message].
  factory AppLockBiometricResult.fromError(Object error) {
    if (error is LocalAuthException) {
      return AppLockBiometricResult(switch (error.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.userRequestedFallback ||
        LocalAuthExceptionCode.authInProgress =>
          AppLockBiometricOutcome.cancelled,
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.noCredentialsSet =>
          AppLockBiometricOutcome.unavailable,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout =>
          AppLockBiometricOutcome.lockedOut,
        LocalAuthExceptionCode.timeout => AppLockBiometricOutcome.timedOut,
        _ => AppLockBiometricOutcome.failed,
      });
    }
    if (error is PlatformException && error.code == 'CANCELED') {
      return const AppLockBiometricResult(AppLockBiometricOutcome.cancelled);
    }
    return const AppLockBiometricResult(AppLockBiometricOutcome.failed);
  }
}

/// The device calls of the app lock (test seam).
class AppLockBiometrics {
  const AppLockBiometrics();

  /// Biometrics only: the app's own PIN is the fallback.
  Future<bool> authenticate(String reason) =>
      LocalAuthentication().authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
        biometricOnly: true,
      );

  /// Whether the enrolled biometric is a face (for the button glyph).
  Future<bool> usesFace() async {
    try {
      final types = await LocalAuthentication().getAvailableBiometrics();
      return types.contains(BiometricType.face);
    } catch (_) {
      return false;
    }
  }
}
