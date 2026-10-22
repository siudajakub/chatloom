// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/personal_client.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Private bookmarks of single messages (synced through the private
/// journal, listed under Settings › Bookmarks). Ordinary and merged chats
/// share them.
abstract final class MessageBookmarks {
  static String keyOf(PersonalClient personal, Event event) =>
      'bookmark:${personal.transcriptId(event)}';

  static bool isBookmarked(PersonalClient personal, Event event) =>
      personal.values.containsKey(keyOf(personal, event));

  /// Whether [event] can be bookmarked: a sent, readable message.
  static bool canBookmark(Event event) =>
      event.status.isSent && !event.redacted && event.eventId.startsWith(r'$');

  /// Bookmarks [event], or removes its bookmark; confirms with a snackbar
  /// that opens the list.
  static Future<void> toggle(
    BuildContext context,
    PersonalClient personal,
    Event event,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final router = GoRouter.maybeOf(context);
    final key = keyOf(personal, event);
    final remove = personal.values.containsKey(key);
    try {
      if (remove) {
        await personal.delete(key);
      } else {
        await personal.put(key, {
          'source': personal.source(event).toJson(),
          'network': PersonalClient.networkOf(event.room),
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        });
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            remove ? 'Removed from Bookmarks' : 'Saved to Bookmarks',
          ),
          action: remove || router == null
              ? null
              : SnackBarAction(
                  label: 'View',
                  onPressed: () => router.push('/rooms/settings/bookmarks'),
                ),
        ),
      );
    } catch (_) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            remove
                ? 'The bookmark was not removed. Check private sync and try again.'
                : 'The bookmark was not saved. Check private sync and try again.',
          ),
        ),
      );
    }
  }
}
