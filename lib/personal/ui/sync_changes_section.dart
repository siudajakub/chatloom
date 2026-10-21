// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/sync_changes.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Settings → Sync: changes still waiting for the background service and
/// settings changed on two devices, each named by what it is about (never
/// an identifier) with its one-tap action.
///
/// Waiting changes say why they wait; an unconfirmed one can be sent again.
/// A conflict shows both versions and resolves with one tap: keep this
/// device's version, or use the other one. Drafts can also be combined.
class SyncChangesSection extends StatelessWidget {
  final PersonalClient personal;

  /// The settings page's guarded runner (shows a snackbar on failure).
  final Future<void> Function(Future<void> Function() action) run;

  const SyncChangesSection({
    super.key,
    required this.personal,
    required this.run,
  });

  @override
  Widget build(BuildContext context) {
    final changes = SyncChanges.of(personal);
    return NotionSizeReveal(
      visible: !changes.isEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (changes.conflicts.isNotEmpty) ...[
            const NotionSectionHeader(title: 'Changed on two devices'),
            Text(
              'Both versions are kept until you choose one.',
              style: context.notion.typography.footnoteMuted,
            ),
            for (final conflict in changes.conflicts)
              SyncConflictTile(
                key: ValueKey('sync-conflict-${conflict.entity}'),
                personal: personal,
                conflict: conflict,
                run: run,
              ),
          ],
          if (changes.pending.isNotEmpty) ...[
            const NotionSectionHeader(title: 'Waiting for confirmation'),
            for (final change in changes.pending)
              SyncPendingRow(
                key: ValueKey('sync-pending-${change.entity}'),
                personal: personal,
                change: change,
                run: run,
              ),
          ],
        ],
      ),
    );
  }
}

/// One change waiting for the background service, with the reason and, when
/// it went unconfirmed, a "Send again" action.
class SyncPendingRow extends StatelessWidget {
  final PersonalClient personal;
  final PendingChange change;
  final Future<void> Function(Future<void> Function() action) run;

  /// Overrides the row title (for a screen that is itself about the entity).
  final String? title;

  const SyncPendingRow({
    super.key,
    required this.personal,
    required this.change,
    required this.run,
    this.title,
  });

  @override
  Widget build(BuildContext context) => NotionListRow(
    leading: switch (change.state) {
      PendingChangeState.unconfirmed => const Icon(
        Icons.sync_problem_outlined,
        size: NotionSize.icon,
      ),
      PendingChangeState.workerOffline => const Icon(
        Icons.cloud_off_outlined,
        size: NotionSize.icon,
      ),
      PendingChangeState.local => const Icon(
        Icons.lock_outline,
        size: NotionSize.icon,
      ),
      // A still clock, like Telegram's pending message: no loop to watch.
      _ => const Icon(Icons.schedule_rounded, size: NotionSize.icon),
    },
    title: title ?? change.title,
    subtitle: change.reason,
    trailing: change.resendable
        ? NotionButton.ghost(
            label: 'Send again',
            onPressed: () =>
                run(() => personal.resendPending(change.operation.opId)),
          )
        : null,
  );
}

/// A setting changed on this device and elsewhere: both versions and the
/// one-tap choice between them.
class SyncConflictTile extends StatelessWidget {
  final PersonalClient personal;
  final SyncConflict conflict;
  final Future<void> Function(Future<void> Function() action) run;

  /// Overrides the row title (for a screen that is itself about the entity).
  final String? title;

  const SyncConflictTile({
    super.key,
    required this.personal,
    required this.conflict,
    required this.run,
    this.title,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NotionSpace.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionListRow(
          leading: const Icon(Icons.call_split_rounded, size: NotionSize.icon),
          title: title ?? conflict.title,
          subtitle:
              'This device: ${conflict.local}\nOther version: ${conflict.other}',
        ),
        Wrap(
          spacing: NotionSpace.xs,
          runSpacing: NotionSpace.xs,
          children: [
            NotionButton(
              label: 'Keep this device’s version',
              onPressed: personal.ready
                  ? () => run(
                      () => personal.resolveConflict(
                        conflict.entity,
                        keepLocal: true,
                      ),
                    )
                  : null,
            ),
            NotionButton.ghost(
              label: 'Use the other version',
              onPressed: () => run(
                () =>
                    personal.resolveConflict(conflict.entity, keepLocal: false),
              ),
            ),
            if (conflict.draft)
              NotionButton.ghost(
                label: 'Combine…',
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => DraftConflictPage(
                      personal: personal,
                      entityKey: conflict.entity,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
