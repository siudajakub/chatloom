// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/round_video_recorder.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/journal_trust.dart';
import 'package:chatloom/personal/media/immediate_media_outbox.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/pending_media_store.dart';
import 'package:chatloom/personal/media/send_error_text.dart';
import 'package:chatloom/personal/media/upload_progress.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/privacy_transport.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

import 'round_capture_backend.dart';
import 'round_capture_controller.dart';
import 'round_media_preparer.dart';
import 'round_playback_coordinator.dart';
import 'round_playback_receipts.dart';
import 'telegram_room_binding.dart';

class TelegramRoundService extends ChangeNotifier
    implements RoundPlaybackReceipts {
  static final _instances = <Client, TelegramRoundService>{};
  static TelegramRoundService of(Client client) =>
      _instances.putIfAbsent(client, () => TelegramRoundService._(client));
  final Client client;
  TelegramRoundService._(this.client) {
    _subscriptions.add(client.onTimelineEvent.stream.listen(_receive));
    _subscriptions.add(client.onHistoryEvent.stream.listen(_receive));
  }
  final _subscriptions = <StreamSubscription<Event>>[];

  /// Drops the outbox's in-memory draft copies when the app is hidden (lock
  /// screen, background): the drafts stay durable in protected storage.
  AppLifecycleListener? _lifecycle;
  static final _dispatchEligibilityKey = Object();
  bool get _dispatchEligible {
    final test = Zone.current[_dispatchEligibilityKey];
    return test is! bool Function() || test();
  }

  PendingMediaStore? _store;
  PersonalStore? _controls;
  ImmediateMediaOutbox? _outbox;
  Future<void>? _opening;
  bool _closed = false;
  bool capturing = false;
  final _reporting = <String>{};
  final _reported = <String>{};
  final _states = <String, Map<String, dynamic>?>{};
  final _forwardTails = <String, Future<void>>{};
  String _stateKey(Event event) => '${event.room.id}:${event.eventId}';
  Map<String, dynamic>? verifiedMediaStateSnapshot(Event event) =>
      _states[_stateKey(event)];

  /// True once the verified reverse state for [event] was loaded, including a
  /// known absence (no row). Distinguishes "known null" from "not loaded".
  bool isMediaStateKnown(Event event) => _states.containsKey(_stateKey(event));

  /// A recording protected storage refused, per room, with the action ID
  /// its bubble already shows. Memory only: the bubble offers Retry/Delete.
  final _unstaged =
      <
        String,
        (RoundSendTarget, RoundEncodingProfile, PreparedRoundMedia, String)
      >{};

  /// First frames of this session's own rounds, by transaction ID: the
  /// bubble shows the frame from the moment the recorder closes, before
  /// the server has the round (Telegram). Small JPEGs, bounded.
  final _localThumbnails = <String, Uint8List>{};
  static const _localThumbnailLimit = 16;

  /// Actions whose bubble is already being reconciled after a restart.
  final _reconciling = <String>{};

  /// One dispatch at a time per room keeps rounds in recording order while the
  /// composer is already free for the next recording.
  final _roomDispatch = <String, Future<void>>{};

  /// When a room's upload limit was last measured by a passing preflight.
  final _preflightAt = <String, DateTime>{};

  /// A media-config measurement this recent is reused by the dispatch guards
  /// instead of another `/media/config` round trip on the send path. Room
  /// state, trust and capability are still evaluated at every guard.
  static const preflightReuse = Duration(seconds: 30);


  /// The action of an own round bubble (`round-<id>`), or null.
  static String? actionOf(Event event) {
    final txid = event.transactionId ?? event.eventId;
    return RegExp(r'^round-([A-Za-z0-9_-]{1,128})$').firstMatch(txid)?[1];
  }

  /// Whether [event] is an own round the server does not have yet. Such a
  /// bubble shows its first frame and the upload, and cannot be played:
  /// the SDK would look for a cached file that rounds never use.
  bool isUnsentRound(Event event) =>
      event.senderId == client.userID &&
      !event.status.isSent &&
      actionOf(event) != null;

  /// The first frame of this session's own round [event], if known.
  Uint8List? localThumbnail(Event event) {
    final txid = event.transactionId ?? event.eventId;
    return txid.startsWith('round-') ? _localThumbnails[txid] : null;
  }

  void _rememberThumbnail(String transactionId, Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return;
    _localThumbnails.remove(transactionId);
    _localThumbnails[transactionId] = bytes;
    while (_localThumbnails.length > _localThumbnailLimit) {
      _localThumbnails.remove(_localThumbnails.keys.first);
    }
  }

  Future<void> initialize() async {
    if (_closed) throw const ImmediateMediaRejected('sessionClosed');
    if (_opened) return;
    try {
      await (_opening ??= _open());
      _opened = !_closed;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  bool _opened = false;

  Future<void> _open() async {
    final account = client.userID, device = client.deviceID;
    if (account == null || device == null) {
      throw const ImmediateMediaRejected('sessionUnavailable');
    }
    final directory = await getApplicationSupportDirectory();
    final path = '${directory.path}/pending_round_v1.sqlite';
    final lock = await File('$path.init.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final cipher = await getProtectedStorageCipher(
        'pending_round_password_v1',
        requireExisting: await File(path).exists(),
      );
      _store = await PersonalPerformanceProbe.time(
        'db.open.pending',
        () => PendingMediaStore.open(path: path, cipher: cipher),
      );
    } finally {
      await lock.close();
    }
    _controls = await PersonalStore.open();
    for (final value in (await _controls!.readPrefix(
      'round-trust:$account:$device:',
    )).values) {
      if (value['matrix_user_id'] != account ||
          value['device_id'] != device ||
          value['account_id'] is! String ||
          value['state_key'] is! String ||
          value['sender_id'] is! String ||
          value['room_id'] is! String) {
        continue;
      }
      TelegramRoomBinding.installTrustedIdentity(
        client,
        RoundBridgeIdentity(
          accountId: value['account_id'] as String,
          stateKey: value['state_key'] as String,
          senderId: value['sender_id'] as String,
          roomId: value['room_id'] as String,
        ),
      );
    }
    _outbox = ImmediateMediaOutbox(
      accountId: account,
      deviceId: device,
      store: _store!,
      guard: _guard,
      onPhase: (actionId, phase) {
        if (!_closed) notifyListeners();
      },
      encrypt: (bytes, thumbnail) async {
        final video = await MatrixFile(
          bytes: bytes,
          name: 'video_message.mp4',
          mimeType: 'video/mp4',
        ).encrypt();
        final thumb = thumbnail == null
            ? null
            : await MatrixFile(
                bytes: thumbnail,
                name: 'thumbnail.jpg',
                mimeType: 'image/jpeg',
              ).encrypt();
        Map<String, dynamic> descriptor(EncryptedFile value) => {
          'v': 'v2',
          'iv': value.iv,
          'key': {
            'alg': 'A256CTR',
            'ext': true,
            'k': value.k,
            'key_ops': ['encrypt', 'decrypt'],
            'kty': 'oct',
          },
          'hashes': {'sha256': value.sha256},
        };
        return RoundEncryptionResult(
          bytes: video.data,
          fileDescriptor: descriptor(video),
          thumbnailBytes: thumb?.data,
          thumbnailDescriptor: thumb == null ? null : descriptor(thumb),
        );
      },
      upload: (target, bytes, part) async {
        final room = _sourceRoom(target);
        if (!room.encrypted || !client.fileEncryptionEnabled) {
          throw const ImmediateMediaRejected('encryptionUnavailable');
        }
        try {
          return await client.uploadContent(
            bytes,
            filename: 'media.bin',
            contentType: 'application/octet-stream',
          );
        } on PrivacySuppressed {
          // Refused on this device before any byte left it.
          throw const ImmediateMediaRejected('privacySuppressed');
        }
      },
      sendEvent: (target, content, txid) async {
        final room = _sourceRoom(target);
        try {
          return await PersonalPrivacy.withFrozenRoundReadCutoff(
            room,
            target.readUpToEventId,
            () => room.sendEvent(
              content,
              txid: txid,
              displayPendingEvent: true,
              retryOnTransportFailure: false,
            ),
            stillCurrent: () => _targetStillBound(
              target,
              RoundVideoDescriptor.fromContent(content),
            ),
          );
        } on PersonalCapabilityUnavailable {
          throw const ImmediateMediaRejected('bridgeUnavailable');
        } on PrivacySuppressed {
          // Refused on this device before the request was made: definitely
          // not sent (not "unconfirmed").
          throw const ImmediateMediaRejected('privacySuppressed');
        } on MatrixException catch (error) {
          if ({
            'M_FORBIDDEN',
            'M_UNKNOWN_TOKEN',
            'M_UNAUTHORIZED',
            'M_BAD_JSON',
            'M_NOT_JSON',
            'M_TOO_LARGE',
          }.contains(error.errcode)) {
            throw const ImmediateMediaRejected('sendRejected');
          }
          rethrow;
        }
      },
    );
    try {
      _lifecycle ??= AppLifecycleListener(
        onHide: () => _outbox?.releaseStaged(),
      );
    } catch (_) {
      /* no widgets binding: the outbox's own TTL still bounds the copies */
    }
  }

  Room _sourceRoom(RoundSendTarget target) {
    final room = client.getRoomById(target.roomId);
    if (_closed ||
        !_dispatchEligible ||
        target.accountId != client.userID ||
        target.deviceId != client.deviceID ||
        room == null ||
        room.membership != Membership.join) {
      throw const ImmediateMediaRejected('frozenSessionUnavailable');
    }
    return room;
  }

  bool _targetStillBound(
    RoundSendTarget target, [
    RoundVideoDescriptor? descriptor,
  ]) {
    final room = client.getRoomById(target.roomId);
    final binding = room == null ? null : TelegramRoomBinding.of(room);
    if (room == null || binding == null) return false;
    final caps = binding.capabilities(room),
        profile = binding.capabilities(room).profile;
    return !_closed &&
        _dispatchEligible &&
        PersonalPrivacy.surfaceUnlocked &&
        _surfaceVisible &&
        room.encrypted &&
        client.encryptionEnabled &&
        client.fileEncryptionEnabled &&
        room.canSendDefaultMessages &&
        caps.result.allowed &&
        (!target.silent || caps.extension.operation('silent_send').allowed) &&
        profile != null &&
        (descriptor == null ||
            (descriptor.sizeBytes != null &&
                descriptor.sizeBytes! <= profile.maxSizeBytes &&
                descriptor.durationMs != null &&
                descriptor.durationMs! <= profile.maxDurationMs &&
                descriptor.width != null &&
                descriptor.width! <= profile.maxSide &&
                descriptor.width == descriptor.height)) &&
        target.accountId == client.userID &&
        target.deviceId == client.deviceID &&
        target.bridgeAccountId == binding.identity.accountId &&
        target.bridgeStateKey == binding.identity.stateKey &&
        target.bridgeSenderId == binding.identity.senderId;
  }

  Future<void> _guard(
    RoundSendTarget target,
    RoundVideoDescriptor descriptor,
  ) async {
    final room = _sourceRoom(target);
    final binding = TelegramRoomBinding.of(room);
    if (binding == null ||
        target.bridgeAccountId != binding.identity.accountId ||
        target.bridgeStateKey != binding.identity.stateKey ||
        target.bridgeSenderId != binding.identity.senderId) {
      throw const ImmediateMediaRejected('frozenBridgeIdentityChanged');
    }
    if (!PersonalPrivacy.surfaceUnlocked ||
        !_surfaceVisible ||
        !room.encrypted ||
        !client.encryptionEnabled ||
        !client.fileEncryptionEnabled) {
      throw const ImmediateMediaRejected('encryptionOrSurfaceUnavailable');
    }
    final caps = await _preflight(room);
    if (caps?.result.allowed != true ||
        caps?.profile == null ||
        (target.silent &&
            caps?.extension.operation('silent_send').allowed != true) ||
        descriptor.outgoingError(caps!.profile!) != null) {
      // No upload limit because the server could not be asked: a
      // connection problem, not a bridge that refuses rounds.
      throw ImmediateMediaRejected(
        caps?.profile == null &&
                TelegramRoomBinding.uploadLimitUnreachable(client)
            ? 'uploadLimitUnavailable'
            : 'roundCapabilityUnavailable',
      );
    }
    for (final pair in [
      (target.replyEventId, BridgeFeature.reply),
      (target.threadEventId, BridgeFeature.thread),
    ]) {
      if (pair.$1 == null) continue;
      final source = await room.getEventById(pair.$1!);
      if (source == null ||
          source.redacted ||
          RoomCapabilities.forFeature(pair.$2, room, event: source).status !=
              CapabilityStatus.available) {
        throw const ImmediateMediaRejected('frozenRelationUnavailable');
      }
    }
  }

  /// [TelegramRoomBinding.preflight], reusing a passing upload-limit
  /// measurement younger than [preflightReuse]: capabilities are always
  /// re-evaluated from current room state, only the network fetch is skipped.
  Future<RoundBridgeCapabilities?> _preflight(Room room) async {
    final measured = _preflightAt[room.id];
    if (measured != null &&
        DateTime.now().difference(measured) < preflightReuse) {
      final caps = TelegramRoomBinding.of(room)?.capabilities(room);
      if (caps?.result.allowed == true && caps?.profile != null) return caps;
    }
    final caps = await TelegramRoomBinding.preflight(room);
    if (caps?.result.allowed == true && caps?.profile != null) {
      _preflightAt[room.id] = DateTime.now();
    } else {
      _preflightAt.remove(room.id);
    }
    return caps;
  }

  /// Precise, content-free reason (`round:<RoundGateCode>`) for a refused gate.
  static ImmediateMediaRejected _gateRejection(
    Room room, {
    required bool silent,
    bool requireUploadLimit = false,
  }) {
    final gate = TelegramRoomBinding.diagnose(
      room,
      silent: silent,
      requireUploadLimit: requireUploadLimit,
    );
    return ImmediateMediaRejected(
      gate.terminal || gate.code == RoundGateCode.uploadLimitUnknown
          ? 'round:${gate.code.name}'
          : 'round:unconfirmed',
    );
  }

  Future<ImmediateMediaResult?> captureAndSend(
    BuildContext context,
    Room room, {
    Event? reply,
    String? threadId,
    String? readUpToEventId,
    bool silent = false,
    required bool Function() stillCurrent,
    RoundCaptureGestureController? gesture,
    void Function(String eventId)? onAccepted,
  }) async {
    // Freeze before storage, permission dialogs, trust prompts or capture.
    final initialBinding = TelegramRoomBinding.unverifiedCandidate(room);
    final frozen = RoundSendTarget(
      accountId: client.userID ?? '',
      deviceId: client.deviceID ?? '',
      roomId: room.id,
      network: 'telegram',
      bridgeAccountId: initialBinding?.identity.accountId,
      bridgeStateKey: initialBinding?.identity.stateKey,
      bridgeSenderId: initialBinding?.identity.senderId,
      silent: silent,
      replyEventId: reply?.eventId,
      threadEventId: threadId,
      readUpToEventId:
          readUpToEventId ?? PersonalPrivacy.frozenReadCutoff(room),
    );
    if (initialBinding == null) throw _gateRejection(room, silent: silent);
    if (capturing) return null;
    if (hasUnstaged(room.id))
      throw const ImmediateMediaRejected('saveExistingDraftFirst');
    capturing = true;
    notifyListeners();
    // Actions this call reserved in [_staging] (released in `finally`).
    final reserved = <String>{};
    try {
      await initialize();
      if (!context.mounted || !stillCurrent()) return null;
      if (!await _ensureTrustedBridge(context, room)) return null;
      if (!context.mounted || !stillCurrent()) return null;
      // A passing upload-limit measurement younger than [preflightReuse] is
      // reused (capabilities are still read from current room state), so a
      // second round in a row opens the camera without a network round trip.
      final caps = await _preflight(room);
      final profile = caps?.profile;
      if (caps?.result.allowed != true ||
          (silent &&
              caps?.extension.operation('silent_send').allowed != true) ||
          profile == null ||
          !room.encrypted ||
          !client.encryptionEnabled ||
          !client.fileEncryptionEnabled) {
        throw _gateRejection(room, silent: silent, requireUploadLimit: true);
      }
      if (!context.mounted || !stillCurrent()) return null;
      if (gesture != null &&
          !{
            RoundCaptureGesturePhase.holding,
            RoundCaptureGesturePhase.locked,
          }.contains(gesture.phase)) {
        return null;
      }
      if (!await showTrustUserInRoomDialog(context, room)) return null;
      if (!context.mounted || !stillCurrent()) return null;
      final records = await _outbox!.recoverSummaries();
      final used = records.fold(
        0,
        (int total, record) => total + record.storedBytes,
      );
      final budget = (_store!.maxStoreBytes - used - 4 * 1024 * 1024) ~/ 2;
      final maxBytes = budget < profile.maxSizeBytes
          ? budget
          : profile.maxSizeBytes;
      if (maxBytes <= 0) {
        throw const ImmediateMediaRejected('pendingMediaQuota');
      }
      if (!context.mounted || !stillCurrent()) return null;
      final access = await Matrix.of(context).audioMediaAccess;
      if (!context.mounted || !stillCurrent()) return null;
      await RoundPlaybackCoordinator.shared.stopAll(suspend: false);
      if (!context.mounted || !stillCurrent()) return null;
      final prepared = await showRoundVideoRecorder(
        context,
        gesture: gesture,
        mediaAccess: access,
        targetLabel:
            'Telegram · ${room.getLocalizedDisplayname()}${silent ? ' · silent' : ''}',
        profile: RoundCaptureProfile.fromBridge(
          maxBytes: maxBytes,
          maxSide: profile.maxSide,
          recommendedSide: profile.recommendedSide,
          maxDurationMs: profile.maxDurationMs,
          videoBitrate: profile.videoBitrate,
          audioBitrate: profile.audioBitrate,
          highQuality: AppSettings.personalRoundHighQuality.value,
          stabilize: AppSettings.personalRoundStabilization.value,
          noiseReduction: AppSettings.personalRoundNoiseReduction.value,
        ),
      );
      if (prepared == null) return null;
      // The bubble appears as the recorder closes (Telegram): a local echo
      // with the first frame and the frozen reply, sending until the server
      // has the round. Staging, encryption and the upload follow.
      final actionId = _outbox!.newActionId();
      final transactionId = 'round-$actionId';
      // Reserved before the bubble and the durable record exist, until the
      // dispatch owns it: a chat opening meanwhile must not mark it failed.
      _staging.add(actionId);
      reserved.add(actionId);
      final descriptor = _descriptorOf(prepared);
      Uint8List? frame;
      try {
        frame = await prepared.readThumbnailBytes();
      } catch (_) {
        frame = null;
      }
      _rememberThumbnail(transactionId, frame);
      await _showEcho(room, frozen, transactionId, descriptor);
      _unstaged[frozen.roomId] = (frozen, profile, prepared, actionId);
      ImmediateMediaResult staged;
      try {
        staged = await _stage(frozen, profile, prepared, actionId: actionId);
      } catch (_) {
        staged = ImmediateMediaResult(
          actionId: actionId,
          transactionId: transactionId,
          state: ImmediateMediaState.failed,
          errorCode: 'storageUnavailable',
        );
      }
      if (staged.state == ImmediateMediaState.failed) {
        // Protected storage refused it: the bubble says "Not sent" and its
        // Retry saves and sends this in-memory recording again.
        _staging.remove(actionId);
        reserved.remove(actionId);
        await _markFailed(room, transactionId);
        notifyListeners();
        return staged;
      }
      _staging.add(staged.actionId);
      reserved.add(staged.actionId);
      _unstaged.remove(frozen.roomId);
      await prepared.close();
      if (staged.actionId != actionId) {
        // An identical draft already existed: its bubble is the one to keep.
        await _replaceEcho(room, transactionId, staged.actionId);
      }
      // The protected draft is durable: the composer may record the next round
      // while this one uploads (Telegram parity). Sends stay ordered per room.
      capturing = false;
      notifyListeners();
      // Synchronously claims the action in [_dispatching] before the
      // reservation below is released.
      unawaited(_dispatch(room, staged.actionId, onAccepted: onAccepted));
      return staged;
    } finally {
      _staging.removeAll(reserved);
      capturing = false;
      if (!_closed) notifyListeners();
    }
  }

  RoundVideoDescriptor _descriptorOf(PreparedRoundMedia media) =>
      RoundVideoDescriptor(
        sizeBytes: media.sizeBytes,
        width: media.width,
        height: media.height,
        durationMs: media.durationMs,
        videoCodec: media.videoCodec,
        audioCodec: media.audioCodec,
        cornersSanitized: media.cornersSanitized,
      );

  /// Content of the bubble shown before the round is uploaded: the round
  /// marker and size (so it renders as a round of its final size) and the
  /// same relation the final event carries. No file: nothing to download.
  static Map<String, dynamic> roundEchoContent(
    RoundSendTarget target,
    RoundVideoDescriptor descriptor,
  ) => {
    'msgtype': 'm.video',
    'body': 'video_message.mp4',
    'filename': 'video_message.mp4',
    'info': descriptor.matrixInfo,
    if (target.threadEventId != null)
      'm.relates_to': {
        'rel_type': 'm.thread',
        'event_id': target.threadEventId,
        'is_falling_back': target.replyEventId == null,
        'm.in_reply_to': {
          'event_id': target.replyEventId ?? target.threadEventId,
        },
      }
    else if (target.replyEventId != null)
      'm.relates_to': {
        'm.in_reply_to': {'event_id': target.replyEventId},
      },
  };

  Future<void> _showEcho(
    Room room,
    RoundSendTarget target,
    String transactionId,
    RoundVideoDescriptor descriptor, {
    EventStatus status = EventStatus.sending,
  }) async {
    // Never aged into "error" by the SDK while this process works on it.
    if (status.isSending) OutgoingEcho.own(room, transactionId);
    try {
      await OutgoingEcho.show(
        room,
        transactionId: transactionId,
        at: DateTime.now(),
        status: status,
        content: roundEchoContent(target, descriptor),
      );
    } catch (_) {
      // Without the early bubble the SDK still shows one once the round is
      // sent; nothing about the send itself depends on it.
    }
  }

  /// Unsent bubble -> "Not sent · Tap to retry". Never touches a round the
  /// server accepted.
  Future<void> _markFailed(Room room, String transactionId) async {
    OutgoingEcho.release(room, transactionId);
    try {
      await OutgoingEcho.setStatus(room, transactionId, EventStatus.error);
    } catch (_) {}
  }

  Future<void> _replaceEcho(Room room, String from, String actionId) async {
    try {
      final early = await OutgoingEcho.stored(room, from);
      if (early != null && !early.status.isSent) await early.cancelSend();
    } catch (_) {}
    final thumbnail = _localThumbnails[from];
    if (thumbnail != null) _rememberThumbnail('round-$actionId', thumbnail);
    await _ensureEcho(room, actionId);
  }

  /// Sends a durable draft in the background, in recording order per room.
  /// The bubble shows the upload and ends as sent, or as "Not sent" with
  /// Retry. Leaving the chat does not stop it; a locked or backgrounded app
  /// sends nothing (the guard checks that before and after the upload).
  Future<ImmediateMediaResult?> _dispatch(
    Room room,
    String actionId, {
    void Function(String eventId)? onAccepted,
  }) async {
    final transactionId = 'round-$actionId';
    if (_closed || !_dispatching.add(actionId)) return null;
    if (!PersonalPrivacy.surfaceUnlocked || !_surfaceVisible) {
      // Do not keep the multi-megabyte copy in memory; Retry reads storage.
      _outbox!.releaseStaged(actionId);
      await _markFailed(room, transactionId);
      _dispatching.remove(actionId);
      return null;
    }
    OutgoingEcho.own(room, transactionId);
    try {
      final result = await _inRoomOrder(
        room.id,
        () => UploadProgress.track(
          transactionId,
          () => _outbox!.dispatch(actionId),
        ),
      );
      switch (result.state) {
        case ImmediateMediaState.matrixAccepted:
          _unconfirmed.remove(actionId);
          final eventId = result.eventId;
          if (eventId != null) onAccepted?.call(eventId);
          await _finishAccepted(actionId);
        case ImmediateMediaState.cancelled:
          break;
        case ImmediateMediaState.unknown:
          _unconfirmed.add(actionId);
          await _markFailed(room, transactionId);
        case ImmediateMediaState.staged:
        case ImmediateMediaState.failed:
          await _markFailed(room, transactionId);
      }
      return result;
    } catch (_) {
      await _markFailed(room, transactionId);
      return null;
    } finally {
      _dispatching.remove(actionId);
      OutgoingEcho.release(room, transactionId);
      UploadProgress.reset(transactionId);
      if (!_closed) notifyListeners();
    }
  }

  /// Matrix accepted the round: that is "sent". The durable record keeps
  /// its tombstone (no resend) and drops the media bytes.
  Future<void> _finishAccepted(String actionId) async {
    try {
      await _outbox!.complete(actionId);
      await _outbox!.purgeAcceptedMedia(actionId);
    } catch (_) {
      // Retried by [reconcileRoom]; the round is sent either way.
    }
  }

  Future<T> _inRoomOrder<T>(String roomId, Future<T> Function() action) {
    final previous = _roomDispatch[roomId] ?? Future<void>.value();
    final future = previous.then((_) => action());
    final tail = future.then<void>((_) {}, onError: (Object _) {});
    _roomDispatch[roomId] = tail;
    return future.whenComplete(() {
      if (identical(_roomDispatch[roomId], tail)) _roomDispatch.remove(roomId);
    });
  }

  Future<ImmediateMediaResult> _stage(
    RoundSendTarget target,
    RoundEncodingProfile profile,
    PreparedRoundMedia media, {
    String? actionId,
  }) async => _outbox!.stage(
    target: target,
    profile: profile,
    bytes: await media.readBytes(),
    thumbnailBytes: await media.readThumbnailBytes(),
    reservedActionId: actionId,
    // The plaintext draft commits first; SDK encryption runs alongside it and
    // its ciphertext is committed by dispatch while the upload runs.
    encryptWhileStaging: true,
    descriptor: _descriptorOf(media),
  );

  bool hasUnstaged(String roomId) => _unstaged.containsKey(roomId);
  Future<bool> _ensureTrustedBridge(BuildContext context, Room room) async {
    if (TelegramRoomBinding.of(room) != null) return true;
    final candidate = TelegramRoomBinding.unverifiedCandidate(room);
    if (candidate == null) return false;
    final identity = candidate.identity;
    final accepted = await showNotionConfirmDialog(
      context: context,
      title: 'Trust your Telegram bridge',
      message:
          'Confirm this is your configured bridge and Telegram login.\n\nBot: ${identity.senderId}\nLogin: ${identity.accountId}\nNamespace: ${identity.stateKey.isEmpty ? '(empty)' : identity.stateKey}',
      cancelLabel: 'Cancel',
      confirmLabel: 'Trust this bridge',
    );
    if (accepted != true || !context.mounted) return false;
    final current = TelegramRoomBinding.unverifiedCandidate(room);
    if (current == null ||
        current.identity.senderId != identity.senderId ||
        current.identity.accountId != identity.accountId ||
        current.identity.stateKey != identity.stateKey) {
      return false;
    }
    final key = sha256.convert(
      utf8.encode(
        jsonEncode([identity.stateKey, identity.accountId, identity.senderId]),
      ),
    );
    await _controls!
        .put('round-trust:${client.userID}:${client.deviceID}:$key', {
          'matrix_user_id': client.userID,
          'account_id': identity.accountId,
          'device_id': client.deviceID,
          'state_key': identity.stateKey,
          'sender_id': identity.senderId,
          'room_id': identity.roomId,
        });
    TelegramRoomBinding.installTrustedIdentity(client, identity);
    return true;
  }

  (RoundSendTarget, RoundEncodingProfile, PreparedRoundMedia, String)?
  _unstagedFor(String actionId) {
    for (final entry in _unstaged.values) {
      if (entry.$4 == actionId) return entry;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _metadataOf(String actionId) async {
    for (final record in await _outbox!.recoverSummaries()) {
      if (record.actionId == actionId) return record.metadata;
    }
    return null;
  }

  Future<Room?> _roomOf(String actionId) async {
    final target = (await _metadataOf(actionId))?['target'];
    return target is Map && target['roomId'] is String
        ? client.getRoomById(target['roomId'] as String)
        : null;
  }

  /// Retry from a round's bubble ("Not sent · Tap to retry"): the same
  /// durable attempt and transaction ID, so it is never sent twice. A
  /// recording protected storage refused is saved first. Returns the
  /// dispatch result, or null when nothing could be started.
  Future<ImmediateMediaResult?> retry(
    String actionId, {
    Room? room,
    bool Function()? stillCurrent,
  }) async {
    await initialize();
    if (stillCurrent?.call() == false) return null;
    final unstaged = _unstagedFor(actionId);
    final target =
        room ??
        (unstaged == null ? null : client.getRoomById(unstaged.$1.roomId)) ??
        await _roomOf(actionId);
    if (target == null) return null;
    final transactionId = 'round-$actionId';
    try {
      await OutgoingEcho.setStatus(target, transactionId, EventStatus.sending);
    } catch (_) {}
    if (unstaged == null) return _dispatch(target, actionId);
    // Staging again: reconcile leaves the bubble alone until dispatch owns it.
    _staging.add(actionId);
    try {
      return await _retryUnstaged(target, actionId, unstaged);
    } finally {
      _staging.remove(actionId);
    }
  }

  Future<ImmediateMediaResult?> _retryUnstaged(
    Room target,
    String actionId,
    (RoundSendTarget, RoundEncodingProfile, PreparedRoundMedia, String)
    unstaged,
  ) async {
    final transactionId = 'round-$actionId';
    ImmediateMediaResult staged;
    try {
      staged = await _stage(
        unstaged.$1,
        unstaged.$2,
        unstaged.$3,
        actionId: actionId,
      );
    } catch (_) {
      staged = ImmediateMediaResult(
        actionId: actionId,
        transactionId: transactionId,
        state: ImmediateMediaState.failed,
        errorCode: 'storageUnavailable',
      );
    }
    if (staged.state == ImmediateMediaState.failed) {
      await _markFailed(target, transactionId);
      notifyListeners();
      return staged;
    }
    _unstaged.remove(unstaged.$1.roomId);
    await unstaged.$3.close();
    if (staged.actionId != actionId) {
      await _replaceEcho(target, transactionId, staged.actionId);
    }
    return _dispatch(target, staged.actionId);
  }

  /// Delete from a round's bubble: retires the attempt (it is never sent)
  /// and drops its local copy. The caller removes the bubble itself.
  Future<void> discard(String actionId) async {
    await initialize();
    final unstaged = _unstagedFor(actionId);
    if (unstaged != null) {
      _unstaged.remove(unstaged.$1.roomId);
      await unstaged.$3.close();
    }
    await _outbox!.discard(actionId);
    _unconfirmed.remove(actionId);
    _localThumbnails.remove('round-$actionId');
    notifyListeners();
  }

  /// Why the round [actionId] was not sent, in plain language, for the
  /// bubble's Retry/Delete sheet.
  // TODO(matrix-errors): use the shared Matrix error text for refusals.
  Future<String> failureReason(String actionId) async {
    const same = 'Retry sends the same attempt, so it is never sent twice.';
    if (_unstagedFor(actionId) != null) {
      return 'The round video could not be saved on this device. Retry '
          'saves and sends it; it is lost if ChatLoom closes first.';
    }
    await initialize();
    final metadata = await _metadataOf(actionId);
    if (metadata == null) {
      return 'This round video is no longer on this device. Delete it and '
          'record it again.';
    }
    if ({'unknown', 'inFlight'}.contains(metadata['state'])) {
      return 'ChatLoom could not confirm that the server received this '
          'round video. $same';
    }
    final code = metadata['errorCode'];
    if (code is String && code.startsWith('round:')) {
      return 'The Telegram bridge does not accept round videos right now. '
          '$same';
    }
    return switch (code) {
      'encryptionOrSurfaceUnavailable' =>
        'ChatLoom was locked or in the background, so the round video was '
            'not sent. Retry sends it now.',
      'roundCapabilityUnavailable' || 'encryptionUnavailable' =>
        'The Telegram bridge does not accept round videos right now. $same',
      'frozenRelationUnavailable' =>
        'The message you replied to is no longer available.',
      'frozenBridgeIdentityChanged' =>
        'The Telegram bridge of this chat changed. Delete the round video '
            'and record it again.',
      'sendRejected' => 'The server did not accept this round video.',
      'uploadLimitUnavailable' =>
        'ChatLoom could not reach the server to check the upload limit. '
            'Check your connection and retry. $same',
      'privacySuppressed' =>
        'ChatLoom was locked or signed out, so the round video was not '
            'sent. Retry sends it now.',
      'preDispatchFailure' =>
        'The upload did not finish. Check your connection and retry. $same',
      _ => 'The round video was not sent. $same',
    };
  }

  /// Actions dispatched (or queued for dispatch) by this process.
  final _dispatching = <String>{};

  /// Actions whose bubble or durable draft is being created (recorded, or
  /// saved again by Retry) and not yet dispatched. [reconcileRoom] leaves
  /// them alone, so a chat opening meanwhile never says "Not sent" while
  /// the round is about to upload.
  final _staging = <String>{};

  /// Sends continue while ChatLoom is on screen but not focused (`inactive`:
  /// the notification shade, a permission or biometric dialog), as
  /// Telegram's do. Hidden, paused or locked stops them.
  static bool get _surfaceVisible {
    if (PersonalPrivacy.surfaceForeground) return true;
    try {
      return WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.inactive;
    } catch (_) {
      return false;
    }
  }

  /// Attempts whose server response was lost: their copy arriving in sync
  /// confirms them ([_receive]).
  final _unconfirmed = <String>{};

  /// Brings the bubbles of [room]'s own rounds in line with the durable
  /// queue when the chat opens: accepted rounds are finished (their local
  /// copy dropped), an unsent bubble no longer uploading says "Not sent"
  /// with Retry, and a draft whose bubble was lost gets it back. Never
  /// sends anything by itself.
  Future<void> reconcileRoom(Room room) async {
    if (_closed) return;
    await initialize();
    final records = await _outbox!.recoverSummaries();
    for (final record in records) {
      final target = record.metadata['target'];
      final id = record.actionId;
      if (target is! Map ||
          target['roomId'] != room.id ||
          _dispatching.contains(id) ||
          _staging.contains(id) ||
          !_reconciling.add(id)) {
        continue;
      }
      try {
        switch (record.metadata['state']) {
          case 'matrixAccepted':
            await _finishAccepted(id);
          case 'completed':
            if (record.metadata['bytesReleased'] == true) {
              await _outbox!.forgetCompleted(id);
            } else {
              await _outbox!.purgeAcceptedMedia(id);
            }
          case 'cancelled':
            break;
          default:
            await _reconcileUnsent(room, record);
        }
      } catch (_) {
        // The next chat opening tries again.
      } finally {
        _reconciling.remove(id);
      }
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _reconcileUnsent(Room room, PendingMediaSummary record) async {
    final id = record.actionId;
    final transactionId = 'round-$id';
    final unknown = {'unknown', 'inFlight'}.contains(record.metadata['state']);
    if (unknown) _unconfirmed.add(id);
    final echo = await OutgoingEcho.stored(room, transactionId);
    if (echo != null) {
      // Nothing uploads it in this process: say so, with Retry.
      if (echo.status.isSending) await _markFailed(room, transactionId);
      return;
    }
    if (unknown) {
      // The server's copy may have replaced the bubble already.
      final accepted = await _acceptedCopy(room, transactionId);
      if (accepted != null) {
        if (await _outbox!.confirmAccepted(id, accepted)) {
          _unconfirmed.remove(id);
          await _finishAccepted(id);
        }
        return;
      }
    }
    await _ensureEcho(room, id, status: EventStatus.error);
  }

  /// The accepted event of [transactionId] among [room]'s recent stored
  /// events, if the server's copy already arrived.
  Future<String?> _acceptedCopy(Room room, String transactionId) async {
    try {
      final events = await client.database.getEventList(room, limit: 200);
      for (final event in events) {
        if (event.transactionId == transactionId &&
            event.eventId.startsWith(r'$')) {
          return event.eventId;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Shows the bubble of a durable draft that has none (e.g. lost with a
  /// cleared timeline cache).
  Future<void> _ensureEcho(
    Room room,
    String actionId, {
    EventStatus status = EventStatus.sending,
  }) async {
    final transactionId = 'round-$actionId';
    if (await OutgoingEcho.stored(room, transactionId) != null) return;
    final metadata = await _metadataOf(actionId);
    final target = metadata?['target'], descriptor = metadata?['descriptor'];
    if (target is! Map || descriptor is! Map) return;
    await _showEcho(
      room,
      RoundSendTarget.fromJson(Map<String, dynamic>.from(target)),
      transactionId,
      RoundVideoDescriptor.fromJson(Map<String, dynamic>.from(descriptor)),
      status: status,
    );
  }

  Future<void> _confirmFromSync(String actionId, String eventId) async {
    try {
      await initialize();
      if (await _outbox!.confirmAccepted(actionId, eventId)) {
        await _finishAccepted(actionId);
      }
      _unconfirmed.remove(actionId);
    } catch (_) {}
  }

  @override
  bool get incognito => PersonalPrivacy.policy.incognito;
  @override
  bool canExplicitlyReport(Event event) =>
      !event.redacted &&
      // Sent once: the action disappears after success (CC-20).
      !_reported.contains('${event.room.id}:${event.eventId}') &&
      verifiedMediaStateSnapshot(event)?['expired'] != true &&
      event.senderId != client.userID &&
      event.room.client == client &&
      event.eventId.startsWith(r'$') &&
      RoundVideoDescriptor.fromContent(event.content) != null &&
      RoundMediaPolicy.fromContent(event.content).canPlay &&
      TelegramRoomBinding.of(event.room)
              ?.capabilities(event.room)
              .extension
              .operation('playback_receipts')
              .allowed ==
          true;
  @override
  Future<void> onUserStartedPlaying(Event event) async {
    if (!incognito) await _reportPlayed(event, false);
  }

  @override
  Future<void> explicitlyReportPlayed(Event event) =>
      _reportPlayed(event, true);

  /// Sends one playback receipt. Automatic reports end silently when a gate
  /// closes; an explicit one (the user tapped "Send playback receipt")
  /// throws instead, so the UI can say it was not sent (CC-20).
  Future<void> _reportPlayed(Event event, bool explicit) async {
    void notSent() {
      if (explicit) throw StateError('Playback receipt not sent');
    }

    final intentAge = Stopwatch()..start();
    final account = client.userID, device = client.deviceID;
    final surfaceGeneration = PersonalPrivacy.surfaceGeneration;
    if ((await mediaState(event))?['expired'] == true) return notSent();
    if (!canExplicitlyReport(event) ||
        intentAge.elapsed >= const Duration(seconds: 20) ||
        client.userID != account ||
        client.deviceID != device ||
        PersonalPrivacy.surfaceGeneration != surfaceGeneration ||
        (!explicit && incognito) ||
        !PersonalPrivacy.surfaceUnlocked ||
        !PersonalPrivacy.surfaceForeground) {
      return notSent();
    }
    final key = '${event.room.id}:${event.eventId}';
    if (_reported.contains(key)) return;
    if (_reporting.contains(key)) return notSent();
    final binding = TelegramRoomBinding.of(event.room)!;
    final requestId = const Uuid().v4();
    final currentIncognito = incognito;
    final content = <String, dynamic>{
      'version': 1,
      'request_id': requestId,
      'created_at_ms': DateTime.now().millisecondsSinceEpoch,
      'source': {
        'account_id': binding.identity.accountId,
        'room_id': event.room.id,
        'event_id': event.eventId,
      },
      'manual': true,
      'incognito': currentIncognito,
      'explicit_grant': explicit,
    };
    final server = client.baseUri;
    if (server == null) return notSent();
    _reporting.add(key);
    try {
      final result = await withMediaPlayedGrant(
        roomId: event.room.id,
        eventId: event.eventId,
        sourceAccountId: binding.identity.accountId,
        requestId: requestId,
        server: server,
        explicit: explicit,
        isCurrent: () =>
            !_closed &&
            client.userID == account &&
            client.deviceID == device &&
            PersonalPrivacy.surfaceGeneration == surfaceGeneration &&
            PersonalPrivacy.surfaceUnlocked &&
            PersonalPrivacy.surfaceForeground &&
            !event.redacted &&
            canExplicitlyReport(event),
        action: () => event.room.sendEvent(
          content,
          type: telegramMediaPlayedEventType,
          txid: 'round-play-$requestId',
          displayPendingEvent: false,
          retryOnTransportFailure: false,
        ),
      );
      if (result != null) {
        _reported.add(key);
        notifyListeners();
      } else {
        notSent();
      }
    } catch (_) {
      /* No durable public-receipt queue or delayed automatic retry. */
      if (explicit) rethrow;
    } finally {
      _reporting.remove(key);
    }
  }

  Future<String?> forward(Event source, Room destination) async {
    final account = client.userID, device = client.deviceID;
    final generation = PersonalPrivacy.surfaceGeneration;
    final origin = TelegramRoomBinding.of(source.room)?.identity;
    final target = TelegramRoomBinding.of(destination)?.identity;
    bool sameIdentity(
      RoundBridgeIdentity? current,
      RoundBridgeIdentity? frozen,
    ) =>
        current != null &&
        frozen != null &&
        current.accountId == frozen.accountId &&
        current.stateKey == frozen.stateKey &&
        current.senderId == frozen.senderId;
    bool stillCurrent() =>
        !_closed &&
        client.userID == account &&
        client.deviceID == device &&
        PersonalPrivacy.surfaceGeneration == generation &&
        PersonalPrivacy.surfaceUnlocked &&
        PersonalPrivacy.surfaceForeground &&
        identical(source.room.client, client) &&
        identical(destination.client, client) &&
        sameIdentity(TelegramRoomBinding.of(source.room)?.identity, origin) &&
        sameIdentity(TelegramRoomBinding.of(destination)?.identity, target) &&
        canNativeForward(source) &&
        TelegramRoomBinding.of(destination)
                ?.capabilities(destination)
                .extension
                .operation('native_forward')
                .allowed ==
            true;
    if (!stillCurrent())
      throw const ImmediateMediaRejected('frozenSessionUnavailable');
    final key = '${source.room.id}:${source.eventId}:${destination.id}';
    final old = _forwardTails[key] ?? Future<void>.value();
    final future = old.then((_) => _forward(source, destination, stillCurrent));
    final tail = future.then<void>((_) {}, onError: (Object _) {});
    _forwardTails[key] = tail;
    try {
      return await future;
    } finally {
      if (identical(_forwardTails[key], tail)) _forwardTails.remove(key);
    }
  }

  Future<String?> _forward(
    Event source,
    Room destination,
    bool Function() stillCurrent,
  ) async {
    if (!stillCurrent())
      throw const ImmediateMediaRejected('frozenSessionUnavailable');
    await initialize();
    if (!stillCurrent())
      throw const ImmediateMediaRejected('frozenSessionUnavailable');
    if (!identical(source.room.client, client) ||
        !identical(destination.client, client)) {
      throw const ImmediateMediaRejected('crossAccountForwardUnavailable');
    }
    if ((await mediaState(source))?['expired'] == true) {
      throw const ImmediateMediaRejected('sourceExpired');
    }
    final origin = TelegramRoomBinding.of(source.room);
    final target = TelegramRoomBinding.of(destination);
    if (origin == null ||
        target == null ||
        origin.identity.accountId != target.identity.accountId ||
        !RoundMediaPolicy.fromContent(source.content).canForward ||
        !target
            .capabilities(destination)
            .extension
            .operation('native_forward')
            .allowed) {
      throw const ImmediateMediaRejected('nativeForwardUnavailable');
    }
    final controlKey =
        'round-control:${client.userID}:${source.room.id}:${source.eventId}:${destination.id}';
    final existing = await _controls!.get(controlKey);
    if (existing != null && existing['device_id'] != client.deviceID) {
      throw const ImmediateMediaRejected('differentSessionNeedsReconciliation');
    }
    if (existing?['state'] == 'matrixAccepted') {
      return existing!['event_id'] as String?;
    }
    final id = existing?['request_id'] as String? ?? const Uuid().v4();
    final content = existing?['content'] is Map
        ? Map<String, dynamic>.from(existing!['content'] as Map)
        : <String, dynamic>{
            'version': 1,
            'request_id': id,
            'created_at_ms': DateTime.now().millisecondsSinceEpoch,
            'source': {
              'account_id': origin.identity.accountId,
              'room_id': source.room.id,
              'event_id': source.eventId,
            },
            'destination': {
              'account_id': target.identity.accountId,
              'room_id': destination.id,
            },
            'preserve_author': true,
            'silent': false,
            'schedule_date': 0,
          };
    final record = {
      'request_id': id,
      'device_id': client.deviceID,
      'content': content,
      'state': 'unknown',
    };
    await _controls!.put(controlKey, record);
    if (!stillCurrent())
      throw const ImmediateMediaRejected('frozenSessionUnavailable');
    final accepted = await PersonalPrivacy.withFrozenRoundReadCutoff(
      destination,
      null,
      () => destination.sendEvent(
        content,
        type: telegramMediaForwardEventType,
        txid: 'round-forward-$id',
        displayPendingEvent: false,
        retryOnTransportFailure: false,
      ),
      stillCurrent: stillCurrent,
    );
    await _controls!.put(controlKey, {
      ...record,
      'state': accepted == null ? 'unknown' : 'matrixAccepted',
      'event_id': accepted,
    });
    return accepted;
  }

  bool canNativeForward(Event event) {
    final binding = TelegramRoomBinding.of(event.room);
    return binding != null &&
        event.room.client == client &&
        !event.redacted &&
        verifiedMediaStateSnapshot(event)?['expired'] != true &&
        event.eventId.startsWith(r'$') &&
        RoundVideoDescriptor.fromContent(event.content) != null &&
        RoundMediaPolicy.fromContent(event.content).canForward &&
        binding
            .capabilities(event.room)
            .extension
            .operation('native_forward')
            .allowed;
  }

  Future<void> showForwardPicker(BuildContext context, Event event) async {
    final generation = PersonalPrivacy.surfaceGeneration;
    if (!canNativeForward(event)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This round video cannot be forwarded in Telegram.'),
        ),
      );
      return;
    }
    final origin = TelegramRoomBinding.of(event.room)!;
    bool accepts(Room room) {
      final binding = TelegramRoomBinding.of(room);
      return binding?.identity.accountId == origin.identity.accountId &&
          binding
                  ?.capabilities(room)
                  .extension
                  .operation('native_forward')
                  .allowed ==
              true;
    }

    // The forward sheet of every other message, narrowed to the chats of
    // this Telegram login that take native forwards; one chat per round.
    // Matrix acceptance is "forwarded"; the bridge's own failure comes back
    // as a bridge notice.
    await showNotionSheet<void>(
      context: context,
      title: 'Forward in Telegram',
      builder: (sheet) => ForwardSheet(
        personal: PersonalClient.of(client),
        multiple: false,
        accepts: accepts,
        emptyMessage: 'No Telegram chat here takes forwarded round videos.',
        send: (sheet, room) async {
          if (generation != PersonalPrivacy.surfaceGeneration ||
              !identical(Matrix.of(sheet).client, client)) {
            return 'Not sent.';
          }
          try {
            final result = await forward(event, room);
            return result == null
                ? 'Couldn’t confirm the forward. Try again; it is never sent twice.'
                : null;
          } on ImmediateMediaRejected {
            return 'Telegram does not allow forwarding this round video there.';
          } catch (error) {
            return 'Couldn’t forward. ${sendErrorText(error)}';
          }
        },
      ),
    );
  }

  void _receive(Event event) {
    PersonalPrivacy.forgetObservedControl(event);
    if (_closed) return;
    if (event.senderId == client.userID &&
        event.status.isSent &&
        event.eventId.startsWith(r'$')) {
      final id = actionOf(event);
      // A lost response: the server's copy confirms the attempt.
      if (id != null && _unconfirmed.contains(id)) {
        unawaited(_confirmFromSync(id, event.eventId));
      }
    }
    if (event.type != telegramMediaStateEventType) return;
    unawaited(_applyState(event).catchError((Object _) {}));
  }

  Future<void> _applyState(Event event) async {
    final binding = TelegramRoomBinding.of(event.room);
    final data = event.content;
    final sourceId = data['source_event_id'];
    if (binding == null ||
        event.redacted ||
        event.originalSource?.type != EventTypes.Encrypted ||
        event.senderId != binding.identity.senderId ||
        data['version'] != 1 ||
        data['account_id'] != binding.identity.accountId ||
        data['room_id'] != event.room.id ||
        data['bridge_state_key'] != binding.identity.stateKey ||
        sourceId is! String ||
        !sourceId.startsWith(r'$') ||
        data['revision'] is! int ||
        (data['revision'] as int) <= 0 ||
        data['media_unread'] is! bool ||
        data['expired'] is! bool) {
      return;
    }
    // A verified bridge device must have encrypted it: checked through the
    // megolm session that decrypted it, not the envelope sender_key.
    if (!await MegolmTrustSnapshot.verify(event, userId: event.senderId)) {
      return;
    }
    final source = await event.room.getEventById(sourceId);
    if (source == null ||
        source.redacted ||
        RoundVideoDescriptor.fromContent(source.content) == null) {
      return;
    }
    await initialize();
    if (await _store!.applyMediaState(
      client.userID!,
      event.room.id,
      sourceId,
      data['revision'] as int,
      data,
    )) {
      _states['${event.room.id}:$sourceId'] = await _store!.getMediaState(
        client.userID!,
        event.room.id,
        sourceId,
      );
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> mediaState(Event event) async {
    final key = _stateKey(event);
    if (_states.containsKey(key)) return _states[key];
    await initialize();
    if (_states.containsKey(key)) return _states[key];
    return _states[key] = await _store!.getMediaState(
      client.userID!,
      event.room.id,
      event.eventId,
    );
  }

  /// Loads reverse media states for many events with one batched query, so
  /// visible rounds and the prefetcher do not issue one query per row. Does not
  /// notify: rows read the cached state through [mediaState].
  Future<void> preloadMediaStates(Room room, Iterable<String> eventIds) async {
    final missing = {
      for (final id in eventIds)
        if (id.startsWith(r'$') && !_states.containsKey('${room.id}:$id')) id,
    };
    if (missing.isEmpty) return;
    await initialize();
    final found = await _store!.getMediaStates(
      client.userID!,
      room.id,
      missing,
    );
    for (final id in missing) {
      // A newer verified state may have arrived while the query ran.
      _states.putIfAbsent('${room.id}:$id', () => found[id]);
    }
  }

  static Future<void> closeFor(Client client) async {
    final service = _instances.remove(client);
    if (service == null) return;
    service._closed = true;
    service._lifecycle?.dispose();
    service._lifecycle = null;
    service._outbox?.releaseStaged();
    for (final sub in service._subscriptions) {
      await sub.cancel();
    }
    for (final draft in service._unstaged.values) {
      await draft.$3.close();
    }
    service._unstaged.clear();
    await service._store?.close();
    await service._controls?.close();
    service.dispose();
  }
}
