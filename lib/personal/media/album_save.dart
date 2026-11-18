// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/personal/media/media_store.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The user dismissed the folder picker: stop saving, say nothing.
class AlbumSaveCancelled implements Exception {
  const AlbumSaveCancelled();
}

/// What a save of a whole album did.
class AlbumSaveResult {
  const AlbumSaveResult({
    this.photos = 0,
    this.videos = 0,
    this.failed = 0,
    this.cancelled = false,
  });

  final int photos;
  final int videos;
  final int failed;
  final bool cancelled;

  int get saved => photos + videos;

  /// The one confirmation of the whole save, or null when the user cancelled
  /// before anything was saved.
  String? get message {
    if (saved == 0) return cancelled ? null : 'Could not save the files.';
    if (failed > 0) return 'Saved $saved of ${saved + failed} items';
    return switch ((photos, videos)) {
      (final p, 0) => 'Saved $p ${p == 1 ? 'photo' : 'photos'}',
      (0, final v) => 'Saved $v ${v == 1 ? 'video' : 'videos'}',
      (final p, final v) =>
        'Saved $p ${p == 1 ? 'photo' : 'photos'} and $v '
            '${v == 1 ? 'video' : 'videos'}',
    };
  }
}

/// The items one Save of [display] exports: the members of the photo/video
/// [album] it leads, or the visual items of a gallery message. Empty for an
/// ordinary message, which keeps the single-file save.
List<Event> albumSaveEvents(Event display, List<Event>? album) {
  if (GalleryContent.isGallery(display)) {
    return [
      for (final item in GalleryContent.itemEvents(display))
        if (item.messageType == MessageTypes.Image ||
            item.messageType == MessageTypes.Video)
          item,
    ];
  }
  return album != null && album.length > 1 ? album : const [];
}

/// Menu label of the album save: "Save 3 photos to gallery" on Android (no
/// dialog), "Save 3 photos…" where a folder panel opens.
String albumSaveLabel(List<Event> events, {bool? android}) {
  final photos = events.where((e) => e.messageType == MessageTypes.Image);
  final videos = events.where((e) => e.messageType == MessageTypes.Video);
  final noun = videos.isEmpty
      ? 'photos'
      : photos.isEmpty
      ? 'videos'
      : 'items';
  final label = 'Save ${events.length} $noun';
  return (android ?? PlatformInfos.isAndroid) ? '$label to gallery' : '$label…';
}

/// [name] made unique among [taken] ("photo.jpg", "photo (1).jpg", ...).
String uniqueExportName(String name, bool Function(String name) taken) {
  if (!taken(name)) return name;
  final dot = name.lastIndexOf('.');
  final hasExtension = dot > 0 && dot < name.length - 1;
  final stem = hasExtension ? name.substring(0, dot) : name;
  final extension = hasExtension ? name.substring(dot) : '';
  for (var n = 1; ; n++) {
    final candidate = '$stem ($n)$extension';
    if (!taken(candidate)) return candidate;
  }
}

/// Saves [events] one after the other: [fetch] downloads (and decrypts) one
/// item, [store] writes it; only one file is in memory at a time. An item
/// that fails is counted and skipped; [AlbumSaveCancelled] from [store]
/// ends the run.
Future<AlbumSaveResult> saveAlbumItems({
  required List<Event> events,
  required Future<MatrixFile?> Function(Event event, int index) fetch,
  required Future<bool> Function(MatrixFile file) store,
}) async {
  var photos = 0;
  var videos = 0;
  var failed = 0;
  for (var i = 0; i < events.length; i++) {
    try {
      final file = await fetch(events[i], i);
      if (file != null && await store(file)) {
        if (events[i].messageType == MessageTypes.Video) {
          videos++;
        } else {
          photos++;
        }
      } else {
        failed++;
      }
    } on AlbumSaveCancelled {
      return AlbumSaveResult(
        photos: photos,
        videos: videos,
        failed: failed,
        cancelled: true,
      );
    } catch (e) {
      Logs().w('Unable to save album item', e.runtimeType);
      failed++;
    }
  }
  return AlbumSaveResult(photos: photos, videos: videos, failed: failed);
}

/// Writes files into one folder the user picked once, with unique names.
class AlbumFolderSink {
  AlbumFolderSink(this.pick);

  /// Asks for the folder; null when dismissed.
  final Future<String?> Function() pick;
  String? _directory;
  final _used = <String>{};

  Future<bool> write(MatrixFile file) async {
    final directory = _directory ??= await pick();
    if (directory == null) throw const AlbumSaveCancelled();
    final name = uniqueExportName(
      exportFileName(file.name, file.mimeType),
      (n) => _used.contains(n) || File('$directory/$n').existsSync(),
    );
    _used.add(name);
    await File('$directory/$name').writeAsBytes(file.bytes, flush: true);
    return true;
  }
}

/// Save for a whole album or gallery message: Android puts every item in
/// the gallery like the single save; elsewhere (and on Android 9 and older)
/// the folder is asked once. [guard] is the export gate of one item.
Future<void> saveAlbum(
  BuildContext context,
  List<Event> events, {
  required Future<bool> Function(Event event) guard,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final allowed = <Event>[];
  for (final event in events) {
    if (await guard(event)) allowed.add(event);
    if (!context.mounted) return;
  }
  if (allowed.isEmpty) return;
  final folder = AlbumFolderSink(
    () => FilePicker.getDirectoryPath(
      dialogTitle: 'Save ${allowed.length} items to',
      initialDirectory: PlatformInfos.isMacOS
          ? macDownloadsDirectory(Platform.environment['HOME'])
          : null,
    ),
  );
  // Where there is no one-tap save the folder is asked before the downloads.
  if (!PlatformInfos.isAndroid) {
    final first = await folder.pick();
    if (first == null || !context.mounted) return;
    folder._directory = first;
  }
  final result = await showFutureLoadingDialog(
    context: context,
    futureWithProgress: (onProgress) => saveAlbumItems(
      events: allowed,
      fetch: (event, index) async {
        final size = event.infoMap['size'];
        final file = await downloadAttachmentCancellable(
          event,
          token: MediaDownloadToken(),
          onDownloadProgress: size is int && size > 0
              ? (bytes) => onProgress((index + bytes / size) / allowed.length)
              : null,
        );
        // A disappearing message may have outlived the download.
        return await guard(event) ? file : null;
      },
      store: (file) async {
        if (PlatformInfos.isAndroid) {
          final saved = await MediaStore.save(file);
          if (saved != null) return true;
        }
        return folder.write(file);
      },
    ),
  );
  final value = result.asValue?.value;
  final message = result.isError ? 'Could not save the files.' : value?.message;
  if (message == null) return;
  messenger.showSnackBar(SnackBar(content: Text(message), showCloseIcon: true));
}
