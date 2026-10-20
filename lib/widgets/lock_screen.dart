// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

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

  Future<void> tryUnlockWithBiometrics() async {
    setState(() {
      _errorText = null;
    });

    final success = await AppLock.of(context).unlockWithBiometrics();
    if (!mounted) return;

    if (success) {
      setState(() {
        _inputBlocked = false;
        _errorText = null;
      });
      return;
    }

    _reject();
    setState(() {
      _errorText = L10n.of(context).wrongPinEntered(_coolDownSeconds);
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

  void _reject() {
    _rejections++;
    NotionHaptics.light();
  }

  Future<void> tryUnlock(String text) async {
    text = text.trim();
    setState(() {
      _errorText = null;
    });

    final enteredPin = int.tryParse(text);
    if (enteredPin == null) {
      _reject();
      setState(() {
        _errorText = L10n.of(context).invalidInput;
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
      _errorText = L10n.of(context).wrongPinEntered(_coolDownSeconds);
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

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final appLock = AppLock.of(context);
    final field = TextField(
      controller: _textEditingController,
      textInputAction: TextInputAction.go,
      keyboardType: TextInputType.number,
      obscureText: true,
      autofocus: true,
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
        prefix: appLock.useBiometrics
            ? IconButton(
                tooltip: L10n.of(context).unlockWithBiometrics,
                icon: FutureBuilder(
                  future: LocalAuthentication().getAvailableBiometrics(),
                  builder: (context, snapshot) {
                    final availableBiometrics = snapshot.data ?? [];
                    if (availableBiometrics.contains(BiometricType.face)) {
                      return Icon(Icons.face_unlock_outlined);
                    }
                    return Icon(Icons.fingerprint_outlined);
                  },
                ),
                onPressed: _inputBlocked ? null : tryUnlockWithBiometrics,
              )
            : IconButton(
                tooltip: L10n.of(context).reset,
                icon: Icon(Icons.cancel_outlined),
                onPressed: _inputBlocked ? null : _textEditingController.clear,
              ),
        suffix: IconButton(
          tooltip: L10n.of(context).unlock,
          icon: Icon(Icons.send_outlined),
          onPressed: _inputBlocked
              ? null
              : () => tryUnlock(_textEditingController.text),
        ),
      ),
    );
    final error = _errorText;
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => Scaffold(
            appBar: AppBar(
              title: Text(L10n.of(context).pleaseEnterYourPin),
              centerTitle: true,
            ),
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
                      'assets/logo/mini/logo_mono_mini.png',
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
                        color: colors.danger,
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
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
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
