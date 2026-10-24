// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The text field of a dialog: the themed Notion field (rounded `field`
/// corners, `surface` fill) with the label above it, on every platform (no
/// Cupertino field on macOS).
class DialogTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final String? initialText;
  final String? counterText;
  final String? prefixText;
  final String? suffixText;
  final String? errorText;
  final bool obscureText;
  final bool isDestructive = false;
  final int? minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final int? maxLength;
  final bool autocorrect;
  final bool readOnly;
  final bool autofocus;
  final TextStyle? textStyle;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const DialogTextField({
    super.key,
    this.hintText,
    this.labelText,
    this.initialText,
    this.prefixText,
    this.suffixText,
    this.minLines,
    this.maxLines,
    this.keyboardType,
    this.maxLength,
    this.controller,
    this.counterText,
    this.errorText,
    this.obscureText = false,
    this.readOnly = false,
    this.autofocus = false,
    this.autocorrect = true,
    this.textStyle,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final field = TextField(
      readOnly: readOnly,
      controller: controller,
      obscureText: obscureText,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: obscureText ? 1 : maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      autocorrect: autocorrect,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: textStyle ?? tokens.typography.callout,
      decoration: InputDecoration(
        errorText: errorText,
        hintText: hintText,
        prefixText: prefixText,
        suffixText: suffixText,
        counterText: counterText,
      ),
    );
    final label = labelText;
    if (label == null) return field;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: NotionSpace.xxs),
          child: Text(label, style: tokens.typography.sectionLabel),
        ),
        field,
      ],
    );
  }
}
