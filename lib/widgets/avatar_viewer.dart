// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:chatloom/personal/media/avatar_cache.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/private_avatar.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Opens the original, uncropped photo; pinch to zoom and pan, back to close.
Future<void> showAvatarViewer(
  BuildContext context, {
  required Client client,
  required Uri? uri,
  required String name,
  Future<Uint8List?> Function()? privatePhoto,
  Uint8List? initialBytes,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => AvatarViewer(
      name: name,
      initialBytes: initialBytes,
      loadPhoto: () async {
        final private = await privatePhoto?.call();
        if (private != null) return private;
        if (uri == null) return null;
        return AvatarCache.loadAvatar(
          client,
          uri,
          isThumbnail: false,
          animated: false,
          thumbnailMethod: ThumbnailMethod.scale,
        );
      },
    ),
  ),
);

Future<void> showPersonalAvatarViewer(
  BuildContext context, {
  required PersonalClient personal,
  required String entityId,
  required Uri? uri,
  required String name,
}) {
  final private = privateAvatarShown(personal, entityId);
  return showAvatarViewer(
    context,
    client: personal.client,
    uri: uri,
    name: name,
    initialBytes: private
        ? cachedPrivateAvatar(personal.values[privateAvatarKey(entityId)])
        : null,
    privatePhoto: private
        ? () => downloadPrivateAvatar(personal, entityId)
        : null,
  );
}

/// Shared by contact cards and both conversation/person details. Private
/// photos stay in memory; no plaintext is written to disk by this viewer.
class AvatarViewer extends StatefulWidget {
  final String name;
  final Future<Uint8List?> Function() loadPhoto;
  final Uint8List? initialBytes;
  const AvatarViewer({
    super.key,
    required this.name,
    required this.loadPhoto,
    this.initialBytes,
  });
  @override
  State<AvatarViewer> createState() => _AvatarViewerState();
}

class _AvatarViewerState extends State<AvatarViewer> {
  late Future<Uint8List?> _photo;
  final _transform = TransformationController();

  @override
  void initState() {
    super.initState();
    _photo = widget.loadPhoto();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotionScaffold(
    title: widget.name,
    onBack: () => Navigator.of(context).pop(),
    backLabel: 'Close photo',
    body: SafeArea(
      child: FutureBuilder<Uint8List?>(
        future: _photo,
        initialData: widget.initialBytes,
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? widget.initialBytes;
          if (bytes == null) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: NotionDelayedSpinner());
            }
            return _unavailable();
          }
          return InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 8,
            child: SizedBox.expand(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                cacheWidth: 2048,
                semanticLabel: 'Photo of ${widget.name}',
                errorBuilder: (_, _, _) => _unavailable(),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _unavailable() => Center(
    child: Padding(
      padding: const EdgeInsets.all(NotionSpace.inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Photo unavailable', style: context.notion.typography.body),
          const SizedBox(height: NotionSpace.md),
          NotionButton(
            label: 'Try again',
            icon: Icons.refresh,
            onPressed: () => setState(() {
              _photo = widget.loadPhoto();
            }),
          ),
        ],
      ),
    ),
  );
}
