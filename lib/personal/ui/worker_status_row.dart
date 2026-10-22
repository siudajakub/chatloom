// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

NotionStatusTone workerStatusTone(WorkerHealth health) => switch (health) {
  WorkerHealth.ok => NotionStatusTone.success,
  WorkerHealth.attention => NotionStatusTone.warning,
  WorkerHealth.offline => NotionStatusTone.danger,
  WorkerHealth.unknown => NotionStatusTone.neutral,
};

/// The background service (worker) in one settings row: a status pill
/// ("Ready", "Offline"), one plain line, and the full details on tap —
/// like the account status in Telegram's and Messenger's linked-account
/// lists. Used on Transcription and on Private sync (once).
class WorkerStatusRow extends StatelessWidget {
  final PersonalClient personal;
  final String title;

  /// Report transcription readiness instead of the overall status.
  final bool transcription;

  const WorkerStatusRow({
    super.key,
    required this.personal,
    this.title = 'Background service',
    this.transcription = false,
  });

  Future<void> _details(BuildContext context) => showNotionSheet<void>(
    context: context,
    title: title,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          personal.problem ?? personal.workerReadinessDescription,
          style: context.notion.typography.callout,
        ),
        const SizedBox(height: NotionSpace.md),
        Text(
          'The background service runs on your server. It sends scheduled '
          'messages, delivers reminders and transcribes voice messages.',
          style: context.notion.typography.footnoteMuted,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final status = personal.workerStatus(transcription: transcription);
    return NotionListRow(
      key: const ValueKey('worker-status'),
      leading: const Icon(Icons.cloud_outlined),
      title: title,
      subtitle: status.line,
      trailing: NotionStatusPill(
        label: status.label,
        tone: workerStatusTone(status.health),
      ),
      onTap: () => _details(context),
    );
  }
}
