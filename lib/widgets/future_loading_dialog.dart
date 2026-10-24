// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:async/async.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_notion_adaptive_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix_api_lite/utils/logs.dart';

/// Displays a loading dialog which reacts to the given [future]. The dialog
/// will be dismissed and the value will be returned when the future completes.
/// If an error occured, then [onError] will be called and this method returns
/// null.
Future<Result<T>> showFutureLoadingDialog<T>({
  required BuildContext context,
  Future<T> Function()? future,
  Future<T> Function(void Function(double?) setProgress)? futureWithProgress,
  String? title,
  String? backLabel,
  bool barrierDismissible = false,
  bool delay = true,
  ExceptionContext? exceptionContext,
  bool ignoreError = false,
}) async {
  assert(future != null || futureWithProgress != null);
  final onProgressStream = StreamController<double?>();
  final futureExec =
      futureWithProgress?.call(onProgressStream.add) ?? future!();
  final resultFuture = ResultFuture(futureExec);

  if (delay) {
    // Fast operations finish inside the grace period and never flash a
    // dialog. A cancelled timer (not `Future.delayed`) leaves nothing pending.
    final grace = Completer<void>();
    final timer = Timer(NotionMotion.loaderGrace, grace.complete);
    await Future.any<void>([
      futureExec.then<void>((_) {}, onError: (_, _) {}),
      grace.future,
    ]);
    timer.cancel();
    final result = resultFuture.result;
    if (result != null && !result.isError) return result;
  }

  if (!context.mounted) {
    Logs().e(
      'Unable to show loading dialog!',
      Exception('The BuildContext is not mounted!'),
      StackTrace.current,
    );
    return Result.capture(futureExec);
  }

  final result = await showNotionAdaptiveDialog<Result<T>>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext context) => LoadingDialog<T>(
      future: futureExec,
      title: title,
      backLabel: backLabel,
      exceptionContext: exceptionContext,
      onProgressStream: onProgressStream.stream,
    ),
  );
  return result ??
      Result.error(Exception('FutureDialog canceled'), StackTrace.current);
}

class LoadingDialog<T> extends StatefulWidget {
  final String? title;
  final String? backLabel;
  final Future<T> future;
  final ExceptionContext? exceptionContext;
  final Stream<double?> onProgressStream;

  const LoadingDialog({
    super.key,
    required this.future,
    this.title,
    this.backLabel,
    this.exceptionContext,
    required this.onProgressStream,
  });

  @override
  LoadingDialogState<T> createState() => LoadingDialogState<T>();
}

/// Progress morphs into a check that pops in before the dialog leaves, or
/// fades through to the error, which shakes once. The check is the only
/// hold: its animation completing closes the dialog (no timers).
class LoadingDialogState<T> extends State<LoadingDialog<T>>
    with SingleTickerProviderStateMixin {
  Object? exception;
  StackTrace? stackTrace;
  Result<T>? _done;

  late final AnimationController _check = AnimationController(
    vsync: this,
    duration: NotionMotion.medium,
  )..addStatusListener(_checkStatus);
  late final CurvedAnimation _checkScale = CurvedAnimation(
    parent: _check,
    curve: NotionMotion.bouncyCurve,
  );

  @override
  void initState() {
    super.initState();
    widget.future.then(
      (result) {
        if (!mounted) return;
        _done = Result.value(result);
        if (NotionMotion.reduced(context)) {
          _close();
          return;
        }
        setState(() {});
        _check.forward();
      },
      onError: (e, s) {
        if (!mounted) return;
        setState(() {
          exception = e;
          stackTrace = s;
        });
      },
    );
  }

  void _checkStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _close();
  }

  void _close() {
    final done = _done;
    if (!mounted || done == null) return;
    _done = null;
    if (!Navigator.of(context).canPop()) return;
    Navigator.of(context).pop<Result<T>>(done);
  }

  @override
  void dispose() {
    _checkScale.dispose();
    _check.dispose();
    super.dispose();
  }

  Widget _progress(BuildContext context) {
    if (_check.isAnimating || _check.isCompleted) {
      return SizedBox.square(
        key: const ValueKey('done'),
        dimension: NotionSize.iconLg,
        child: ScaleTransition(
          scale: _checkScale,
          child: Icon(
            Icons.check_circle_outline,
            size: NotionSize.iconLg,
            color: context.notion.colors.success,
          ),
        ),
      );
    }
    return StreamBuilder<double?>(
      key: const ValueKey('progress'),
      stream: widget.onProgressStream,
      builder: (context, snapshot) {
        final value = snapshot.data;
        if (value == null) {
          // The dialog itself appeared after the grace period, so the ring
          // shows at once; it still rests after `loopCap` (an endless wait
          // draws no frames).
          return const NotionDelayedSpinner(
            size: NotionSize.iconLg,
            strokeWidth: 2.5,
            delay: Duration.zero,
          );
        }
        // Determinate progress glides between reported values.
        return TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0, 1).toDouble()),
          duration: NotionMotion.of(context, NotionMotion.medium),
          curve: NotionMotion.standard,
          builder: (context, value, _) => SizedBox.square(
            dimension: NotionSize.iconLg,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 2.5,
              color: context.notion.colors.textSecondary,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final exception = this.exception;
    final tokens = context.notion;
    final titleLabel = exception != null
        ? exception.toLocalizedString(context, widget.exceptionContext)
        : widget.title ?? L10n.of(context).loadingPleaseWait;

    final Widget body = exception == null
        ? Row(
            key: const ValueKey('loading'),
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              NotionMorphSwitcher(rotate: false, child: _progress(context)),
              const SizedBox(width: NotionSpace.md),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    titleLabel,
                    maxLines: 4,
                    textAlign: TextAlign.start,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.typography.callout,
                  ),
                ),
              ),
            ],
          )
        : Column(
            key: const ValueKey('error'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NotionPop(
                bounce: false,
                from: NotionMotion.dialogFrom,
                child: Icon(
                  Icons.error_outline_outlined,
                  color: tokens.colors.danger,
                  size: NotionSize.avatar,
                ),
              ),
              const SizedBox(height: NotionSpace.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  titleLabel,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: tokens.typography.callout,
                ),
              ),
              // The action stays with the content so the dialog grows in
              // one smooth step.
              Padding(
                padding: const EdgeInsets.only(top: NotionSpace.lg),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: NotionButton(
                    key: const Key('loading_dialog_close_button'),
                    label: widget.backLabel ?? L10n.of(context).close,
                    onPressed: () => Navigator.of(
                      context,
                    ).pop<Result<T>>(Result.error(exception, stackTrace)),
                  ),
                ),
              ),
            ],
          );

    // A compact glass panel (the dialog radius and tint) on every platform:
    // no Cupertino alert or activity indicator on macOS.
    return NotionDialogFrame(
      maxWidth: _maxWidth,
      padding: const EdgeInsets.all(NotionSpace.lg),
      child: NotionShake(
        // The error arrives with a single shake.
        trigger: exception,
        child: NotionAnimatedSize(
          curve: NotionMotion.emphasized,
          alignment: Alignment.topCenter,
          child: NotionFadeThrough(alignment: Alignment.center, child: body),
        ),
      ),
    );
  }

  /// A progress line, not a full dialog: narrower than a question.
  static const double _maxWidth = 320;
}

extension DeprecatedApiAccessExtension<T> on Result<T> {
  T? get result => asValue?.value;

  Object? get error => asError?.error;
}
