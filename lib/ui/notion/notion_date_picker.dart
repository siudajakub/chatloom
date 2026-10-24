// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_primitives.dart';
import 'notion_tokens.dart';

/// A month calendar in a Notion sheet (Telegram's "jump to date"): picking a
/// day closes the sheet and returns it. The calendar takes its colours from
/// the theme (the accent marks the chosen day, today is outlined); the sheet
/// is the usual glass panel.
Future<DateTime?> showNotionDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String title = 'Jump to date',
}) => showNotionSheet<DateTime>(
  context: context,
  title: title,
  builder: (context) => NotionDatePicker(
    initialDate: initialDate,
    firstDate: firstDate,
    lastDate: lastDate,
    onSelected: (day) => Navigator.of(context).pop(day),
  ),
);

/// The calendar of [showNotionDatePicker]; [initialDate] is clamped into
/// the range.
class NotionDatePicker extends StatelessWidget {
  const NotionDatePicker({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.onSelected,
  });

  final DateTime initialDate, firstDate, lastDate;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final initial = initialDate.isBefore(firstDate)
        ? firstDate
        : initialDate.isAfter(lastDate)
        ? lastDate
        : initialDate;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: NotionSize.dialogMaxWidth),
      child: CalendarDatePicker(
        initialDate: initial,
        firstDate: firstDate,
        lastDate: lastDate,
        onDateChanged: onSelected,
      ),
    );
  }
}
