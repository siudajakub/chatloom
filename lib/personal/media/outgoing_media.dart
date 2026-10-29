// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/utils/start_push_foreground_service.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'send_error_text.dart';
import 'upload_progress.dart';
import 'voice_format.dart';

/// Local echoes ChatLoom shows itself, before (or instead of) the SDK's own
/// send: the same shape the SDK uses (`transaction_id`, the sending status
/// in `unsigned`), so the SDK's later updates of the same transaction ID
/// replace the bubble in place and the server's copy replaces it on sync.
abstract final class OutgoingEcho {
  /// Test seam: replaces the database/sync writes of this class.
  @visibleForTesting
  static OutgoingEchoWriter? debugWriter;

  /// Shows (or replaces) the echo [transactionId] in [room].
  static Future<void> show(
    Room room, {
    required String transactionId,
    required Map<String, dynamic> content,
    required DateTime at,
    Map<String, dynamic> unsigned = const {},
    EventStatus status = EventStatus.sending,
  }) {
    final sender = room.client.userID;
    if (sender == null) throw StateError('No signed-in account');
    final event = MatrixEvent(
      type: EventTypes.Message,
      content: content,
      eventId: transactionId,
      senderId: sender,
      originServerTs: at,
      unsigned: {
        ...unsigned,
        messageSendingStatusKey: status.intValue,
        'transaction_id': transactionId,
      },
    );
    return (debugWriter?.write ?? _write)(room, event);
  }

  /// Moves the stored, still unsent echo to [status]. An echo the server
  /// accepted is never touched. Returns whether anything changed.
  static Future<bool> setStatus(
    Room room,
    String transactionId,
    EventStatus status,
  ) async {
    final stored = await (debugWriter?.read ?? _read)(room, transactionId);
    if (stored == null || stored.status.isSent || stored.status == status) {
      return false;
    }
    final json = stored.toJson();
    json['unsigned'] = {
      ...?(json['unsigned'] as Map?)?.cast<String, dynamic>(),
      messageSendingStatusKey: status.intValue,
      'transaction_id': transactionId,
    };
    await (debugWriter?.write ?? _write)(room, MatrixEvent.fromJson(json));
    return true;
  }

  /// The stored echo of [transactionId], if any (no network).
  static Future<Event?> stored(Room room, String transactionId) =>
      (debugWriter?.read ?? _read)(room, transactionId);

  /// While ChatLoom owns a send, the SDK must not age its echo into
  /// "error" (it does so for unsent echoes older than the send timeout
  /// that are not in this list, e.g. during a long upload or a queue wait).
  static void own(Room room, String transactionId) {
    if (!room.sendingQueueEventsByTxId.contains(transactionId)) {
      room.sendingQueueEventsByTxId.add(transactionId);
    }
  }

  static void release(Room room, String transactionId) =>
      room.sendingQueueEventsByTxId.remove(transactionId);

  static Future<void> _write(Room room, MatrixEvent event) {
    final client = room.client;
    return client.database.transaction(
      () => client.handleSync(
        SyncUpdate(
          nextBatch: '',
          rooms: RoomsUpdate(
            join: {
              room.id: JoinedRoomUpdate(
                timeline: TimelineUpdate(events: [event]),
              ),
            },
          ),
        ),
      ),
    );
  }

  static Future<Event?> _read(Room room, String transactionId) =>
      room.client.database.getEventById(transactionId, room);

  /// Stores this device's copy of an unsent file (the SDK's own cache key,
  /// so `Event.sendAgain` and the bubble preview read it).
  static Future<void> storeFile(Room room, Uri key, Uint8List bytes) =>
      debugWriter?.storeFile(room, key, bytes) ??
      room.client.database.storeFile(
        key,
        bytes,
        DateTime.now().millisecondsSinceEpoch,
      );

  static Future<Uint8List?> getFile(Room room, Uri key) =>
      debugWriter?.getFile(room, key) ?? room.client.database.getFile(key);

  /// Drops this device's copy once its file is sent or its bubble deleted.
  static Future<void> deleteFile(Room room, Uri key) =>
      debugWriter?.deleteFile(room, key) ??
      room.client.database.deleteFile(key).then<void>((_) {});

  /// The largest copy [storeFile] keeps (the encrypted cache skips bigger
  /// files silently).
  static int maxFileSize(Room room) =>
      debugWriter?.maxFileSize ?? room.client.database.maxFileSize;
}

/// See [OutgoingEcho.debugWriter].
abstract class OutgoingEchoWriter {
  Future<void> write(Room room, MatrixEvent event);
  Future<Event?> read(Room room, String transactionId);
  Future<void> storeFile(Room room, Uri key, Uint8List bytes);
  Future<Uint8List?> getFile(Room room, Uri key);
  Future<void> deleteFile(Room room, Uri key);
  int get maxFileSize;
}

/// [file] with its pixel size when it is an image without one: read from
/// the image header (no decode), so the bubble keeps its final size while
/// it uploads instead of jumping when the SDK learns the size.
Future<MatrixFile> withImageSize(MatrixFile file) async {
  if (file is! MatrixImageFile || (file.width != null && file.height != null)) {
    return file;
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(file.bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return MatrixImageFile(
      bytes: file.bytes,
      name: file.name,
      mimeType: file.mimeType,
      width: descriptor.width,
      height: descriptor.height,
    );
  } catch (_) {
    return file;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// A photo or video sent deliberately as a file (the send preview's
/// "Original"): an `m.file` document with the original bytes, whatever its
/// mimetype, so receivers and bridges deliver it unchanged.
class MatrixDocumentFile extends MatrixFile {
  MatrixDocumentFile({
    required super.bytes,
    required super.name,
    super.mimeType,
  });

  @override
  String get msgType => MessageTypes.File;
}

/// The result of [OutgoingMedia.send]: the bubble is already visible.
class OutgoingMediaTicket {
  final String transactionId;

  /// The accepted event ID. Completes with an error when the send failed;
  /// the bubble then shows "Not sent · Tap to retry". Never needs a
  /// listener: an unhandled failure is not reported.
  final Future<String> accepted;

  OutgoingMediaTicket(this.transactionId, Future<String> accepted)
    : accepted = accepted..ignore();
}

/// The file is no longer on this device, so it cannot be sent again.
class OutgoingMediaUnavailable implements Exception {
  const OutgoingMediaUnavailable();
}

/// Work a file needs before its upload (video compression, a thumbnail).
/// It may run again on Retry when its first run failed (the echo then has
/// no bytes of its own, e.g. a video that is only read when prepared).
typedef OutgoingMediaPrepare =
    Future<(MatrixFile, MatrixImageFile?)> Function();

/// Own files, photos, videos and voice messages, sent the Telegram /
/// Messenger way:
///
/// - the bubble is in the timeline before any heavy work or network I/O
///   (its bytes are stored first, so a retry after a restart still works);
/// - compression, thumbnails, encryption and the upload run afterwards,
///   with the upload progress in the bubble;
/// - the sends of one chat leave in the order they were made;
/// - a failure stays in its bubble ("Not sent · Tap to retry"); nothing
///   blocks the composer, and no dialog waits for the server;
/// - one job per file: while it runs (queued, preparing, uploading, waiting
///   out a rate limit) the bubble says "Sending…" and offers neither Retry
///   nor Delete, and a Retry of a file already uploaded resends only its
///   event, without the bytes.
///
/// Encryption, transaction IDs and retries are the SDK's own
/// (`Room.sendFileEvent`); this class only orders the work and shows it.
abstract final class OutgoingMedia {
  static final _tails = <String, Future<void>>{};
  static final _failures = <String, String>{};

  /// The job of each file this process is sending, by [_jobKey].
  static final _jobs = <String, Future<String>>{};

  /// Files whose bubble was deleted while their job was queued or waiting:
  /// the job never starts (or restarts) their upload.
  static final _discarded = <String>{};

  /// Files too large for the encrypted cache ([OutgoingEcho.maxFileSize]),
  /// kept in memory until sent or deleted so that Retry works in this
  /// session (after a restart such a file has to be picked again). Oldest
  /// first, at most [maxHeldBytes] beyond the files a job still sends.
  static final _held = <String, (MatrixFile, MatrixImageFile?)>{};
  static const maxHeldBytes = 256 * 1024 * 1024;

  /// Keeps uploads alive when the app goes to the background.
  static final _sendLease = ForegroundServices.lease(
    ForegroundServiceTasks.sendFiles,
  );

  /// The preparation of each file until it was sent or deleted, so Retry
  /// can prepare a file whose bytes were never stored (MD-05).
  static final _prepares = <String, OutgoingMediaPrepare>{};

  /// How to stop a running preparation (video compression), by job key.
  static final _cancelPrepares = <String, Future<void> Function()>{};
  static final _preparing = <String>{};

  /// Transaction IDs the user cancelled while their job ran: the SDK stops
  /// their upload and never sends the event (`Client.fileSendCancelled`).
  static final _cancelled = <String>{};

  static String _roomKey(Room room) =>
      '${identityHashCode(room.client)}|${room.id}';
  static String _jobKey(Room room, String id) => '${_roomKey(room)}|$id';
  static String _idOf(Event event) => event.transactionId ?? event.eventId;

  /// Why the send of [transactionId] failed (plain language), if known.
  static String? failureOf(String transactionId) => _failures[transactionId];

  /// Whether this process still sends [event]'s file (queued, preparing,
  /// uploading or waiting out a rate limit). It then ends as sent or as
  /// "Not sent" by itself: Retry would start a second job, and Delete could
  /// not stop an upload already on its way.
  static bool isActive(Event event) =>
      _jobs.containsKey(_jobKey(event.room, _idOf(event)));

  /// Shows [file] in [room] at once and sends it in the background.
  /// Returns when the bubble is visible; throws (and shows nothing) only
  /// when the bubble itself could not be stored.
  static Future<OutgoingMediaTicket> send(
    Room room,
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? threadRootEventId,
    String? threadLastEventId,
    MatrixImageFile? thumbnail,
    int? shrinkImageMaxDimension,
    Map<String, dynamic>? extraContent,
    OutgoingMediaPrepare? prepare,
    Future<void> Function()? cancelPrepare,
  }) async {
    final client = room.client;
    client.fileSendCancelled = _cancelled.contains;
    final readUpToEventId = PersonalPrivacy.frozenReadCutoff(room);
    final id = txid ?? client.generateUniqueTransactionId();
    final key = _jobKey(room, id);
    // The same attempt twice (a repeated tap) is one job and one bubble.
    final running = _jobs[key];
    if (running != null) return OutgoingMediaTicket(id, running);
    final relation = _relation(
      inReplyTo: inReplyTo,
      threadRootEventId: threadRootEventId,
      threadLastEventId: threadLastEventId,
    );
    // The relation travels with every SDK update of the echo, so a reply
    // shows its quote while it uploads; the SDK writes the same relation
    // into the final event.
    final extra = <String, dynamic>{
      ...?extraContent,
      'm.relates_to': ?relation,
    };
    final at = DateTime.now();
    _failures.remove(id);
    _discarded.remove(key);
    _cancelled.remove(id);
    // A file only read when prepared (a video) has no bytes yet; the SDK
    // stores the prepared copy itself when the upload starts.
    if (file.bytes.isNotEmpty) {
      await OutgoingEcho.storeFile(room, _fileKey(id), file.bytes);
    }
    if (thumbnail != null) {
      await OutgoingEcho.storeFile(room, _thumbnailKey(id), thumbnail.bytes);
    }
    OutgoingEcho.own(room, id);
    try {
      await OutgoingEcho.show(
        room,
        transactionId: id,
        at: at,
        content: {
          'msgtype': file.msgType,
          'body': file.name,
          'filename': file.name,
          'info': file.info,
          ...extra,
        },
        unsigned: {
          'personal_read_cutoff': readUpToEventId,
          'in_reply_to': ?inReplyTo?.eventId,
          'shrink_image_max_dimension': ?shrinkImageMaxDimension,
          if (extra.isNotEmpty) 'extra_content': extra,
          if (prepare != null)
            fileSendingStatusKey: FileSendingStatus.generatingThumbnail.name,
        },
      );
    } catch (_) {
      OutgoingEcho.release(room, id);
      rethrow;
    }
    _hold(room, key, file, thumbnail);
    if (prepare != null) _prepares[key] = prepare;
    if (cancelPrepare != null) _cancelPrepares[key] = cancelPrepare;
    final accepted = _enqueue(room, id, () async {
      var upload = file;
      var preview = thumbnail;
      if (prepare != null) {
        (upload, preview) = await _runPrepare(key, prepare);
        preview ??= thumbnail;
        // Retry sends what was prepared (the SDK caches the same bytes).
        _hold(room, key, upload, preview);
      }
      return PersonalPrivacy.withFrozenRoundReadCutoff(
        room,
        readUpToEventId,
        () => room.sendFileEvent(
          upload,
          txid: id,
          inReplyTo: inReplyTo,
          thumbnail: preview,
          shrinkImageMaxDimension: shrinkImageMaxDimension,
          extraContent: extra.isEmpty ? null : extra,
          threadRootEventId: threadRootEventId,
          threadLastEventId: threadLastEventId,
        ),
      );
    });
    return OutgoingMediaTicket(id, accepted);
  }

  /// Sends the failed file of [event] again with its original transaction
  /// ID (never a second message): only its event when the file is already
  /// on the server (the final send failed), otherwise this device's copy
  /// with the original metadata, reply and thread. While its job still runs
  /// this returns that job instead of starting another one.
  static Future<OutgoingMediaTicket> retry(Event event) async {
    final room = event.room;
    final id = _idOf(event);
    final key = _jobKey(room, id);
    final running = _jobs[key];
    if (running != null) return OutgoingMediaTicket(id, running);
    // Reserved before the first await: a second tap joins this retry, and
    // a Delete from now on stops it.
    final reserved = Completer<String>();
    _jobs[key] = reserved.future..ignore();
    _discarded.remove(key);
    var owned = false;
    try {
      final transport = await _retryTransport(event, id, key);
      _failures.remove(id);
      OutgoingEcho.own(room, id);
      owned = true;
      await OutgoingEcho.setStatus(room, id, EventStatus.sending);
      final job = _enqueue(room, id, transport);
      reserved.complete(job);
      return OutgoingMediaTicket(id, job);
    } catch (error, stack) {
      if (identical(_jobs[key], reserved.future)) {
        _jobs.remove(key);
        if (owned) OutgoingEcho.release(room, id);
      }
      if (!reserved.isCompleted) reserved.completeError(error, stack);
      rethrow;
    }
  }

  static Future<(MatrixFile, MatrixImageFile?)> _runPrepare(
    String key,
    OutgoingMediaPrepare prepare,
  ) async {
    _checkDiscarded(key);
    _preparing.add(key);
    try {
      return await prepare();
    } on MatrixException {
      // A deliberate refusal (e.g. the video is still too large) is told
      // as such, not as "could not be prepared".
      rethrow;
    } catch (_) {
      if (_discarded.contains(key)) throw const _Discarded();
      throw const _PrepareFailed();
    } finally {
      _preparing.remove(key);
      // Deleted while it was prepared: nothing of it is uploaded.
      _checkDiscarded(key);
    }
  }

  static Future<Future<String?> Function()> _retryTransport(
    Event event,
    String id,
    String key,
  ) async {
    final room = event.room;
    if (_uploaded(event.content)) {
      // Upload done, final send failed: the stored event is complete (URL,
      // keys, reply and thread), so the same event goes again.
      final content = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(event.content)) as Map,
      );
      return () => room.sendEvent(content, txid: id);
    }
    final held = _held[key];
    final info = event.infoMap;
    final voice = event.content.containsKey('org.matrix.msc3245.voice');
    MatrixFile file;
    MatrixImageFile? thumbnail;
    OutgoingMediaPrepare? rerun;
    final cached = held == null
        ? await OutgoingEcho.getFile(room, _fileKey(id))
        : null;
    if (held != null) {
      (file, thumbnail) = held;
    } else if ((cached == null || cached.isEmpty) && _prepares[key] != null) {
      // Never prepared successfully (its bytes were never stored): the
      // same preparation runs again.
      rerun = _prepares[key];
      file = _typedFile(event, Uint8List(0));
      thumbnail = null;
    } else {
      final bytes = cached;
      if (bytes == null || bytes.isEmpty) {
        throw const OutgoingMediaUnavailable();
      }
      final thumbnailBytes = await OutgoingEcho.getFile(
        room,
        _thumbnailKey(id),
      );
      file = _typedFile(event, bytes);
      if (voice) {
        // The recorder's actual container, not a stale or generic label.
        file = MatrixAudioFile(
          bytes: bytes,
          name: file.name,
          mimeType: voiceRecordingMime(
            bytes,
            info.tryGet<String>('mimetype') ?? 'application/octet-stream',
          ),
          duration: info.tryGet<int>('duration'),
        );
      }
      final preview = event.thumbnailInfoMap;
      thumbnail = thumbnailBytes == null
          ? null
          : MatrixImageFile(
              bytes: thumbnailBytes,
              name: '${file.name}.thumbnail',
              mimeType: preview.tryGet<String>('mimetype'),
              width: preview.tryGet<int>('w'),
              height: preview.tryGet<int>('h'),
            );
    }
    final retryMime = file.mimeType;
    final unsigned = event.unsigned ?? const <String, dynamic>{};
    final replyId = unsigned['in_reply_to'];
    final reply = replyId is String ? await room.getEventById(replyId) : null;
    final storedExtra = unsigned['extra_content'];
    final extra = <String, dynamic>{
      if (storedExtra is Map) ...storedExtra.cast<String, dynamic>(),
      if (voice) ...{
        'org.matrix.msc3245.voice': event.content['org.matrix.msc3245.voice'],
        if (event.content.containsKey('org.matrix.msc1767.audio'))
          'org.matrix.msc1767.audio': event.content['org.matrix.msc1767.audio'],
        'info': {...info, 'mimetype': retryMime, 'size': file.bytes.length},
      },
    };
    final shrink = unsigned['shrink_image_max_dimension'];
    final thread = _thread(event.content);
    return () async {
      if (rerun != null) {
        (file, thumbnail) = await _runPrepare(key, rerun);
        _hold(room, key, file, thumbnail);
      }
      return PersonalPrivacy.withFrozenRoundReadCutoff(
        room,
        unsigned['personal_read_cutoff'] as String?,
        () => room.sendFileEvent(
          file,
          txid: id,
          inReplyTo: reply,
          thumbnail: thumbnail,
          shrinkImageMaxDimension: shrink is int ? shrink : null,
          extraContent: extra.isEmpty ? null : extra,
          threadRootEventId: thread?.$1,
          threadLastEventId: thread?.$2,
        ),
      );
    };
  }

  /// The user deleted the unsent bubble of [event], or cancelled its upload
  /// with the "×" (Telegram): a queued job never starts, a running
  /// preparation (video compression) is stopped, a running upload is
  /// aborted and its message is never sent. This device's copies of the
  /// file are dropped.
  static Future<void> discard(Event event) async {
    final room = event.room;
    final id = _idOf(event);
    final key = _jobKey(room, id);
    _failures.remove(id);
    _prepares.remove(key);
    if (_jobs.containsKey(key)) {
      // The job drops the copies when it ends.
      _discarded.add(key);
      _cancelled.add(id);
      UploadProgress.abort(id);
      // Also for a queued job: it never starts, and its cancel releases
      // what the preparation owns (an edited video's render).
      final cancel = _cancelPrepares[key];
      if (cancel != null) {
        try {
          await cancel();
        } catch (_) {
          // The job still ends as discarded once the codec returns.
        }
      }
      return;
    }
    // A failed preparation kept for Retry: its cancel releases what it owns.
    final cancel = _cancelPrepares.remove(key);
    if (cancel != null) {
      try {
        await cancel();
      } catch (_) {}
    }
    _held.remove(key);
    await _forgetCopies(room, id);
  }

  /// Whether [error] (of [OutgoingMediaTicket.accepted]) means the user
  /// cancelled the send.
  static bool isDiscard(Object error) => error is _Discarded;

  /// Whether the file of [content] is on the server already (the SDK wrote
  /// the final content into the echo before its last send failed).
  static bool _uploaded(Map<String, dynamic> content) {
    final file = content['file'];
    return content['url'] is String || (file is Map && file['url'] is String);
  }

  /// The file of a failed echo with the metadata it was sent with (size,
  /// duration, blurhash), as the SDK's own `Event.sendAgain` rebuilds it.
  static MatrixFile _typedFile(Event event, Uint8List bytes) {
    final info = event.infoMap;
    final name = event.content.tryGet<String>('filename') ?? event.body;
    final mimeType = info.tryGet<String>('mimetype');
    return switch (event.messageType) {
      MessageTypes.Image => MatrixImageFile(
        bytes: bytes,
        name: name,
        mimeType: mimeType,
        width: info.tryGet<int>('w'),
        height: info.tryGet<int>('h'),
        blurhash: info.tryGet<String>('xyz.amorgan.blurhash'),
      ),
      MessageTypes.Video => MatrixVideoFile(
        bytes: bytes,
        name: name,
        mimeType: mimeType,
        width: info.tryGet<int>('w'),
        height: info.tryGet<int>('h'),
        duration: info.tryGet<int>('duration'),
      ),
      MessageTypes.Audio => MatrixAudioFile(
        bytes: bytes,
        name: name,
        mimeType: mimeType,
        duration: info.tryGet<int>('duration'),
      ),
      // A document stays a document on Retry, even with an image type.
      _ => MatrixDocumentFile(bytes: bytes, name: name, mimeType: mimeType),
    };
  }

  /// The thread root (and the event a falling-back reply points to) of a
  /// threaded echo, so a retried file stays in its thread.
  static (String, String?)? _thread(Map<String, dynamic> content) {
    final relation = content['m.relates_to'];
    if (relation is! Map || relation['rel_type'] != RelationshipTypes.thread) {
      return null;
    }
    final root = relation['event_id'];
    if (root is! String) return null;
    final reply = relation['m.in_reply_to'];
    final last = relation['is_falling_back'] == true && reply is Map
        ? reply['event_id']
        : null;
    return (root, last is String ? last : null);
  }

  /// Keeps [file] in memory when the encrypted cache cannot hold it.
  static void _hold(
    Room room,
    String key,
    MatrixFile file,
    MatrixImageFile? thumbnail,
  ) {
    _held.remove(key);
    if (file.bytes.length <= OutgoingEcho.maxFileSize(room)) return;
    _held[key] = (file, thumbnail);
    var total = 0;
    for (final held in _held.values) {
      total += held.$1.bytes.length;
    }
    for (final other in _held.keys.toList()) {
      if (total <= maxHeldBytes) break;
      if (other == key || _jobs.containsKey(other)) continue;
      total -= _held.remove(other)!.$1.bytes.length;
    }
  }

  static Future<void> _forgetCopies(Room room, String id) async {
    try {
      await OutgoingEcho.deleteFile(room, _fileKey(id));
      await OutgoingEcho.deleteFile(room, _thumbnailKey(id));
    } catch (_) {
      // The cache's own expiry removes it later.
    }
  }

  static Uri _fileKey(String id) =>
      Uri(scheme: 'cache', host: 'file', path: id);
  static Uri _thumbnailKey(String id) =>
      Uri(scheme: 'cache', host: 'thumbnail', path: id);

  static Map<String, dynamic>? _relation({
    Event? inReplyTo,
    String? threadRootEventId,
    String? threadLastEventId,
  }) {
    if (threadRootEventId != null) {
      final replyTo = inReplyTo?.eventId ?? threadLastEventId;
      return {
        'event_id': threadRootEventId,
        'rel_type': RelationshipTypes.thread,
        'is_falling_back': inReplyTo == null,
        if (replyTo != null) 'm.in_reply_to': {'event_id': replyTo},
      };
    }
    if (inReplyTo == null) return null;
    return {
      'm.in_reply_to': {'event_id': inReplyTo.eventId},
    };
  }

  static Future<String> _enqueue(
    Room room,
    String id,
    Future<String?> Function() transport,
  ) {
    final roomKey = _roomKey(room);
    final key = _jobKey(room, id);
    final previous = _tails[roomKey] ?? Future<void>.value();
    late final Future<String> job;
    job = previous.then((_) async {
      final release = _sendLease.hold();
      try {
        String? eventId;
        try {
          _checkDiscarded(key);
          eventId = await UploadProgress.track(id, transport);
        } on MatrixException catch (error) {
          // One automatic retry after a rate limit, with the same txid.
          final wait = error.retryAfterMs;
          if (error.error != MatrixError.M_LIMIT_EXCEEDED || wait == null) {
            rethrow;
          }
          // Still this job's file: the bubble stays "Sending…" while it
          // waits (the SDK marked it "Not sent"), without Retry or Delete.
          await OutgoingEcho.setStatus(room, id, EventStatus.sending);
          await Future<void>.delayed(Duration(milliseconds: wait + 1000));
          _checkDiscarded(key);
          eventId = await UploadProgress.track(id, transport);
        }
        if (eventId == null || !eventId.startsWith(r'$')) {
          throw const _NotConfirmed();
        }
        _held.remove(key);
        _prepares.remove(key);
        _cancelPrepares.remove(key);
        // The SDK drops its copy after a full send; a resent event alone
        // leaves it.
        await _forgetCopies(room, id);
        return eventId;
      } on _Discarded {
        rethrow;
      } catch (error) {
        // Cancelled by the user: the abort is not a failure.
        if (_discarded.contains(key)) throw const _Discarded();
        // From here on the bubble offers Retry.
        if (identical(_jobs[key], job)) _jobs.remove(key);
        _failures[id] = describeFailure(error);
        while (_failures.length > 64) {
          _failures.remove(_failures.keys.first);
        }
        // The SDK marks its own echo when an upload or the final send
        // fails; anything before that (preparation, encryption, storage)
        // is marked here. An accepted event is never downgraded.
        try {
          await OutgoingEcho.setStatus(room, id, EventStatus.error);
        } catch (_) {}
        rethrow;
      } finally {
        // A Retry started meanwhile owns the echo and its progress now.
        final current = !_jobs.containsKey(key) || identical(_jobs[key], job);
        if (identical(_jobs[key], job)) _jobs.remove(key);
        if (current) {
          OutgoingEcho.release(room, id);
          UploadProgress.reset(id);
        }
        release();
        if (_discarded.remove(key)) {
          _held.remove(key);
          _prepares.remove(key);
          _cancelPrepares.remove(key);
          _cancelled.remove(id);
          await _forgetCopies(room, id);
        }
      }
    });
    _jobs[key] = job..ignore();
    final tail = job.then<void>((_) {}, onError: (Object _) {});
    _tails[roomKey] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[roomKey], tail)) _tails.remove(roomKey);
      }),
    );
    return job;
  }

  static void _checkDiscarded(String key) {
    if (_discarded.contains(key)) throw const _Discarded();
  }

  /// A plain-language reason for the failure sheet. Server and network
  /// errors go through [sendErrorText], i.e. the shared Matrix error text.
  static String describeFailure(Object error) => switch (error) {
    _PrepareFailed() => 'The file could not be prepared for sending.',
    _NotConfirmed() =>
      'ChatLoom could not confirm that the server received this file. '
          'Retry sends the same attempt, so it is never delivered twice.',
    _ => sendErrorText(error, upload: true),
  };
}

class _PrepareFailed implements Exception {
  const _PrepareFailed();
}

class _NotConfirmed implements Exception {
  const _NotConfirmed();
}

/// The bubble was deleted before the job sent the file.
class _Discarded implements Exception {
  const _Discarded();
}
