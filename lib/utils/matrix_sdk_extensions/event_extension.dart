// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:async/async.dart' as async;
import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/open_file.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:chatloom/widgets/lottie_sticker_data.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'matrix_file_extension.dart';

extension LocalizedBody on Event {
  bool get personalMediaExportAllowed =>
      !redacted &&
      {EventTypes.Message, EventTypes.Sticker}.contains(type) &&
      RoundMediaPolicy.fromContent(content).canExport;

  Future<bool> _guardMediaExport(BuildContext context) async {
    if (!status.isSent) {
      // An unsent file is saved or shared once the server has it (the
      // download would find no file yet, never delete the bubble).
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This file is not sent yet. Save or share it once it is sent.',
            ),
          ),
        );
      }
      return false;
    }
    var allowed = personalMediaExportAllowed;
    if (allowed && RoundVideoDescriptor.fromContent(content) != null) {
      try {
        final state = await TelegramRoundService.of(
          room.client,
        ).mediaState(this);
        allowed = state?['expired'] != true && personalMediaExportAllowed;
      } catch (_) {
        allowed = false;
      }
    }
    if (allowed) return true;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This protected message cannot be saved or shared.'),
        ),
      );
    }
    return false;
  }

  Future<async.Result<MatrixFile?>> _getFile(BuildContext context) =>
      showFutureLoadingDialog(
        context: context,
        futureWithProgress: (onProgress) {
          final fileSize = infoMap['size'] is int
              ? infoMap['size'] as int
              : null;
          // Same transfer as the viewer: a large video already watched
          // comes from the encrypted video cache instead of the network.
          return downloadAttachmentCancellable(
            this,
            token: MediaDownloadToken(),
            onDownloadProgress: fileSize == null
                ? null
                : (bytes) => onProgress(bytes / fileSize),
          );
        },
      );

  /// Downloads the attachment behind the export gate (checked again after
  /// the download, which may outlive a disappearing message).
  Future<MatrixFile?> _exportableFile(BuildContext context) async {
    if (!await _guardMediaExport(context)) return null;
    if (!context.mounted) return null;
    final matrixFile = await _getFile(context);
    if (!context.mounted) return null;
    if (!await _guardMediaExport(context)) return null;
    if (!context.mounted) return null;
    return matrixFile.result;
  }

  /// One-tap save: the gallery or Downloads on Android, the save panel
  /// elsewhere (see [MatrixFileExtension.save]).
  Future<void> saveFile(BuildContext context) async {
    final file = await _exportableFile(context);
    if (file == null || !context.mounted) return;
    await file.save(context);
  }

  /// Telegram's file tap: download (progress in the bubble, a second tap
  /// cancels), then open in the system's default app from a short-lived
  /// private copy; "Save" where that is not possible (see
  /// [openEventAttachment]).
  Future<void> openFile(BuildContext context) => openEventAttachment(
    context,
    this,
    guard: () => _guardMediaExport(context),
    save: () => saveFile(context),
  );

  /// The system "Save as" dialog (Android: choose folder and name).
  Future<void> saveFileAs(BuildContext context) async {
    final file = await _exportableFile(context);
    if (file == null || !context.mounted) return;
    await file.saveAs(context);
  }

  Future<void> shareFile(BuildContext context) async {
    final file = await _exportableFile(context);
    if (file == null || !context.mounted) return;
    await file.share(context);
  }

  /// Whether "Copy image" applies: a still or animated picture (not a
  /// Lottie sticker) that may be exported, on macOS, where the clipboard
  /// holds it in memory. Android's clipboard plugin would write a
  /// plaintext copy into the app cache, so it is not offered there.
  bool get canCopyImage =>
      PlatformInfos.isMacOS &&
      personalMediaExportAllowed &&
      status.isSent &&
      {MessageTypes.Image, MessageTypes.Sticker}.contains(messageType) &&
      !LottieStickerData.isLottieMime(attachmentMimetype);

  Future<void> copyImage(BuildContext context) async {
    final file = await _exportableFile(context);
    if (file == null || !context.mounted) return;
    await file.copyImage(context);
  }

  bool get isAttachmentSmallEnough =>
      infoMap['size'] is int &&
      (infoMap['size'] as int) < room.client.database.maxFileSize;

  bool get isThumbnailSmallEnough =>
      thumbnailInfoMap['size'] is int &&
      (thumbnailInfoMap['size'] as int) < room.client.database.maxFileSize;

  bool get showThumbnail =>
      !redacted &&
      RoundMediaPolicy.fromContent(content).canPersist &&
      [
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Video,
      ].contains(messageType) &&
      (kIsWeb ||
          isAttachmentSmallEnough ||
          isThumbnailSmallEnough ||
          (content['url'] is String));

  String? get sizeString => content
      .tryGetMap<String, Object?>('info')
      ?.tryGet<int>('size')
      ?.sizeString;
}
