// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Typing can only invoke the local callback. Public discovery is an explicit
/// separate action, so the production controller never discloses a typed query.
class NotionInboxSearch extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;
  final VoidCallback onHistorySearch;
  final VoidCallback onPublicDiscovery;
  final bool searchingPublic;
  final Widget? options;
  const NotionInboxSearch({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
    required this.onHistorySearch,
    required this.onPublicDiscovery,
    this.searchingPublic = false,
    this.options,
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
    child: ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: onChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search your chats',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) => TextButton(
                        onPressed: value.text.isEmpty
                            ? null
                            : () {
                                controller.clear();
                                onChanged('');
                                focusNode.requestFocus();
                              },
                        child: const Text('Clear'),
                      ),
                    ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
              NotionIconButton(
                icon: Icons.close,
                label: 'Close search',
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Private search · loaded conversation names and metadata',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: onHistorySearch,
                icon: const Icon(Icons.manage_search, size: 18),
                label: const Text('Search message history'),
              ),
              TextButton.icon(
                onPressed: searchingPublic || value.text.trim().isEmpty
                    ? null
                    : onPublicDiscovery,
                icon: NotionMorphSwitcher(
                  rotate: false,
                  child: searchingPublic
                      ? const NotionDelayedSpinner(
                          key: ValueKey('searching'),
                          size: 16,
                        )
                      : const Icon(
                          Icons.public,
                          key: ValueKey('public'),
                          size: 18,
                        ),
                ),
                label: const Text('Discover publicly'),
              ),
              ?options,
            ],
          ),
        ],
      ),
    ),
  );
}
