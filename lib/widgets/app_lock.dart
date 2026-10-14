import 'package:fluffychat/personal/privacy.dart';
import 'dart:async';
import 'package:fluffychat/personal/round_video/round_playback_coordinator.dart';
import 'package:fluffychat/personal/round_video/round_capture_controller.dart';
// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/widgets/lock_screen.dart';
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
    if(!_isLocked && WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed) {
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
      children: [widget.child, if (isLocked) const LockScreen()],
    ),
  );
}
