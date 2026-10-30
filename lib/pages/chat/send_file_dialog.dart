// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:ui' as ui;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/recording_output_cleanup.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/capabilities.dart'
    show PersonalCapabilityUnavailable;
import 'package:chatloom/personal/media/caption_followup.dart';
import 'package:chatloom/personal/media/editor/media_edit_plan.dart';
import 'package:chatloom/personal/media/editor/photo_editor_page.dart';
import 'package:chatloom/personal/media/editor/video_editor_page.dart';
import 'package:chatloom/personal/media/gallery_batch.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/media/media_quality.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:chatloom/utils/other_party_can_receive.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';

import '../../utils/resize_video.dart';

/// Captured before a picker or trust dialog can change the active composer.
class FrozenAttachmentContext {
  final Room room;
  final Event? replyTo;
  final String? threadRootEventId, threadLastEventId;
  final bool Function() isCurrent;
  final String? _accountId;

  FrozenAttachmentContext({
    required this.room,
    required this.isCurrent,
    this.replyTo,
    this.threadRootEventId,
    this.threadLastEventId,
  }) : _accountId = room.client.userID;

  void validate() {
    if (!isCurrent() ||
        room.client.userID != _accountId ||
        !room.canSendDefaultMessages ||
        (replyTo != null &&
            (!identical(replyTo!.room.client, room.client) ||
                replyTo!.room.id != room.id ||
                replyTo!.redacted))) {
      throw StateError('The conversation changed. Open attachments again.');
    }
  }
}

/// Where a send preview's attachments go: the room with the reply, guard,
/// destination checks and accepted-event callback that belong to it.
class AttachmentDestination {
  final Room room;
  final Event? replyTo;
  final FrozenAttachmentContext? composeContext;
  final Future<bool> Function(
    BuildContext context,
    List<XFile> files,
    String caption,
  )?
  preflight;
  final void Function(String eventId, DateTime acceptedAt)? onAccepted;

  const AttachmentDestination({
    required this.room,
    this.replyTo,
    this.composeContext,
    this.preflight,
    this.onAccepted,
  });
}

/// A merged chat's source in the send preview: a chip beside the caption
/// names the network the attachments go to and, until the first one is in
/// the chat, lets the user send them through another source.
class AttachmentSourceChoice {
  /// The chip for [room]; [onPressed] is null while the choice is locked
  /// (a send is under way or some attachments are already in the chat).
  final Widget Function(
    BuildContext context,
    Room room,
    VoidCallback? onPressed,
  )
  chip;

  /// Asks for another source; null keeps the current one.
  final Future<AttachmentDestination?> Function(
    BuildContext context,
    Room current,
  )
  choose;

  const AttachmentSourceChoice({required this.chip, required this.choose});
}

class AttachmentSendResult {
  final String caption;
  const AttachmentSendResult(this.caption);
}

/// Opens [dialog] as the full-screen send preview (UI-18): it rises from
/// the bottom (a translation only, so its glass bars blur from the first
/// frame) and covers the chat; Esc or the close button leaves it.
Future<AttachmentSendResult?> showSendFileDialog(
  BuildContext context,
  SendFileDialog dialog,
) {
  // Above every pane (like the dialog it replaced).
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    _SendPreviewRoute(
      duration: NotionMotion.of(context, NotionMotion.long),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (_) => dialog,
    ),
  );
}

class _SendPreviewRoute extends PageRoute<AttachmentSendResult> {
  _SendPreviewRoute({
    required this.builder,
    required this.duration,
    this.themes,
  }) : super(fullscreenDialog: true);

  final WidgetBuilder builder;
  final Duration duration;
  final CapturedThemes? themes;

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration =>
      duration == Duration.zero ? Duration.zero : NotionMotion.reverse;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final page = builder(context);
    return themes?.wrap(page) ?? page;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => SlideTransition(
    position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
      CurvedAnimation(
        parent: animation,
        curve: NotionMotion.emphasized,
        reverseCurve: NotionMotion.exitFast,
      ),
    ),
    child: child,
  );
}

/// The send preview of picked photos, videos and files, Telegram and
/// Messenger style: a full-screen, swipeable preview of every item, a
/// thumbnail strip to pick and remove items, the caption composer at the
/// bottom and the send button. Open it with [showSendFileDialog].
///
/// It never asks whether to compress (J, 2026-10-24): photos and videos
/// are compressed on the device before upload ([MediaProfile.standard]),
/// unless the small "HD" chip in the header is on for this send
/// ([MediaProfile.hd]; per send, never remembered). The exact original
/// goes out only from the attach menu's "File" entry ([sendAsFiles]).
class SendFileDialog extends StatefulWidget {
  final Room room;
  final List<XFile> files;
  final BuildContext outerContext;
  final String? threadLastEventId, threadRootEventId;
  final Event? replyTo;
  final String initialCaption;
  final FrozenAttachmentContext? composeContext;

  /// The attach menu's "File" entry (Telegram's "Send as file", MD-02):
  /// photos and videos go out as documents with their original bytes,
  /// unchanged. Every other entry (gallery, camera, paste, drag and drop,
  /// sharing into the app) compresses automatically, without a question.
  final bool sendAsFiles;

  /// Checks the selection against the destination before anything is
  /// shown in the chat, e.g. a bridge's media limits for a merged chat's
  /// source. Throw [PersonalCapabilityUnavailable] to keep the dialog open
  /// with that reason; return false to stay open silently (the user backed
  /// out of a follow-up question).
  final Future<bool> Function(
    BuildContext context,
    List<XFile> files,
    String caption,
  )?
  preflight;

  /// Each attachment's accepted event ID (a merged chat keeps the newest
  /// outgoing message as its routing anchor).
  final void Function(String eventId, DateTime acceptedAt)? onAccepted;

  /// A merged chat: which source the attachments go through, switchable in
  /// the preview. The fields above are the initial source.
  final AttachmentSourceChoice? sourceChoice;

  const SendFileDialog({
    required this.room,
    required this.files,
    required this.outerContext,
    required this.threadLastEventId,
    required this.threadRootEventId,
    this.replyTo,
    this.initialCaption = '',
    this.composeContext,
    this.sendAsFiles = false,
    this.preflight,
    this.onAccepted,
    this.sourceChoice,
    super.key,
  });

  @override
  SendFileDialogState createState() => SendFileDialogState();
}

enum _Kind { image, video, other }

/// One picked item and its preview sources, created once (never in build).
class _Item {
  final XFile file;
  final String? mimeType;
  final _Kind kind;
  final ImageProvider? image;
  Future<Uint8List?>? videoFrame;

  _Item(this.file, this.mimeType, this.kind, this.image);

  factory _Item.of(XFile file) {
    final mime =
        file.mimeType ??
        lookupMimeType(file.name) ??
        (file.path.isEmpty ? null : lookupMimeType(file.path));
    final kind = mime == null
        ? _Kind.other
        : mime.startsWith('image/')
        ? _Kind.image
        : mime.startsWith('video/')
        ? _Kind.video
        : _Kind.other;
    return _Item(
      file,
      mime,
      kind,
      kind == _Kind.image ? XFileImage(file) : null,
    );
  }
}

class SendFileDialogState extends State<SendFileDialog> {
  /// The "HD" chip: this send only, off every time the preview opens.
  bool hd = false;

  MediaProfile get _profile => hd ? MediaProfile.hd : MediaProfile.standard;
  bool _sending = false;
  int _accepted = 0;
  String? _problem;
  int _page = 0;
  final PageController _pages = PageController();
  final FocusNode _captionFocus = FocusNode();

  /// One transaction per item; removing an item removes its own.
  final List<String> _transactionIds = [];

  /// The album the picked photos and videos form ([MediaAlbumBatch]); kept
  /// when "Send again" sends the rest.
  final String _albumId = const Uuid().v4();

  /// Videos up to this size are sent as they are.
  static const int minSizeToCompress = 20 * 1000;

  /// Long captions are allowed; a network that cannot carry one on media
  /// gets it as its own message ([CaptionFollowUp]).
  static const int maxCaptionLength = 4096;

  late final TextEditingController _labelTextController = TextEditingController(
    text: widget.initialCaption,
  );

  /// Mutable working copy of [SendFileDialog.files]. Editing an image
  /// replaces its entry with a new [XFile] whose bytes, mimetype and
  /// filename extension all reflect the edit result.
  late final List<_Item> _items = [
    for (final file in widget.files) _Item.of(file),
  ];

  /// Read once per selection change, never on a rebuild (MD-06).
  late Future<int> _totalSize = _calcTotalSize();

  List<XFile> get _files => [for (final item in _items) item.file];

  bool get _locked => _sending || _accepted > 0;

  /// The current destination; [SendFileDialog.sourceChoice] may replace it
  /// until the first attachment is accepted.
  late AttachmentDestination _to = AttachmentDestination(
    room: widget.room,
    replyTo: widget.replyTo,
    composeContext: widget.composeContext,
    preflight: widget.preflight,
    onAccepted: widget.onAccepted,
  );

  bool _choosingSource = false;

  Future<void> _chooseSource() async {
    final choice = widget.sourceChoice;
    if (choice == null || _locked || _choosingSource) return;
    _choosingSource = true;
    final AttachmentDestination? next;
    try {
      next = await choice.choose(context, _to.room);
    } finally {
      _choosingSource = false;
    }
    if (next == null || !mounted || _locked) return;
    setState(() {
      _to = next!;
      _problem = null;
      _split = _captionNeedsSplit(_labelTextController.text.trim());
    });
  }

  bool get _hasMedia => _items.any((item) => item.kind != _Kind.other);

  Future<int> _calcTotalSize() async {
    final lengths = await Future.wait(_items.map((item) => item.file.length()));
    return lengths.fold<int>(0, (sum, length) => sum + length);
  }

  @override
  void initState() {
    super.initState();
    _transactionIds.addAll(_items.map((_) => const Uuid().v4()));
    _split = _captionNeedsSplit(_labelTextController.text.trim());
    _labelTextController.addListener(_onCaptionChanged);
  }

  /// Whether the caption goes out as its own message (BR-04); the preview
  /// rebuilds only when that changes, not per keystroke.
  bool _split = false;

  void _onCaptionChanged() {
    final split = _captionNeedsSplit(_labelTextController.text.trim());
    if (split != _split && mounted) setState(() => _split = split);
  }

  bool _captionNeedsSplit(String caption) {
    if (caption.isEmpty || _items.isEmpty) return false;
    final last = _items.last;
    return CaptionFollowUp.needsSplit(
      _to.room,
      mimeType: _sendMimeType(last),
      caption: caption,
    );
  }

  /// The type the bridge sees for [item].
  String _sendMimeType(_Item item) {
    final mime = item.mimeType ?? 'application/octet-stream';
    if (item.kind == _Kind.other || !widget.sendAsFiles) return mime;
    // The original as a file: the bridge checks it as a document.
    return 'application/octet-stream';
  }

  /// Plaintext renders of edited videos, by item: closed once the video was
  /// read for sending, replaced, removed, or the preview closes unsent.
  final Map<_Item, ManagedMediaFile> _edits = {};

  bool _canEdit(_Item item) => switch (item.kind) {
    _Kind.image => true,
    _Kind.video => canEditVideos && item.file.path.isNotEmpty,
    _Kind.other => false,
  };

  /// The tag of the preview at [index], which flies into the editor and
  /// back: by its slot (transaction), so an edit that replaces the item
  /// still lands on its preview.
  String _heroTag(int index) => 'send-preview-${_transactionIds[index]}';

  Future<void> _edit(int index) async {
    if (_locked || index >= _items.length) return;
    final item = _items[index];
    final _Item edited;
    if (item.kind == _Kind.image) {
      Uint8List bytes;
      try {
        bytes = await item.file.readAsBytes();
      } catch (_) {
        if (mounted) {
          setState(
            () => _problem = 'This image could not be opened. Select it again.',
          );
        }
        return;
      }
      if (!mounted) return;
      final result = await showPhotoEditor(
        context,
        bytes: bytes,
        heroTag: _heroTag(index),
      );
      if (!mounted || result == null) return;
      final name = editedFileName(item.file.name, result.format.extension);
      edited = _Item.of(
        XFile.fromData(
          result.bytes,
          mimeType: result.format.mimeType,
          name: name,
          path: name,
          length: result.bytes.length,
        ),
      );
    } else if (item.kind == _Kind.video && _canEdit(item)) {
      final result = await showVideoEditor(
        context,
        path: item.file.path,
        heroTag: _heroTag(index),
        // Sent as a file, the edit is not compressed afterwards.
        keepQuality: widget.sendAsFiles,
      );
      if (result == null) return;
      if (!mounted || _locked || !identical(_items[index], item)) {
        await result.lease.close();
        return;
      }
      edited = _Item(
        XFile(
          result.path,
          mimeType: 'video/mp4',
          name: editedFileName(item.file.name, 'mp4'),
        ),
        'video/mp4',
        _Kind.video,
        null,
      );
      _edits[edited] = result.lease;
    } else {
      return;
    }
    if (!identical(_items[index], item)) return;
    setState(() {
      _items[index] = edited;
      _totalSize = _calcTotalSize();
    });
    // An earlier render of this item is no longer shown or sent.
    unawaited(_edits.remove(item)?.close());
    _onCaptionChanged();
  }

  void _remove(int index) {
    if (_locked || index >= _items.length) return;
    if (_items.length == 1) {
      Navigator.of(context).pop();
      return;
    }
    unawaited(_edits.remove(_items[index])?.close());
    setState(() {
      _items.removeAt(index);
      _transactionIds.removeAt(index);
      _totalSize = _calcTotalSize();
      _page = _page.clamp(0, _items.length - 1);
    });
    if (_pages.hasClients) _pages.jumpToPage(_page);
    _onCaptionChanged();
  }

  void _goTo(int page) {
    if (page < 0 || page >= _items.length || !_pages.hasClients) return;
    final duration = NotionMotion.of(context, NotionMotion.medium);
    if (duration == Duration.zero) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(
        page,
        duration: duration,
        curve: NotionMotion.standard,
      );
    }
  }

  Future<Uint8List?> _videoFrame(_Item item) =>
      item.videoFrame ??= _readVideoFrame(item.file);

  static Future<Uint8List?> _readVideoFrame(XFile file) async {
    if (!PlatformInfos.supportsVideoTranscode || file.path.isEmpty) {
      return null;
    }
    String? framePath;
    try {
      framePath = await LightCompressor().getVideoThumbnail(
        file.path,
        quality: 70,
      );
      return await XFile(framePath).readAsBytes();
    } catch (_) {
      return null;
    } finally {
      if (framePath != null && framePath != file.path) {
        try {
          await cleanupRecordingOutput(ownedNativePath: framePath);
        } catch (_) {}
      }
    }
  }

  /// Telegram/Messenger: the dialog closes as soon as every attachment has
  /// its bubble in the chat. Compression, thumbnails, encryption and the
  /// upload continue in the background ([OutgoingMedia]); progress and any
  /// failure ("Not sent · Tap to retry") are shown in the bubble. Only a
  /// problem found before anything is shown keeps the dialog open.
  Future<void> _send() async {
    if (_sending) return;
    final label = _labelTextController.text.trim();
    setState(() {
      _sending = true;
      _problem = null;
    });
    try {
      _to.composeContext?.validate();
      final preflight = _to.preflight;
      if (preflight != null) {
        final files = _files.skip(_accepted).toList();
        if (!await preflight(context, files, label) || !mounted) return;
        _to.composeContext?.validate();
      }
      final proceed = await showTrustUserInRoomDialog(context, _to.room);
      if (!mounted || !proceed) return;
      _to.composeContext?.validate();
      if (!_to.room.otherPartyCanReceiveMessages) {
        throw OtherPartyCanNotReceiveMessages();
      }
      // Cached by the SDK (days); a network fetch only on first use.
      final clientConfig = await _to.room.client.getConfig();
      if (!mounted) return;
      _to.composeContext?.validate();
      final maxUploadSize = clientConfig.mUploadSize ?? 100 * 1000 * 1000;
      // Telegram: one caption under the album, on its newest item (an
      // album only forms when the older items carry none). A network that
      // drops or limits captions gets it as a text right after the media.
      final split = _captionNeedsSplit(label);
      Future<String>? lastAccepted;
      // Photos and videos picked together go out as separate messages (no
      // bridge accepts one album message, see MediaAlbumBatch) and stay one
      // album in ChatLoom.
      final albumCount = widget.sendAsFiles
          ? 0
          : _items.where((item) => item.kind != _Kind.other).length;

      for (var i = _accepted; i < _items.length; i++) {
        if (!mounted) return;
        _to.composeContext?.validate();
        final item = _items[i];
        final xfile = item.file;
        final mimeType = item.mimeType;
        final captioned = i == _items.length - 1 && label.isNotEmpty && !split;
        // The size is known before anything is read (MD-05).
        final size = await xfile.length();
        if (!mounted) return;
        final asDocument = widget.sendAsFiles && item.kind != _Kind.other;
        final transcode =
            item.kind == _Kind.video &&
            !widget.sendAsFiles &&
            PlatformInfos.supportsVideoTranscode &&
            xfile.path.isNotEmpty;
        if (!transcode && size > maxUploadSize) {
          throw FileTooBigMatrixException(size, maxUploadSize);
        }
        final MatrixFile file;
        OutgoingMediaPrepare? prepare;
        Future<void> Function()? cancelPrepare;
        if (transcode) {
          // The bubble shows at once; the video is only read (or
          // re-encoded) when its job runs, one video at a time.
          file = PendingVideoFile(
            name: xfile.name,
            mimeType: mimeType,
            declaredSize: size,
          );
          final job = VideoPrepareJob();
          final shrink = size > minSizeToCompress;
          final profile = _profile;
          // An edited video's render lives until its bytes were read; a
          // failed preparation keeps it for Retry (the next start sweeps it).
          // Handed over to the send once its ticket exists (below).
          final edit = _edits[item];
          prepare = () async {
            final prepared = await xfile.prepareVideo(
              compress: shrink,
              maxUploadSize: maxUploadSize,
              job: job,
              profile: profile,
            );
            await edit?.close();
            return prepared;
          };
          cancelPrepare = () async {
            await job.cancel();
            await edit?.close();
          };
        } else {
          final bytes = await xfile.readAsBytes();
          unawaited(_edits.remove(item)?.close());
          if (!mounted) return;
          if (asDocument) {
            // Sent deliberately as a file: the original bytes, unchanged
            // (its metadata included), as a document.
            file = MatrixDocumentFile(
              bytes: bytes,
              name: xfile.name,
              mimeType: mimeType,
            );
          } else {
            file = await withImageSize(
              MatrixFile(
                bytes: bytes,
                name: xfile.name,
                mimeType: mimeType,
              ).detectFileType,
            );
          }
        }
        if (!mounted) return;
        _to.composeContext?.validate();
        final albumIndex = albumCount > 1 && item.kind != _Kind.other
            ? _items.take(i).where((other) => other.kind != _Kind.other).length
            : null;
        final extra = <String, Object?>{
          if (captioned) 'body': label,
          if (albumIndex != null)
            ...MediaAlbumBatch.content(
              id: _albumId,
              index: albumIndex,
              count: albumCount,
            ),
        };
        final ticket = await OutgoingMedia.send(
          _to.room,
          file,
          txid: _transactionIds[i],
          inReplyTo: _to.replyTo,
          // The long side also selects the JPEG quality (q80, HD q85) and
          // is stored with the bubble, so Retry keeps the same profile.
          shrinkImageMaxDimension:
              !widget.sendAsFiles && file is MatrixImageFile
              ? _profile.photoMaxSide
              : null,
          extraContent: extra.isEmpty ? null : extra,
          threadRootEventId: widget.threadRootEventId,
          threadLastEventId: widget.threadLastEventId,
          prepare: prepare,
          cancelPrepare: cancelPrepare,
        );
        // The send owns an edited video's render from here.
        if (transcode) _edits.remove(item);
        lastAccepted = ticket.accepted;
        final onAccepted = _to.onAccepted;
        if (onAccepted != null) {
          unawaited(
            ticket.accepted.then(
              (id) => onAccepted(id, DateTime.now()),
              onError: (Object _) {},
            ),
          );
        }
        if (mounted) setState(() => _accepted = i + 1);
      }
      if (split && label.isNotEmpty && lastAccepted != null) {
        _sendCaptionAfter(lastAccepted, label);
      }
      if (mounted) {
        setState(() => _sending = false);
        Navigator.of(context).pop(AttachmentSendResult(label));
      }
    } on PersonalCapabilityUnavailable catch (error) {
      if (mounted) setState(() => _problem = error.reason);
    } on OtherPartyCanNotReceiveMessages catch (_) {
      if (mounted) {
        setState(
          () => _problem =
              'No one in this chat can read encrypted messages yet. Your selection and caption are kept.',
        );
      }
    } on FileTooBigMatrixException catch (_) {
      if (mounted) {
        setState(
          () => _problem =
              'This file is too large for the server. Your selection and caption are kept.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _problem =
              'Attachments could not be prepared in this conversation. Your selection and caption are kept.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// The caption as its own message once the media's send ended, so it
  /// follows the media in the chat (Telegram, Instagram). It is not sent
  /// when the user cancelled the media.
  void _sendCaptionAfter(Future<String> media, String caption) {
    final room = _to.room;
    final thread = widget.threadRootEventId;
    Future<void> send() => CaptionFollowUp.send(room, caption, threadId: thread)
        .catchError((Object e) {
          Logs().w('Caption could not be sent', e.runtimeType);
        });
    unawaited(
      media.then<void>(
        (_) => send(),
        onError: (Object error) {
          if (!OutgoingMedia.isDiscard(error)) return send();
        },
      ),
    );
  }

  @override
  void dispose() {
    for (final edit in _edits.values) {
      unawaited(edit.close());
    }
    _edits.clear();
    _labelTextController.dispose();
    _pages.dispose();
    _captionFocus.dispose();
    super.dispose();
  }

  void _close() {
    if (_sending) return;
    Navigator.of(context).pop();
  }

  /// Esc closes; ← / → page while the caption is not being edited.
  KeyEventResult _pageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (_captionFocus.hasFocus) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _goTo(_page - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _goTo(_page + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _captionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !PlatformInfos.isDesktop) {
      return KeyEventResult.ignored;
    }
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter || HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    unawaited(_send());
    return KeyEventResult.handled;
  }

  String _title() {
    if (_items.length > 1) return '${_page + 1} of ${_items.length}';
    return switch (_items.single.kind) {
      _Kind.image => 'Photo',
      _Kind.video => 'Video',
      _Kind.other => 'File',
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final tokens = context.notion;
    final current = _items[_page.clamp(0, _items.length - 1)];
    return PopScope(
      canPop: !_sending,
      child: Focus(
        autofocus: true,
        onKeyEvent: _pageKey,
        child: Scaffold(
          backgroundColor: NotionMediaColors.viewer,
          body: BackdropGroup(
            child: Column(
              children: [
                _PreviewHeader(
                  title: _title(),
                  onClose: _sending ? null : _close,
                  closeLabel: l10n.cancel,
                  editLabel: current.kind == _Kind.video
                      ? 'Edit video'
                      : 'Edit photo',
                  onEdit: _canEdit(current) && !_locked
                      ? () => _edit(_page)
                      : null,
                  removeLabel: l10n.remove,
                  onRemove: _items.length > 1 && !_locked
                      ? () => _remove(_page)
                      : null,
                  showHd: !widget.sendAsFiles && _hasMedia,
                  hd: hd,
                  onHd: _locked ? null : () => setState(() => hd = !hd),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: PageView.builder(
                          controller: _pages,
                          itemCount: _items.length,
                          onPageChanged: (page) => setState(() => _page = page),
                          itemBuilder: (context, i) => _PreviewPage(
                            key: ObjectKey(_items[i]),
                            item: _items[i],
                            heroTag: _heroTag(i),
                            videoFrame: _items[i].kind == _Kind.video
                                ? _videoFrame(_items[i])
                                : null,
                          ),
                        ),
                      ),
                      if (PlatformInfos.isDesktop && _items.length > 1) ...[
                        if (_page > 0)
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Padding(
                              padding: const EdgeInsets.all(NotionSpace.md),
                              child: NotionGlassPill(
                                icon: Icons.chevron_left_rounded,
                                tooltip: 'Previous',
                                onPressed: () => _goTo(_page - 1),
                              ),
                            ),
                          ),
                        if (_page < _items.length - 1)
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: Padding(
                              padding: const EdgeInsets.all(NotionSpace.md),
                              child: NotionGlassPill(
                                icon: Icons.chevron_right_rounded,
                                tooltip: 'Next',
                                onPressed: () => _goTo(_page + 1),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                NotionGlassBar(
                  hairlineTop: true,
                  child: SafeArea(
                    top: false,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: NotionSize.contentMaxWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            NotionSpace.sm,
                            NotionSpace.xs,
                            NotionSpace.sm,
                            NotionSpace.sm,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_accepted > 0)
                                _Notice(
                                  '$_accepted of ${_items.length} attachments are already in the chat. Send again for the rest.',
                                ),
                              if (_problem != null)
                                Semantics(
                                  liveRegion: true,
                                  child: _Notice(
                                    _problem!,
                                    color: tokens.colors.danger,
                                  ),
                                ),
                              if (_split) const _Notice(CaptionFollowUp.notice),
                              if (_items.length > 1)
                                _ThumbnailStrip(
                                  items: _items,
                                  selected: _page,
                                  onSelect: _goTo,
                                ),
                              if (widget.sendAsFiles && _hasMedia)
                                FutureBuilder<int>(
                                  future: _totalSize,
                                  builder: (context, size) => _Notice(
                                    _items.length > 1
                                        ? 'Sent as files, unchanged'
                                              '${size.hasData ? ' · ${size.data!.toDouble().sizeString}' : ''}'
                                        : 'Sent as a file, unchanged'
                                              '${size.hasData ? ' · ${size.data!.toDouble().sizeString}' : ''}',
                                  ),
                                ),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (widget.sourceChoice case final choice?)
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        end: NotionSpace.xxs,
                                      ),
                                      child: choice.chip(
                                        context,
                                        _to.room,
                                        _locked ? null : _chooseSource,
                                      ),
                                    ),
                                  Expanded(
                                    child: Focus(
                                      onKeyEvent: _captionKey,
                                      child: _CaptionField(
                                        controller: _labelTextController,
                                        focusNode: _captionFocus,
                                        readOnly: _locked,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: NotionSpace.xs),
                                  _SendButton(
                                    label: l10n.send,
                                    busy: _sending,
                                    onPressed: _sending ? null : _send,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Decodes an [XFile] for a preview without keeping its bytes: they are
/// read when the image is first shown and released after the decode. Wrap
/// it in a [ResizeImage] so only the displayed size is decoded (MD-06).
class XFileImage extends ImageProvider<XFileImage> {
  final XFile file;
  const XFileImage(this.file);

  @override
  Future<XFileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(XFileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: 'send-preview',
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await file.readAsBytes();
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is XFileImage && identical(other.file, file);

  @override
  int get hashCode => identityHashCode(file);
}

class _PreviewHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onClose, onEdit, onRemove;
  final String closeLabel, editLabel, removeLabel;

  /// The "HD" chip (Telegram), for photos and videos.
  final bool showHd, hd;
  final VoidCallback? onHd;

  const _PreviewHeader({
    required this.title,
    required this.onClose,
    required this.closeLabel,
    required this.onEdit,
    required this.editLabel,
    required this.onRemove,
    required this.removeLabel,
    this.showHd = false,
    this.hd = false,
    this.onHd,
  });

  @override
  Widget build(BuildContext context) => NotionGlassBar(
    hairlineBottom: true,
    child: SafeArea(
      bottom: false,
      child: SizedBox(
        height: NotionSize.headerHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NotionSpace.xxs),
          child: Row(
            children: [
              NotionIconButton(
                icon: Icons.close_rounded,
                label: closeLabel,
                onPressed: onClose,
              ),
              Expanded(
                child: NotionFadeThrough(
                  child: Text(
                    title,
                    key: ValueKey(title),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.notion.typography.headline,
                  ),
                ),
              ),
              if (showHd) _HdChip(hd: hd, onPressed: onHd),
              if (onEdit != null)
                NotionIconButton(
                  icon: Icons.edit_outlined,
                  label: editLabel,
                  onPressed: onEdit,
                ),
              if (onRemove != null)
                NotionIconButton(
                  icon: Icons.delete_outline_rounded,
                  label: removeLabel,
                  onPressed: onRemove,
                ),
              if (onEdit == null && onRemove == null && !showHd)
                const SizedBox(width: NotionSize.touchTarget),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PreviewPage extends StatelessWidget {
  final _Item item;
  final Future<Uint8List?>? videoFrame;

  final String heroTag;

  const _PreviewPage({
    super.key,
    required this.item,
    required this.heroTag,
    this.videoFrame,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(NotionSpace.md),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final width = (constraints.maxWidth * dpr).ceil();
        final height = (constraints.maxHeight * dpr).ceil();
        final image = item.image;
        if (image != null) {
          return Center(
            child: Hero(
              tag: heroTag,
              createRectTween: NotionMediaHero.rectTween,
              child: ClipRRect(
              borderRadius: NotionRadius.mdAll,
              child: Image(
                image: ResizeImage(
                  image,
                  width: width,
                  height: height,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, _) =>
                    _FileCard(item: item, broken: true),
              ),
            ),
            ),
          );
        }
        final frame = videoFrame;
        if (frame == null) return Center(child: _FileCard(item: item));
        return FutureBuilder<Uint8List?>(
          future: frame,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return Center(child: _FileCard(item: item));
            }
            return Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Hero(
                    tag: heroTag,
                    createRectTween: NotionMediaHero.rectTween,
                    child: ClipRRect(
                    borderRadius: NotionRadius.mdAll,
                    child: Image(
                      image: ResizeImage(
                        MemoryImage(bytes),
                        width: width,
                        height: height,
                        policy: ResizeImagePolicy.fit,
                      ),
                      fit: BoxFit.contain,
                    ),
                  ),
                  ),
                  const DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: CircleBorder(),
                      color: NotionMediaColors.scrim,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(NotionSpace.sm),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: NotionMediaColors.onScrim,
                        size: NotionSize.iconLg,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}

/// A file (or an unreadable image) in the preview: icon, name, size, type.
class _FileCard extends StatelessWidget {
  final _Item item;
  final bool broken;

  const _FileCard({required this.item, this.broken = false});

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final type = item.file.name.contains('.')
        ? item.file.name.split('.').last.toUpperCase()
        : (item.mimeType ?? '');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: NotionSize.dialogMaxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: NotionRadius.lgAll,
          border: Border.all(color: colors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(NotionSpace.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                broken
                    ? Icons.broken_image_outlined
                    : switch (item.kind) {
                        _Kind.video => Icons.video_file_outlined,
                        _Kind.image => Icons.image_outlined,
                        _Kind.other =>
                          item.mimeType?.startsWith('audio/') ?? false
                              ? Icons.audio_file_outlined
                              : Icons.description_outlined,
                      },
                size: NotionSize.iconLg,
                color: colors.textSecondary,
              ),
              const SizedBox(width: NotionSpace.sm),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.notion.typography.body,
                    ),
                    FutureBuilder<int>(
                      future: _lengthOf(item.file),
                      builder: (context, size) => Text(
                        [
                          if (size.hasData) size.data!.toDouble().sizeString,
                          if (type.isNotEmpty) type,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.notion.typography.footnoteMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static final _lengths = Expando<Future<int>>();

  /// Read once per file, not on every rebuild.
  static Future<int> _lengthOf(XFile file) =>
      _lengths[file] ??= file.length()..ignore();
}

class _ThumbnailStrip extends StatelessWidget {
  final List<_Item> items;
  final int selected;
  final ValueChanged<int> onSelect;

  const _ThumbnailStrip({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  static const double _side = NotionSize.touchTarget + NotionSpace.xs;

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decode = (_side * dpr).ceil();
    return Padding(
      padding: const EdgeInsets.only(bottom: NotionSpace.xs),
      child: SizedBox(
        height: _side,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: NotionSpace.xs),
          itemBuilder: (context, i) {
            final item = items[i];
            final image = item.image;
            final active = i == selected;
            return Semantics(
              button: true,
              selected: active,
              label: '${i + 1} of ${items.length}',
              child: NotionPressable(
                scale: NotionMotion.pressIcon,
                onTap: () => onSelect(i),
                child: AnimatedContainer(
                  duration: NotionMotion.of(context, NotionMotion.quick),
                  curve: NotionMotion.standard,
                  width: _side,
                  height: _side,
                  decoration: BoxDecoration(
                    borderRadius: NotionRadius.smAll,
                    border: Border.all(
                      color: active
                          ? context.notion.palette.accentFill
                          : colors.border,
                      width: active ? 2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: NotionRadius.smAll,
                    child: image == null
                        ? ColoredBox(
                            color: colors.surface,
                            child: Icon(
                              item.kind == _Kind.video
                                  ? Icons.videocam_outlined
                                  : Icons.description_outlined,
                              size: NotionSize.icon,
                              color: colors.textSecondary,
                            ),
                          )
                        : Image(
                            image: ResizeImage(
                              image,
                              width: decode,
                              height: decode,
                              policy: ResizeImagePolicy.fit,
                            ),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => ColoredBox(
                              color: colors.surface,
                              child: Icon(
                                Icons.broken_image_outlined,
                                size: NotionSize.icon,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Telegram's "HD" toggle: off, photos and videos go out at the automatic
/// sweet spot ([MediaProfile.standard]); on, sharper and larger
/// ([MediaProfile.hd]). It is not a compression question: both compress on
/// the device and strip EXIF/GPS; the original file is the attach menu's
/// "File" entry.
class _HdChip extends StatelessWidget {
  final bool hd;
  final VoidCallback? onPressed;

  const _HdChip({required this.hd, required this.onPressed});

  @override
  Widget build(BuildContext context) => Semantics(
    toggled: hd,
    child: NotionIconButton(
      icon: hd ? Icons.hd_rounded : Icons.hd_outlined,
      label: hd
          ? 'HD on: sharper photos and videos, larger files'
          : 'Send in HD',
      selected: hd,
      onPressed: onPressed,
    ),
  );
}

class _CaptionField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool readOnly;

  const _CaptionField({
    required this.controller,
    required this.focusNode,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    const border = OutlineInputBorder(
      borderRadius: NotionRadius.fieldAll,
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      readOnly: readOnly,
      minLines: 1,
      maxLines: 5,
      maxLength: SendFileDialogState.maxCaptionLength,
      maxLengthEnforcement: MaxLengthEnforcement.enforced,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      style: context.notion.typography.body,
      decoration: InputDecoration(
        hintText: 'Add a caption…',
        counterText: '',
        filled: true,
        fillColor: colors.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: NotionSpace.md,
          vertical: NotionSpace.sm,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  const _SendButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.notion.palette;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        enabled: onPressed != null,
        child: NotionPressable(
          bounce: true,
          enabled: onPressed != null,
          child: Material(
            color: palette.accentFill,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox.square(
                dimension: NotionSize.touchTarget,
                child: Center(
                  child: busy
                      ? NotionDelayedReveal(
                          placeholder: Icon(
                            Icons.send_rounded,
                            size: NotionSize.iconMd,
                            color: palette.onAccentFill,
                          ),
                          child: SizedBox.square(
                            dimension: NotionSize.iconMd,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.onAccentFill,
                            ),
                          ),
                        )
                      : Icon(
                          Icons.send_rounded,
                          size: NotionSize.iconMd,
                          color: palette.onAccentFill,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final Color? color;

  const _Notice(this.text, {this.color});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NotionSpace.xs),
    child: Text(
      text,
      style: context.notion.typography.footnoteMuted.copyWith(color: color),
    ),
  );
}
