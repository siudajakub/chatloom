// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/round_video/round_capture_controller.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/lock_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

class AppLockWidget extends StatefulWidget {
  const AppLockWidget({
    required this.child,
    required this.pincode,
    required this.useBiometrics,
    required this.isLoggedIn,
    super.key,
  });

  final bool isLoggedIn, useBiometrics;
  final String? pincode;
  final Widget child;

  @override
  State<AppLockWidget> createState() => AppLock();
}

class AppLock extends State<AppLockWidget> with WidgetsBindingObserver {
  String? _pincode;
  bool _isLocked = false;
  bool _useBiometrics = false;
  bool _triedAutoBiometrics = false;
  bool _paused = false;
  bool get isActive =>
      _pincode != null &&
      int.tryParse(_pincode!) != null &&
      _pincode!.length >= 4 &&
      !_paused;
  bool get useBiometrics => _useBiometrics;

  @override
  void initState() {
    _useBiometrics = widget.useBiometrics;
    _pincode = widget.pincode;
    _isLocked = isActive;
    PersonalPrivacy.surfaceUnlocked = !_isLocked;
    if (!_isLocked &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      RoundPlaybackCoordinator.shared.resume();
    }
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(_checkLoggedIn);
    if (isActive && useBiometrics) unlockWithBiometrics();
  }

  Future<void> _checkLoggedIn(_) async {
    if (widget.isLoggedIn) return;

    await changePincode(null);
    setState(() {
      _isLocked = false;
      PersonalPrivacy.surfaceUnlocked = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    PersonalPrivacy.surfaceForeground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) {
      unawaited(
        RoundPlaybackCoordinator.shared.stopAll().catchError((Object _) {}),
      );
      unawaited(
        RoundCaptureController.interruptActive().catchError((Object _) {}),
      );
    } else if (!_isLocked) {
      RoundPlaybackCoordinator.shared.resume();
    }
    if (isActive && state == AppLifecycleState.hidden && !_isLocked) {
      showLockScreen();
    }
    if (_isLocked &&
        state == AppLifecycleState.resumed &&
        useBiometrics &&
        !_triedAutoBiometrics) {
      unlockWithBiometrics();
    }
  }

  bool get isLocked => _isLocked;

  Future<void> changeUseBiometrics(bool useBiometrics) async {
    await const FlutterSecureStorage().write(
      key: 'chat.fluffy.use_biometrics',
      value: useBiometrics.toString(),
    );
    _useBiometrics = useBiometrics;
    return;
  }

  Future<void> changePincode(String? pincode) async {
    await const FlutterSecureStorage().write(
      key: 'chat.fluffy.app_lock',
      value: pincode,
    );
    _pincode = pincode;
    return;
  }

  Future<bool> unlockWithBiometrics() async {
    _triedAutoBiometrics = true;
    final localAuth = LocalAuthentication();
    final unlocked = await localAuth.authenticate(
      localizedReason: 'Please authenticate to unlock the app.',
      persistAcrossBackgrounding: true,
      biometricOnly: true,
    );
    if (unlocked) {
      setState(() {
        _isLocked = false;
        PersonalPrivacy.surfaceUnlocked = true;
        RoundPlaybackCoordinator.shared.resume();
        _triedAutoBiometrics = false;
      });
    }
    return unlocked;
  }

  bool unlock(String pincode) {
    final isCorrect = pincode == _pincode;
    if (isCorrect) {
      setState(() {
        _isLocked = false;
        PersonalPrivacy.surfaceUnlocked = true;
        RoundPlaybackCoordinator.shared.resume();
      });
    }
    return isCorrect;
  }

  void showLockScreen() => setState(() {
    PersonalPrivacy.surfaceUnlocked = false;
    unawaited(
      RoundPlaybackCoordinator.shared.stopAll().catchError((Object _) {}),
    );
    unawaited(
      RoundCaptureController.interruptActive().catchError((Object _) {}),
    );
    _isLocked = true;
  });
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<T> pauseWhile<T>(Future<T> future) async {
    _paused = true;
    try {
      return await future;
    } finally {
      _paused = false;
    }
  }

  static AppLock of(BuildContext context) =>
      Provider.of<AppLock>(context, listen: false);

  @override
  Widget build(BuildContext context) => Provider<AppLock>(
    create: (_) => this,
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
