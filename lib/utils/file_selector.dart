// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
// The endorsed Android implementation of image_picker (resolved through it,
// see pubspec.lock): its photo picker switch has no app-facing API.
// ignore: depend_on_referenced_packages
import 'package:image_picker_android/image_picker_android.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;

Future<List<XFile>> selectFiles(
  BuildContext context, {
  String? title,
  FileType type = FileType.any,
  bool allowMultiple = false,
}) async {
  final result = await AppLock.of(context).pauseWhile(
    showFutureLoadingDialog(
      context: context,
      future: () async {
        if (allowMultiple) {
          final result = await FilePicker.pickFiles(
            type: type,
            dialogTitle: title,
          );
          return result.map((file) => file.xFile).toList();
        }
        final result = await FilePicker.pickFile(
          type: type,
          dialogTitle: title,
        );
        return [?result?.xFile];
      },
    ),
  );
  return result.result ?? [];
}

/// Routes image_picker's gallery picks on Android through the system Photo
/// Picker (`PickVisualMedia`, which also lists Google Photos cloud media).
/// Without it image_picker_android 0.8.13 sends `ACTION_GET_CONTENT` with
/// `*/*`, i.e. the same documents UI as "File". Idempotent.
void useSystemPhotoPicker() {
  if (!PlatformInfos.isAndroid) return;
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
}

/// Photos and videos, several at once. Phones open the system photo picker
/// directly (Android Photo Picker, iOS PHPicker); other platforms fall back to
/// the file picker filtered to media.
Future<List<XFile>> selectPhotosOrVideos(
  BuildContext context, {
  String? title,
}) async {
  if (!PlatformInfos.isMobile) {
    return selectFiles(
      context,
      title: title,
      type: FileType.media,
      allowMultiple: true,
    );
  }
  useSystemPhotoPicker();
  // The picker returns only after it copied the files (cloud videos can take
  // a while), so the loading dialog covers that wait after it closes.
  final result = await AppLock.of(context).pauseWhile(
    showFutureLoadingDialog(
      context: context,
      future: () => ImagePicker().pickMultipleMedia(requestFullMetadata: false),
    ),
  );
  return result.result ?? [];
}
