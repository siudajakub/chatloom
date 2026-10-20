// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

extension MatrixFileExtension on MatrixFile {
  Future<void> save(BuildContext context) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    final downloadPath = await FilePicker.saveFile(
      dialogTitle: l10n.saveFile,
      fileName: name,
      type: filePickerFileType,
      bytes: bytes,
    );
    if (downloadPath == null) return;

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(l10n.fileHasBeenSavedAt(downloadPath.toString())),
        showCloseIcon: true,
      ),
    );
  }

  FileType get filePickerFileType {
    if (this is MatrixImageFile) return FileType.image;
    if (this is MatrixAudioFile) return FileType.audio;
    if (this is MatrixVideoFile) return FileType.video;
    return FileType.any;
  }

  Future<void> share(BuildContext context) async {
    // Workaround for iPad from
    // https://github.com/fluttercommunity/plus_plugins/tree/main/packages/share_plus/share_plus#ipad
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    if (kIsWeb) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, name: name, mimeType: mimeType)],
          sharePositionOrigin: origin,
        ),
      );
      return;
    }
    final access = await MediaAccess.open(
      directory: Directory(
        '${(await getTemporaryDirectory()).path}/personal_media',
      ),
    );
    final extension = switch (msgType) {
      'm.image' => '.jpg',
      'm.audio' => '.ogg',
      'm.video' => '.mp4',
      _ => '.bin',
    };
    final lease = await access.create(bytes, extension: extension);
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(lease.file.path, name: name, mimeType: mimeType)],
          sharePositionOrigin: origin,
        ),
      );
    } finally {
      await lease.close();
    }
    return;
  }

  MatrixFile get detectFileType {
    if (msgType == MessageTypes.Image) {
      return MatrixImageFile(bytes: bytes, name: name);
    }
    if (msgType == MessageTypes.Video) {
      return MatrixVideoFile(bytes: bytes, name: name);
    }
    if (msgType == MessageTypes.Audio) {
      return MatrixAudioFile(bytes: bytes, name: name);
    }
    return this;
  }

  String get sizeString => size.sizeString;
}
