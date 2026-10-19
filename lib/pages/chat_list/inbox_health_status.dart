// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/encryption/e2ee_health.dart';
import 'package:fluffychat/personal/ui/inbox_health_notice.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Inbox status row for encryption and private sync health. Replaces the
/// red snackbar that appeared on every launch: it stays until fixed or
/// dismissed, and a dismissal lasts until the problems change.
class InboxHealthStatus extends StatefulWidget {
  final Client client;

  /// Test seam: snapshot source instead of the live client state.
  final Future<E2eeSnapshot> Function()? load;

  const InboxHealthStatus({super.key, required this.client, this.load});

  static InboxHealthItem itemFor(E2eeIssue issue) => InboxHealthItem(
    icon: switch (issue.kind) {
      E2eeIssueKind.encryptionOff => Icons.lock_open_outlined,
      E2eeIssueKind.recovery => Icons.key_outlined,
      E2eeIssueKind.session => Icons.gpp_maybe_outlined,
      E2eeIssueKind.privateSync => Icons.sync_problem_outlined,
      E2eeIssueKind.undecryptable => Icons.lock_clock_outlined,
      E2eeIssueKind.devices => Icons.devices_other_outlined,
    },
    tone: switch (issue.kind) {
      E2eeIssueKind.encryptionOff => NotionCalloutTone.danger,
      E2eeIssueKind.undecryptable ||
      E2eeIssueKind.devices => NotionCalloutTone.neutral,
      _ => NotionCalloutTone.warning,
    },
    title: issue.title,
    message: issue.message,
    actionLabel: issue.actionLabel,
  );

  @override
  State<InboxHealthStatus> createState() => _InboxHealthStatusState();
}

class _InboxHealthStatusState extends State<InboxHealthStatus> {
  late E2eeHealthController _health;

  @override
  void initState() {
    super.initState();
    _health = _create();
  }

  E2eeHealthController _create() =>
      E2eeHealthController(widget.client, load: widget.load)..start();

  @override
  void didUpdateWidget(InboxHealthStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      _health.dispose();
      _health = _create();
    }
  }

  @override
  void dispose() {
    _health.dispose();
    super.dispose();
  }

  int? _busyIndex(List<E2eeIssue> issues) {
    final busy = _health.busy;
    if (busy == null) return null;
    final index = issues.indexWhere((issue) => issue.fix == busy);
    return index < 0 ? null : index;
  }

  void _details() {
    unawaited(
      showNotionSheet<void>(
        context: context,
        title: 'Encryption and sync',
        builder: (sheetContext) => ListenableBuilder(
          listenable: _health,
          builder: (sheetContext, _) {
            final issues = _health.issues;
            return InboxHealthDetails(
              items: issues.map(InboxHealthStatus.itemFor).toList(),
              busy: _busyIndex(issues),
              onFix: (index) {
                final issue = issues[index];
                // Screens open from the inbox, not from under the sheet.
                if (e2eeFixRoute(issue.fix) != null) {
                  Navigator.of(sheetContext).pop();
                }
                unawaited(_health.fix(context, issue));
              },
            );
          },
        ),
      ),
    );
  }

  /// Problems shown last, kept while the notice collapses after a fix or a
  /// dismissal.
  List<E2eeIssue> _shown = const [];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _health,
    builder: (context, _) {
      final issues = _health.visible;
      if (issues.isNotEmpty) _shown = issues;
      final shown = _shown;
      if (shown.isEmpty) return const SizedBox.shrink();
      final items = shown.map(InboxHealthStatus.itemFor).toList();
      // Grows in when a problem appears, shrinks away when it is fixed or
      // hidden; a different top problem cross-fades in place.
      return NotionSizeReveal(
        visible: issues.isNotEmpty,
        revealOnMount: true,
        child: Padding(
          padding: const EdgeInsets.only(top: NotionSpace.xs),
          child: NotionFadeThrough(
            child: SizedBox(
              key: ValueKey((items.first.title, items.length)),
              width: double.infinity,
              child: InboxHealthNotice(
                items: items,
                busy: _busyIndex(shown),
                onFix: (index) {
                  final current = _health.visible;
                  if (index < current.length) {
                    unawaited(_health.fix(context, current[index]));
                  }
                },
                onDismiss: () => unawaited(_health.dismiss()),
                onDetails: _details,
              ),
            ),
          ),
        ),
      );
    },
  );
}
