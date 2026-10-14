// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

class TranscriptPanel extends StatefulWidget {
  final Event event;
  const TranscriptPanel({super.key, required this.event});
  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends State<TranscriptPanel> {
  late final personal = PersonalClient.of(widget.event.room.client);
  String? language;
  @override
  void initState() {
    super.initState();
    personal.load();
  }

  Future<void> _request() async {
    try {
      await personal.transcribe(widget.event, language: language);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Connect private sync in Settings. Only audio from the selected message is sent to OpenAI.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _cancel(TranscriptionJob job) async {
    try {
      await personal.cancelTranscript(job.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cancellation was not confirmed. Check the transcription state before retrying.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: personal,
    builder: (context, _) {
      final job = personal.transcripts[personal.transcriptId(widget.event)];
      final busy =
          job != null &&
          {
            JobState.waitingSync,
            JobState.waitingKeys,
            JobState.queued,
            JobState.processing,
          }.contains(job.state);
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                NotionTranscribeAction(
                  onPressed: widget.event.redacted || busy ? null : _request,
                  busy: busy,
                  label: busy
                      ? switch (job.state) {
                          JobState.waitingSync => 'Waiting for confirmation',
                          JobState.waitingKeys => 'Waiting for keys',
                          JobState.queued => 'Queued',
                          _ => 'Transcribing…',
                        }
                      : job?.text == null
                      ? 'Transcribe'
                      : 'Transcribe again',
                ),
                PopupMenuButton<String>(
                  tooltip: 'Transcription language',
                  enabled: !busy && !widget.event.redacted,
                  onSelected: (v) =>
                      setState(() => language = v == 'auto' ? null : v),
                  itemBuilder: (_) => [
                    for (final item in {
                      'auto': 'Automatic',
                      'pl': 'Polish',
                      'en': 'English',
                    }.entries)
                      PopupMenuItem(value: item.key, child: Text(item.value)),
                  ],
                ),
                if (busy)
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: personal.isTranscriptCancellationPending(job.id)
                        ? null
                        : () => _cancel(job),
                  ),
              ],
            ),
            if (job != null && personal.isTranscriptCancellationPending(job.id))
              const Text(
                'Cancellation requested. Processing may already have started.',
              ),
            if (job?.text != null) SelectableText(job!.text!),
            if (job?.state == JobState.unknown)
              const Text(
                'The result is unknown. Retrying may incur an additional cost.',
              ),
            if (job?.state == JobState.failed)
              const Text('Could not process this audio. You can retry.'),
            if (job?.state == JobState.cancelled)
              const Text('Transcription cancelled.'),
            if (job?.state == JobState.conflict)
              const Text(
                'The transcription changed on another device. Check the result before retrying.',
              ),
            if (job?.estimatedCostUsd != null)
              Text(
                'Estimated cost: \$${job!.estimatedCostUsd!.toStringAsFixed(4)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      );
    },
  );
}
