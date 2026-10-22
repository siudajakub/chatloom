// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/utils/platform_infos.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Test seam: whether the system confirms clipboard writes itself.
@visibleForTesting
bool? debugSystemShowsClipboardOverlay;

Future<bool>? _systemOverlay;

/// Android 13 (API 33) and later show their own clipboard overlay for every
/// copy, so an app toast would say it twice (Telegram's
/// `AndroidUtilities.shouldShowClipboardToast`). Asked once per process.
Future<bool> systemShowsClipboardOverlay() {
  final debug = debugSystemShowsClipboardOverlay;
  if (debug != null) return SynchronousFuture(debug);
  if (!PlatformInfos.isAndroid) return SynchronousFuture(false);
  return _systemOverlay ??= DeviceInfoPlugin().androidInfo
      .then((info) => info.version.sdkInt >= 33)
      .catchError((Object _) => false);
}

/// Confirms a copy with a snackbar saying [label], unless the system
/// already shows its own confirmation (then nothing is shown).
Future<void> showCopiedNotice(BuildContext context, String label) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  if (await systemShowsClipboardOverlay()) return;
  messenger.showSnackBar(SnackBar(content: Text(label)));
}
