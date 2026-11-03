// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/personal/bridge_notices.dart';
import 'package:chatloom/personal/bridge_timeline.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/disappearing_state.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// One original message in timeline order. IDs stay on the device and are
/// used only to deduplicate pagination; they are never part of [SummarySource].
class SummaryHistoryEntry {
  const SummaryHistoryEntry({
    required this.id,
    required this.timestamp,
    this.message,
    this.omission,
    this.unreadAttachment = false,
  });

  final String id;
  final DateTime timestamp;
  final SummaryMessage? message;
  final String? omission;
  final bool unreadAttachment;

  @override
  String toString() => 'SummaryHistoryEntry(redacted)';
}

/// Separate from the visible conversation timeline: opening or paginating
/// this source never marks messages read, sends typing, or requests media.
abstract interface class SummaryHistorySource {
  Future<void> initialize({required int pageSize});
  List<SummaryHistoryEntry> get entries;
  bool get hasMore;
  Object get position;
  Future<void> loadOlder({required int pageSize});
  void dispose();
}

/// Collects an exact scope. Unavailable messages consume their place in a
/// last-N selection; older readable messages never replace them. A failure
/// to reach the requested boundary is an error, never a partial "whole chat".
class SummaryHistoryCollector {
  const SummaryHistoryCollector({
    this.maxPages = 200,
    this.maxEvents = 20000,
    this.maxSourceBytes = 350000,
    this.pageTimeout = const Duration(seconds: 30),
  });

  final int maxPages;
  final int maxEvents;
  final int maxSourceBytes;
  final Duration pageTimeout;
  static const _pageSize = 100;

  Future<SummarySource> collectRoom({
    required Room room,
    required SummaryRequest request,
    PersonalClient? personal,
    SummaryCancellation? cancellation,
    void Function(int loadedMessages)? onProgress,
    DateTime? now,
  }) => collect(
    source: MatrixSummaryHistorySource(room: room, personal: personal),
    request: request,
    cancellation: cancellation,
    onProgress: onProgress,
    now: now,
  );

  Future<SummarySource> collect({
    required SummaryHistorySource source,
    required SummaryRequest request,
    SummaryCancellation? cancellation,
    void Function(int loadedMessages)? onProgress,
    DateTime? now,
  }) async {
    final cancel = cancellation ?? SummaryCancellation();
    try {
      if (!request.isValid) throw const SummaryException('invalid_request');
      final upperBound = (now ?? DateTime.now()).toUtc();
      final lowerBound = switch (request.scope) {
        SummaryScopeKind.hours => upperBound.subtract(
          Duration(hours: request.amount),
        ),
        SummaryScopeKind.days => upperBound.subtract(
          Duration(days: request.amount),
        ),
        _ => null,
      };
      cancel.throwIfCancelled();
      await _bounded(source.initialize(pageSize: _pageSize), cancel);
      var pages = 0;
      var lastProgress = -1;
      final positions = <Object>{};
      while (true) {
        cancel.throwIfCancelled();
        final seen = <String>{};
        final inScope = <SummaryHistoryEntry>[];
        DateTime? oldestLoadedTimestamp;
        // The source's order is the order shown by the conversation, newest
        // first. Server timestamps decide time windows, not the last-N order.
        for (final entry in source.entries) {
          if (!seen.add(entry.id) || entry.timestamp.isAfter(upperBound)) {
            continue;
          }
          oldestLoadedTimestamp = entry.timestamp;
          if (lowerBound != null && entry.timestamp.isBefore(lowerBound)) {
            continue;
          }
          inScope.add(entry);
          if (request.scope == SummaryScopeKind.messages &&
              inScope.length == request.amount) {
            break;
          }
        }
        if (inScope.length != lastProgress) {
          lastProgress = inScope.length;
          onProgress?.call(lastProgress);
        }
        final requestedCountReached =
            request.scope == SummaryScopeKind.messages &&
            inScope.length >= request.amount;
        // An old backfilled message can sit among recent messages. Only the
        // older edge of the loaded timeline may close a time window.
        final reachedTimeBoundary =
            lowerBound != null &&
            oldestLoadedTimestamp != null &&
            oldestLoadedTimestamp.isBefore(lowerBound);
        final exhausted = !source.hasMore;
        if (requestedCountReached || reachedTimeBoundary || exhausted) {
          cancel.throwIfCancelled();
          return _finish(inScope, request: request, exhausted: exhausted);
        }
        if (pages >= maxPages || seen.length >= maxEvents) {
          throw const SummaryException('summary_history_incomplete');
        }
        final before = source.position;
        if (!positions.add(before)) {
          throw const SummaryException('summary_history_incomplete');
        }
        await _bounded(source.loadOlder(pageSize: _pageSize), cancel);
        cancel.throwIfCancelled();
        pages++;
        if (source.hasMore && before == source.position) {
          throw const SummaryException('summary_history_incomplete');
        }
      }
    } on SummaryException {
      rethrow;
    } catch (_) {
      // Never propagate SDK errors: they can contain room IDs or payloads.
      throw const SummaryException('summary_history_incomplete');
    } finally {
      source.dispose();
    }
  }

  Future<void> _bounded(Future<void> operation, SummaryCancellation cancel) =>
      Future.any<void>([
        operation.timeout(pageTimeout),
        cancel.whenCancelled.then<void>((_) {
          throw const SummaryCancelledException();
        }),
      ]);

  SummarySource _finish(
    List<SummaryHistoryEntry> selected, {
    required SummaryRequest request,
    required bool exhausted,
  }) {
    final messages =
        selected.map((e) => e.message).whereType<SummaryMessage>().toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (messages.isEmpty) throw const SummaryException('no_messages');
    final omitted = selected.length - messages.length;
    final unreadAttachments = selected.where((e) => e.unreadAttachment).length;
    final notes = <String>[];
    if (omitted > 0) {
      final reasons = <String, int>{};
      for (final entry in selected.where((e) => e.message == null)) {
        final reason = entry.omission ?? 'unavailable';
        reasons[reason] = (reasons[reason] ?? 0) + 1;
      }
      notes.add(
        '$omitted selected messages were excluded '
        '(${reasons.entries.map((e) => '${e.value} ${e.key}').join(', ')}).',
      );
    }
    if (unreadAttachments > 0) {
      notes.add(
        '$unreadAttachments attachments are represented by their type and '
        'explicit caption only; their contents were not read.',
      );
    }
    if (exhausted &&
        request.scope == SummaryScopeKind.messages &&
        selected.length < request.amount) {
      notes.add(
        'Only ${selected.length} of the requested ${request.amount} messages '
        'are available to this account.',
      );
    }
    if (request.scope == SummaryScopeKind.all ||
        (exhausted && request.scope != SummaryScopeKind.messages)) {
      notes.add(
        'Covers history available to this account. Earlier messages not '
        'provided by the network cannot be included.',
      );
    }
    final result = SummarySource(
      messages: messages,
      complete: omitted == 0 && unreadAttachments == 0,
      omittedMessages: omitted,
      coverageNote: notes.isEmpty ? null : notes.join(' '),
    );
    // Bound the actual UTF-8 upload (including names and metadata), without
    // truncating a message or silently discarding older selected messages.
    if (utf8.encode(jsonEncode(result.toJson())).length > maxSourceBytes ||
        messages.length > 10000) {
      throw const SummaryException('source_too_large');
    }
    return result;
  }
}

/// Uses existing Matrix decryption and the existing encrypted private store.
/// No keys, media, transcript jobs, receipts or outgoing messages are created.
class MatrixSummaryHistorySource implements SummaryHistorySource {
  MatrixSummaryHistorySource({required this.room, PersonalClient? personal})
    : _personal = personal ?? PersonalClient.of(room.client),
      _account = room.client.userID,
      _lockGeneration = PersonalPrivacy.surfaceLockGeneration;

  final Room room;
  final PersonalClient _personal;
  final String? _account;
  final int _lockGeneration;
  final _storedHidden = <String>{};
  final _fallbackNames = <String, String>{};
  Timeline? _timeline;
  bool _disposed = false;

  void _checkAccess() {
    if (_disposed) throw const SummaryCancelledException();
    if (_account == null || room.client.userID != _account) {
      throw const SummaryException('summary_account_unavailable');
    }
    if (!PersonalPrivacy.surfaceUnlocked ||
        _lockGeneration != PersonalPrivacy.surfaceLockGeneration) {
      throw const SummaryException('summary_locked');
    }
    if (roomMayDisappear(room)) {
      throw const SummaryException('summary_disappearing_room');
    }
  }

  @override
  Future<void> initialize({required int pageSize}) async {
    await loadRoomState(room);
    _checkAccess();
    try {
      await _personal.loadLocal();
      final record = await _personal.readLocalRecord(
        PersonalHiddenMessagesStorage.key,
      );
      final keys = record?['keys'];
      if (keys is List) _storedHidden.addAll(keys.whereType<String>());
    } catch (_) {
      throw const SummaryException('summary_storage_unavailable');
    }
    _checkAccess();
    final timeline = await room.getTimeline(limit: pageSize);
    if (_disposed) {
      timeline.cancelSubscriptions();
      throw const SummaryCancelledException();
    }
    _timeline = timeline;
    _checkAccess();
  }

  @override
  List<SummaryHistoryEntry> get entries {
    _checkAccess();
    final timeline = _timeline;
    if (timeline == null) return const [];
    final entries = <SummaryHistoryEntry>[];
    for (final original in timeline.events) {
      final entry = project(
        original,
        timeline: timeline,
        hidden:
            _storedHidden.contains('${room.id}\u0000${original.eventId}') ||
            HiddenMessages.hides(original),
        sender: _sender(original),
        transcript: _transcript(original),
      );
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  String _sender(Event event) {
    final name = event.senderFromMemoryOrFallback.calcDisplayname().trim();
    if (name.isNotEmpty && !name.startsWith('@')) {
      return name.length > 255 ? name.substring(0, 255) : name;
    }
    return _fallbackNames.putIfAbsent(
      event.senderId,
      () => 'Participant ${_fallbackNames.length + 1}',
    );
  }

  String? _transcript(Event original) {
    // Only readable, completed private-sync results. Reading never requests a
    // transcription or publishes a command, including when the worker is off.
    if (!_personal.ready) return null;
    final id = _personal.transcriptId(original);
    if (_personal.isTranscriptCancellationPending(id)) return null;
    final job = _personal.transcripts[id];
    final text = job?.text;
    return job?.state == JobState.done && text != null && text.trim().isNotEmpty
        ? text.trim()
        : null;
  }

  /// Projection kept separate so privacy and media handling can be verified
  /// with fictional SDK events without opening a database or a network.
  static SummaryHistoryEntry? project(
    Event original, {
    required Timeline timeline,
    required String sender,
    bool hidden = false,
    String? transcript,
  }) {
    if (hidden ||
        !original.status.isSent ||
        !original.eventId.startsWith(r'$') ||
        original.stateKey != null ||
        isBridgeTimelineNoise(original) ||
        original.relationshipType == RelationshipTypes.edit ||
        original.relationshipType == RelationshipTypes.reaction ||
        !const {
          EventTypes.Message,
          EventTypes.Encrypted,
          EventTypes.Sticker,
          PollEventContent.startType,
          'm.poll.start',
        }.contains(original.type)) {
      return null;
    }
    SummaryHistoryEntry excluded(String reason) => SummaryHistoryEntry(
      id: original.eventId,
      timestamp: original.originServerTs,
      omission: reason,
    );
    if (isDeletedForDisplay(original)) return excluded('deleted');
    if (original.type == EventTypes.Encrypted) return excluded('encrypted');
    if (!RoundMediaPolicy.fromContent(original.content).canTranscribe) {
      return excluded('protected or disappearing');
    }
    final display = original.getDisplayEvent(timeline);
    if (isDeletedForDisplay(display)) return excluded('deleted');
    if (display.content['fi.mau.whatsapp.undecryptable'] == true ||
        display.content.containsKey('fi.mau.bridge.internal_error') ||
        display.content.containsKey('fi.mau.whatsapp.failed_media')) {
      return excluded('unavailable');
    }
    if (bridgeServiceNotice(display) != null ||
        isBridgeBotSender(original.room, original.senderId)) {
      return null;
    }
    if (!RoundMediaPolicy.fromContent(display.content).canTranscribe) {
      return excluded('protected or disappearing');
    }
    final type = display.type == EventTypes.Sticker
        ? MessageTypes.Sticker
        : display.messageType;
    final attachment = switch (type) {
      MessageTypes.Image => 'Image',
      MessageTypes.Video => 'Video',
      MessageTypes.Audio => 'Audio',
      MessageTypes.File => 'File',
      MessageTypes.Sticker => 'Sticker',
      MessageTypes.Location => 'Location',
      GalleryContent.unstableMsgType || GalleryContent.stableMsgType => 'Album',
      _ => null,
    };
    var unreadAttachment = false;
    String text;
    if (attachment != null) {
      final filename = display.content['filename'];
      // MSC2530 distinguishes captions from filenames. A media body's
      // fallback filename is never presented as the contents of the media.
      final caption = GalleryContent.msgTypes.contains(type)
          ? GalleryContent.of(display)?.caption ?? ''
          : filename is String &&
                filename.isNotEmpty &&
                display.body != filename
          ? _plain(display)
          : '';
      final storedTranscript = transcript?.trim();
      if (storedTranscript != null && storedTranscript.isNotEmpty) {
        text = '[$attachment; existing transcript]\n$storedTranscript';
      } else {
        unreadAttachment = true;
        text = '[$attachment attachment; contents not read]';
      }
      if (caption.isNotEmpty) text += '\nCaption: $caption';
    } else if (const {
      PollEventContent.startType,
      'm.poll.start',
    }.contains(display.type)) {
      final poll = display.content[display.type];
      final question = poll is Map ? poll['question'] : null;
      final value = question is Map
          ? question['m.text'] ?? question['org.matrix.msc1767.text']
          : null;
      text = value is String ? '[Poll] $value' : '[Poll; contents not read]';
      unreadAttachment = value is! String;
    } else if (const {
      MessageTypes.Text,
      MessageTypes.Notice,
      MessageTypes.Emote,
    }.contains(type)) {
      text = _plain(display);
      if (type == MessageTypes.Emote && text.isNotEmpty) {
        text = '[Action] $text';
      }
    } else {
      return excluded('unsupported');
    }
    if (text.trim().isEmpty) return excluded('empty');
    return SummaryHistoryEntry(
      id: original.eventId,
      timestamp: original.originServerTs,
      message: SummaryMessage(
        timestamp: original.originServerTs,
        sender: sender,
        text: text.trim(),
      ),
      unreadAttachment: unreadAttachment,
    );
  }

  static String _plain(Event event) => event
      .calcUnlocalizedBody(
        hideReply: true,
        hideEdit: true,
        plaintextBody: true,
        removeMarkdown: true,
      )
      .trim();

  @override
  bool get hasMore {
    _checkAccess();
    return _timeline?.canRequestHistory ?? false;
  }

  @override
  Object get position {
    _checkAccess();
    final timeline = _timeline;
    return (
      timeline?.events.length ?? 0,
      room.prev_batch,
      timeline?.events.lastOrNull?.eventId,
    );
  }

  @override
  Future<void> loadOlder({required int pageSize}) async {
    _checkAccess();
    await _timeline?.requestHistory(historyCount: pageSize);
    _checkAccess();
  }

  @override
  void dispose() {
    _disposed = true;
    _timeline?.cancelSubscriptions();
    _timeline = null;
    _storedHidden.clear();
    _fallbackNames.clear();
  }
}
