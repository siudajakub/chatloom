// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/personal/bridge_contact_search.dart'
    show searchFold, searchTerms;
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:matrix/matrix.dart';

/// Search over the messages already stored on this device (FX-03 in-chat
/// search, FX-04 "Messages" in the global search).
///
/// Beeper rooms are end-to-end encrypted, so the homeserver cannot search
/// them; the SDK's encrypted store already holds the decrypted messages the
/// device has seen. Nothing here is indexed, persisted or sent anywhere:
/// matching runs in memory over pages read from the store and is dropped
/// with its owner.

/// What one stored event contributes to a search: the text of a message
/// ([targetId] is its own id) or, for an edit, the new text standing for the
/// edited message ([targetId] is the original). Null for everything that is
/// not a readable message (state, reactions, redacted, undecryptable).
({String targetId, String text, bool edit})? localMessageText(Event event) {
  if (event.type != EventTypes.Message || event.redacted) return null;
  if (event.relationshipType == RelationshipTypes.edit) {
    final target = event.relationshipEventId;
    final replacement = event.content['m.new_content'];
    final body = replacement is Map ? replacement['body'] : null;
    if (target == null || body is! String || body.trim().isEmpty) return null;
    return (targetId: target, text: body, edit: true);
  }
  final body = event.body;
  if (body.trim().isEmpty) return null;
  return (targetId: event.eventId, text: body, edit: false);
}

/// Search terms of [query]: folded (lower case, no diacritics) and split on
/// white space, as the inbox search does.
List<String> localSearchTerms(String query) => searchTerms(query);

/// Whether every term of [terms] occurs in [folded] (a [searchFold]ed text).
bool localTextMatches(String folded, List<String> terms) =>
    terms.isNotEmpty && terms.every(folded.contains);

/// Ranges of [text] that match [terms], for bold highlights. Folding is
/// applied per character, so the ranges index the original text.
List<(int, int)> localMatchRanges(String text, List<String> terms) {
  if (terms.isEmpty || text.isEmpty) return const [];
  final folded = StringBuffer();
  final origin = <int>[];
  var offset = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final fold = searchFold(char);
    for (var i = 0; i < fold.length; i++) {
      origin.add(offset);
    }
    folded.write(fold);
    offset += char.length;
  }
  origin.add(offset);
  final haystack = folded.toString();
  final ranges = <(int, int)>[];
  for (final term in terms) {
    var from = 0;
    while (true) {
      final at = haystack.indexOf(term, from);
      if (at < 0) break;
      ranges.add((origin[at], origin[at + term.length]));
      from = at + term.length;
    }
  }
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[ranges.first];
  for (final range in ranges.skip(1)) {
    final last = merged.last;
    if (range.$1 <= last.$2) {
      merged[merged.length - 1] = (
        last.$1,
        range.$2 > last.$2 ? range.$2 : last.$2,
      );
    } else {
      merged.add(range);
    }
  }
  return merged;
}

/// One message found on the device.
@immutable
class LocalMessageHit {
  const LocalMessageHit({required this.event, required this.text});

  /// The message itself (sender, time and room for the row; its id is the
  /// jump target).
  final Event event;

  /// Its current text (the latest edit).
  final String text;

  String get eventId => event.eventId;
  Room get room => event.room;
  DateTime get time => event.originServerTs;
}

class _PoolEntry {
  Event? original;
  String? text;
  String? editText;
  DateTime? editTime;
  String? _folded;

  String? get current => editText ?? text;

  String get folded => _folded ??= searchFold(current ?? '');
}

/// The messages of one search session: every event read for it, merged per
/// message (an edit replaces the text of the message it edits). Bounded by
/// what the owner feeds it; dropped with the owner.
class LocalMessagePool {
  final _entries = <String, _PoolEntry>{};

  static String _key(Room room, String eventId) => '${room.id}\u0000$eventId';

  /// Adds [events] (any order); returns whether anything changed.
  bool add(Iterable<Event> events) {
    var changed = false;
    for (final event in events) {
      final text = localMessageText(event);
      if (text == null) {
        if (event.redacted) {
          changed =
              _entries.remove(_key(event.room, event.eventId)) != null ||
              changed;
        }
        continue;
      }
      final entry = _entries.putIfAbsent(
        _key(event.room, text.targetId),
        _PoolEntry.new,
      );
      if (text.edit) {
        final time = event.originServerTs;
        final previous = entry.editTime;
        if (previous != null && !time.isAfter(previous)) continue;
        entry
          ..editText = text.text
          ..editTime = time
          .._folded = null;
      } else {
        if (identical(entry.original, event) && entry.text == text.text) {
          continue;
        }
        entry
          ..original = event
          ..text = text.text
          .._folded = null;
      }
      changed = true;
    }
    return changed;
  }

  /// Messages matching [terms], newest first. Edits whose message is not
  /// stored are skipped (there is no row to show or jump to).
  List<LocalMessageHit> search(List<String> terms) {
    if (terms.isEmpty) return const [];
    final hits = <LocalMessageHit>[
      for (final entry in _entries.values)
        if (entry.original != null &&
            entry.current != null &&
            localTextMatches(entry.folded, terms))
          LocalMessageHit(event: entry.original!, text: entry.current!),
    ];
    hits.sort(compareLocalHits);
    return hits;
  }
}

/// Newest first; ties by event id so the order is stable.
int compareLocalHits(LocalMessageHit a, LocalMessageHit b) {
  final byTime = b.time.compareTo(a.time);
  if (byTime != 0) return byTime;
  return a.eventId.compareTo(b.eventId);
}

/// Reads one page of [room]'s stored events, newest first, starting at
/// [start]. The default reads the SDK's encrypted store.
typedef StoredEventReader =
    Future<List<Event>> Function(Room room, int start, int limit);

Future<List<Event>> readStoredEvents(Room room, int start, int limit) =>
    room.client.database.getEventList(room, start: start, limit: limit);

/// Lets a frame through between slices of work, so a long scan never holds
/// the UI thread for more than one slice.
Future<void> localSearchYield() {
  final completer = Completer<void>();
  SchedulerBinding.instance.scheduleTask<void>(
    completer.complete,
    Priority.animation,
  );
  return completer.future;
}

/// One message of [DeviceMessageSearch]: only what a result row and its tap
/// need, so a large scan holds a few megabytes, not the events themselves.
@immutable
class DeviceMessageHit {
  const DeviceMessageHit({
    required this.roomId,
    required this.eventId,
    required this.senderId,
    required this.text,
    required this.time,
  });

  final String roomId, eventId, senderId, text;
  final DateTime time;
}

/// The global search's "Messages on this device" (FX-04 option A). Once per
/// search page, on the first query, it reads up to [perRoom] stored events
/// of up to [maxRooms] chats, one room per slice with a frame between
/// slices, and keeps a compact copy of their text; every query then filters
/// that copy in slices of [sliceSize]. A newer query or [dispose] cancels
/// the running pass. No network, nothing written.
class DeviceMessageSearch extends ChangeNotifier {
  DeviceMessageSearch({
    required this.rooms,
    this.read = readStoredEvents,
    this.perRoom = 200,
    this.maxRooms = 100,
    this.sliceSize = 2000,
    Future<void> Function()? yieldSlice,
  }) : _yield = yieldSlice ?? localSearchYield;

  /// The chats to read, most recent first (already filtered by the owner:
  /// joined, not technical, not the private journal).
  final List<Room> Function() rooms;
  final StoredEventReader read;
  final int perRoom, maxRooms, sliceSize;
  final Future<void> Function() _yield;

  final _entries = <(String, DeviceMessageHit)>[];
  Future<void>? _loading;
  bool _disposed = false;
  int _generation = 0;
  String _query = '';
  String? _done;
  List<DeviceMessageHit> _hits = const [];

  /// Hits of the last finished query, newest first.
  List<DeviceMessageHit> get hits => _hits;

  /// Reading the store or filtering is still running for [query].
  bool get searching => _query.isNotEmpty && _done != _query;

  String get query => _query;

  /// Messages read so far.
  int get length => _entries.length;

  /// Searches [query]; an empty query clears the hits.
  void search(String query) {
    final text = query.trim();
    if (text == _query) return;
    _query = text;
    final generation = ++_generation;
    if (text.isEmpty) {
      _hits = const [];
      _done = '';
      _notify();
      return;
    }
    _notify();
    unawaited(_run(generation, text, localSearchTerms(text)));
  }

  Future<void> _run(int generation, String query, List<String> terms) async {
    final hits = <DeviceMessageHit>[];
    try {
      await (_loading ??= _load());
      for (var i = 0; i < _entries.length; i += sliceSize) {
        if (i > 0) await _yield();
        if (!_current(generation)) return;
        final end = math.min(i + sliceSize, _entries.length);
        for (var j = i; j < end; j++) {
          final (folded, hit) = _entries[j];
          if (localTextMatches(folded, terms)) hits.add(hit);
        }
      }
      hits.sort((a, b) {
        final byTime = b.time.compareTo(a.time);
        return byTime != 0 ? byTime : a.eventId.compareTo(b.eventId);
      });
    } catch (_) {
      hits.clear();
    }
    if (!_current(generation)) return;
    _hits = hits;
    _done = query;
    _notify();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _load() async {
    final list = rooms().take(maxRooms).toList();
    for (final (index, room) in list.indexed) {
      if (_disposed) return;
      if (index > 0) await _yield();
      List<Event> events;
      try {
        events = await read(room, 0, perRoom);
      } catch (_) {
        // A room whose store cannot be read is skipped; the others count.
        continue;
      }
      if (_disposed) return;
      _entries.addAll(compactMessages(events));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _entries.clear();
    super.dispose();
  }
}

/// [events] of one room as (folded text, hit) pairs: one per message, with
/// the text of its latest edit; edits of messages not in [events] and
/// everything that is not a readable message are left out.
List<(String, DeviceMessageHit)> compactMessages(List<Event> events) {
  final edits = <String, (DateTime, String)>{};
  final originals = <Event>[];
  for (final event in events) {
    final text = localMessageText(event);
    if (text == null) continue;
    if (text.edit) {
      final previous = edits[text.targetId];
      if (previous == null || event.originServerTs.isAfter(previous.$1)) {
        edits[text.targetId] = (event.originServerTs, text.text);
      }
    } else {
      originals.add(event);
    }
  }
  final result = <(String, DeviceMessageHit)>[];
  for (final event in originals) {
    final text = edits[event.eventId]?.$2 ?? event.body;
    result.add((
      searchFold(text),
      DeviceMessageHit(
        roomId: event.room.id,
        eventId: event.eventId,
        senderId: event.senderId,
        text: text,
        time: event.originServerTs,
      ),
    ));
  }
  return result;
}

/// [text] from just before its first match with up to [before] characters in front, so
/// a long message shows the match, not its opening (Telegram's snippets).
String localSnippet(String text, List<String> terms, {int before = 24}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final first = localMatchRanges(flat, terms).firstOrNull;
  if (first == null || first.$1 <= before) return flat;
  var start = first.$1 - before;
  final space = flat.indexOf(' ', start);
  if (space >= 0 && space < first.$1) start = space + 1;
  return '…${flat.substring(start)}';
}
