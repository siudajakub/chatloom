// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/inbox_health.dart' show networkRoute;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Debounced connection status line: "Connecting…" / "Waiting for
/// network…" / "Updating…" after the grace period, nothing while online.
/// One self-contained widget for the inbox header
/// (`NotionInboxPage(headerStatus:)`) and chat headers
/// (`NotionCompactChatHeader(status:)`).
class ConnectionStatusLine extends StatelessWidget {
  const ConnectionStatusLine({super.key, required this.client, this.monitor});

  final Client client;

  /// Test seam; defaults to the client's shared monitor.
  final ConnectionStatusMonitor? monitor;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: monitor ?? ConnectionStatusMonitor.of(client),
    builder: (context, phase, _) => NotionStatusLine(status: phase.label),
  );
}

/// Banner at the top of a chat (under the glass header, over the timeline)
/// while the chat's network bridge has a problem: "WhatsApp is disconnected —
/// messages won't be delivered until it reconnects". Place it directly in
/// the chat body's `Stack`; it positions itself below the header.
class ChatBridgeNotice extends StatefulWidget {
  const ChatBridgeNotice({super.key, required this.room, this.monitor});

  final Room room;

  /// Test seam; defaults to the client's shared monitor.
  final BridgeHealthMonitor? monitor;

  /// Banner text for [health]; pure, shared with tests.
  static (String title, String message) textFor(BridgeHealth health) {
    return switch (health.state) {
      BridgeHealthState.loggedOut => (
        health.title,
        'Messages won’t arrive or be delivered until you sign in again.',
      ),
      BridgeHealthState.disconnected => (
        health.title,
        'Messages won’t be delivered until it reconnects.',
      ),
      _ => (health.title, health.reason),
    };
  }

  @override
  State<ChatBridgeNotice> createState() => _ChatBridgeNoticeState();
}

class _ChatBridgeNoticeState extends State<ChatBridgeNotice> {
  /// Hidden per chat until the problem changes (this app run only).
  static final _dismissed = <String>{};

  BridgeHealth? _last;

  BridgeHealthMonitor get _monitor =>
      widget.monitor ?? BridgeHealthMonitor.of(widget.room.client);

  String _key(BridgeHealth health) => '${widget.room.id}|${health.signature}';

  /// The network page explains the problem and offers its fix (BR-08).
  void _open(BridgeHealth health) => context.push(networkRoute(health.network));

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Positioned(
      top: top + NotionSpace.xs,
      left: NotionSpace.sm,
      right: NotionSpace.sm,
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: _monitor,
          builder: (context, _) {
            final problem = _monitor.problemFor(widget.room);
            final visible =
                problem != null && !_dismissed.contains(_key(problem));
            if (visible) _last = problem;
            final shown = _last;
            if (shown == null) return const SizedBox.shrink();
            final (title, message) = ChatBridgeNotice.textFor(shown);
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ChatLoomThemes.maxTimelineWidth,
                ),
                child: NotionSizeReveal(
                  visible: visible,
                  revealOnMount: true,
                  child: NotionFadeThrough(
                    child: SizedBox(
                      key: ValueKey(shown.signature),
                      width: double.infinity,
                      child: NotionCallout(
                        icon: bridgeHealthIcon(shown.state),
                        tone: shown.state == BridgeHealthState.degraded
                            ? NotionCalloutTone.warning
                            : NotionCalloutTone.danger,
                        title: title,
                        message: message,
                        actionLabel: shown.state == BridgeHealthState.loggedOut
                            ? 'Sign in'
                            : 'Details',
                        onAction: () => _open(shown),
                        onDismiss: () =>
                            setState(() => _dismissed.add(_key(shown))),
                        dismissLabel: 'Hide until something changes',
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Icon of a bridge problem (chat banner and inbox row).
IconData bridgeHealthIcon(BridgeHealthState state) => switch (state) {
  BridgeHealthState.loggedOut => Icons.link_off,
  BridgeHealthState.disconnected => Icons.sync_problem_outlined,
  _ => Icons.warning_amber_outlined,
};
