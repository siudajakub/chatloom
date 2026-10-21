// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:ui' as ui;

import 'package:chatloom/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:chatloom/utils/start_push_foreground_service.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'send_error_text.dart';
import 'upload_progress.dart';

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
}

/// See [OutgoingEcho.debugWriter].
abstract class OutgoingEchoWriter {
  Future<void> write(Room room, MatrixEvent event);
  Future<Event?> read(Room room, String transactionId);
  Future<void> storeFile(Room room, Uri key, Uint8List bytes);
  Future<Uint8List?> getFile(Room room, Uri key);
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
///   blocks the composer, and no dialog waits for the server.
///
/// Encryption, transaction IDs and retries are the SDK's own
/// (`Room.sendFileEvent`); this class only orders the work and shows it.
abstract final class OutgoingMedia {
  static final _tails = <String, Future<void>>{};
  static final _failures = <String, String>{};
  static int _running = 0;

  static String _roomKey(Room room) =>
      '${identityHashCode(room.client)}|${room.id}';

  /// Why the send of [transactionId] failed (plain language), if known.
  static String? failureOf(String transactionId) => _failures[transactionId];

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
  }) async {
    final client = room.client;
    final id = txid ?? client.generateUniqueTransactionId();
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
    await OutgoingEcho.storeFile(room, _fileKey(id), file.bytes);
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
    final accepted = _enqueue(room, id, () async {
      var upload = file;
      var preview = thumbnail;
      if (prepare != null) {
        try {
          (upload, preview) = await prepare();
        } catch (_) {
          throw const _PrepareFailed();
        }
        preview ??= thumbnail;
      }
      return room.sendFileEvent(
        upload,
        txid: id,
        inReplyTo: inReplyTo,
        thumbnail: preview,
        shrinkImageMaxDimension: shrinkImageMaxDimension,
        extraContent: extra.isEmpty ? null : extra,
        threadRootEventId: threadRootEventId,
        threadLastEventId: threadLastEventId,
      );
    });
    return OutgoingMediaTicket(id, accepted);
  }

  /// Sends the failed file of [event] again from this device's copy, with
  /// its original transaction ID (never a second message).
  static Future<OutgoingMediaTicket> retry(Event event) async {
    final room = event.room;
    final id = event.transactionId ?? event.eventId;
    final bytes = await OutgoingEcho.getFile(room, _fileKey(id));
    if (bytes == null || bytes.isEmpty) throw const OutgoingMediaUnavailable();
    final thumbnailBytes = await OutgoingEcho.getFile(room, _thumbnailKey(id));
    final info = event.infoMap;
    final file = MatrixFile(
      bytes: bytes,
      name: event.content.tryGet<String>('filename') ?? event.body,
      mimeType: info.tryGet<String>('mimetype'),
    ).detectFileType;
    final thumbnail = thumbnailBytes == null
        ? null
        : MatrixImageFile(
            bytes: thumbnailBytes,
            name: '${file.name}.thumbnail',
            mimeType: event.thumbnailInfoMap.tryGet<String>('mimetype'),
          );
    final unsigned = event.unsigned ?? const <String, dynamic>{};
    final replyId = unsigned['in_reply_to'];
    final reply = replyId is String ? await room.getEventById(replyId) : null;
    final extra = unsigned['extra_content'];
    final shrink = unsigned['shrink_image_max_dimension'];
    _failures.remove(id);
    OutgoingEcho.own(room, id);
    await OutgoingEcho.setStatus(room, id, EventStatus.sending);
    final accepted = _enqueue(
      room,
      id,
      () => room.sendFileEvent(
        file,
        txid: id,
        inReplyTo: reply,
        thumbnail: thumbnail,
        shrinkImageMaxDimension: shrink is int ? shrink : null,
        extraContent: extra is Map ? extra.cast<String, dynamic>() : null,
      ),
    );
    return OutgoingMediaTicket(id, accepted);
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
    final key = _roomKey(room);
    final previous = _tails[key] ?? Future<void>.value();
    final job = previous.then((_) async {
      _started();
      try {
        String? eventId;
        try {
          eventId = await UploadProgress.track(id, transport);
        } on MatrixException catch (error) {
          // One automatic retry after a rate limit, with the same txid.
          final wait = error.retryAfterMs;
          if (error.error != MatrixError.M_LIMIT_EXCEEDED || wait == null) {
            rethrow;
          }
          await Future<void>.delayed(Duration(milliseconds: wait + 1000));
          await OutgoingEcho.setStatus(room, id, EventStatus.sending);
          eventId = await UploadProgress.track(id, transport);
        }
        if (eventId == null || !eventId.startsWith(r'$')) {
          throw const _NotConfirmed();
        }
        return eventId;
      } catch (error) {
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
        OutgoingEcho.release(room, id);
        UploadProgress.reset(id);
        _stopped();
      }
    });
    final tail = job.then<void>((_) {}, onError: (Object _) {});
    _tails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[key], tail)) _tails.remove(key);
      }),
    );
    return job;
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

  static void _started() {
    if (_running++ == 0 && ForegroundServices.platformSupported) {
      // Keeps an upload alive when the app goes to the background.
      unawaited(ForegroundServices.startService('send_files'));
    }
  }

  static void _stopped() {
    if (--_running == 0 && ForegroundServices.platformSupported) {
      unawaited(ForegroundServices.stopService('send_files'));
    }
  }
}

class _PrepareFailed implements Exception {
  const _PrepareFailed();
}

class _NotConfirmed implements Exception {
  const _NotConfirmed();
}
