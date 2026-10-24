// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:ui' as ui;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/image_edit_geometry.dart';
import 'package:chatloom/pages/chat/recording_output_cleanup.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/capabilities.dart'
    show PersonalCapabilityUnavailable;
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/media/caption_followup.dart';
import 'package:chatloom/personal/media/media_quality.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
import 'package:chatloom/personal/media/photo_encoder.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:chatloom/utils/other_party_can_receive.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/show_scaffold_dialog.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:crop_image/crop_image.dart';
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
      widget.room,
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

  Future<void> _editImage(int index) async {
    if (_locked) return;
    Uint8List bytes;
    try {
      bytes = await _items[index].file.readAsBytes();
    } catch (_) {
      if (mounted) {
        setState(
          () => _problem = 'This image could not be opened. Select it again.',
        );
      }
      return;
    }
    if (!mounted) return;
    final result = await showScaffoldDialog<_EditedImage?>(
      context: context,
      builder: (_) => _ImageEditPage(bytes: bytes),
    );
    if (!mounted || result == null) return;
    final original = _items[index].file;
    final dot = original.name.lastIndexOf('.');
    final baseName = dot > 0 ? original.name.substring(0, dot) : original.name;
    final name = '$baseName.${result.extension}';
    setState(() {
      _items[index] = _Item.of(
        XFile.fromData(
          result.bytes,
          mimeType: result.mimeType,
          name: name,
          path: name,
          length: result.bytes.length,
        ),
      );
      _totalSize = _calcTotalSize();
    });
  }

  void _remove(int index) {
    if (_locked || index >= _items.length) return;
    if (_items.length == 1) {
      Navigator.of(context).pop();
      return;
    }
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
      widget.composeContext?.validate();
      final preflight = widget.preflight;
      if (preflight != null) {
        final files = _files.skip(_accepted).toList();
        if (!await preflight(context, files, label) || !mounted) return;
        widget.composeContext?.validate();
      }
      final proceed = await showTrustUserInRoomDialog(context, widget.room);
      if (!mounted || !proceed) return;
      widget.composeContext?.validate();
      if (!widget.room.otherPartyCanReceiveMessages) {
        throw OtherPartyCanNotReceiveMessages();
      }
      // Cached by the SDK (days); a network fetch only on first use.
      final clientConfig = await widget.room.client.getConfig();
      if (!mounted) return;
      widget.composeContext?.validate();
      final maxUploadSize = clientConfig.mUploadSize ?? 100 * 1000 * 1000;
      // Telegram: one caption under the album, on its newest item (an
      // album only forms when the older items carry none). A network that
      // drops or limits captions gets it as a text right after the media.
      final split = _captionNeedsSplit(label);
      Future<String>? lastAccepted;

      for (var i = _accepted; i < _items.length; i++) {
        if (!mounted) return;
        widget.composeContext?.validate();
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
          prepare = () => xfile.prepareVideo(
            compress: shrink,
            maxUploadSize: maxUploadSize,
            job: job,
            profile: profile,
          );
          cancelPrepare = job.cancel;
        } else {
          final bytes = await xfile.readAsBytes();
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
        widget.composeContext?.validate();
        final ticket = await OutgoingMedia.send(
          widget.room,
          file,
          txid: _transactionIds[i],
          inReplyTo: widget.replyTo,
          // The long side also selects the JPEG quality (q80, HD q85) and
          // is stored with the bubble, so Retry keeps the same profile.
          shrinkImageMaxDimension:
              !widget.sendAsFiles && file is MatrixImageFile
              ? _profile.photoMaxSide
              : null,
          extraContent: captioned ? {'body': label} : null,
          threadRootEventId: widget.threadRootEventId,
          threadLastEventId: widget.threadLastEventId,
          prepare: prepare,
          cancelPrepare: cancelPrepare,
        );
        lastAccepted = ticket.accepted;
        final onAccepted = widget.onAccepted;
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
    final room = widget.room;
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
                  editLabel: l10n.editImage,
                  onEdit: current.kind == _Kind.image && !_locked
                      ? () => _editImage(_page)
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

  const _PreviewPage({super.key, required this.item, this.videoFrame});

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
                  ClipRRect(
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

/// The editor's result: an opaque edit as JPEG q92 (an edited 12 MP photo
/// was a ~20 MB PNG, MD-20), a transparent one as PNG.
class _EditedImage {
  final Uint8List bytes;
  final String mimeType;
  const _EditedImage(this.bytes, this.mimeType);

  String get extension => mimeType == 'image/jpeg' ? 'jpg' : 'png';
}

enum _EditMode { crop, draw }

/// The crop (a normalized rectangle held by [CropController]), the rotation
/// (quarter turns) and the drawn strokes are only composited into a single
/// full-resolution bitmap when the user saves.
///
/// Returns the edited image ([_EditedImage]: JPEG q92 when the source is
/// opaque, PNG otherwise) via [Navigator.pop], or null if the user cancelled
/// or made no changes (in which case the original file is kept).
class _ImageEditPage extends StatefulWidget {
  final Uint8List bytes;

  const _ImageEditPage({required this.bytes});

  @override
  State<_ImageEditPage> createState() => _ImageEditPageState();
}

class _ImageEditPageState extends State<_ImageEditPage> {
  static const List<Color> _palette = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.purple,
    Colors.black,
    Colors.white,
  ];

  static const Rect _fullCrop = Rect.fromLTWH(0, 0, 1, 1);

  final CropController _cropController = CropController();

  /// Source image, decoded once at full resolution. Never mutated.
  ui.Image? _image;
  Object? _decodeError;

  _EditMode _mode = _EditMode.crop;

  /// Clockwise quarter turns applied on top of the crop. Kept separate from the
  /// crop controller so the crop rectangle always stays in the un-rotated image
  /// coordinate space, which keeps all stroke math rotation-free.
  int _quarterTurns = 0;

  /// Strokes, stored in source-image pixel coordinates (crop- and
  /// rotation-independent) so they stay anchored to the image content.
  final List<_Stroke> _strokes = [];
  Color _color = Colors.red;
  double _strokeWidth = 4.0;
  bool _eraser = false;
  bool _saving = false;

  /// View transform for the draw surface (two-finger pinch to zoom). Drawing
  /// happens with one finger; two fingers zoom via [InteractiveViewer].
  final TransformationController _drawTransform = TransformationController();

  /// Horizontal mirror (flip), applied together with rotation at save time.
  bool _mirror = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _cropController.dispose();
    _drawTransform.dispose();
    // Note: [_image] is intentionally not disposed here. A save may still be
    // rasterizing from it asynchronously when this page is popped; the engine's
    // finalizer reclaims the decoded image once it is no longer referenced.
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (e, s) {
      Logs().w('Unable to decode image for editing', e, s);
      if (mounted) setState(() => _decodeError = e);
    }
  }

  Rect _cropRectPx(ui.Image image) {
    final c = _cropController.crop;
    return Rect.fromLTRB(
      c.left * image.width,
      c.top * image.height,
      c.right * image.width,
      c.bottom * image.height,
    );
  }

  bool get _hasEdits =>
      _strokes.isNotEmpty ||
      _quarterTurns % 4 != 0 ||
      _mirror ||
      _cropController.crop != _fullCrop;

  void _rotate(int direction) {
    if (_saving) return;
    setState(() => _quarterTurns += direction);
  }

  void _toggleMirror() {
    if (_saving) return;
    setState(() => _mirror = !_mirror);
  }

  /// Returns a horizontally mirrored copy of [image] (lossless, axis-aligned).
  Future<ui.Image> _flippedHorizontally(ui.Image image) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.translate(image.width.toDouble(), 0);
    canvas.scale(-1, 1);
    canvas.drawImage(image, Offset.zero, Paint());
    return recorder.endRecording().toImage(image.width, image.height);
  }

  /// Composites the current edits into a single full-resolution image.
  Future<_EditedImage?> _compose(ui.Image image) async {
    // 1. Bake strokes onto the full-resolution image (only if there are any).
    var painted = image;
    if (_strokes.isNotEmpty) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = Size(image.width.toDouble(), image.height.toDouble());
      canvas.drawImage(image, Offset.zero, Paint());
      _StrokePainter(
        strokes: _strokes,
        sourceRect: Offset.zero & size,
      ).paint(canvas, size);
      painted = await recorder.endRecording().toImage(
        image.width,
        image.height,
      );
    }

    // 2. Crop (without rotation — the crop rect lives in the un-rotated frame).
    final cropped = await CropController.getCroppedBitmap(
      crop: _cropController.crop,
      rotation: CropRotation.up,
      image: painted,
    );
    if (!identical(painted, image)) painted.dispose();

    // 3. Mirror, then rotation — both lossless and in the same order as the
    //    on-screen preview (flip inside, rotation outside).
    var staged = cropped;
    if (_mirror) {
      staged = await _flippedHorizontally(cropped);
      cropped.dispose();
    }

    final rotation = imageEditorRotationForQuarterTurns(_quarterTurns);
    var output = staged;
    if (rotation != CropRotation.up) {
      output = await CropController.getCroppedBitmap(
        crop: _fullCrop,
        rotation: rotation,
        image: staged,
      );
      staged.dispose();
    }

    // 4. Encode: an opaque photo as JPEG q92 (visually lossless, a tenth
    //    of the PNG); transparency stays PNG.
    try {
      if (!photoHasAlpha(widget.bytes)) {
        final rgba = await output.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (rgba != null) {
          final (jpeg, _) = await encodeJpegRgba(
            rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
            output.width,
            output.height,
            quality: _editedJpegQuality,
          );
          return _EditedImage(jpeg, 'image/jpeg');
        }
      }
      final data = await output.toByteData(format: ui.ImageByteFormat.png);
      return data == null
          ? null
          : _EditedImage(data.buffer.asUint8List(), 'image/png');
    } finally {
      output.dispose();
    }
  }

  static const _editedJpegQuality = 92;

  Future<void> _save() async {
    if (_saving) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final image = _image;
    // Nothing was changed: keep the original file untouched (pop with null).
    if (image == null || !_hasEdits) {
      navigator.pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await _compose(image);
      if (!mounted) return;
      navigator.pop(result);
    } catch (e, s) {
      Logs().w('Unable to save edited image', e, s);
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(humanErrorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final image = _image;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.editImage),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              tooltip: l10n.save,
              icon: const Icon(Icons.check),
              onPressed: image == null ? null : _save,
            ),
        ],
        bottom: image == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: SegmentedButton<_EditMode>(
                    segments: [
                      ButtonSegment(
                        value: _EditMode.crop,
                        icon: const Icon(Icons.crop),
                        label: Text(l10n.crop),
                      ),
                      ButtonSegment(
                        value: _EditMode.draw,
                        icon: const Icon(Icons.brush_outlined),
                        label: Text(l10n.draw),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: _saving
                        ? null
                        : (s) => setState(() {
                            _mode = s.first;
                            // Start each draw session at the un-zoomed fit.
                            // Gesture-state (active stroke, active pointers,
                            // multi-touch lock) lives inside [_DrawSurface] and
                            // is reset automatically because the widget is
                            // recreated whenever the user switches back.
                            _drawTransform.value = Matrix4.identity();
                          }),
                  ),
                ),
              ),
      ),
      body: _decodeError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.broken_image_outlined, size: 64),
                    const SizedBox(height: 16),
                    Text(l10n.oopsSomethingWentWrong),
                  ],
                ),
              ),
            )
          : image == null
          ? const Center(child: CircularProgressIndicator.adaptive())
          : Column(
              children: [
                Expanded(
                  // Inset from the screen edges so dragging crop handles or
                  // drawing near the border doesn't trigger the system back-
                  // swipe gesture.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20.0,
                      vertical: 12.0,
                    ),
                    child: RotatedBox(
                      quarterTurns: _quarterTurns,
                      child: Transform.flip(
                        flipX: _mirror,
                        child: _mode == _EditMode.crop
                            ? CropImage(
                                controller: _cropController,
                                // Decode a separate image from the original
                                // bytes for the crop widget. Sharing our
                                // [_image] via UiImageProvider is unsafe: when
                                // CropImage is unmounted (switching to draw),
                                // its Image widget disposes the underlying
                                // ui.Image — which would be our [_image],
                                // breaking draw mode and save.
                                image: Image.memory(widget.bytes),
                                overlayPainter: _strokes.isEmpty
                                    ? null
                                    : _StrokePainter(
                                        strokes: _strokes,
                                        sourceRect:
                                            Offset.zero &
                                            Size(
                                              image.width.toDouble(),
                                              image.height.toDouble(),
                                            ),
                                      ),
                              )
                            : _DrawSurface(
                                image: image,
                                cropPx: _cropRectPx(image),
                                strokes: _strokes,
                                color: _color,
                                strokeWidth: _strokeWidth,
                                eraser: _eraser,
                                transformController: _drawTransform,
                                onStrokesChanged: () => setState(() {}),
                              ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: _mode == _EditMode.crop
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: l10n.rotateLeft,
                                icon: const Icon(Icons.rotate_left),
                                onPressed: () => _rotate(-1),
                              ),
                              IconButton(
                                tooltip: l10n.rotateRight,
                                icon: const Icon(Icons.rotate_right),
                                onPressed: () => _rotate(1),
                              ),
                              IconButton(
                                tooltip: l10n.mirror,
                                isSelected: _mirror,
                                icon: const Icon(Icons.flip),
                                onPressed: _toggleMirror,
                              ),
                            ],
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  tooltip: l10n.draw,
                                  isSelected: !_eraser,
                                  icon: const Icon(Icons.brush_outlined),
                                  selectedIcon: const Icon(Icons.brush),
                                  onPressed: () =>
                                      setState(() => _eraser = false),
                                ),
                                IconButton(
                                  tooltip: l10n.eraser,
                                  isSelected: _eraser,
                                  icon: const Icon(
                                    Icons.cleaning_services_outlined,
                                  ),
                                  selectedIcon: const Icon(
                                    Icons.cleaning_services,
                                  ),
                                  onPressed: () =>
                                      setState(() => _eraser = true),
                                ),
                                Expanded(
                                  child: Slider(
                                    min: 1,
                                    max: 30,
                                    value: _strokeWidth,
                                    onChanged: (v) =>
                                        setState(() => _strokeWidth = v),
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.undo,
                                  icon: const Icon(Icons.undo),
                                  onPressed: _strokes.isEmpty
                                      ? null
                                      : () => setState(_strokes.removeLast),
                                ),
                                IconButton(
                                  tooltip: l10n.clear,
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: _strokes.isEmpty
                                      ? null
                                      : () => setState(_strokes.clear),
                                ),
                              ],
                            ),
                            SizedBox(
                              height: 48,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8.0,
                                ),
                                children: [
                                  for (final color in _palette)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4.0,
                                      ),
                                      child: GestureDetector(
                                        onTap: () => setState(() {
                                          _color = color;
                                          _eraser = false;
                                        }),
                                        child: Container(
                                          width: 32,
                                          height: 32,
                                          margin: const EdgeInsets.symmetric(
                                            vertical: 8.0,
                                          ),
                                          decoration: BoxDecoration(
                                            color: color,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: !_eraser && _color == color
                                                  ? theme.colorScheme.primary
                                                  : Colors.grey,
                                              width: !_eraser && _color == color
                                                  ? 3
                                                  : 1,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}

/// Freehand drawing surface with pinch-to-zoom.
///
/// This is a widget class (not a helper method on the parent state) so it gets
/// its own [BuildContext] and its own rebuild boundary — a pointer move only
/// invalidates this subtree, not the whole editor page.
///
/// Persistent editor state (the stroke list, current colour/width/eraser flag,
/// zoom transform) lives on the parent and is passed in as props; only the
/// pure gesture state (active stroke, currently-down pointers, multi-touch
/// lock) lives inside this widget. [onStrokesChanged] is called whenever a
/// stroke is added or discarded so the parent can rebuild consumers like the
/// undo/clear button enable state and the crop overlay preview.
class _DrawSurface extends StatefulWidget {
  final ui.Image image;
  final Rect cropPx;
  final List<_Stroke> strokes;
  final Color color;
  final double strokeWidth;
  final bool eraser;
  final TransformationController transformController;
  final VoidCallback onStrokesChanged;

  const _DrawSurface({
    required this.image,
    required this.cropPx,
    required this.strokes,
    required this.color,
    required this.strokeWidth,
    required this.eraser,
    required this.transformController,
    required this.onStrokesChanged,
  });

  @override
  State<_DrawSurface> createState() => _DrawSurfaceState();
}

class _DrawSurfaceState extends State<_DrawSurface> {
  /// The stroke the current one-finger gesture is drawing, or null when no
  /// stroke is active (e.g. during a two-finger zoom). Held by reference so a
  /// stroke can be fully discarded if the gesture turns into a pinch.
  _Stroke? _activeStroke;

  /// Currently active (touching) pointer ids on the draw surface.
  final Set<int> _pointers = {};

  /// True once a second finger has touched, until all fingers lift again. While
  /// set, drawing is suppressed so a pinch never draws — not at its start and
  /// not when lifting back down to one finger on release.
  bool _multiTouch = false;

  /// Removes a lifted pointer. Once all fingers are up, the multi-touch lock is
  /// released so a fresh single touch can draw again.
  void _endPointer(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty) {
      setState(() {
        _multiTouch = false;
        _activeStroke = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cropPx = widget.cropPx;
    return Center(
      child: AspectRatio(
        aspectRatio: cropPx.width / cropPx.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            // Map a pointer position (viewport pixels) to source-image pixels,
            // going through the current zoom transform first.
            Offset toImagePx(Offset viewportPoint) => imageEditorLocalToImagePx(
              widget.transformController.toScene(viewportPoint),
              size,
              cropPx,
            );
            // Drawing is driven from raw pointer events (not InteractiveViewer's
            // gesture phases) so the real finger count decides draw vs. zoom.
            // The Listener is passive: it never enters the gesture arena, so
            // InteractiveViewer below still handles the two-finger pinch.
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                _pointers.add(e.pointer);
                if (_pointers.length >= 2) {
                  // A pinch: this gesture is a zoom. Drop any stroke it started
                  // and block drawing until every finger has lifted again.
                  _multiTouch = true;
                  final active = _activeStroke;
                  if (active != null) {
                    widget.strokes.remove(active);
                    setState(() => _activeStroke = null);
                    widget.onStrokesChanged();
                  }
                  return;
                }
                if (_multiTouch) return;
                final stroke = _Stroke(
                  color: widget.color,
                  width: widget.strokeWidth * (cropPx.width / size.width),
                  eraser: widget.eraser,
                  points: [toImagePx(e.localPosition)],
                );
                widget.strokes.add(stroke);
                setState(() => _activeStroke = stroke);
                widget.onStrokesChanged();
              },
              onPointerMove: (e) {
                final active = _activeStroke;
                if (active == null || _multiTouch || _pointers.length != 1) {
                  return;
                }
                setState(() => active.points.add(toImagePx(e.localPosition)));
              },
              onPointerUp: (e) => _endPointer(e.pointer),
              onPointerCancel: (e) => _endPointer(e.pointer),
              child: InteractiveViewer(
                transformationController: widget.transformController,
                // One finger draws (via the Listener); two fingers pinch-zoom.
                panEnabled: false,
                minScale: 1,
                maxScale: 8,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _CroppedImagePainter(
                        image: widget.image,
                        sourceRect: cropPx,
                      ),
                    ),
                    CustomPaint(
                      painter: _StrokePainter(
                        strokes: widget.strokes,
                        sourceRect: cropPx,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Stroke {
  final Color color;

  /// Stroke width, in source-image pixels.
  final double width;
  final bool eraser;

  /// Points, in source-image pixel coordinates.
  final List<Offset> points;

  _Stroke({
    required this.color,
    required this.width,
    required this.eraser,
    required this.points,
  });
}

/// Paints the [sourceRect] region (in image pixels) of [image] to fill the
/// canvas. Only repaints when the image or the crop changes, so freehand
/// drawing doesn't continuously re-rasterize the background.
class _CroppedImagePainter extends CustomPainter {
  final ui.Image image;
  final Rect sourceRect;

  const _CroppedImagePainter({required this.image, required this.sourceRect});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      sourceRect,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant _CroppedImagePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.sourceRect != sourceRect;
}

/// Paints freehand [strokes] (stored in source-image pixel coordinates) onto a
/// canvas that shows the image region [sourceRect] scaled to fill the canvas.
class _StrokePainter extends CustomPainter {
  final List<_Stroke> strokes;
  final Rect sourceRect;

  const _StrokePainter({required this.strokes, required this.sourceRect});

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;
    final scale = size.width / sourceRect.width;
    // saveLayer so eraser strokes (BlendMode.clear) only erase prior strokes
    // within this layer, not whatever is painted below it.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.translate(-sourceRect.left * scale, -sourceRect.top * scale);
    canvas.scale(scale);
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (stroke.eraser) {
        paint
          ..color = const Color(0xFF000000)
          ..blendMode = BlendMode.clear;
      } else {
        paint.color = stroke.color;
      }
      // A single point (a tap) renders as a dot.
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first,
          stroke.width / 2,
          Paint()
            ..color = paint.color
            ..blendMode = paint.blendMode
            ..style = PaintingStyle.fill,
        );
        continue;
      }
      final path = Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (final p in stroke.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}
