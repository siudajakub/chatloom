// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/adaptive_dialogs/dialog_text_field.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_notion_adaptive_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// Asks for one line (or [maxLines]) of text in a glass [NotionDialog].
/// The field takes focus at once (Telegram's rename/report dialogs); a
/// single-line field confirms on Return. A rejected value shakes the field
/// and keeps the [validator]'s message.
Future<String?> showTextInputDialog({
  required BuildContext context,
  required String title,
  String? message,
  String? okLabel,
  String? cancelLabel,
  bool useRootNavigator = true,
  String? hintText,
  String? labelText,
  String? initialText,
  String? prefixText,
  String? suffixText,
  bool obscureText = false,
  bool isDestructive = false,
  int? minLines,
  int? maxLines,
  String? Function(String input)? validator,
  TextInputType? keyboardType,
  int? maxLength,
  bool autocorrect = true,
}) => showNotionAdaptiveDialog<String>(
  context: context,
  useRootNavigator: useRootNavigator,
  builder: (context) => _TextInputDialog(
    title: title,
    message: message,
    okLabel: okLabel,
    cancelLabel: cancelLabel,
    hintText: hintText,
    labelText: labelText,
    initialText: initialText,
    prefixText: prefixText,
    suffixText: suffixText,
    obscureText: obscureText,
    isDestructive: isDestructive,
    minLines: minLines,
    maxLines: maxLines,
    validator: validator,
    keyboardType: keyboardType,
    maxLength: maxLength,
    autocorrect: autocorrect,
  ),
);

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String? message;
  final String? okLabel;
  final String? cancelLabel;
  final String? hintText;
  final String? labelText;
  final String? initialText;
  final String? prefixText;
  final String? suffixText;
  final bool obscureText;
  final bool isDestructive;
  final int? minLines;
  final int? maxLines;
  final String? Function(String input)? validator;
  final TextInputType? keyboardType;
  final int? maxLength;
  final bool autocorrect;

  const _TextInputDialog({
    required this.title,
    required this.message,
    required this.okLabel,
    required this.cancelLabel,
    required this.hintText,
    required this.labelText,
    required this.initialText,
    required this.prefixText,
    required this.suffixText,
    required this.obscureText,
    required this.isDestructive,
    required this.minLines,
    required this.maxLines,
    required this.validator,
    required this.keyboardType,
    required this.maxLength,
    required this.autocorrect,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  // State, not the builder: the dialog rebuilds when the keyboard opens, and
  // the input and the shown error must survive that.
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  final ValueNotifier<DialogValidation> _error = ValueNotifier(
    const DialogValidation(),
  );

  bool get _singleLine => widget.obscureText || widget.maxLines == 1;

  void _submit() {
    final input = _controller.text;
    final errorText = widget.validator?.call(input);
    if (errorText != null) {
      _error.value = _error.value.reject(errorText);
      return;
    }
    Navigator.of(context).pop<String>(input);
  }

  @override
  void dispose() {
    _controller.dispose();
    _error.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    return NotionDialog(
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) ...[
            Flexible(child: DialogMessage(message)),
            const SizedBox(height: NotionSpace.md),
          ],
          DialogValidationFeedback(
            validation: _error,
            builder: (context, error) => DialogTextField(
              hintText: widget.hintText,
              errorText: error,
              labelText: widget.labelText,
              controller: _controller,
              prefixText: widget.prefixText,
              suffixText: widget.suffixText,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              maxLength: widget.maxLength,
              keyboardType: widget.keyboardType,
              obscureText: widget.obscureText,
              autocorrect: widget.autocorrect,
              autofocus: true,
              textInputAction: _singleLine ? TextInputAction.done : null,
              onSubmitted: _singleLine ? (_) => _submit() : null,
            ),
          ),
        ],
      ),
      actions: [
        NotionButton.ghost(
          key: const Key('text_input_dialog_cancel_button'),
          label: widget.cancelLabel ?? L10n.of(context).cancel,
          onPressed: () => Navigator.of(context).pop(null),
        ),
        NotionButton(
          key: const Key('text_input_dialog_ok_button'),
          label: widget.okLabel ?? L10n.of(context).ok,
          variant: widget.isDestructive
              ? NotionButtonVariant.destructive
              : NotionButtonVariant.primary,
          onPressed: _submit,
        ),
      ],
    );
  }
}
