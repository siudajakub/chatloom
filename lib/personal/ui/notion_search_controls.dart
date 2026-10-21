// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The field of the full-screen search (a pill in the glass header).
///
/// Typing only invokes [onChanged], which filters on the device; anything
/// that sends the query to a network is a separate, explicit action on the
/// page. Escape closes the search unless an IME composition is active.
class NotionSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback onClose;
  final String hint;
  final bool autofocus;
  const NotionSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
    this.onSubmitted,
    this.hint = 'Search chats, people and messages',
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.escape ||
          (controller.value.composing.isValid &&
              !controller.value.composing.isCollapsed)) {
        return KeyEventResult.ignored;
      }
      onClose();
      return KeyEventResult.handled;
    },
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      style: context.notion.typography.callout,
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: NotionSize.icon),
        // The clear button pops in once there is something to clear.
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => NotionMorphSwitcher(
            rotate: false,
            child: value.text.isEmpty
                ? const SizedBox.shrink(key: ValueKey('empty'))
                : IconButton(
                    key: const ValueKey('clear'),
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close, size: NotionSize.icon),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                      focusNode.requestFocus();
                    },
                  ),
          ),
        ),
        // The theme's pill outline (NotionRadius.field).
      ),
    ),
  );
}
