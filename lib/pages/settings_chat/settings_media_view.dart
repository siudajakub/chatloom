// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:material_ui/material_ui.dart';

/// Settings → Chats & media → Voice messages & round videos.
///
/// Capture quality for voice notes (read by `RecordingViewModel` when a
/// recording starts), round video capture options and automatic downloads
/// of voice and round messages.
class SettingsMediaPage extends StatefulWidget {
  /// Round video capture exists on Android and macOS; tests can force the
  /// section.
  final bool? showRoundOptions;

  /// Bluetooth headset recording is an Android (SCO) choice; macOS records
  /// from the system's input device. Tests can force the row.
  final bool? showBluetoothOption;

  /// Capture effects exist only on Android: the voice note's noise
  /// suppression, gain, echo cancellation and strong noise reduction, and
  /// the round's stabilization and call-microphone noise reduction. macOS
  /// records voice notes to a file without effects (docs/voice-recording.md)
  /// and its rounds honour only High quality. Tests can force the rows.
  final bool? showEffectOptions;
  const SettingsMediaPage({
    super.key,
    this.showRoundOptions,
    this.showBluetoothOption,
    this.showEffectOptions,
  });

  @override
  State<SettingsMediaPage> createState() => _SettingsMediaPageState();
}

class _SettingsMediaPageState extends State<SettingsMediaPage> {
  final Set<AppSettings<bool>> _pending = {};

  Future<void> _set(AppSettings<bool> setting, bool value) async {
    setState(() => _pending.add(setting));
    try {
      await setting.setItem(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save this setting. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending.remove(setting));
    }
  }

  Widget _toggle(
    AppSettings<bool> setting, {
    required String title,
    String? subtitle,
    bool enabled = true,
    bool? forcedValue,
  }) => NotionSettingsToggle(
    key: ValueKey(setting.key),
    title: title,
    subtitle: subtitle,
    value: forcedValue ?? setting.value,
    onChanged: !enabled || forcedValue != null || _pending.contains(setting)
        ? null
        : (value) => _set(setting, value),
  );

  @override
  Widget build(BuildContext context) {
    final isolation = AppSettings.personalVoiceIsolation.value;
    final autoDownload = AppSettings.personalAutoDownloadVoiceRounds.value;
    final rounds =
        widget.showRoundOptions ?? PlatformInfos.supportsRoundCapture;
    final bluetooth = widget.showBluetoothOption ?? PlatformInfos.isAndroid;
    final effects = widget.showEffectOptions ?? !PlatformInfos.isMacOS;
    final secondary = context.notion.colors.textSecondary;
    return NotionSettingsScaffold(
      title: 'Voice messages & round videos',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotionSettingsSection('Voice messages'),
          if (effects) ...[
            _toggle(
              AppSettings.audioRecordingNoiseSuppress,
              title: 'Noise suppression',
              subtitle: isolation
                  ? 'Included in strong noise reduction'
                  : 'Reduce steady background noise',
              forcedValue: isolation ? true : null,
            ),
            _toggle(
              AppSettings.audioRecordingAutoGain,
              title: 'Automatic gain',
              subtitle: isolation
                  ? 'Included in strong noise reduction'
                  : 'Keep your voice at an even volume',
              forcedValue: isolation ? true : null,
            ),
            _toggle(
              AppSettings.audioRecordingEchoCancel,
              title: 'Echo cancellation',
              subtitle: isolation
                  ? 'Included in strong noise reduction'
                  : 'Remove sound from the speaker while recording',
              forcedValue: isolation ? true : null,
            ),
            _toggle(
              AppSettings.personalVoiceIsolation,
              title: 'Strong noise reduction',
              subtitle: 'Voice isolation for noisy places. May sound narrower',
            ),
          ],
          _toggle(
            AppSettings.personalVoiceHighQuality,
            title: 'High quality',
            subtitle: 'Higher bitrate, larger files',
          ),
          if (!effects)
            Padding(
              key: const ValueKey('voice-no-effects-caption'),
              padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
              child: Text(
                'macOS records from the system input device without effects.',
                style: NotionType.caption.copyWith(color: secondary),
              ),
            ),
          if (bluetooth)
            _toggle(
              AppSettings.personalVoiceBluetoothMic,
              title: 'Record with Bluetooth headset microphone',
              subtitle: 'Uses the call microphone; sounds narrower',
            ),
          if (rounds) ...[
            const NotionSettingsSection('Round videos'),
            _toggle(
              AppSettings.personalRoundHighQuality,
              title: 'High quality',
              // macOS exports with Apple's medium-quality preset: only the
              // picture size changes there.
              subtitle: effects
                  ? '480 px at about 2 Mbps, larger files'
                  : 'Larger picture (up to 480 px), larger files',
            ),
            if (effects) ...[
              _toggle(
                AppSettings.personalRoundStabilization,
                title: 'Stabilization',
                subtitle: 'Smooth out hand shake when the camera supports it',
              ),
              _toggle(
                AppSettings.personalRoundNoiseReduction,
                title: 'Noise reduction',
                subtitle:
                    'Uses the call microphone mode; may sound like a phone call.',
              ),
            ],
          ],
          const NotionSettingsSection('Media downloads'),
          _toggle(
            AppSettings.personalAutoDownloadVoiceRounds,
            title: 'Auto-download voice messages & round videos',
            subtitle: 'Play instantly, no waiting',
          ),
          _toggle(
            AppSettings.personalAutoDownloadWifiOnly,
            title: 'Only on Wi-Fi',
            subtitle: autoDownload
                ? 'Skip automatic downloads on mobile data'
                : 'Turn on auto-download first',
            enabled: autoDownload,
          ),
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.md),
            child: Text(
              'Changes apply to the next recording or download.',
              style: NotionType.caption.copyWith(color: secondary),
            ),
          ),
        ],
      ),
    );
  }
}
