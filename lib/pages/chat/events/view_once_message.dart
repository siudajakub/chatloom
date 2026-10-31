// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/view_once_openings.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show InstagramRavenMode;

import 'image_bubble.dart';
import 'video_player.dart';

/// Opens [event] full screen (the existing media viewer).
typedef ViewOnceOpen =
    void Function(BuildContext context, Event event, Timeline timeline);

/// An Instagram view-once ("raven") photo or video in a conversation, the
/// ordinary and the merged chat alike (J, 2026-10-31).
///
/// Until it is opened on this device it is a "Tap to view" card that shows
/// nothing of the media. Its bytes load exactly as an ordinary photo or video
/// bubble's would (the same bubble is built offstage: same request, same
/// caches), so the first tap opens at once. The tap records the opening in
/// the device-local [ViewOnceOpenings] and opens the media viewer; from then
/// on the message is the ordinary photo or video, re-openable any number of
/// times, with a badge reminding that Instagram was not told: the bridge
/// never reports an opening, so the sender still sees it unopened.
/// Save, share and forward stay hidden (`RoundMediaPolicy.canExport`).
class ViewOnceMessage extends StatelessWidget {
  const ViewOnceMessage(
    this.event, {
    super.key,
    required this.mode,
    required this.timeline,
    required this.borderRadius,
    required this.textColor,
    required this.linkColor,
    this.openings,
    this.onOpen,
  });

  final Event event;
  final InstagramRavenMode mode;
  final Timeline timeline;
  final BorderRadius borderRadius;
  final Color textColor;
  final Color linkColor;

  /// Registry of openings; [ViewOnceOpenings.instance] by default.
  final ViewOnceOpenings? openings;

  /// Opens the viewer on the first tap; [showImageViewer] with this message
  /// alone by default (no swiping on to its neighbours).
  final ViewOnceOpen? onOpen;

  /// Badge text over opened media.
  static const notMarkedLabel = 'Not marked as opened on Instagram';

  static bool _video(Event event) => event.messageType == MessageTypes.Video;

  /// "Photo · View once", "Video · Replay allowed".
  static String titleFor(Event event, InstagramRavenMode mode) =>
      '${_video(event) ? 'Video' : 'Photo'} · '
      '${mode == InstagramRavenMode.allowReplay ? 'Replay allowed' : 'View once'}';

  static void _openViewer(BuildContext context, Event event, Timeline _) =>
      showImageViewer(context, event, mediaEvents: [event]);

  /// The ordinary bubble content of this photo or video.
  Widget _media(BuildContext context) {
    if (_video(event)) {
      return EventVideoPlayer(
        event,
        textColor: textColor,
        linkColor: linkColor,
        timeline: timeline,
        borderRadius: borderRadius,
      );
    }
    // The photo rule of an ordinary bubble (MessageContent).
    final info = event.content.tryGetMap<String, Object?>('info');
    final box = ConversationMedia.frame(
      maxWidth: NotionBubble.mediaMaxWidth,
      width: info?.tryGet<int>('w'),
      height: info?.tryGet<int>('h'),
    );
    return ImageBubble(
      event,
      width: box.width,
      height: box.height,
      fit: BoxFit.cover,
      sticker: false,
      borderRadius: borderRadius,
      timeline: timeline,
      textColor: textColor,
      onTap: () => showImageViewer(context, event, timeline: timeline),
    );
  }

  @override
  Widget build(BuildContext context) {
    final openings = this.openings ?? ViewOnceOpenings.instance;
    return ListenableBuilder(
      listenable: openings,
      builder: (context, _) {
        final opened = openings.isOpened(event);
        final video = _video(event);
        return Stack(
          children: [
            // One tree in both states: the bubble built while sealed is the
            // bubble shown once opened, so nothing loads twice. Offstage, it
            // is neither painted, hit nor read out, and takes no hero flight.
            HeroMode(
              enabled: opened,
              child: Offstage(offstage: !opened, child: _media(context)),
            ),
            if (!opened)
              ConversationMessageChromeTap(
                child: NotionViewOnceCard(
                  title: titleFor(event, mode),
                  semanticLabel: video ? 'View-once video' : 'View-once photo',
                  borderRadius: borderRadius,
                  onTap: () {
                    openings.markOpened(event);
                    (onOpen ?? _openViewer)(context, event, timeline);
                  },
                ),
              )
            else
              const PositionedDirectional(
                top: NotionSpace.xs,
                end: NotionSpace.xs,
                child: NotionViewOnceBadge(label: notMarkedLabel),
              ),
          ],
        );
      },
    );
  }
}
