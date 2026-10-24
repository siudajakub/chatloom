// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/pages/chat/events/file_send_status_indicator.dart';
import 'package:chatloom/pages/chat/events/outgoing_upload_progress.dart';
import 'package:chatloom/personal/media/open_file.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class MessageDownloadContent extends StatelessWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;

  const MessageDownloadContent(
    this.event, {
    required this.textColor,
    required this.linkColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final filename = event.content.tryGet<String>('filename') ?? event.body;
    final filetype = (filename.contains('.')
        ? filename.split('.').last.toUpperCase()
        : event.content
                  .tryGetMap<String, Object?>('info')
                  ?.tryGet<String>('mimetype')
                  ?.toUpperCase() ??
              'UNKNOWN');
    final sizeString = event.sizeString ?? 'Size unavailable';
    final fileDescription = event.fileDescription;
    // The SDK keeps the last upload phase on a failed file; the bubble's
    // failure line explains it instead of a spinner that never stops.
    final uploading = isOutgoingUpload(event);
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .start,
      spacing: 8,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(NotionTokens.radius),
            // Telegram: a tap downloads (ring in the bubble, a second tap
            // cancels) and opens the file in its default app; Save stays in
            // the message menu.
            onTap: () => event.openFile(context),
            child: Container(
              // Hugs the file name, up to the media width.
              constraints: const BoxConstraints(
                maxWidth: NotionBubble.mediaMaxWidth,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NotionTokens.radius),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisSize: .min,
                spacing: 16,
                children: [
                  if (uploading)
                    FileSendStatusIndicator(
                      fileSendingStatus:
                          event.fileSendingStatus ??
                          FileSendingStatus.uploading,
                      progress: uploadProgressOf(event),
                    )
                  else
                    FileOpenStatusIcon(
                      eventId: event.eventId,
                      idle: Icon(
                        Icons.insert_drive_file_outlined,
                        color: textColor,
                        size: 28,
                      ),
                    ),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: .start,
                      mainAxisSize: .min,
                      children: [
                        Text(
                          filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '$sizeString · $filetype',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: textColor, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (fileDescription != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Linkify(
              text: fileDescription,
              textWidthBasis: TextWidthBasis.longestLine,
              textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
              style: TextStyle(
                color: textColor,
                fontSize: AppConfig.messageFontSize,
              ),
              options: const LinkifyOptions(humanize: false),
              linkStyle: TextStyle(
                color: linkColor,
                fontSize: AppConfig.messageFontSize,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              ),
              onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
            ),
          ),
        ],
      ],
    );
  }
}
