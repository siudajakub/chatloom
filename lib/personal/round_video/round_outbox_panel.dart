// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../media/immediate_media_outbox.dart';
import '../media/pending_media_store.dart';
import 'telegram_round_service.dart';

class RoundOutboxPanel extends StatefulWidget {
  final Room room;
  const RoundOutboxPanel({super.key, required this.room});

  @override
  State<RoundOutboxPanel> createState() => _RoundOutboxPanelState();
}

/// The panel sits above every composer: the protected queue is read once
/// and again only when the round service reports a change, never on a
/// composer rebuild (each keystroke, reply, focus change).
class _RoundOutboxPanelState extends State<RoundOutboxPanel> {
  late TelegramRoundService _service;
  List<PendingMediaSummary> _records = const [];
  bool _failed = false;
  int _generation = 0;

  Room get room => widget.room;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(RoundOutboxPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != room.id ||
        !identical(oldWidget.room.client, room.client)) {
      _service.removeListener(_changed);
      _records = const [];
      _failed = false;
      _bind();
    }
  }

  @override
  void dispose() {
    _generation++;
    _service.removeListener(_changed);
    super.dispose();
  }

  void _bind() {
    _service = TelegramRoundService.of(room.client)..addListener(_changed);
    _reload();
  }

  void _changed() {
    if (!mounted) return;
    // Saving/phase flags change synchronously; the queue follows.
    setState(() {});
    _reload();
  }

  /// Keeps the last result on screen while the queue is re-read; only the
  /// newest read is applied.
  void _reload() {
    final generation = ++_generation;
    final roomId = room.id;
    _service
        .pendingFor(roomId)
        .then(
          (records) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _records = records;
              _failed = false;
            });
          },
          onError: (Object _) {
            if (!mounted || generation != _generation) return;
            setState(() => _failed = true);
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return Builder(
      builder: (context) {
        if (_failed) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'The protected queue is unavailable. Saved recordings remain on this device.',
            ),
          );
        }
        final records = _records;
        final saving = service.isSaving(room.id);
        if (records.isEmpty && !service.hasUnstaged(room.id) && !saving) {
          return const SizedBox.shrink();
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Optimistic row: shown from the moment the recorder closes,
                // before the protected draft exists.
                if (saving)
                  const ListTile(
                    key: Key('round_outbox_saving'),
                    dense: true,
                    leading: NotionDelayedSpinner(),
                    title: Text('Saving round video…'),
                  ),
                if (service.hasUnstaged(room.id) && !saving)
                  ListTile(
                    title: const Text('Recording awaiting protected storage'),
                    subtitle: const Text(
                      'Storage refused this recording. This copy will not survive closing the app.',
                    ),
                    trailing: Wrap(
                      children: [
                        TextButton(
                          onPressed: () => _act(
                            context,
                            () => service.retryStaging(room.id),
                          ),
                          child: const Text('Retry saving'),
                        ),
                        IconButton(
                          tooltip: 'Discard unsaved recording',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _discard(
                            context,
                            () => service.discardUnstaged(room.id),
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final record in records)
                  if (service.phaseOf(record.actionId) case final phase?)
                    ListTile(
                      key: ValueKey('round_outbox_progress_${record.actionId}'),
                      dense: true,
                      leading: const NotionDelayedSpinner(),
                      title: Text(switch (phase) {
                        RoundSendPhase.encrypting => 'Encrypting round video…',
                        RoundSendPhase.uploading => 'Uploading round video…',
                        RoundSendPhase.sending => 'Sending round video…',
                      }),
                      subtitle: const Text(
                        'Keep this chat open until it is sent',
                      ),
                    )
                  else
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.video_file_outlined),
                      title: Text(switch (record.metadata['state']) {
                        'matrixAccepted' => 'Matrix accepted the round video',
                        'inFlight' || 'unknown' => 'Send outcome unknown',
                        'failed' => 'Round video awaiting retry',
                        _ => 'Round video saved locally',
                      }),
                      subtitle: Text(
                        record.metadata['bridgeDelivery'] == 'delivered'
                            ? 'Telegram confirmed delivery'
                            : 'Telegram delivery not confirmed',
                      ),
                      trailing: Wrap(
                        children: [
                          if (record.metadata['state'] != 'matrixAccepted')
                            IconButton(
                              tooltip: 'Retry the same send attempt',
                              icon: const Icon(Icons.send_outlined),
                              onPressed: () => _act(context, () async {
                                await service.retry(
                                  record.actionId,
                                  stillCurrent: () =>
                                      context.mounted &&
                                      identical(
                                        Matrix.of(context).client,
                                        room.client,
                                      ),
                                );
                              }),
                            ),
                          if (!{
                            'unknown',
                            'inFlight',
                            'matrixAccepted',
                          }.contains(record.metadata['state']))
                            IconButton(
                              tooltip: 'Delete local round video draft',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _act(
                                context,
                                () => service.cancel(record.actionId),
                              ),
                            ),
                          if (record.metadata['state'] == 'matrixAccepted')
                            IconButton(
                              tooltip:
                                  'Delete local copy of accepted recording',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _discard(
                                context,
                                () => service.retainAccepted(record.actionId),
                              ),
                            ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _act(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The operation was not confirmed. The recording remains in the protected queue.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _discard(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final confirmed = await showNotionCustomDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the local recording copy?'),
        content: const Text(
          'This copy cannot be recovered. Deleting it does not confirm delivery in Telegram.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete local copy'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) await _act(context, action);
  }
}
