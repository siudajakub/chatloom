// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion.dart';

/// One option of a single choice ([NotionPickerRow], [NotionChoicePill]).
@immutable
class NotionChoice<T> {
  final T value;
  final String label;
  final String? subtitle;
  const NotionChoice(this.value, this.label, {this.subtitle});
}

/// Telegram's settings picker: a glass sheet listing [options] with the
/// [selected] one checked. Returns the picked option (so a `null` value,
/// e.g. "All networks", differs from a dismissed sheet), or null.
Future<NotionChoice<T>?> showNotionChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<NotionChoice<T>> options,
  required T selected,
  String keyPrefix = 'choice',
}) => showNotionSheet<NotionChoice<T>>(
  context: context,
  title: title,
  builder: (context) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in options)
          NotionGlassMenuRow(
            key: ValueKey('$keyPrefix-${option.label}'),
            title: option.label,
            subtitle: option.subtitle,
            selected: option.value == selected,
            trailing: option.value == selected
                ? Icon(
                    Icons.check,
                    size: NotionSize.iconMd,
                    color: context.notion.colors.accent,
                  )
                : null,
            onTap: () => Navigator.of(context).pop(option),
          ),
      ],
    ),
  ),
);

String? _labelOf<T>(List<NotionChoice<T>> options, T value) =>
    options.where((o) => o.value == value).firstOrNull?.label;

/// A settings row for a single choice: label, the current value on the
/// right and a chevron; a tap opens [showNotionChoiceSheet]. Disabled
/// (no chevron, muted value) when [onChanged] is null.
class NotionPickerRow<T> extends StatelessWidget {
  final String label;
  final String? subtitle;
  final IconData? icon;
  final T value;
  final List<NotionChoice<T>> options;
  final ValueChanged<T>? onChanged;

  /// Shown when [value] is none of [options] ("Choose…").
  final String placeholder;
  const NotionPickerRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    this.subtitle,
    this.icon,
    this.onChanged,
    this.placeholder = 'Choose…',
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final current = _labelOf(options, value) ?? placeholder;
    final onChanged = this.onChanged;
    return Semantics(
      value: current,
      child: NotionListRow(
        leading: icon == null ? null : Icon(icon),
        title: label,
        subtitle: subtitle,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: NotionFadeThrough(
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  current,
                  key: ValueKey(current),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: onChanged == null
                      ? tokens.typography.calloutMuted.copyWith(
                          color: tokens.colors.textTertiary,
                        )
                      : tokens.typography.calloutMuted,
                ),
              ),
            ),
            if (onChanged != null) ...[
              const SizedBox(width: NotionSpace.xxs),
              const Icon(Icons.chevron_right, size: NotionSize.iconMd),
            ],
          ],
        ),
        onTap: onChanged == null || options.isEmpty
            ? null
            : () async {
                final picked = await showNotionChoiceSheet<T>(
                  context,
                  title: label,
                  options: options,
                  selected: value,
                );
                if (picked != null && picked.value != value) {
                  onChanged(picked.value);
                }
              },
      ),
    );
  }
}

/// A filter pill showing the current choice ("All networks ▾"); selected
/// while it differs from [neutral]. A tap opens [showNotionChoiceSheet].
class NotionChoicePill<T> extends StatelessWidget {
  final String title;
  final T value;
  final T neutral;
  final List<NotionChoice<T>> options;
  final ValueChanged<T>? onChanged;
  final IconData? icon;
  const NotionChoicePill({
    super.key,
    required this.title,
    required this.value,
    required this.neutral,
    required this.options,
    this.onChanged,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return NotionGlassPill(
      icon: icon,
      label: _labelOf(options, value) ?? title,
      selected: value != neutral,
      trailing: const Icon(Icons.expand_more, size: NotionSize.iconSm),
      onPressed: onChanged == null
          ? null
          : () async {
              final picked = await showNotionChoiceSheet<T>(
                context,
                title: title,
                options: options,
                selected: value,
              );
              if (picked != null && picked.value != value) {
                onChanged(picked.value);
              }
            },
    );
  }
}
