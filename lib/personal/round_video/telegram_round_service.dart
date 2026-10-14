// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fluffychat/pages/chat/round_video_recorder.dart';
import 'package:fluffychat/pages/chat/trust_user_key_dialog.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/media/immediate_media_outbox.dart';
import 'package:fluffychat/personal/media/pending_media_store.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/privacy_transport.dart';
import 'package:fluffychat/personal/storage/personal_store.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart';
import 'package:fluffychat/widgets/matrix.dart';
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
  final _unstaged =
      <String, (RoundSendTarget, RoundEncodingProfile, PreparedRoundMedia)>{};

  Future<void> initialize() async {
    if (_closed) throw const ImmediateMediaRejected('sessionClosed');
    try {
      await (_opening ??= _open());
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

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
      _store = await PendingMediaStore.open(path: path, cipher: cipher);
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
        return client.uploadContent(
          bytes,
          filename: 'media.bin',
          contentType: 'application/octet-stream',
        );
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
        PersonalPrivacy.surfaceForeground &&
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
        !PersonalPrivacy.surfaceForeground ||
        !room.encrypted ||
        !client.encryptionEnabled ||
        !client.fileEncryptionEnabled) {
      throw const ImmediateMediaRejected('encryptionOrSurfaceUnavailable');
    }
    final caps = await TelegramRoomBinding.preflight(room);
    if (caps?.result.allowed != true ||
        caps?.profile == null ||
        (target.silent &&
            caps?.extension.operation('silent_send').allowed != true) ||
        descriptor.outgoingError(caps!.profile!) != null) {
      throw const ImmediateMediaRejected('roundCapabilityUnavailable');
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

  Future<ImmediateMediaResult?> captureAndSend(
    BuildContext context,
    Room room, {
    Event? reply,
    String? threadId,
    String? readUpToEventId,
    bool silent = false,
    required bool Function() stillCurrent,
    RoundCaptureGestureController? gesture,
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
    if (initialBinding == null)
      throw const ImmediateMediaRejected('trustedRoundBridgeRequired');
    if (capturing) return null;
    if (hasUnstaged(room.id))
      throw const ImmediateMediaRejected('saveExistingDraftFirst');
    capturing = true;
    notifyListeners();
    try {
      await initialize();
      if (!context.mounted || !stillCurrent()) return null;
      if (!await _ensureTrustedBridge(context, room)) return null;
      if (!context.mounted || !stillCurrent()) return null;
      final caps = await TelegramRoomBinding.preflight(room);
      final profile = caps?.profile;
      if (caps?.result.allowed != true ||
          (silent &&
              caps?.extension.operation('silent_send').allowed != true) ||
          profile == null ||
          !room.encrypted ||
          !client.encryptionEnabled ||
          !client.fileEncryptionEnabled) {
        throw const ImmediateMediaRejected('trustedRoundBridgeRequired');
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
            'Telegram · ${room.getLocalizedDisplayname()}${silent ? ' · bez powiadomienia' : ''}',
        profile: RoundCaptureProfile(
          maxBytes: maxBytes,
          side: profile.recommendedSide - profile.recommendedSide % 2,
          maxDurationMs: profile.maxDurationMs,
          videoBitrate: profile.videoBitrate,
          audioBitrate: profile.audioBitrate,
        ),
      );
      if (prepared == null) return null;
      _unstaged[frozen.roomId] = (frozen, profile, prepared);
      final staged = await _stage(frozen, profile, prepared);
      if (staged.state == ImmediateMediaState.failed) {
        _unstaged[frozen.roomId] = (frozen, profile, prepared);
        notifyListeners();
        return staged;
      }
      _unstaged.remove(frozen.roomId);
      await prepared.close();
      if (!context.mounted ||
          !stillCurrent() ||
          !PersonalPrivacy.surfaceUnlocked ||
          !PersonalPrivacy.surfaceForeground) {
        notifyListeners();
        return staged;
      }
      final result = await runZoned(
        () => _outbox!.dispatch(staged.actionId),
        zoneValues: {_dispatchEligibilityKey: stillCurrent},
      );
      notifyListeners();
      return result;
    } finally {
      capturing = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<ImmediateMediaResult> _stage(
    RoundSendTarget target,
    RoundEncodingProfile profile,
    PreparedRoundMedia media,
  ) async => _outbox!.stage(
    target: target,
    profile: profile,
    bytes: await media.readBytes(),
    thumbnailBytes: await media.readThumbnailBytes(),
    descriptor: RoundVideoDescriptor(
      sizeBytes: media.sizeBytes,
      width: media.width,
      height: media.height,
      durationMs: media.durationMs,
      videoCodec: media.videoCodec,
      audioCodec: media.audioCodec,
      cornersSanitized: media.cornersSanitized,
    ),
  );

  bool hasUnstaged(String roomId) => _unstaged.containsKey(roomId);
  Future<bool> _ensureTrustedBridge(BuildContext context, Room room) async {
    if (TelegramRoomBinding.of(room) != null) return true;
    final candidate = TelegramRoomBinding.unverifiedCandidate(room);
    if (candidate == null) return false;
    final identity = candidate.identity;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trust your Telegram bridge'),
        content: Text(
          'Confirm this is your configured bridge and Telegram login.\n\nBot: ${identity.senderId}\nLogin: ${identity.accountId}\nNamespace: ${identity.stateKey.isEmpty ? '(pusty)' : identity.stateKey}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Zaufaj temu mostowi'),
          ),
        ],
      ),
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

  Future<void> discardUnstaged(String roomId) async {
    final media = _unstaged.remove(roomId);
    await media?.$3.close();
    notifyListeners();
  }

  Future<void> retryStaging(String roomId) async {
    final media = _unstaged[roomId];
    if (media == null) return;
    await initialize();
    final result = await _stage(media.$1, media.$2, media.$3);
    if (result.state != ImmediateMediaState.failed) {
      _unstaged.remove(roomId);
      await media.$3.close();
    }
    notifyListeners();
  }

  Future<List<PendingMediaSummary>> pendingFor(String roomId) async {
    await initialize();
    return (await _outbox!.recoverSummaries())
        .where(
          (record) =>
              (record.metadata['target'] as Map)['roomId'] == roomId &&
              !{'completed', 'cancelled'}.contains(record.metadata['state']),
        )
        .toList();
  }

  Future<ImmediateMediaResult> retry(
    String actionId, {
    bool Function()? stillCurrent,
  }) async {
    await initialize();
    final result = await runZoned(
      () => _outbox!.dispatch(actionId),
      zoneValues: {_dispatchEligibilityKey: stillCurrent},
    );
    notifyListeners();
    return result;
  }

  Future<void> cancel(String actionId) async {
    await initialize();
    await _outbox!.cancel(actionId);
    notifyListeners();
  }

  Future<void> retainAccepted(String actionId) async {
    await initialize();
    await _outbox!.complete(actionId);
    await _outbox!.purgeAcceptedMedia(actionId);
    notifyListeners();
  }

  @override
  bool get incognito => PersonalPrivacy.policy.incognito;
  @override
  bool canExplicitlyReport(Event event) =>
      !event.redacted &&
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
  Future<void> _reportPlayed(Event event, bool explicit) async {
    final intentAge = Stopwatch()..start();
    final account = client.userID, device = client.deviceID;
    final surfaceGeneration = PersonalPrivacy.surfaceGeneration;
    if ((await mediaState(event))?['expired'] == true) return;
    if (!canExplicitlyReport(event) ||
        intentAge.elapsed >= const Duration(seconds: 20) ||
        client.userID != account ||
        client.deviceID != device ||
        PersonalPrivacy.surfaceGeneration != surfaceGeneration ||
        (!explicit && incognito) ||
        !PersonalPrivacy.surfaceUnlocked ||
        !PersonalPrivacy.surfaceForeground) {
      return;
    }
    final key = '${event.room.id}:${event.eventId}';
    if (_reporting.contains(key) || _reported.contains(key)) return;
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
    if (server == null) return;
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
      if (result != null) _reported.add(key);
    } catch (_) {
      /* No durable public-receipt queue or delayed automatic retry. */
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
          content: Text(
            'The bridge has not confirmed safe forwarding for this message.',
          ),
        ),
      );
      return;
    }
    final origin = TelegramRoomBinding.of(event.room)!;
    final rooms = client.rooms.where((room) {
      final binding = TelegramRoomBinding.of(room);
      return binding?.identity.accountId == origin.identity.accountId &&
          binding
                  ?.capabilities(room)
                  .extension
                  .operation('native_forward')
                  .allowed ==
              true;
    }).toList();
    final selected = await showModalBottomSheet<Room>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Forward in Telegram')),
            for (final room in rooms)
              ListTile(
                title: Text(room.getLocalizedDisplayname()),
                onTap: () => Navigator.pop(context, room),
              ),
            if (rooms.isEmpty)
              const ListTile(title: Text('No destination conversations available.')),
          ],
        ),
      ),
    );
    if (selected == null ||
        !context.mounted ||
        generation != PersonalPrivacy.surfaceGeneration ||
        !identical(Matrix.of(context).client, client))
      return;
    try {
      final result = await forward(event, selected);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result == null
                  ? 'Forwarding outcome unknown. Retrying will keep the same attempt.'
                  : 'Matrix accepted the forward. Telegram confirmation has not arrived.',
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Forwarding was not confirmed. Check the bridge and permissions.',
            ),
          ),
        );
      }
    }
  }

  void _receive(Event event) {
    PersonalPrivacy.forgetObservedControl(event);
    if (event.type != telegramMediaStateEventType || _closed) return;
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
    await client.userDeviceKeysLoading;
    final senderKey = event.originalSource?.content['sender_key'];
    if (client.userDeviceKeys[event.senderId]?.deviceKeys.values.any(
          (device) => device.verified && device.curve25519Key == senderKey,
        ) !=
        true) {
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
    await initialize();
    final key = _stateKey(event);
    if (_states.containsKey(key)) return _states[key];
    return _states[key] = await _store!.getMediaState(
      client.userID!,
      event.room.id,
      event.eventId,
    );
  }

  static Future<void> closeFor(Client client) async {
    final service = _instances.remove(client);
    if (service == null) return;
    service._closed = true;
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
