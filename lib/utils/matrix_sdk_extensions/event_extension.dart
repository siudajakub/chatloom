// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:async/async.dart' as async;
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
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
          content: Text(
            'This protected message cannot be saved or shared.',
          ),
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
          return downloadAndDecryptAttachment(
            onDownloadProgress: fileSize == null
                ? null
                : (bytes) => onProgress(bytes / fileSize),
          );
        },
      );

  Future<void> saveFile(BuildContext context) async {
    if (!await _guardMediaExport(context)) return;
    if (!context.mounted) return;
    final matrixFile = await _getFile(context);
    if (!context.mounted) return;
    if (!await _guardMediaExport(context)) return;
    if (!context.mounted) return;

    matrixFile.result?.save(context);
  }

  Future<void> shareFile(BuildContext context) async {
    if (!await _guardMediaExport(context)) return;
    if (!context.mounted) return;
    final matrixFile = await _getFile(context);
    if (!context.mounted) return;
    if (!await _guardMediaExport(context)) return;
    if (!context.mounted) return;

    matrixFile.result?.share(context);
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
