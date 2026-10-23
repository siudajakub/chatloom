// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/utils/uia_stage.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/chatloom_app.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher.dart';

extension UiaRequestManager on MatrixState {
  Future uiaRequestHandler(UiaRequest uiaRequest) async {
    final l10n = L10n.of(context);
    final navigatorContext =
        ChatLoomApp.router.routerDelegate.navigatorKey.currentContext ??
        context;
    try {
      if (uiaRequest.state != UiaRequestState.waitForUser ||
          uiaRequest.nextStages.isEmpty) {
        Logs().d('Uia Request Stage: ${uiaRequest.state}');
        return;
      }
      final stage = preferredUiaStage(uiaRequest.nextStages);
      Logs().d('Uia Request Stage: $stage');
      switch (stage) {
        case AuthenticationTypes.password:
          final input =
              cachedPassword ??
              (await showTextInputDialog(
                context: navigatorContext,
                title: l10n.pleaseEnterYourPassword,
                okLabel: l10n.ok,
                cancelLabel: l10n.cancel,
                minLines: 1,
                maxLines: 1,
                obscureText: true,
                hintText: '******',
              ));
          if (input == null || input.isEmpty) {
            return uiaRequest.cancel();
          }
          return await uiaRequest.completeStage(
            AuthenticationPassword(
              session: uiaRequest.session,
              password: input,
              identifier: AuthenticationUserIdentifier(user: client.userID!),
            ),
          );
        case AuthenticationTypes.dummy:
          return await uiaRequest.completeStage(
            AuthenticationData(
              type: AuthenticationTypes.dummy,
              session: uiaRequest.session,
            ),
          );
        default:
          final stageUrl = uiaRequest.params
              .tryGetMap<String, Object?>(stage)
              ?.tryGet<String>('url');
          final fallbackUrl = uiaFallbackUrl(
            client.homeserver!,
            stage,
            uiaRequest.session,
          );
          final url = stageUrl != null
              ? (Uri.tryParse(stageUrl) ?? fallbackUrl)
              : fallbackUrl;

          final consent = await showOkCancelAlertDialog(
            useRootNavigator: false,
            title: l10n.pleaseFollowInstructionsOnWeb,
            context: navigatorContext,
            okLabel: l10n.open,
            cancelLabel: l10n.cancel,
          );
          if (consent != OkCancelResult.ok) return uiaRequest.cancel();

          final launched = await launchUrl(
            url,
            mode: LaunchMode.externalApplication,
          );
          if (!launched) {
            return uiaRequest.cancel(
              UiaException('Authentication page could not be opened.'),
            );
          }

          if (!navigatorContext.mounted) return uiaRequest.cancel();
          final completed = await showOkCancelAlertDialog(
            useRootNavigator: false,
            context: navigatorContext,
            title: l10n.pleaseFollowInstructionsOnWeb,
            message:
                'Complete authentication in your browser, then continue. '
                'If the page is unavailable, cancel and verify this session '
                'from another trusted device instead.',
            okLabel: l10n.continueText,
            cancelLabel: l10n.cancel,
          );
          if (completed != OkCancelResult.ok) return uiaRequest.cancel();

          return await uiaRequest.completeStage(
            AuthenticationData(
              session: uiaRequest.session,
              type: stageUrl == null ? null : stage,
            ),
          );
      }
    } catch (e, s) {
      Logs().e('Error while background UIA', e, s);
      return uiaRequest.cancel(e is Exception ? e : Exception(e));
    }
  }
}

class UiaException implements Exception {
  final String reason;

  UiaException(this.reason);

  @override
  String toString() => reason;
}
