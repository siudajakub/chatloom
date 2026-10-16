// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' show parseFragment;
import 'package:matrix/matrix.dart';

bool sharedVisible(Event event) =>
    !event.redacted && event.type == EventTypes.Message;
bool sharedMedia(Event event) =>
    sharedVisible(event) &&
    {MessageTypes.Image, MessageTypes.Video}.contains(event.messageType);
bool sharedFile(Event event) =>
    sharedVisible(event) &&
    {MessageTypes.File, MessageTypes.Audio}.contains(event.messageType);

/// Links stay local until explicitly opened; no preview/favicons are fetched.
List<String> sharedLinks(Event event) {
  if (!sharedVisible(event)) return const [];
  Iterable<String> plain(String text) => RegExp(
    r'''https?://[^\s<>"']+''',
    caseSensitive: false,
  ).allMatches(text).map((m) => m.group(0)!);
  final formatted = event.content['formatted_body'];
  final fragment = formatted is String ? parseFragment(formatted) : null;
  final candidates = [
    ...plain(event.body),
    if (fragment != null)
      ...fragment.querySelectorAll('a[href]').map((a) => a.attributes['href']!),
    if (fragment != null) ...plain(fragment.text ?? ''),
  ];
  return candidates
      .map((s) {
        s = s.replaceFirst(RegExp(r'[.,;!?]+$'), '');
        for (final pair in [('(', ')'), ('[', ']'), ('{', '}')]) {
          while (s.endsWith(pair.$2) &&
              pair.$2.allMatches(s).length > pair.$1.allMatches(s).length) {
            s = s.substring(0, s.length - 1);
          }
        }
        return s;
      })
      .where((s) {
        final uri = Uri.tryParse(s);
        return uri != null &&
            {'http', 'https'}.contains(uri.scheme.toLowerCase()) &&
            uri.host.isNotEmpty;
      })
      .toSet()
      .toList();
}

class ContentBatch {
  final List<Event> events;
  final String? next;
  final bool localComplete;
  const ContentBatch(this.events, {this.next, this.localComplete = false});
}

abstract class ContentSource {
  Object get identity;
  String get name;
  bool get available;
  String? get initialCursor;
  Future<ContentBatch> local(int limit);
  Future<ContentBatch> older(String? cursor);
}

class MatrixContentSource implements ContentSource {
  final Room room;
  MatrixContentSource(this.room);
  @override
  Object get identity => (room.client, room.client.userID, room.id);
  @override
  String get name => room.getLocalizedDisplayname();
  @override
  bool get available =>
      identical(room.client.getRoomById(room.id), room) &&
      {Membership.join, Membership.leave}.contains(room.membership);
  @override
  String? get initialCursor => room.prev_batch;
  @override
  Future<ContentBatch> local(int limit) async {
    final ids = await room.client.database.getEventIdList(
      room,
      limit: limit + 1,
    );
    final events = await room.client.database.getEventList(room, limit: limit);
    return ContentBatch(events, localComplete: ids.length <= limit);
  }

  @override
  Future<ContentBatch> older(String? cursor) async {
    // Unlike searchEvents, retain encrypted events so missing keys stay visible.
    // Use the SDK's decryption/key recovery, never a separate crypto implementation.
    final page = await room.client.getRoomEvents(
      room.id,
      Direction.b,
      from: cursor,
      limit: 80,
    );
    final events = <Event>[];
    for (final raw in page.chunk) {
      events.add(await decrypt(Event.fromMatrixEvent(raw, room)));
    }
    return ContentBatch(events, next: page.end);
  }

  Future<Event> decrypt(Event event) async {
    final encryption = room.client.encryption;
    if (event.type == EventTypes.Encrypted && encryption != null) {
      try {
        event = await encryption.decryptRoomEvent(
          event,
          store: false,
          updateType: EventUpdateType.history,
        );
        if (event.type == EventTypes.Encrypted) {
          final content = event.parsedRoomEncryptedContent;
          if (content.sessionId != null) {
            await encryption.keyManager.maybeAutoRequest(
              room.id,
              content.sessionId!,
              content.senderKey,
              tryOnlineBackup: true,
              onlineKeyBackupOnly: true,
              awaitRequest: true,
            );
            event = await encryption.decryptRoomEvent(
              event,
              store: false,
              updateType: EventUpdateType.history,
            );
          }
        }
      } catch (_) {
        // Keep the encrypted event and continue the page when key recovery is
        // offline or ciphertext is unavailable. The UI reports this range.
      }
    }
    return event;
  }
}

class ContentSourceState {
  final ContentSource source;
  final Object identity;
  int localLimit = 0;
  bool localEnd = false, remoteEnd = false, busy = false, started = false;
  String? cursor, error;
  final cursors = <String>{};
  ContentSourceState(this.source) : identity = source.identity;
}

/// A single shared scope for the three projections and local message search.
/// Prefix snapshots intentionally avoid SDK offsets: first-page SENDING records,
/// missing stored rows and a concurrent sync never advance a synced offset.
class ConversationContentController extends ChangeNotifier {
  final bool Function() unlocked;
  final int Function() privacyGeneration;
  final int _privacyGeneration;
  final List<ContentSourceState> sources;
  final _events = <(Object, String), Event>{};
  final _redactions = <(Object, String), Event>{};
  bool _disposed = false;
  int _generation = 0;
  ConversationContentController(
    List<ContentSource> sources, {
    required this.unlocked,
    int Function()? privacyGeneration,
  }) : _privacyGeneration = (privacyGeneration ?? (() => 0))(),
       privacyGeneration = privacyGeneration ?? (() => 0),
       sources = sources.map(ContentSourceState.new).toList();
  bool get busy => sources.any((s) => s.busy);
  bool get localEnd => sources.every((s) => s.localEnd);
  bool get remoteEnd => sources.every((s) => s.remoteEnd);
  List<Event> get events {
    if (!_current(_generation)) return const [];
    final result = _events.entries.toList()
      ..sort((a, b) {
        final date = b.value.originServerTs.compareTo(a.value.originServerTs);
        if (date != 0) return date;
        final id = a.value.eventId.compareTo(b.value.eventId);
        if (id != 0) return id;
        return sources
            .indexWhere((s) => s.identity == a.key.$1)
            .compareTo(sources.indexWhere((s) => s.identity == b.key.$1));
      });
    return result.map((e) => e.value).toList();
  }

  int get encrypted =>
      events.where((e) => !e.redacted && e.type == EventTypes.Encrypted).length;
  bool _current(int generation) =>
      !_disposed &&
      generation == _generation &&
      unlocked() &&
      privacyGeneration() == _privacyGeneration &&
      sources.every((s) => s.identity == s.source.identity);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load({bool remote = false, bool refresh = false}) async {
    if (_disposed || busy || !unlocked()) return;
    final generation = _generation;
    for (final state in sources) {
      if (!_current(generation)) return;
      if (remote ? state.remoteEnd : state.localEnd && !refresh) continue;
      state.busy = true;
      state.error = null;
      _notify();
      try {
        if (!state.source.available) throw StateError('Source unavailable');
        List<Event> page;
        if (remote) {
          final cursor = state.started
              ? state.cursor
              : state.source.initialCursor;
          final batch = await state.source.older(cursor);
          if (!_current(generation)) return;
          if (!state.source.available) throw StateError('Source unavailable');
          page = batch.events;
          // Retain useful events even if a broken server returns a cyclic token.
          for (final event in page) {
            _record(state.source, event);
          }
          if (batch.next != null &&
              (batch.next == cursor || state.cursors.contains(batch.next))) {
            throw StateError('History did not advance');
          }
          if (cursor != null) state.cursors.add(cursor);
          state.started = true;
          state.cursor = batch.next;
          if (batch.next != null) state.cursors.add(batch.next!);
          state.remoteEnd = batch.next == null;
        } else {
          final limit = refresh
              ? (state.localLimit == 0 ? 80 : state.localLimit)
              : state.localLimit + 80;
          final batch = await state.source.local(limit);
          page = batch.events;
          if (!_current(generation)) return;
          state.localLimit = limit;
          // This is only a local boundary, never proof of server history EOF.
          state.localEnd = batch.localComplete;
        }
        if (!state.source.available) throw StateError('Source unavailable');
        for (final event in page) {
          _record(state.source, event);
        }
        if (page.any((e) => e.type == EventTypes.RoomCreate))
          state.remoteEnd = true;
      } catch (_) {
        if (_current(generation))
          state.error = remote
              ? 'Earlier history could not advance. Loaded items are kept. Retry.'
              : 'Local history could not load. Loaded items are kept. Retry.';
      } finally {
        state.busy = false;
        if (_current(generation)) _notify();
      }
    }
  }

  Future<void> retryEncrypted() async {
    if (busy || !_current(_generation)) return;
    final generation = _generation;
    for (final state in sources) {
      final source = state.source;
      if (source is! MatrixContentSource || !source.available) continue;
      state.busy = true;
      _notify();
      try {
        final entries = _events.entries
            .where(
              (e) =>
                  e.key.$1 == state.identity &&
                  e.value.type == EventTypes.Encrypted,
            )
            .take(80)
            .toList();
        for (final entry in entries) {
          final event = await source.decrypt(entry.value);
          if (!_current(generation)) return;
          _record(source, event);
        }
      } finally {
        state.busy = false;
        if (_current(generation)) _notify();
      }
    }
  }

  void _record(ContentSource source, Event event) {
    if (event.type == EventTypes.Redaction) {
      final id = event.redacts;
      if (id == null) return;
      _redactions[(source.identity, id)] = event;
      _events[(source.identity, id)]?.setRedactionEvent(event);
      return;
    }
    final key = (source.identity, event.eventId);
    final redaction = _redactions[key];
    if (redaction != null) event.setRedactionEvent(redaction);
    _events[key] = event;
  }

  void accept(ContentSource source, Event event) {
    if (!_current(_generation)) return;
    _record(source, event);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _events.clear();
    _redactions.clear();
    super.dispose();
  }
}
