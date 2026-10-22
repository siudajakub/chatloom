// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cross_file/cross_file.dart';

/// Something to forward or share; the picker is `showForwardSheet`
/// (`lib/personal/ui/forward_sheet.dart`), which replaced FluffyChat's
/// share dialog.
abstract class ShareItem {}

class TextShareItem extends ShareItem {
  final String value;
  TextShareItem(this.value);
}

class ContentShareItem extends ShareItem {
  final Map<String, Object?> value;
  ContentShareItem(this.value);
}

class FileShareItem extends ShareItem {
  final XFile value;
  FileShareItem(this.value);
}
