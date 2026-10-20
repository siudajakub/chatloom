// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_transcribe_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

String transcriptionLanguageLabel(String? code) =>
    code == null ? 'Automatic' : transcriptionLanguages[code] ?? 'Automatic';

String transcriptionMinutesLabel(int seconds) => seconds % 60 == 0
    ? '${seconds ~/ 60} min'
    : '${(seconds / 60).toStringAsFixed(1)} min';

/// Settings labels for the synced per-kind switches.
const transcriptionKindLabels = <AutoTranscriptionKind, (String, String)>{
  AutoTranscriptionKind.voice: (
    'Voice messages',
    'Voice notes from every network',
  ),
  AutoTranscriptionKind.round: ('Round videos', 'Telegram video messages'),
  AutoTranscriptionKind.video: (
    'Videos',
    'Only the audio track is sent; clips without sound are skipped',
  ),
  AutoTranscriptionKind.audio: ('Other audio', 'Audio files and recordings'),
};

String transcriptionUsdLabel(double value) => '\$${value.toStringAsFixed(2)}';

/// Estimated spend with cent precision; tiny non-zero amounts read
/// "< $0.01" instead of rounding down to zero.
String transcriptionUsageLabel(double value) =>
    value > 0 && value < .01 ? '< \$0.01' : transcriptionUsdLabel(value);

/// Settings → Transcriptions: synced automatic policy, defaults and usage.
/// Every change is saved as private journal metadata (`transcription-policy`)
/// and applies to all paired devices and the worker.
class TranscriptionSettingsSection extends StatelessWidget {
  final PersonalClient personal;

  /// The settings page's guarded runner (shows a snackbar on failure).
  final Future<void> Function(Future<void> Function() action) run;

  const TranscriptionSettingsSection({
    super.key,
    required this.personal,
    required this.run,
  });

  bool get _canEdit =>
      !kIsWeb &&
      personal.ready &&
      !personal.conflicts.containsKey(transcriptionPolicyEntity);

  void _save(TranscriptionPolicy policy) =>
      run(() => personal.setTranscriptionPolicy(policy));

  Future<T?> _pick<T>(
    BuildContext context, {
    required String title,
    required Map<T, String> choices,
    required T selected,
    Map<T, String> subtitles = const {},
  }) => showNotionSheet<T>(
    context: context,
    title: title,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in choices.entries)
          Semantics(
            selected: entry.key == selected,
            child: NotionListRow(
              title: entry.value,
              subtitle: subtitles[entry.key],
              trailing: entry.key == selected
                  ? const Icon(Icons.check, size: NotionSize.icon)
                  : const SizedBox(width: NotionSize.icon),
              onTap: () => Navigator.of(context).pop(entry.key),
            ),
          ),
      ],
    ),
  );

  Set<String> _networks(TranscriptionPolicy policy) => {
    for (final room in personal.client.rooms)
      if (!room.isSpace && !PersonalPrivacy.isJournal(room))
        PersonalClient.networkOf(room),
    ...policy.networks.keys,
  }..remove('unknown');

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final policy = personal.transcriptionPolicy;
    final editable = _canEdit;
    final jobs = personal.transcripts.values;
    final manual = jobs.where((j) => !j.automatic);
    final automatic = jobs.where((j) => j.automatic);
    double cost(Iterable<TranscriptionJob> list) =>
        list.fold(0, (sum, job) => sum + (job.estimatedCostUsd ?? 0));
    int done(Iterable<TranscriptionJob> list) =>
        list.where((job) => job.state == JobState.done).length;
    final skipped = automatic
        .where((job) => job.errorCode?.startsWith('auto_skipped_') ?? false)
        .length;
    final unknown = jobs.where((job) => job.state == JobState.unknown).length;
    final networks = _networks(policy).toList()
      ..sort((a, b) => notionNetworkLabel(a).compareTo(notionNetworkLabel(b)));
    final pending = personal.pending.values.any(
      (op) => op.entityId == transcriptionPolicyEntity,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionListRow(
          leading: const Icon(Icons.cloud_outlined),
          title: 'Transcription service',
          subtitle: personal.workerReadinessDescription,
        ),
        const NotionSectionHeader(title: 'Automatic transcription'),
        NotionSettingsToggle(
          key: const ValueKey('transcription-auto'),
          title: 'Transcribe automatically',
          subtitle:
              'Incoming voice messages, round videos and videos are transcribed on the server as soon as they arrive; only their audio is sent to OpenAI. Your own messages, disappearing messages, muted and ignored chats are skipped.'
              '${policy.auto && !personal.autoTranscriptionAvailable ? ' Currently off on the worker: tap Transcribe on a message instead.' : ''}',
          value: policy.auto,
          onChanged: editable
              ? (value) => _save(policy.withAuto(value, DateTime.now()))
              : null,
        ),
        NotionListRow(
          title: 'Default language',
          subtitle: transcriptionLanguageLabel(policy.defaultLanguage),
          onTap: editable
              ? () async {
                  final value = await _pick<String>(
                    context,
                    title: 'Default language',
                    selected: policy.defaultLanguage ?? 'auto',
                    choices: {'auto': 'Automatic', ...transcriptionLanguages},
                    subtitles: const {
                      'auto': 'Detect the spoken language',
                      ...notionTranscriptionNativeNames,
                    },
                  );
                  if (value == null) return;
                  _save(
                    policy.copyWith(
                      defaultLanguage: () => value == 'auto' ? null : value,
                    ),
                  );
                }
              : null,
        ),
        NotionListRow(
          title: 'Maximum length',
          subtitle:
              '${transcriptionMinutesLabel(policy.maxSeconds)} · longer messages are skipped automatically',
          onTap: editable && policy.auto
              ? () async {
                  final value = await _pick<int>(
                    context,
                    title: 'Maximum length',
                    selected: policy.maxSeconds,
                    choices: {
                      for (final seconds in transcriptionMaxSecondsChoices)
                        seconds: transcriptionMinutesLabel(seconds),
                    },
                  );
                  if (value != null) _save(policy.copyWith(maxSeconds: value));
                }
              : null,
        ),
        NotionListRow(
          title: 'Daily limit',
          subtitle:
              '${transcriptionUsdLabel(policy.dailyBudgetUsd)} per 24 hours of automatic transcription',
          onTap: editable && policy.auto
              ? () async {
                  final value = await _pick<double>(
                    context,
                    title: 'Daily limit',
                    selected: policy.dailyBudgetUsd,
                    choices: {
                      for (final usd in transcriptionDailyBudgetChoices)
                        usd: transcriptionUsdLabel(usd),
                    },
                  );
                  if (value != null) {
                    _save(policy.copyWith(dailyBudgetUsd: value));
                  }
                }
              : null,
        ),
        const NotionSectionHeader(title: 'Media'),
        for (final entry in transcriptionKindLabels.entries)
          NotionSettingsToggle(
            key: ValueKey('transcription-kind-${entry.key.name}'),
            title: entry.value.$1,
            subtitle:
                entry.key == AutoTranscriptionKind.video ||
                    entry.key == AutoTranscriptionKind.audio
                ? personal.workerTranscribesAllMedia || !personal.workerOnline
                      ? entry.value.$2
                      : '${entry.value.$2} · needs a worker update'
                : entry.value.$2,
            value: policy.kindEnabled(entry.key),
            onChanged: editable && policy.auto
                ? (value) => _save(policy.withKind(entry.key, value))
                : null,
          ),
        if (networks.isNotEmpty) ...[
          const NotionSectionHeader(title: 'Networks'),
          for (final network in networks)
            NotionSettingsToggle(
              key: ValueKey('transcription-network-$network'),
              title: notionNetworkLabel(network),
              // Shows the saved choice; editable only with automatic on.
              value: policy.networkEnabled(network),
              onChanged: editable && policy.auto
                  ? (value) => _save(policy.withNetwork(network, value))
                  : null,
            ),
        ],
        NotionSizeReveal(
          visible: pending,
          child: Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xs),
            child: Text(
              'Saved locally · awaiting private sync confirmation.',
              style: tokens.typography.footnoteMuted,
            ),
          ),
        ),
        NotionSizeReveal(
          visible: personal.conflicts.containsKey(transcriptionPolicyEntity),
          child: Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xs),
            child: Text(
              'Conflicting changes from another device. Review them in Sync & transcriptions.',
              style: tokens.typography.footnoteMuted,
            ),
          ),
        ),
        const NotionSectionHeader(title: 'Usage'),
        NotionListRow(
          title: 'Manual: ${done(manual)} completed',
          subtitle:
              'Estimated cost: ${transcriptionUsageLabel(cost(manual))}${unknown > 0 ? ' · $unknown unknown attempts' : ''}',
        ),
        NotionListRow(
          title: 'Automatic: ${done(automatic)} completed',
          subtitle:
              'Estimated cost: ${transcriptionUsageLabel(cost(automatic))}${skipped > 0 ? ' · $skipped skipped by limits' : ''}',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: NotionSpace.sm),
          child: Text(
            'Costs are estimates, not a bill. Change a single chat in its Visibility & notifications settings.',
            style: tokens.typography.footnoteMuted,
          ),
        ),
      ],
    );
  }
}
