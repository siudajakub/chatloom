// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The PIN screen over the app. Its words are plain English constants, not
/// `L10n`: the same screen covers the startup surface, whose app has no
/// localizations yet, and a missing lookup there must never break the lock.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  static const title = 'Enter your PIN';

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String? _errorText;
  int _coolDownSeconds = 5;
  bool _inputBlocked = false;

  /// Bumped on every rejected attempt: drives the shake.
  int _rejections = 0;
  final TextEditingController _textEditingController = TextEditingController();
  final FocusNode _pinFocus = FocusNode();

  /// The lock this screen covers for: its biometric state and advice.
  late final AppLockController _lock = AppLock.of(context).controller;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_lockChanged);
  }

  void _lockChanged() {
    if (mounted) setState(() {});
  }

  /// A failed or cancelled prompt hands over to the PIN field: no cool-down
  /// (the system rate-limits biometrics itself), at most one sentence, which
  /// the lock itself keeps ([AppLockController.biometricMessage]) so the
  /// automatic prompt is explained as well.
  Future<void> tryUnlockWithBiometrics() async {
    setState(() => _errorText = null);
    final result = await AppLock.of(context).unlockWithBiometrics();
    if (!mounted || result.unlocked) return;
    if (result.outcome == AppLockBiometricOutcome.notRecognised) {
      setState(_reject);
    }
    _pinFocus.requestFocus();
  }

  void _reject() {
    _rejections++;
    NotionHaptics.light();
  }

  Future<void> tryUnlock(String text) async {
    text = text.trim();
    _lock.clearBiometricMessage();
    setState(() {
      _errorText = null;
    });

    final enteredPin = int.tryParse(text);
    if (enteredPin == null) {
      _reject();
      setState(() {
        _errorText = 'Enter digits only.';
      });
      _textEditingController.clear();
      return;
    }

    if (AppLock.of(context).unlock(text)) {
      setState(() {
        _inputBlocked = false;
        _errorText = null;
      });
      _textEditingController.clear();
      return;
    }

    _reject();
    setState(() {
      _errorText = 'Wrong PIN. Try again in $_coolDownSeconds seconds.';
      _inputBlocked = true;
    });
    Future.delayed(Duration(seconds: _coolDownSeconds)).then((_) {
      if (!mounted) return;
      setState(() {
        _inputBlocked = false;
        _coolDownSeconds *= 2;
        _errorText = null;
      });
    });
    _textEditingController.clear();
  }

  /// The lock sits above the app's navigator, so it brings its own
  /// [Overlay] for the text field. An [Overlay] keeps its first entry, so
  /// the entry must not capture this build's values: [_content] reads the
  /// current state on every rebuild (a captured closure kept showing the
  /// first frame: no "Wrong PIN" text, no blocked input).
  @override
  Widget build(BuildContext context) =>
      Overlay(initialEntries: [OverlayEntry(builder: _content)]);

  Widget _content(BuildContext context) {
    final colors = context.notion.colors;
    final appLock = AppLock.of(context);
    final field = TextField(
      controller: _textEditingController,
      textInputAction: TextInputAction.go,
      keyboardType: TextInputType.number,
      obscureText: true,
      autofocus: true,
      focusNode: _pinFocus,
      textAlign: TextAlign.center,
      readOnly: _inputBlocked,
      // The typed digits are drawn as the popping dots below.
      showCursor: false,
      enableInteractiveSelection: false,
      onChanged: (text) {
        if (text.length >= 6) tryUnlock(text);
      },
      onSubmitted: tryUnlock,
      style: const TextStyle(fontSize: 40, color: Colors.transparent),
      inputFormatters: [LengthLimitingTextInputFormatter(6)],
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(40)),
        hintText: '✱✱✱✱',
        hintStyle: TextStyle(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        prefix: appLock.biometricsAvailable
            ? IconButton(
                tooltip: 'Unlock with biometrics',
                icon: FutureBuilder<bool>(
                  future: appLock.usesFace,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.face_unlock_outlined
                        : Icons.fingerprint_outlined,
                  ),
                ),
                onPressed: _inputBlocked ? null : tryUnlockWithBiometrics,
              )
            : IconButton(
                tooltip: 'Clear',
                icon: Icon(Icons.cancel_outlined),
                onPressed: _inputBlocked ? null : _textEditingController.clear,
              ),
        suffix: IconButton(
          tooltip: 'Unlock',
          icon: Icon(Icons.send_outlined),
          onPressed: _inputBlocked
              ? null
              : () => tryUnlock(_textEditingController.text),
        ),
      ),
    );
    // A rejected PIN is an error; biometric advice is a muted hint.
    final hint = _errorText == null;
    final error = _errorText ?? _lock.biometricMessage;
    return Scaffold(
      appBar: AppBar(title: const Text(LockScreen.title), centerTitle: true),
      body: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(NotionSpace.md),
        children: [
          NotionEntrance(
            afterRoute: false,
            rise: 0,
            scale: NotionMotion.dialogFrom,
            child: Center(
              child: Image.asset(
                AppConfig.logoSilhouetteAsset,
                width: 128,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
              ),
            ),
          ),
          const SizedBox(height: NotionSpace.md),
          NotionEntrance(
            index: 1,
            afterRoute: false,
            child: Center(
              child: NotionShake(
                trigger: _rejections,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    field,
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: _PinDots(
                            controller: _textEditingController,
                            color: colors.text,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          NotionSizeReveal(
            visible: error != null,
            child: Padding(
              padding: const EdgeInsets.only(top: NotionSpace.xs),
              child: Text(
                error ?? '',
                textAlign: TextAlign.center,
                style: context.notion.typography.footnote.copyWith(
                  color: hint ? colors.textSecondary : colors.danger,
                ),
              ),
            ),
          ),
          NotionSizeReveal(
            visible: _inputBlocked,
            child: const Padding(
              padding: EdgeInsets.all(NotionSpace.md),
              child: Center(child: NotionDelayedSpinner()),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _lock.removeListener(_lockChanged);
    _pinFocus.dispose();
    _textEditingController.dispose();
    super.dispose();
  }
}

/// One dot per typed digit; each new dot pops in, deleted dots leave.
class _PinDots extends StatelessWidget {
  final TextEditingController controller;
  final Color color;
  const _PinDots({required this.controller, required this.color});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: NotionSpace.sm,
      children: [
        for (var i = 0; i < value.text.length; i++)
          NotionPop(
            key: ValueKey(i),
            child: Container(
              width: NotionSpace.sm,
              height: NotionSpace.sm,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
      ],
    ),
  );
}
