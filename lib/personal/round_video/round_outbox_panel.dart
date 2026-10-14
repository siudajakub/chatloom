// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../media/pending_media_store.dart';
import 'telegram_round_service.dart';

class RoundOutboxPanel extends StatelessWidget {
  final Room room;
  const RoundOutboxPanel({super.key, required this.room});
  @override
  Widget build(BuildContext context) {
    final service = TelegramRoundService.of(room.client);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => FutureBuilder<List<PendingMediaSummary>>(
        future: service.pendingFor(room.id),
        builder: (context, snapshot) {
          if(snapshot.hasError) return const Padding(padding:EdgeInsets.all(8),child:Text(
            'The protected queue is unavailable. Saved recordings remain on this device.'));
          final records = snapshot.data ?? const <PendingMediaSummary>[];
          if (records.isEmpty && !service.hasUnstaged(room.id)) {
            return const SizedBox.shrink();
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (service.hasUnstaged(room.id))
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
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.video_file_outlined),
                      title: Text(switch (record.metadata['state']) {
                        'matrixAccepted' => 'Matrix accepted the round video',
                        'inFlight' ||
                        'unknown' => 'Send outcome unknown',
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
                              tooltip: 'Delete local copy of accepted recording',
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
      ),
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
    final confirmed = await showDialog<bool>(
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
