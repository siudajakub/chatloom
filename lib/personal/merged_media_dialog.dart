import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_selector.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart' show FileType;
import 'package:just_audio/just_audio.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

class MergedMediaResult {
  final bool accepted;
  final String caption;
  final DateTime? acceptedAt;
  final String? acceptedEventId;
  const MergedMediaResult({
    required this.accepted,
    this.caption = '',
    this.acceptedAt,
    this.acceptedEventId,
  });
}

class _PreparedMedia {
  final MatrixFile file;
  final BridgeFeature feature;
  final BridgeMediaRequest measurements;
  final String transactionId = const Uuid().v4();
  _PreparedMedia(this.file, this.feature, this.measurements);
}

/// Source-bound sibling of the upstream file dialog. The shared picker and
/// trust flow are reused; this dialog additionally preserves a source reply.
Future<MergedMediaResult> showMergedMediaDialog(
  BuildContext context,
  PersonalClient personal,
  SendTarget frozen, {
  Event? replyTo,
  String caption = '',
  List<XFile>? pickedFiles,
  FileType pickerType = FileType.any,
  bool Function()? isCurrent,
  void Function(String eventId, DateTime acceptedAt)? onAccepted,
}) async {
  final room = personal.client.getRoomById(frozen.conversation.roomId);
  if (room == null ||
      frozen.conversation.accountId != personal.client.userID ||
      !room.canSendDefaultMessages) {
    throw const PersonalCapabilityUnavailable(
      'The selected source is unavailable. Choose a network before attaching a file.',
    );
  }
  if (replyTo != null &&
      (replyTo.room.id != room.id ||
          replyTo.room.client != personal.client ||
          replyTo.redacted)) {
    throw const PersonalCapabilityUnavailable(
      'An attachment can only reply to a message in the selected network.',
    );
  }
  if (isCurrent?.call() == false)
    return const MergedMediaResult(accepted: false);
  final files =
      pickedFiles ??
      await selectFiles(
        context,
        title: 'Attachments for the selected network',
        allowMultiple: true,
        type: pickerType,
      );
  if (files.isEmpty || !context.mounted || isCurrent?.call() == false) {
    return const MergedMediaResult(accepted: false);
  }
  if (files.length > 5) {
    throw const PersonalCapabilityUnavailable(
      'Select up to five attachments at a time.',
    );
  }
  final prepared = <_PreparedMedia>[];
  var total = 0;
  var actualTotal = 0;
  for (final file in files) {
    if (!context.mounted || isCurrent?.call() == false)
      return const MergedMediaResult(accepted: false);
    final length = await file.length();
    total += length;
    if (length <= 0 || length > 25 * 1024 * 1024 || total > 50 * 1024 * 1024) {
      throw const PersonalCapabilityUnavailable(
        'Choose files up to 25 MB each and 50 MB in total.',
      );
    }
    final media = await _prepare(file);
    actualTotal += media.file.size;
    if (actualTotal > 50 * 1024 * 1024) {
      throw const PersonalCapabilityUnavailable(
        'Choose attachments up to 50 MB in total.',
      );
    }
    _validate(room, media, '');
    prepared.add(media);
  }
  if (!context.mounted || isCurrent?.call() == false)
    return const MergedMediaResult(accepted: false);
  return await showDialog<MergedMediaResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MergedMediaDialog(
          room: room,
          frozen: frozen,
          files: prepared,
          replyTo: replyTo,
          initialCaption: caption,
          onAccepted: onAccepted,
          isCurrent: isCurrent,
        ),
      ) ??
      const MergedMediaResult(accepted: false);
}

Future<_PreparedMedia> _prepare(XFile picked) async {
  final bytes = await picked.readAsBytes();
  if (bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
    throw const PersonalCapabilityUnavailable(
      'The file changed or exceeds 25 MB. Select it again.',
    );
  }
  final mime =
      lookupMimeType(picked.name, headerBytes: bytes) ??
      picked.mimeType ??
      'application/octet-stream';
  final kind = MatrixFile.msgTypeFromMime(mime);
  int? width, height, duration;
  if (kind == MessageTypes.Image) {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      width = descriptor.width;
      height = descriptor.height;
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }
  if (kind == MessageTypes.Video) {
    try {
      final info = await LightCompressor()
          .getMediaInfo(picked.path)
          .timeout(const Duration(seconds: 5));
      width = info.width;
      height = info.height;
      duration = info.duration?.inMilliseconds;
    } catch (_) {}
  }
  if (kind == MessageTypes.Audio) {
    final player = AudioPlayer();
    try {
      final uri = Uri.tryParse(picked.path);
      if (uri != null && {'', 'file', 'content', 'blob'}.contains(uri.scheme)) {
        duration =
            (await (uri.scheme.isEmpty
                        ? player.setFilePath(picked.path)
                        : player.setUrl(picked.path))
                    .timeout(const Duration(seconds: 5)))
                ?.inMilliseconds;
      }
    } catch (_) {
    } finally {
      await player.dispose();
    }
  }
  final matrixFile = switch (kind) {
    MessageTypes.Image => MatrixImageFile(
      bytes: bytes,
      name: picked.name,
      mimeType: mime,
      width: width,
      height: height,
    ),
    MessageTypes.Video => MatrixVideoFile(
      bytes: bytes,
      name: picked.name,
      mimeType: mime,
      width: width,
      height: height,
      duration: duration,
    ),
    MessageTypes.Audio => MatrixAudioFile(
      bytes: bytes,
      name: picked.name,
      mimeType: mime,
      duration: duration,
    ),
    _ => MatrixFile(bytes: bytes, name: picked.name, mimeType: mime),
  };
  final feature = switch (kind) {
    MessageTypes.Image => BridgeFeature.image,
    MessageTypes.Video => BridgeFeature.video,
    MessageTypes.Audio => BridgeFeature.audio,
    _ => BridgeFeature.upload,
  };
  return _PreparedMedia(
    matrixFile,
    feature,
    BridgeMediaRequest(
      mimeType: mime,
      sizeBytes: bytes.length,
      width: width,
      height: height,
      durationSeconds: duration == null ? null : duration / 1000,
    ),
  );
}

CapabilityResult _validate(Room room, _PreparedMedia prepared, String caption) {
  final media = prepared.measurements;
  final result = RoomCapabilities.forFeature(
    prepared.feature,
    room,
    media: BridgeMediaRequest(
      mimeType: media.mimeType,
      sizeBytes: media.sizeBytes,
      width: media.width,
      height: media.height,
      durationSeconds: media.durationSeconds,
      caption: caption.isEmpty ? null : caption,
    ),
  );
  if (result.status == CapabilityStatus.unavailable) {
    throw PersonalCapabilityUnavailable(result.reason);
  }
  return result;
}

class _MergedMediaDialog extends StatefulWidget {
  final Room room;
  final SendTarget frozen;
  final List<_PreparedMedia> files;
  final Event? replyTo;
  final String initialCaption;
  final void Function(String eventId, DateTime acceptedAt)? onAccepted;
  final bool Function()? isCurrent;
  const _MergedMediaDialog({
    required this.room,
    required this.frozen,
    required this.files,
    required this.initialCaption,
    this.replyTo,
    this.onAccepted,
    this.isCurrent,
  });
  @override
  State<_MergedMediaDialog> createState() => _MergedMediaDialogState();
}

class _MergedMediaDialogState extends State<_MergedMediaDialog> {
  late final caption = TextEditingController(text: widget.initialCaption);
  late final files = [...widget.files];
  bool sending = false, uncertain = false;
  int accepted = 0;
  DateTime? acceptedAt;
  String? acceptedEventId;
  String? problem;
  String? attemptedCaption;
  @override
  void dispose() {
    caption.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (sending || uncertain || files.isEmpty) return;
    final text = attemptedCaption ?? caption.text.trim();
    var transportStarted = false;
    setState(() {
      sending = true;
      problem = null;
    });
    try {
      if (widget.isCurrent?.call() == false ||
          widget.room.id != widget.frozen.conversation.roomId ||
          widget.room.client.userID != widget.frozen.conversation.accountId) {
        throw const PersonalCapabilityUnavailable(
          'The source account changed. Open attachments again.',
        );
      }
      final unknown = <String>{};
      for (final file in files.skip(accepted)) {
        final result = _validate(widget.room, file, text);
        if (result.status == CapabilityStatus.unverified) {
          unknown.add(result.reason);
        }
      }
      final originalReply = widget.replyTo;
      final reply = originalReply == null
          ? null
          : await widget.room.getEventById(originalReply.eventId);
      if (originalReply != null && reply == null) {
        throw const PersonalCapabilityUnavailable(
          'The message you are replying to is unavailable.',
        );
      }
      final replyCapability = reply == null
          ? null
          : RoomCapabilities.forFeature(
              BridgeFeature.reply,
              widget.room,
              event: reply,
            );
      if (replyCapability?.status == CapabilityStatus.unverified) {
        unknown.add(replyCapability!.reason);
      }
      if (reply != null &&
          (reply.redacted ||
              reply.room.id != widget.frozen.conversation.roomId ||
              replyCapability?.status == CapabilityStatus.unavailable)) {
        throw const PersonalCapabilityUnavailable(
          'The source reply is unavailable or unsupported by this network.',
        );
      }
      if (!mounted) return;
      if (unknown.isNotEmpty) {
        final probe = await showNotionCustomDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Compatibility is unverified'),
            content: Text(
              '${unknown.join('\n')}\n\nYou can manually test sending in the selected network.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Back without sending'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Send a test'),
              ),
            ],
          ),
        );
        if (probe != true || !mounted) return;
      }
      if (widget.isCurrent?.call() == false) {
        throw const PersonalCapabilityUnavailable(
          'The conversation changed. Close attachments and select them again.',
        );
      }
      final trust = await showTrustUserInRoomDialog(context, widget.room);
      if (!mounted || !trust) return;
      setState(() {
        sending = true;
        problem = null;
      });
      for (final file in files.skip(accepted)) {
        if (widget.isCurrent?.call() == false) {
          throw const PersonalCapabilityUnavailable(
            'The conversation changed. Close attachments and select them again.',
          );
        }
        _validate(widget.room, file, text);
        if (reply != null &&
            (reply.redacted ||
                RoomCapabilities.forFeature(
                      BridgeFeature.reply,
                      widget.room,
                      event: reply,
                    ).status ==
                    CapabilityStatus.unavailable)) {
          throw const PersonalCapabilityUnavailable(
            'The message you are replying to is no longer available.',
          );
        }
        // No routing is resolved here: the selected Room and original reply
        // were captured before opening the picker, and stay immutable.
        transportStarted = true;
        attemptedCaption ??= text;
        final id = await widget.room.sendFileEvent(
          file.file,
          txid: file.transactionId,
          inReplyTo: reply,
          extraContent: text.isEmpty ? null : {'body': text},
        );
        if (id == null || !id.startsWith(r'$')) {
          throw StateError('Acceptance unknown');
        }
        accepted++;
        transportStarted = false;
        acceptedAt = DateTime.now();
        acceptedEventId = id;
        widget.onAccepted?.call(id, acceptedAt!);
      }
      if (mounted) {
        Navigator.pop(
          context,
          MergedMediaResult(
            accepted: true,
            caption: text,
            acceptedAt: acceptedAt,
            acceptedEventId: acceptedEventId,
          ),
        );
      }
    } on PersonalCapabilityUnavailable catch (error) {
      if (mounted) setState(() => problem = error.reason);
    } on MatrixException catch (_) {
      if (mounted)
        setState(
          () => problem =
              'The server rejected the attachment. Your selection and caption are kept.',
        );
    } catch (_) {
      uncertain = transportStarted;
      if (mounted) {
        setState(
          () => problem = uncertain
              ? 'Sending was not confirmed. $accepted of ${files.length} attachments were accepted. Check the source before retrying.'
              : 'The attachments could not be prepared. Your selection and caption are kept. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !sending,
    child: AlertDialog(
      insetPadding: const EdgeInsets.all(NotionSpace.md),
      titlePadding: const EdgeInsets.fromLTRB(
        NotionSpace.lg,
        NotionSpace.lg,
        NotionSpace.lg,
        NotionSpace.xs,
      ),
      contentPadding: const EdgeInsets.fromLTRB(
        NotionSpace.lg,
        NotionSpace.sm,
        NotionSpace.lg,
        NotionSpace.md,
      ),
      title: const Text('Send attachments', style: NotionType.heading),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Network: ${notionNetworkLabel(widget.frozen.conversation.network)}',
              ),
              if (widget.replyTo != null)
                const Text('Replying to a message in this network'),
              if (accepted > 0)
                Text(
                  '$accepted of ${files.length} attachments were accepted and will be skipped on retry.',
                ),
              const SizedBox(height: 16),
              for (final file in files)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: MediaQuery.textScalerOf(context).scale(16) > 24
                      ? null
                      : SizedBox.square(
                          dimension: 56,
                          child: file.file is MatrixImageFile
                              ? ClipRRect(
                                  borderRadius: NotionRadius.mdAll,
                                  child: Image.memory(
                                    file.file.bytes,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const Icon(Icons.broken_image_outlined),
                                  ),
                                )
                              : Icon(
                                  file.file is MatrixVideoFile
                                      ? Icons.videocam_outlined
                                      : file.file is MatrixAudioFile
                                      ? Icons.audio_file_outlined
                                      : Icons.insert_drive_file_outlined,
                                ),
                        ),
                  title: Tooltip(
                    message: file.file.name,
                    child: Text(
                      file.file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  subtitle: Text(
                    '${(file.file.size / 1024 / 1024).toStringAsFixed(1)} MB',
                  ),
                  trailing: accepted == 0 && !uncertain
                      ? IconButton(
                          tooltip: 'Remove ${file.file.name}',
                          onPressed: sending
                              ? null
                              : () => setState(() => files.remove(file)),
                          icon: const Icon(Icons.close),
                        )
                      : null,
                ),
              const SizedBox(height: 16),
              TextField(
                controller: caption,
                enabled: !sending && !uncertain && attemptedCaption == null,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Attachment caption',
                  helperText: attemptedCaption == null
                      ? null
                      : 'Kept for this send attempt',
                ),
              ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: NotionSpace.sm),
                  child: Text(
                    problem!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (sending)
                const Padding(
                  padding: const EdgeInsets.only(top: NotionSpace.sm),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: sending
              ? null
              : () => Navigator.pop(
                  context,
                  MergedMediaResult(
                    accepted: false,
                    acceptedAt: acceptedAt,
                    acceptedEventId: acceptedEventId,
                  ),
                ),
          child: Text(uncertain ? 'Close without retrying' : 'Cancel'),
        ),
        FilledButton(
          onPressed: sending || uncertain || files.isEmpty ? null : _send,
          child: Text(
            sending
                ? 'Sending…'
                : files.length == 1
                ? 'Send attachment'
                : 'Send ${files.length} attachments',
          ),
        ),
      ],
    ),
  );
}
