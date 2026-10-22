// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/reminder_list.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The time part of Remind me and Send later: one-tap times (Slack/Gmail
/// style), a Date and a Time row for anything else, and inline validation
/// ("Choose a time in the future.") instead of an error after the fact.
///
/// Controlled: the caller keeps [at] and [preset] and receives every change
/// through [onChanged]. Keys are `<keyPrefix>-preset-<label>`,
/// `<keyPrefix>-preset-custom`, `<keyPrefix>-date` and `<keyPrefix>-time`.
class DueTimePicker extends StatelessWidget {
  final DateTime at;

  /// The label of the selected one-tap time; null for a picked time.
  final String? preset;
  final List<({String label, DateTime at})> presets;
  final DateTime Function() clock;
  final void Function(DateTime at, String? preset) onChanged;
  final String keyPrefix;

  const DueTimePicker({
    super.key,
    required this.at,
    required this.preset,
    required this.presets,
    required this.onChanged,
    this.clock = DateTime.now,
    this.keyPrefix = 'due',
  });

  /// Whether [at] can still be accepted (see [reminderTimeValid]).
  static bool valid(DateTime at, DateTime now) => reminderTimeValid(at, now);

  Future<DateTime?> _pickDate(BuildContext context, DateTime from) async {
    final now = clock();
    final today = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      initialDate: from.isBefore(today) ? today : from,
    );
    if (date == null) return null;
    return DateTime(date.year, date.month, date.day, from.hour, from.minute);
  }

  Future<DateTime?> _pickTime(BuildContext context, DateTime from) async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(from),
    );
    if (time == null) return null;
    return DateTime(from.year, from.month, from.day, time.hour, time.minute);
  }

  Future<void> _date(BuildContext context) async {
    final picked = await _pickDate(context, at);
    if (picked != null && context.mounted) onChanged(picked, null);
  }

  Future<void> _time(BuildContext context) async {
    final picked = await _pickTime(context, at);
    if (picked != null && context.mounted) onChanged(picked, null);
  }

  Future<void> _custom(BuildContext context) async {
    var next = await _pickDate(context, at);
    if (next == null || !context.mounted) return;
    onChanged(next, null);
    next = await _pickTime(context, next);
    if (next != null && context.mounted) onChanged(next, null);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final localizations = MaterialLocalizations.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final now = clock();
    final ok = valid(at, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: NotionSpace.xs,
          runSpacing: NotionSpace.xs,
          children: [
            for (final option in presets)
              NotionGlassPill(
                key: ValueKey('$keyPrefix-preset-${option.label}'),
                label: option.label,
                selected: preset == option.label,
                onPressed: () => onChanged(option.at, option.label),
              ),
            NotionGlassPill(
              key: ValueKey('$keyPrefix-preset-custom'),
              icon: Icons.edit_calendar_outlined,
              label: 'Pick date & time',
              selected: preset == null,
              onPressed: () => _custom(context),
            ),
          ],
        ),
        const SizedBox(height: NotionSpace.sm),
        NotionPropertyRow(
          key: ValueKey('$keyPrefix-date'),
          label: 'Date',
          value: Text(
            reminderDay(at, now, localizations),
            style: NotionType.body,
          ),
          onTap: () => _date(context),
        ),
        NotionPropertyRow(
          key: ValueKey('$keyPrefix-time'),
          label: 'Time',
          value: Text(
            localizations.formatTimeOfDay(
              TimeOfDay.fromDateTime(at),
              alwaysUse24HourFormat: use24h,
            ),
            style: NotionType.body,
          ),
          onTap: () => _time(context),
        ),
        NotionSizeReveal(
          visible: !ok,
          child: Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: NotionSpace.xs),
              child: Text(
                'Choose a time in the future.',
                style: NotionType.footnote.copyWith(
                  color: tokens.colors.danger,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
