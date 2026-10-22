// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Human names of the probe's operations; unknown ones show their label.
const performanceOperationNames = <String, String>{
  'chat_open.first_frame': 'Open chat → first frame',
  'chat_open.route': 'Open chat → slide finished',
  'chat_open.timeline': 'Open chat → history loaded',
  'chat_open.rows': 'Open chat → messages on screen',
  'merged_open.first_frame': 'Open person → first frame',
  'merged_open.route': 'Open person → slide finished',
  'merged_open.timeline': 'Open person → histories loaded',
  'merged_open.rows': 'Open person → messages on screen',
  'send.durable': 'Send → saved in outbox',
  'send.bubble': 'Send → bubble on screen',
  'send.acked': 'Send → server accepted',
  'send.http': 'Send request (network)',
  'receive.row': 'New message → inbox row on screen',
  'sync.process': 'Sync processing',
  'inbox.publish': 'Inbox update',
  'members.fetch': 'Member list download',
  'db.key.matrix': 'Matrix database key read',
  'db.open.matrix': 'Matrix database open',
  'db.key.personal': 'Private database key read',
  'db.open.personal': 'Private database open',
  'db.open.pending': 'Pending media database open',
};

/// Settings → Advanced → Performance: timings measured on this device since
/// the app started. Durations and counts only; nothing leaves the device
/// unless "Copy summary" is used.
class PerformancePage extends StatefulWidget {
  const PerformancePage({super.key});

  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final frames = PersonalPerformanceProbe.frames.summary();
    final summaries = PersonalPerformanceProbe.summaries();
    final startup = summaries.where((s) => s.name.startsWith('startup.'));
    final timings = summaries.where((s) => !s.name.startsWith('startup.'));
    return NotionSettingsScaffold(
      title: 'Performance',
      actions: [
        NotionIconButton(
          icon: Icons.refresh,
          label: 'Refresh',
          onPressed: _refresh,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Times measured on this device since ChatLoom started. Only '
            'durations are kept, never names or messages, and nothing is sent.',
          ),
          const NotionSettingsSection('Smoothness'),
          NotionSettingsToggle(
            title: 'Measure frame times',
            subtitle:
                'Until ChatLoom restarts. Use the app normally, then '
                'come back here.',
            value: PersonalPerformanceProbe.recordingFrames,
            onChanged: (on) {
              PersonalPerformanceProbe.recordFrames(on);
              _refresh();
            },
          ),
          if (frames != null) ...[
            NotionListRow(
              title: 'Frames',
              subtitle:
                  '${frames.frames} frames, ${frames.missed} over the '
                  '${formatMs(frames.budgetMs)} budget',
            ),
            NotionListRow(
              title: 'Build time',
              subtitle: _percentiles(
                frames.buildP50,
                frames.buildP90,
                frames.buildP99,
              ),
            ),
            NotionListRow(
              title: 'Raster time',
              subtitle:
                  '${_percentiles(frames.rasterP50, frames.rasterP90, frames.rasterP99)}'
                  ' · worst ${formatMs(frames.worstRaster)}',
            ),
          ],
          const NotionSettingsSection('Timings'),
          if (timings.isEmpty)
            const NotionListRow(
              title: 'No timings yet',
              subtitle: 'Open a chat or send a message, then refresh.',
            ),
          for (final summary in timings) _row(summary),
          if (startup.isNotEmpty) ...[
            const NotionSettingsSection('This start'),
            for (final summary in startup) _row(summary, startup: true),
          ],
          const SizedBox(height: NotionSpace.md),
          NotionButton(
            label: 'Copy summary',
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: PersonalPerformanceProbe.report()),
              );
            },
          ),
          const SizedBox(height: NotionSpace.xs),
          NotionButton(
            label: 'Clear',
            onPressed: () {
              PersonalPerformanceProbe.reset();
              _refresh();
            },
          ),
        ],
      ),
    );
  }

  Widget _row(PerformanceSummary summary, {bool startup = false}) =>
      NotionListRow(
        title:
            performanceOperationNames[summary.name] ??
            (startup
                ? summary.name.substring('startup.'.length)
                : summary.name),
        subtitle: startup
            ? formatMs(summary.max)
            : '${_percentiles(summary.p50, summary.p90, summary.p99)}'
                  ' · ${summary.count}×',
      );
}

String _percentiles(double p50, double p90, double p99) =>
    'median ${formatMs(p50)} · 90% ${formatMs(p90)} · 99% ${formatMs(p99)}';
