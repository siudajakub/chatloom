// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/matrix_error_text.dart';

/// Plain-language text for a send or upload that failed. Never the
/// exception's own text, an errcode or an HTTP status: the wording comes
/// from the shared Matrix error mapping ([humanErrorText]).
String sendErrorText(Object error, {bool upload = false}) => humanErrorText(
  error,
  action: upload ? ErrorAction.upload : ErrorAction.send,
);
