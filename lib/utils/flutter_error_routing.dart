// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Routes framework errors to the global error handler.
///
/// Errors the framework marks [FlutterErrorDetails.silent] (image codec
/// failures of an `Image` without `errorBuilder`, some gesture and
/// keyboard-state noise) are diagnostics, not failed user actions: they are
/// logged and never open the modal error dialog, and before the navigator
/// exists they must never replace the app with the fatal start screen.
/// Only the type and library are logged, never the message text (it can
/// carry URLs or content).
void routeFlutterError(
  FlutterErrorDetails details,
  void Function(Object error, StackTrace stackTrace) report,
) {
  if (details.silent) {
    Logs().w(
      'Silent framework error: ${details.exception.runtimeType} '
      '(${details.library ?? 'unknown library'})',
    );
    return;
  }
  report(details.exception, details.stack ?? StackTrace.current);
}
