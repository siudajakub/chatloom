// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:collection';

import 'package:chatloom/pages/chat/events/message_delivery_status.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The bridged network's name of [room] ("WhatsApp"), or null for a native
/// Matrix chat.
String? bridgedNetworkLabel(Room room) {
  final network = PersonalClient.networkOf(room);
  if (network == 'unknown' || network == 'matrix') return null;
  return notionNetworkLabel(network);
}

/// "Delete for everyone" of own messages, Telegram style: a plain confirm
/// (no reason field), the bubble disappears at once, the redaction runs in
/// the background and the bubble comes back with an explanation and Retry
/// if it fails. A message that is still sending is deleted as soon as the
/// server has it (it is never left behind as a ghost delivery).
///
/// Hidden rows are tracked per client by event and transaction ID, bounded,
/// and checked by the timeline filters (`isVisibleInGui`, merged rows).
abstract final class MessageDeletions {
  static const _cap = 256;
  static final _hidden = Expando<LinkedHashSet<String>>();
  static final _quiet = Expando<LinkedHashSet<String>>();

  static String _key(String roomId, String id) => '$roomId\u0000$id';

  static void _add(
    Expando<LinkedHashSet<String>> into,
    Client client,
    String key,
  ) {
    final set = into[client] ??= LinkedHashSet<String>();
    set
      ..remove(key)
      ..add(key);
    while (set.length > _cap) {
      set.remove(set.first);
    }
  }

  /// Whether [event] is being (or was just) deleted by the user here.
  static bool hides(Event event) {
    final set = _hidden[event.room.client];
    if (set == null || set.isEmpty) return false;
    final room = event.room.id;
    if (set.contains(_key(room, event.eventId))) return true;
    final txid = event.transactionId;
    return txid != null && set.contains(_key(room, txid));
  }

  static void _hide(Event event) {
    _add(_hidden, event.room.client, _key(event.room.id, event.eventId));
    final txid = event.transactionId;
    if (txid != null) {
      _add(_hidden, event.room.client, _key(event.room.id, txid));
    }
  }

  static void _unhide(Event event) {
    final set = _hidden[event.room.client];
    set?.remove(_key(event.room.id, event.eventId));
    final txid = event.transactionId;
    if (txid != null) set?.remove(_key(event.room.id, txid));
  }

  /// A redaction ChatLoom sends to tidy up (a failed original after Send
  /// again, a reverted reaction or edit): a bridge's report about it means
  /// nothing to the user.
  static void markQuiet(Room room, String redactionId) =>
      _add(_quiet, room.client, _key(room.id, redactionId));

  static bool isQuiet(Room room, String eventId) =>
      _quiet[room.client]?.contains(_key(room.id, eventId)) ?? false;

  @visibleForTesting
  static void debugReset(Client client) {
    _hidden[client] = null;
    _quiet[client] = null;
  }

  /// The confirmation text for deleting [event] for everyone.
  static ({String title, String message}) confirmText(Event event) {
    final network = bridgedNetworkLabel(event.room);
    if (event.status.isSending) {
      return (
        title: 'Delete message?',
        message:
            'It is still sending. It will be deleted for everyone as soon '
            'as it goes through.',
      );
    }
    return (
      title: 'Delete message?',
      message: network == null
          ? 'It will be deleted for everyone in this chat. This can’t be '
                'undone.'
          : 'It will be deleted for everyone in this chat and on $network. '
                'This can’t be undone.',
    );
  }

  /// Asks, then deletes [event] for everyone. [refresh] re-filters the
  /// host's rows (safe to call after the host is gone). [redact] replaces
  /// the default `event.redactEvent()` (another account of a bundle).
  static Future<void> delete(
    BuildContext context,
    Event event, {
    required VoidCallback refresh,
    Future<String?> Function()? redact,
    Timeline? timeline,
    bool confirm = true,
  }) async {
    if (confirm) {
      final text = confirmText(event);
      final ok = await showNotionConfirmDialog(
        context: context,
        title: text.title,
        message: text.message,
        confirmLabel: 'Delete',
        destructive: true,
      );
      if (!ok || !context.mounted) return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    // The copy in the timeline now (a sending echo may have landed while
    // the dialog was open).
    final txid = event.transactionId;
    final current = timeline != null && event.status.isSending && txid != null
        ? timeline.events.firstWhereOrNull(
                (e) => e.transactionId == txid || e.eventId == txid,
              ) ??
              event
        : event;
    await _run(
      current,
      refresh: refresh,
      redact: redact,
      messenger: messenger,
      retry: () {
        if (context.mounted) {
          unawaited(
            delete(
              context,
              event,
              refresh: refresh,
              redact: redact,
              timeline: timeline,
              confirm: false,
            ),
          );
        }
      },
    );
  }

  static Future<void> _run(
    Event event, {
    required VoidCallback refresh,
    required Future<String?> Function()? redact,
    required ScaffoldMessengerState? messenger,
    required VoidCallback retry,
  }) async {
    _hide(event);
    refresh();
    void failed(Object error) {
      _unhide(event);
      refresh();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Couldn’t delete the message. ${humanErrorText(error)}',
          ),
          action: SnackBarAction(label: 'Retry', onPressed: retry),
        ),
      );
    }

    if (event.status.isSending) {
      _deleteWhenLanded(event, onError: failed);
      return;
    }
    if (event.status.isError) {
      try {
        await MessageDeliveryActions.discard(event);
      } catch (error) {
        failed(error);
      }
      return;
    }
    try {
      if (redact != null) {
        await redact();
      } else {
        await event.redactEvent();
      }
    } catch (error) {
      failed(error);
    }
  }

  /// A sending message: deleted the moment the server confirms it, or
  /// discarded with its outbox attempt if the send gives up.
  static void _deleteWhenLanded(
    Event event, {
    required void Function(Object) onError,
  }) {
    final room = event.room;
    final txid = event.transactionId ?? event.eventId;
    late final StreamSubscription<Event> sub;
    var done = false;
    Future<void> settle(Event landed) async {
      if (done) return;
      done = true;
      unawaited(sub.cancel());
      try {
        if (landed.status.isError) {
          await MessageDeliveryActions.discard(landed);
        } else {
          await landed.redactEvent();
        }
      } catch (error) {
        onError(error);
      }
    }

    sub = room.client.onTimelineEvent.stream.listen((update) {
      if (update.room.id != room.id) return;
      final matches = update.transactionId == txid || update.eventId == txid;
      if (!matches) return;
      if (update.status.isError ||
          (update.status.isSent && update.eventId.startsWith(r'$'))) {
        unawaited(settle(update));
      }
    });
    // It may have landed between the menu and the confirmation.
    if (event.status.isError) unawaited(settle(event));
  }
}
