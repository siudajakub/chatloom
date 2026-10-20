// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
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

  @override
  void initState() {
    originalOnUpdate = widget.request.onUpdate;
    widget.request.onUpdate = () {
      originalOnUpdate?.call();
      setState(() {});
    };
    widget.request.client.getProfileFromUserId(widget.request.userId).then((p) {
      profile = p;
      setState(() {});
    });
    rootBundle.loadString('assets/sas-emoji.json').then((e) {
      sasEmoji = json.decode(e);
      setState(() {});
    });
    super.initState();
  }

  @override
  void dispose() {
    widget.request.onUpdate =
        originalOnUpdate; // don't want to get updates anymore
    if (![
      KeyVerificationState.error,
      KeyVerificationState.done,
    ].contains(widget.request.state)) {
      widget.request.cancel('m.user');
    }
    textEditingController?.dispose();
    super.dispose();
  }

  Profile? profile;

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
            onPressed: () => widget.request.openSSSS(skip: true),
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
            onPressed: () => widget.request.rejectVerification().then((_) {
              if (!context.mounted) return;
              Navigator.of(context, rootNavigator: false).pop(false);
            }),
            child: Text(
              L10n.of(context).reject,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            onPressed: () => widget.request.acceptVerification(),
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
            onPressed: () => widget.request.cancel(),
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
            onPressed: () => widget.request.rejectSas(),
            child: Text(
              L10n.of(context).theyDontMatch,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        );
        buttons.add(
          AdaptiveDialogAction(
            onPressed: () => widget.request.acceptSas(),
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
        title = const Text('');
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
            // TODO: Add better error UI to user
            Text(
              'Error ${widget.request.canceledCode}: ${widget.request.canceledReason}',
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
    return AlertDialog.adaptive(
      // Every verification step fades through to the next one.
      title: NotionFadeThrough(
        alignment: Alignment.center,
        child: KeyedSubtree(key: ValueKey(step), child: title),
      ),
      content: SizedBox(
        height: 256,
        width: 256,
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
