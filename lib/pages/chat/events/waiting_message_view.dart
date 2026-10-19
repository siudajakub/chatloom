// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:fluffychat/personal/encryption/key_recovery_stage.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Body of a bubble whose message this device cannot decrypt yet: what is
/// happening to its key and, when it is stuck, one way forward. Data and
/// callbacks only; `UndecryptableMessage` binds it to a Matrix event.
class WaitingMessageView extends StatelessWidget {
  /// `null` while the first request is being prepared.
  final KeyRecoveryStage? stage;

  /// Bubble text colour (follows a private chat palette).
  final Color textColor;
  final VoidCallback? onRetry;
  final VoidCallback? onVerify;

  const WaitingMessageView({
    super.key,
    required this.stage,
    required this.textColor,
    this.onRetry,
    this.onVerify,
  });

  static const _spinner = NotionSize.iconSm - NotionSpace.xxs;

  /// Lowers the 20 pt lock onto the title's first line.
  static const _iconNudge = NotionSpace.xxs / 2;

  static String title(KeyRecoveryStage? stage) =>
      stage == KeyRecoveryStage.permanent
      ? 'Can’t decrypt this message'
      : 'Waiting for this message';

  static String detail(KeyRecoveryStage? stage) => switch (stage) {
    null => 'Looking for the key…',
    KeyRecoveryStage.backup => 'Checking your key backup…',
    KeyRecoveryStage.devices => 'Asked your other devices for the key',
    KeyRecoveryStage.keyReceived => 'Key received. Decrypting…',
    KeyRecoveryStage.failed =>
      'Couldn’t get the key. Your other devices may be offline.',
    KeyRecoveryStage.verifySession =>
      'Verify this session to get the key from your other devices.',
    KeyRecoveryStage.permanent =>
      'This device can never read it. Other sessions may still show it.',
  };

  @override
  Widget build(BuildContext context) {
    final stage = this.stage;
    final muted = textColor.withValues(alpha: .72);
    final busy = stage == null || stage.inFlight;
    const detailStyle = NotionType.footnote;
    final detailLine =
        MediaQuery.textScalerOf(context).scale(detailStyle.fontSize!) *
        (detailStyle.height ?? 1.2);
    final spinnerTop = math.max(0.0, detailLine - _spinner) / 2;
    final action = switch (stage) {
      KeyRecoveryStage.failed => ('Try again', Icons.refresh, onRetry),
      KeyRecoveryStage.verifySession => (
        'Verify session',
        Icons.verified_user_outlined,
        onVerify,
      ),
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NotionSpace.xxs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: _iconNudge),
            child: Icon(
              stage == KeyRecoveryStage.permanent
                  ? Icons.lock_outline
                  : Icons.lock_clock_outlined,
              size: NotionSize.icon,
              color: muted,
            ),
          ),
          const SizedBox(width: NotionSpace.xs),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title(stage),
                  style: NotionType.body.copyWith(color: textColor),
                ),
                Semantics(
                  liveRegion: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (busy) ...[
                        // Centred on the first line when the status wraps.
                        Padding(
                          padding: EdgeInsets.only(top: spinnerTop),
                          child: SizedBox.square(
                            dimension: _spinner,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: muted,
                            ),
                          ),
                        ),
                        const SizedBox(width: NotionSpace.xs),
                      ],
                      Flexible(
                        child: Text(
                          detail(stage),
                          style: detailStyle.copyWith(color: muted),
                        ),
                      ),
                    ],
                  ),
                ),
                if (action != null && action.$3 != null)
                  Padding(
                    padding: const EdgeInsets.only(top: NotionSpace.xs),
                    child: _BubbleAction(
                      label: action.$1,
                      icon: action.$2,
                      color: textColor,
                      onTap: action.$3!,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact outlined action drawn in the bubble's own text colour, so it
/// stays legible on private palettes.
class _BubbleAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _BubbleAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  // Same 40 pt height as NotionButton; the pill is the whole hit area.
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: NotionRadius.mdAll,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: NotionSpace.sm),
          decoration: BoxDecoration(
            borderRadius: NotionRadius.mdAll,
            border: Border.all(color: color.withValues(alpha: .32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: NotionSize.iconSm, color: color),
              const SizedBox(width: NotionSpace.xs),
              Text(
                label,
                style: NotionType.footnote.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
