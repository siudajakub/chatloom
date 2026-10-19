// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:material_ui/material_ui.dart';

/// Settings → Chats & organization → Voice messages & round videos.
///
/// Capture quality for voice notes (read by `RecordingViewModel` when a
/// recording starts), round video capture options (Android camera pipeline)
/// and automatic downloads of voice and round messages.
class SettingsMediaPage extends StatefulWidget {
  /// Round video capture exists only on Android; tests can force the section.
  final bool? showRoundOptions;
  const SettingsMediaPage({super.key, this.showRoundOptions});

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
    final rounds = widget.showRoundOptions ?? PlatformInfos.isAndroid;
    final secondary = context.notion.colors.textSecondary;
    return NotionSettingsScaffold(
      title: 'Voice messages & round videos',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotionSettingsSection('Voice messages'),
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
            subtitle: 'Keep your voice at an even volume',
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
          _toggle(
            AppSettings.personalVoiceHighQuality,
            title: 'High quality',
            subtitle: 'Higher bitrate, larger files',
          ),
          if (rounds) ...[
            const NotionSettingsSection('Round videos'),
            _toggle(
              AppSettings.personalRoundHighQuality,
              title: 'High quality',
              subtitle: '480 px at about 2 Mbps, larger files',
            ),
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
