// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Drop-in for `showAdaptiveDialog` that presents the (still adaptive)
/// dialog body in the animated [NotionDialogRoute]: the barrier fades, the
/// dialog scales up from 94 % on a critically damped spring and leaves with
/// a quick fade. Reduced motion keeps a plain fade.
///
/// [barrierDismissible] defaults like `showAdaptiveDialog`: dismissible on
/// Material platforms, not on iOS/macOS.
Future<T?> showNotionAdaptiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool? barrierDismissible,
  bool useRootNavigator = true,
  bool useSafeArea = true,
  RouteSettings? routeSettings,
}) {
  final apple = switch (Theme.of(context).platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => true,
    _ => false,
  };
  return showNotionCustomDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible ?? !apple,
    useRootNavigator: useRootNavigator,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
  );
}

/// The visible state of a validated dialog field: the message plus a
/// counter that changes on every rejected attempt, so repeating the same
/// error still shakes the field.
@immutable
class DialogValidation {
  final String? error;
  final int attempt;
  const DialogValidation([this.error, this.attempt = 0]);

  DialogValidation reject(String error) => DialogValidation(error, attempt + 1);
}

/// Shakes [child] on each rejected attempt and reveals the error smoothly.
class DialogValidationFeedback extends StatelessWidget {
  final ValueListenable<DialogValidation> validation;
  final Widget Function(BuildContext context, String? error) builder;
  const DialogValidationFeedback({
    super.key,
    required this.validation,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<DialogValidation>(
        valueListenable: validation,
        builder: (context, state, _) => NotionShake(
          trigger: state.attempt,
          child: AnimatedSize(
            duration: NotionMotion.of(context, NotionMotion.short),
            curve: NotionMotion.standard,
            alignment: AlignmentDirectional.topStart,
            child: builder(context, state.error),
          ),
        ),
      );
}
