// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

class KeyVerificationDialog extends StatefulWidget {
  Future<bool?> show(BuildContext context) => showNotionCustomDialog<bool>(
    context: context,
    builder: (context) => this,
    barrierDismissible: false,
  );

  final KeyVerification request;

  const KeyVerificationDialog({super.key, required this.request});

  @override
  KeyVerificationPageState createState() => KeyVerificationPageState();
}

class KeyVerificationPageState extends State<KeyVerificationDialog> {
  void Function()? originalOnUpdate;
  late final List<dynamic> sasEmoji;

  /// The user took part: started this verification or accepted it here.
  /// Incoming requests open in [KeyVerificationState.askAccept].
  bool _engaged = false;

  /// The dialog is already closing (Reject, or an automatic dismissal).
  bool _closing = false;

  @override
  void initState() {
    originalOnUpdate = widget.request.onUpdate;
    widget.request.onUpdate = () {
      originalOnUpdate?.call();
      if (!mounted) return;
      if (_dismissIfUnanswered()) return;
      setState(() {});
    };
    super.initState();
    _engaged =
        widget.request.startedVerification ||
        !{
          KeyVerificationState.askAccept,
          KeyVerificationState.error,
        }.contains(widget.request.state);
    _dismissIfUnanswered();
    // The dialog can close before these finish (dismissed request).
    widget.request.client.getProfileFromUserId(widget.request.userId).then((p) {
      if (!mounted) return;
      profile = p;
      setState(() {});
    });
    rootBundle.loadString('assets/sas-emoji.json').then((e) {
      if (!mounted) return;
      sasEmoji = json.decode(e);
      setState(() {});
    });
  }

  @override
  void dispose() {
    widget.request.onUpdate =
        originalOnUpdate; // don't want to get updates anymore
    if (![
      KeyVerificationState.error,
      KeyVerificationState.done,
    ].contains(widget.request.state)) {
      unawaited(
        widget.request
            .cancel('m.user')
            .then(
              (_) {},
              onError: (Object e, StackTrace s) =>
                  logBackgroundError('verification_cancel', e, s),
            ),
      );
    }
    textEditingController?.dispose();
    super.dispose();
  }

  Profile? profile;

  /// An incoming request the user never accepted that stops on its own
  /// (the requesting device gave up, timed out, or another of the user's
  /// devices answered) just goes away, like Element's request toast. Only
  /// a verification the user took part in explains why it stopped.
  bool _dismissIfUnanswered() {
    final request = widget.request;
    if (_closing || request.state != KeyVerificationState.error) return false;
    if (_engaged && request.canceledCode != 'm.accepted') return false;
    _closing = true;
    Logs().i(
      '[Key Verification] unanswered request ended: ${request.canceledCode}',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context, rootNavigator: false);
      if (route.isCurrent) {
        navigator.pop(false);
      } else {
        navigator.removeRoute(route);
      }
    });
    // Nothing else may be animating: make sure that frame comes.
    WidgetsBinding.instance.ensureVisualUpdate();
    return true;
  }

  /// Runs a verification step the user tapped. A step that cannot reach
  /// the server is explained, with "Try again", instead of leaving the
  /// dialog waiting forever.
  void _act(
    Future<void> Function() step, {
    VoidCallback? then,
    VoidCallback? failed,
  }) {
    unawaited(
      step().then<void>(
        (_) => then?.call(),
        onError: (Object error, StackTrace stack) {
          failed?.call();
          if (!mounted) return;
          unawaited(
            ErrorReporter.action(
              context,
              onRetry: () => _act(step, then: then, failed: failed),
            ).onErrorCallback(error, stack),
          );
        },
      ),
    );
  }

  Future<void> checkInput(String input) async {
    if (input.isEmpty) return;

    final valid = await showFutureLoadingDialog(
      context: context,
      future: () async {
        // make sure the loading spinner shows before we test the keys
        await Future.delayed(const Duration(milliseconds: 100));
        var valid = false;
        try {
          await widget.request.openSSSS(keyOrPassphrase: input);
          valid = true;
        } catch (_) {
          valid = false;
        }
        return valid;
      },
    );
    if (valid.error != null) {
      if (!mounted) return;
      setState(() => _rejections++);
      await showOkAlertDialog(
        useRootNavigator: false,
        context: context,
        title: L10n.of(context).incorrectPassphraseOrKey,
      );
    }
  }

  TextEditingController? textEditingController;

  /// Bumped when a passphrase or key is rejected: shakes the field.
  int _rejections = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    User? user;
    final directChatId = widget.request.client.getDirectChatFromUserId(
      widget.request.userId,
    );
    if (directChatId != null) {
      user = widget.request.client
          .getRoomById(directChatId)!
          .unsafeGetUserFromMemoryOrFallback(widget.request.userId);
    }
    final displayName =
        user?.calcDisplayname() ?? widget.request.userId.localpart!;
    var title = Text(L10n.of(context).verifyTitle);
    Widget body;
    final buttons = <Widget>[];

    switch (widget.request.state) {
      case KeyVerificationState.showQRSuccess:
      case KeyVerificationState.confirmQRScan:
        throw 'Not implemented';
      case KeyVerificationState.askSSSS:
        // prompt the user for their ssss passphrase / key
        // Kept across rebuilds, so a profile update does not wipe the input.
        final textEditingController = this.textEditingController ??=
            TextEditingController();
        String input;
        body = Container(
          margin: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Column(
            mainAxisSize: .min,
            children: <Widget>[
              Text(
                L10n.of(context).askSSSSSign,
                style: const TextStyle(fontSize: 20),
              ),
              Container(height: 10),
              NotionShake(
                trigger: _rejections,
                child: TextField(
                  controller: textEditingController,
                  autofocus: false,
                  autocorrect: false,
                  onSubmitted: (s) {
                    input = s;
                    checkInput(input);
                  },
                  minLines: 1,
                  maxLines: 1,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: L10n.of(context).passphraseOrKey,
                    prefixStyle: TextStyle(color: theme.colorScheme.primary),
                    suffixStyle: TextStyle(color: theme.colorScheme.primary),
                  ),
                ),
              ),
            ],
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            child: Text(L10n.of(context).submit),
            onPressed: () => checkInput(textEditingController.text),
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            child: Text(L10n.of(context).skip),
            onPressed: () => _act(() => widget.request.openSSSS(skip: true)),
          ),
        );
        break;
      case KeyVerificationState.askAccept:
        title = Text(L10n.of(context).newVerificationRequest);
        body = Column(
          mainAxisSize: .min,
          children: [
            const SizedBox(height: 16),
            NotionPop(
              bounce: false,
              from: NotionMotion.dialogFrom,
              child: Avatar(
                mxContent: user?.avatarUrl,
                name: displayName,
                size: Avatar.defaultSize * 2,
              ),
            ),
            const SizedBox(height: 16),
            Text(L10n.of(context).askVerificationRequest(displayName)),
          ],
        );
        buttons.add(
          AdaptiveDialogAction(
            onPressed: () {
              _closing = true;
              _act(
                widget.request.rejectVerification,
                then: () {
                  if (!context.mounted) return;
                  Navigator.of(context, rootNavigator: false).pop(false);
                },
                failed: () => _closing = false,
              );
            },
            child: Text(
              L10n.of(context).reject,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            onPressed: () {
              _engaged = true;
              _act(widget.request.acceptVerification);
            },
            child: Text(L10n.of(context).accept),
          ),
        );
        break;
      case KeyVerificationState.askChoice:
      case KeyVerificationState.waitingAccept:
        body = Center(
          child: Column(
            children: <Widget>[
              const SizedBox(height: 16),
              // Waiting for the other side: the avatar breathes a ring.
              NotionPulse(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
                child: Avatar(mxContent: user?.avatarUrl, name: displayName),
              ),
              const SizedBox(height: 16),
              Text(
                L10n.of(context).waitingPartnerAcceptRequest,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            // `m.user`, not the SDK's default `m.unknown`: the other
            // device then knows the user cancelled.
            onPressed: () => _act(() => widget.request.cancel('m.user')),
            child: Text(L10n.of(context).cancel),
          ),
        );

        break;
      case KeyVerificationState.askSas:
        TextSpan compareWidget;
        // maybe add a button to switch between the two and only determine default
        // view for if "emoji" is a present sasType or not?

        if (widget.request.sasTypes.contains('emoji')) {
          title = Text(
            L10n.of(context).compareEmojiMatch,
            maxLines: 1,
            style: const TextStyle(fontSize: 16),
          );
          final emojis = widget.request.sasEmojis;
          // The seven emoji deal in one after another.
          compareWidget = TextSpan(
            children: [
              for (var i = 0; i < emojis.length; i++)
                WidgetSpan(
                  child: NotionEntrance(
                    index: i,
                    afterRoute: false,
                    rise: NotionMotion.riseList,
                    scale: NotionMotion.dialogFrom,
                    child: _Emoji(emojis[i], sasEmoji),
                  ),
                ),
            ],
          );
        } else {
          title = Text(L10n.of(context).compareNumbersMatch);
          final numbers = widget.request.sasNumbers;
          final numbstr = '${numbers.first}-${numbers[1]}-${numbers[2]}';
          compareWidget = TextSpan(
            text: numbstr,
            style: const TextStyle(fontSize: 40),
          );
        }
        body = Column(
          mainAxisSize: .min,
          children: <Widget>[
            Text.rich(compareWidget, textAlign: TextAlign.center),
          ],
        );
        buttons.add(
          AdaptiveDialogAction(
            onPressed: () => _act(widget.request.rejectSas),
            child: Text(
              L10n.of(context).theyDontMatch,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            onPressed: () => _act(widget.request.acceptSas),
            child: Text(L10n.of(context).theyMatch),
          ),
        );
        break;
      case KeyVerificationState.waitingSas:
        final acceptText = widget.request.sasTypes.contains('emoji')
            ? L10n.of(context).waitingPartnerEmoji
            : L10n.of(context).waitingPartnerNumbers;
        body = Column(
          mainAxisSize: .min,
          children: <Widget>[
            const SizedBox(height: 16),
            const NotionDelayedSpinner(size: NotionSize.touchTarget),
            const SizedBox(height: 16),
            Text(acceptText, textAlign: TextAlign.center),
          ],
        );
        break;
      case KeyVerificationState.done:
        title = Text(L10n.of(context).verifySuccess);
        // Success is a reward: the badge springs in.
        body = Padding(
          padding: const EdgeInsets.all(16.0),
          child: NotionPop(
            child: Icon(
              Icons.verified_outlined,
              color: context.notion.colors.success,
              size: 128.0,
            ),
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            child: Text(L10n.of(context).close),
            onPressed: () =>
                Navigator.of(context, rootNavigator: false).pop(true),
          ),
        );
        break;
      case KeyVerificationState.error:
        title = const Text('Verification stopped');
        body = Column(
          mainAxisSize: .min,
          children: <Widget>[
            const SizedBox(height: 16),
            NotionPop(
              bounce: false,
              child: Icon(
                Icons.cancel,
                color: theme.colorScheme.error,
                size: 64.0,
              ),
            ),
            const SizedBox(height: 16),
            // The cancel code is protocol vocabulary (`m.unknown`); the
            // peer's free-text reason is untrusted. Neither is shown.
            Text(
              verificationCancelText(widget.request.canceledCode),
              textAlign: TextAlign.center,
            ),
          ],
        );
        buttons.add(
          AdaptiveDialogAction(
            child: Text(L10n.of(context).close),
            onPressed: () =>
                Navigator.of(context, rootNavigator: false).pop(false),
          ),
        );
        break;
    }

    final step = widget.request.state;
    // The glass dialog on every platform (no Cupertino alert on macOS).
    return NotionAlertDialog(
      // Every verification step fades through to the next one.
      title: NotionFadeThrough(
        alignment: Alignment.center,
        child: KeyedSubtree(key: ValueKey(step), child: title),
      ),
      content: SizedBox(
        height: 256,
        child: NotionFadeThrough(
          child: ListView(key: ValueKey(step), children: [body]),
        ),
      ),
      actions: buttons,
    );
  }
}

class _Emoji extends StatelessWidget {
  final KeyVerificationEmoji emoji;
  final List<dynamic>? sasEmoji;

  const _Emoji(this.emoji, this.sasEmoji);

  // The app is English-only; SAS descriptions follow the app language.
  String getLocalizedName() => emoji.name;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: .min,
      children: <Widget>[
        Text(emoji.emoji, style: const TextStyle(fontSize: 50)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(getLocalizedName()),
        ),
        const SizedBox(height: 10, width: 5),
      ],
    );
  }
}
