// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:chatloom/widgets/app_lock_biometrics.dart';
import 'package:chatloom/widgets/lock_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart' show Logs;
import 'package:provider/provider.dart';

export 'package:chatloom/widgets/app_lock_biometrics.dart';

/// The app lock's single source of truth: the PIN, biometrics, whether the
/// app is locked, and the global privacy gate
/// ([PersonalPrivacy.surfaceUnlocked]) that read markers, push suppression,
/// round autoplay and played receipts check.
///
/// One controller lives for the whole GUI. The startup surface and the app
/// each mount an [AppLockWidget] over it, so the hand-off between them keeps
/// the lock state and an in-flight biometric prompt; only this object writes
/// the privacy gate, and never on behalf of a disposed widget.
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController({
    String? pincode,
    bool useBiometrics = false,
    AppLockBiometrics biometrics = const AppLockBiometrics(),
  }) : this._(pincode, useBiometrics, biometrics, attached: true);

  /// Inert stand-in for an [AppLock] that was never mounted (tests).
  AppLockController._detached()
    : this._(null, false, const AppLockBiometrics(), attached: false);

  AppLockController._(
    this._pincode,
    this._useBiometrics,
    this._biometrics, {
    required bool attached,
  }) : _observes = attached {
    _isLocked = isActive;
    if (!attached) return;
    PersonalPrivacy.surfaceUnlocked = !_isLocked;
    if (!_isLocked &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      RoundPlaybackCoordinator.shared.resume();
    }
    WidgetsBinding.instance.addObserver(this);
  }

  final AppLockBiometrics _biometrics;
  final bool _observes;
  String? _pincode;
  bool _useBiometrics;
  bool _isLocked = false;
  bool _triedAutoBiometrics = false;
  bool _biometricsUnavailable = false;
  bool _autoPromptScheduled = false;
  bool _disposed = false;
  int _pauses = 0;

  /// Bumped on every lock: a prompt that started in an earlier lock session
  /// must not unlock a later one.
  int _lockGeneration = 0;
  Future<AppLockBiometricResult>? _attempt;
  AppLockBiometricResult? _lastBiometric;

  static const _reason = 'Unlock ChatLoom';

  bool get isActive =>
      _pincode != null &&
      int.tryParse(_pincode!) != null &&
      _pincode!.length >= 4 &&
      _pauses == 0;
  bool get isLocked => _isLocked;
  bool get useBiometrics => _useBiometrics;

  /// Biometrics are on and have not proved impossible on this device.
  bool get biometricsAvailable => _useBiometrics && !_biometricsUnavailable;

  /// Why the last prompt of this lock did not unlock, for the lock screen
  /// (also after the automatic prompt); null when nothing needs saying.
  String? get biometricMessage => _lastBiometric?.message;

  /// A PIN attempt replaces the biometric advice.
  void clearBiometricMessage() {
    if (_lastBiometric == null) return;
    _lastBiometric = null;
    _notify();
  }

  /// Whether the enrolled biometric is a face (glyph only).
  late final Future<bool> usesFace = _biometrics.usesFace();

  /// Called by each mounted [AppLockWidget]. The automatic prompt runs once
  /// per controller, after the first frame (never twice for two surfaces).
  void attach() {
    if (_autoPromptScheduled || !_observes) return;
    _autoPromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoPrompt());
  }

  void _autoPrompt() {
    if (_disposed || !_isLocked || !biometricsAvailable) return;
    if (_triedAutoBiometrics) return;
    unawaited(unlockWithBiometrics());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    PersonalPrivacy.surfaceForeground = state == AppLifecycleState.resumed;
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_isLocked) RoundPlaybackCoordinator.shared.resume();
      case AppLifecycleState.inactive:
        // Notification shade, recents peek, permission and biometric dialogs:
        // the app is still on screen. Voice keeps playing (Telegram). Round
        // rows and the mini player stop their videos themselves, because a
        // round's played receipt is foreground-only. Capture always stops.
        unawaited(
          RoundCaptureController.interruptActive().catchError((Object _) {}),
        );
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Background: voice pauses and keeps its position, everything else
        // stops; a lock (below) stops voice too. Nothing resumes by itself.
        // A Mac window that is hidden (closed, minimised, covered, another
        // Space) without a lock keeps a voice note playing, like desktop
        // messengers (MAC-04); videos and rounds still stop.
        unawaited(
          RoundPlaybackCoordinator.shared
              .stopAll(
                retain: state != AppLifecycleState.detached,
                spareHidden: sparesVoiceWhenHidden(state),
              )
              .catchError((Object _) {}),
        );
        unawaited(
          RoundCaptureController.interruptActive().catchError((Object _) {}),
        );
    }
    if (isActive && state == AppLifecycleState.hidden && !_isLocked) {
      showLockScreen();
    }
    if (_isLocked &&
        state == AppLifecycleState.resumed &&
        biometricsAvailable &&
        !_triedAutoBiometrics) {
      unawaited(unlockWithBiometrics());
    }
  }

  /// Whether [state] keeps voice playing: a hidden desktop window while no
  /// lock is configured (a configured lock locks on hidden and stops it).
  @visibleForTesting
  bool sparesVoiceWhenHidden(AppLifecycleState state) =>
      state == AppLifecycleState.hidden &&
      RoundPlaybackCoordinator.keepsVoiceWhenHidden &&
      !isActive &&
      !_isLocked;

  Future<void> changeUseBiometrics(bool useBiometrics) async {
    await personalSecureStorage.write(
      key: 'chat.fluffy.use_biometrics',
      value: useBiometrics.toString(),
    );
    _useBiometrics = useBiometrics;
    if (useBiometrics) _biometricsUnavailable = false;
    _notify();
  }

  Future<void> changePincode(String? pincode) async {
    await personalSecureStorage.write(
      key: 'chat.fluffy.app_lock',
      value: pincode,
    );
    _pincode = pincode;
    _notify();
  }

  /// No account is signed in: the lock is cleared (FluffyChat behaviour).
  /// If the PIN cannot be cleared from storage the app stays locked; the PIN
  /// still unlocks it.
  Future<void> clearForSignedOut() async {
    try {
      await changePincode(null);
    } catch (_) {
      Logs().w('app_lock_clear_failed');
      return;
    }
    if (_disposed) return;
    _setUnlocked();
  }

  /// One biometric prompt at a time; a second call joins the first. Never
  /// throws: every failure is a result, and the app stays locked.
  Future<AppLockBiometricResult> unlockWithBiometrics() {
    final pending = _attempt;
    if (pending != null) return pending;
    if (!_isLocked) return Future.value(AppLockBiometricResult.success);
    _triedAutoBiometrics = true;
    final generation = _lockGeneration;
    return _single(
      _prompt().then((result) {
        if (_disposed || generation != _lockGeneration) return result;
        if (result.unlocked) {
          if (_isLocked) _setUnlocked();
          return result;
        }
        if (result.disablesAutoPrompt) _biometricsUnavailable = true;
        _lastBiometric = result;
        _notify();
        return result;
      }),
    );
  }

  /// A prompt that only confirms the person (turning biometrics on in
  /// settings); it never changes the lock.
  Future<AppLockBiometricResult> confirmBiometrics() =>
      _attempt ?? _single(_prompt());

  Future<AppLockBiometricResult> _single(
    Future<AppLockBiometricResult> attempt,
  ) {
    _attempt = attempt;
    attempt.whenComplete(() {
      if (identical(_attempt, attempt)) _attempt = null;
    }).ignore();
    return attempt;
  }

  Future<AppLockBiometricResult> _prompt() async {
    try {
      final ok = await _biometrics.authenticate(_reason);
      return ok
          ? AppLockBiometricResult.success
          : const AppLockBiometricResult(AppLockBiometricOutcome.notRecognised);
    } catch (error) {
      final result = AppLockBiometricResult.fromError(error);
      Logs().w('app_lock_biometrics ${result.outcome.name}');
      return result;
    }
  }

  bool unlock(String pincode) {
    final isCorrect = pincode == _pincode;
    if (isCorrect && _isLocked) _setUnlocked();
    return isCorrect;
  }

  void _setUnlocked() {
    _isLocked = false;
    _lastBiometric = null;
    // The next lock gets its own automatic prompt again.
    _triedAutoBiometrics = false;
    PersonalPrivacy.surfaceUnlocked = true;
    RoundPlaybackCoordinator.shared.resume();
    _notify();
  }

  void showLockScreen() {
    PersonalPrivacy.surfaceUnlocked = false;
    unawaited(
      RoundPlaybackCoordinator.shared.stopAll().catchError((Object _) {}),
    );
    unawaited(
      RoundCaptureController.interruptActive().catchError((Object _) {}),
    );
    _isLocked = true;
    _lockGeneration++;
    _triedAutoBiometrics = false;
    _lastBiometric = null;
    _notify();
  }

  Future<T> pauseWhile<T>(Future<T> future) async {
    _pauses++;
    try {
      return await future;
    } finally {
      _pauses--;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observes) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class AppLockWidget extends StatefulWidget {
  const AppLockWidget({
    required this.child,
    this.pincode,
    this.useBiometrics = false,
    required this.isLoggedIn,
    this.controller,
    super.key,
  });

  final bool isLoggedIn, useBiometrics;
  final String? pincode;
  final Widget child;

  /// The shared lock (startup surface → app). Without one, the widget owns a
  /// lock built from [pincode] and [useBiometrics].
  final AppLockController? controller;

  @override
  State<AppLockWidget> createState() => AppLock();
}

/// The lock as widgets see it ([AppLock.of]); forwards to the
/// [AppLockController].
class AppLock extends State<AppLockWidget> {
  AppLockController? _controller;
  bool _ownsController = false;

  AppLockController get controller =>
      _controller ??= AppLockController._detached();

  bool get isActive => controller.isActive;
  bool get isLocked => controller.isLocked;
  bool get useBiometrics => controller.useBiometrics;
  bool get biometricsAvailable => controller.biometricsAvailable;
  Future<bool> get usesFace => controller.usesFace;

  Future<void> changeUseBiometrics(bool useBiometrics) =>
      controller.changeUseBiometrics(useBiometrics);
  Future<void> changePincode(String? pincode) =>
      controller.changePincode(pincode);
  Future<AppLockBiometricResult> unlockWithBiometrics() =>
      controller.unlockWithBiometrics();
  Future<AppLockBiometricResult> confirmBiometrics() =>
      controller.confirmBiometrics();
  bool unlock(String pincode) => controller.unlock(pincode);
  void showLockScreen() => controller.showLockScreen();
  Future<T> pauseWhile<T>(Future<T> future) => controller.pauseWhile(future);

  @override
  void initState() {
    super.initState();
    _bind(widget.controller);
    WidgetsBinding.instance.addPostFrameCallback(_checkLoggedIn);
  }

  void _bind(AppLockController? shared) {
    _ownsController = shared == null;
    final controller = _controller =
        shared ??
        AppLockController(
          pincode: widget.pincode,
          useBiometrics: widget.useBiometrics,
        );
    controller.addListener(_changed);
    controller.attach();
  }

  @override
  void didUpdateWidget(AppLockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _unbind();
    _bind(widget.controller);
  }

  void _unbind() {
    final controller = _controller;
    if (controller == null) return;
    controller.removeListener(_changed);
    if (_ownsController) controller.dispose();
    _controller = null;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _checkLoggedIn(_) async {
    if (!mounted || widget.isLoggedIn) return;
    await controller.clearForSignedOut();
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  static AppLock of(BuildContext context) =>
      Provider.of<AppLock>(context, listen: false);

  @override
  Widget build(BuildContext context) => Provider<AppLock>.value(
    value: this,
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        _LockLayer(locked: isLocked),
      ],
    ),
  );
}

/// Hosts the [LockScreen]. Locking covers the app on the same frame (never a
/// fade-in, so content is not exposed); only a successful unlock dissolves
/// the lock away, without input, focus or semantics while it fades.
class _LockLayer extends StatefulWidget {
  final bool locked;
  const _LockLayer({required this.locked});

  @override
  State<_LockLayer> createState() => _LockLayerState();
}

class _LockLayerState extends State<_LockLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _visible = AnimationController(
    vsync: this,
    duration: NotionMotion.medium,
    value: widget.locked ? 1 : 0,
  )..addStatusListener(_status);
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _visible,
    curve: NotionMotion.standard,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1.04,
    end: 1,
  ).animate(CurvedAnimation(parent: _visible, curve: NotionMotion.emphasized));

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(_LockLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locked == widget.locked) return;
    if (widget.locked || NotionMotion.reduced(context)) {
      _visible.value = widget.locked ? 1 : 0;
    } else {
      _visible.reverse(from: 1);
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _visible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.locked;
    if (!locked && _visible.isDismissed) return const SizedBox.shrink();
    // One stable tree, so the lock screen keeps its state while it fades.
    return IgnorePointer(
      ignoring: !locked,
      child: ExcludeFocus(
        excluding: !locked,
        child: ExcludeSemantics(
          excluding: !locked,
          child: FadeTransition(
            opacity: _opacity,
            child: ScaleTransition(scale: _scale, child: const LockScreen()),
          ),
        ),
      ),
    );
  }
}
