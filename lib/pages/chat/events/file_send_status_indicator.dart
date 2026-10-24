// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/pages/chat/events/outgoing_upload_progress.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class FileSendStatusIndicator extends StatelessWidget {
  final FileSendingStatus fileSendingStatus;

  /// Upload progress: the ring fills while bytes go out.
  final ValueListenable<double?>? progress;
  const FileSendStatusIndicator({
    super.key,
    required this.fileSendingStatus,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    return CircleAvatar(
      child: Stack(
        alignment: Alignment.center,
        children: [
          switch (fileSendingStatus) {
            FileSendingStatus.generatingThumbnail => Icon(
              Icons.compress_outlined,
              size: 18,
            ),
            FileSendingStatus.encrypting => Icon(Icons.lock_outlined, size: 18),
            FileSendingStatus.uploading => Icon(
              Icons.upload_outlined,
              size: 18,
            ),
          },
          if (progress == null)
            const NotionDelayedSpinner(
              size: 40,
              strokeWidth: 3,
              delay: Duration.zero,
            )
          else
            OutgoingUploadIndicator(
              progress: progress,
              size: 40,
              strokeWidth: 3,
              color: Theme.of(context).colorScheme.primary,
            ),
        ],
      ),
    );
  }
}
