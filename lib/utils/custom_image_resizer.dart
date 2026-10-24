// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/media/photo_encoder.dart';
import 'package:matrix/matrix.dart';

/// The SDK's image resizer on Android and macOS: ChatLoom's sweet-spot photo
/// encoder ([encodePhoto], profile in `lib/personal/media/media_quality.dart`).
/// It replaced FluffyChat's full-size decode + JPEG q75 of every image, which
/// blackened transparent images and re-encoded files that needed no change.
Future<MatrixImageFileResizedResponse?> customImageResizer(
  MatrixImageFileResizeArguments arguments,
) async {
  try {
    return await encodePhoto(arguments);
  } catch (e, s) {
    Logs().e('Could not prepare the photo', e, s);
    return null;
  }
}
