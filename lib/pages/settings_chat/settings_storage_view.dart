// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/media/cache_budget.dart';
import 'package:chatloom/personal/media/cache_controls.dart';
import 'package:chatloom/personal/media/protected_matrix_database.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';

class SettingsStoragePage extends StatefulWidget {
  const SettingsStoragePage({super.key, this.controls});
  final MediaCacheControls? controls;

  @override
  State<SettingsStoragePage> createState() => _SettingsStoragePageState();
}

class _SettingsStoragePageState extends State<SettingsStoragePage> {
  MediaCacheControls? _controls;
  MediaCacheUsage? _usage;
  MediaCacheBudget? _budget;
  bool _busy = true;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controls != null) return;
    _controls =
        widget.controls ??
        MediaCacheControls(
          databases: Matrix.of(context).widget.clients
              .map((client) => client.database)
              .whereType<ProtectedMatrixDatabase>()
              .toList(),
        );
    unawaited(_refresh());
  }

  static String _size(int? bytes) {
    if (bytes == null) return 'Unavailable';
    if (bytes == 0) return '0 MiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  Future<void> _refresh() => _perform(() async {
    _budget = await MediaCacheBudget.read();
    _usage = await _controls!.usage();
  });

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        _error = 'Could not finish this action. Refresh and try again.';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectBudget(MediaCacheBudget budget) => _perform(() async {
    await _controls!.applyBudget(budget);
    _budget = budget;
    _usage = await _controls!.usage();
  });

  Future<void> _clear(MediaCacheCategory category) => _perform(() async {
    await _controls!.clear(category);
    _usage = await _controls!.usage();
  });

  Widget _caption(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: NotionSpace.sm),
    child: Text(text, style: context.notion.typography.footnoteMuted),
  );

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    return NotionSettingsScaffold(
      title: 'Storage & cache',
      actions: [
        NotionIconButton(
          icon: Icons.refresh_outlined,
          label: 'Refresh usage',
          onPressed: _busy ? null : _refresh,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotionSettingsSection('Cache limits'),
          for (final budget in MediaCacheBudget.values)
            NotionListRow(
              key: ValueKey('cache-budget-${budget.name}'),
              title: '${budget.label} · ${budget.singleAccountMiB} MiB',
              subtitle:
                  '${budget.mediaMiB} MiB photos & voice per account; '
                  '${budget.videoMiB} MiB large videos, ${budget.avatarMiB} MiB '
                  'avatars, ${budget.stickerMiB} MiB stickers shared on this device',
              trailing: _budget == budget
                  ? const Icon(Icons.check)
                  : const SizedBox.shrink(),
              onTap: _busy ? null : () => _selectBudget(budget),
            ),
          _caption(
            'Selecting a lower limit removes older downloaded media. '
            'Extra accounts each have their own photo and voice allowance. '
            'Reels expire after 24 hours, even when played again.',
          ),
          const NotionSettingsSection('Downloaded media'),
          if (usage == null && _busy)
            const NotionDelayedSpinner()
          else ...[
            NotionListRow(
              title: usage?.complete == true
                  ? 'Cached media'
                  : 'Known cache usage',
              subtitle: _size(usage?.knownBytes),
            ),
            for (final category in MediaCacheCategory.values)
              NotionListRow(
                key: ValueKey('cache-usage-${category.name}'),
                title: category.label,
                subtitle: _size(usage?.bytes[category]),
                trailing: NotionButton.ghost(
                  label: 'Clear',
                  onPressed:
                      _busy ||
                          usage?.bytes[category] == null ||
                          usage?.bytes[category] == 0
                      ? null
                      : () => _clear(category),
                ),
              ),
            NotionListRow(
              title: 'Pending send copies · kept',
              subtitle: _size(usage?.outgoingBytes),
            ),
          ],
          if (_error != null) _caption(_error!),
          _caption(
            'Clearing keeps history, encryption keys and pending sends. '
            'Media downloads again when opened. Sizes count cached photo and '
            'voice payloads plus private cache files; they exclude history '
            'and temporary copies opened in other apps. Freed database space '
            'may be reused without immediately shrinking app storage.',
          ),
        ],
      ),
    );
  }
}
