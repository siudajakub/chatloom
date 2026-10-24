// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/media/media_store.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/size_string.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// How long a file shared on macOS stays readable for the chosen service.
const _macShareLease = Duration(minutes: 5);

extension MatrixFileExtension on MatrixFile {
  /// One-tap save (Telegram): on Android straight into the gallery
  /// (`Pictures/ChatLoom`, `Movies/ChatLoom`) or `Download/ChatLoom`, with
  /// an inline confirmation; elsewhere, and on Android 9 and older, the
  /// system save dialog ([saveAs]), on macOS opened in `~/Downloads`.
  Future<void> save(BuildContext context) async {
    if (!PlatformInfos.isAndroid) return saveAs(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    MediaStoreCollection? saved;
    try {
      saved = await MediaStore.save(this);
    } catch (e) {
      Logs().w('Unable to save to MediaStore', e.runtimeType);
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save the file. Check free space and try again.',
          ),
        ),
      );
      return;
    }
    if (saved == null) {
      if (context.mounted) await saveAs(context);
      return;
    }
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text(saved.savedMessage), showCloseIcon: true),
    );
  }

  /// The system "Save as" dialog: the user picks the folder and name.
  Future<void> saveAs(BuildContext context) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    final downloadPath = await FilePicker.saveFile(
      dialogTitle: l10n.saveFile,
      fileName: exportFileName(name, mimeType),
      initialDirectory: PlatformInfos.isMacOS
          ? macDownloadsDirectory(Platform.environment['HOME'])
          : null,
      type: filePickerFileType,
      mimeType: mimeType,
      bytes: bytes,
    );
    if (downloadPath == null) return;

    scaffoldMessenger.showSnackBar(
      SnackBar(
        // Not the device path (CS-11): the person chose where it went.
        content: const Text('File saved.'),
        showCloseIcon: true,
      ),
    );
  }

  /// Puts this image on the clipboard (macOS: in memory, nothing on disk).
  Future<void> copyImage(BuildContext context) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      await Pasteboard.writeImage(bytes);
    } catch (e) {
      Logs().w('Unable to copy image', e.runtimeType);
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Could not copy the image.')),
      );
      return;
    }
    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text('Image copied'), showCloseIcon: true),
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
    // The real extension (PNG, GIF, WebP, PDF…): share targets read it.
    final fileName = exportFileName(name, mimeType);
    final lease = await access.create(
      bytes,
      extension: fileExtension(fileName),
    );
    var keepForService = false;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(lease.file.path, name: fileName, mimeType: mimeType)],
          sharePositionOrigin: origin,
        ),
      );
      // macOS answers when a service is chosen, before AirDrop or Messages
      // read the file: keep the private lease a few minutes (a crash leaves
      // it to the next start's MediaAccess cleanup).
      keepForService =
          PlatformInfos.isMacOS && result.status == ShareResultStatus.success;
    } finally {
      if (keepForService) {
        Timer(_macShareLease, () => unawaited(lease.close()));
      } else {
        await lease.close();
      }
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
