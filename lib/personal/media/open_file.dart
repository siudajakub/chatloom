// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chatloom/pages/chat/events/outgoing_upload_progress.dart';
import 'package:chatloom/personal/media/cancellable_download.dart';
import 'package:chatloom/personal/media/media_store.dart';
import 'package:chatloom/personal/media/video_file_cache.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import 'private_directories_stub.dart'
    if (dart.library.ffi) 'private_directories_native.dart'
    as native;

/// Short-lived decrypted copies of received files that the user opened in
/// another app (MD-08, MAC-11; J, 2026-10-24). This is the only place where
/// ChatLoom hands a plaintext file to another app on purpose:
///
/// * one owner-only (0700) folder per open under the app's temporary
///   directory, `chatloom_open/<pid>_<random>/<file name>` (Android: the app
///   cache, served only through `OpenFileProvider` as a read-only content
///   URI; macOS: the sandbox container's temporary folder);
/// * deleted [keepFor] after the open (timer while the app runs), at the next
///   app start (every folder of an earlier process), on logout and when the
///   other app could not be started;
/// * the file keeps the (sanitised) attachment name because the other app
///   shows it, as the share sheet already does; no contact, room or event
///   id is part of any path.
class OpenedFileCopies {
  static const String folderName = 'chatloom_open';

  /// Long enough to read a document or come back to it, short enough that
  /// a forgotten copy does not stay around (MAC-11 asked for at most 1 h).
  static const Duration defaultKeepFor = Duration(hours: 1);

  static final _copyName = RegExp(r'^(\d+)_[A-Za-z0-9_-]{16}$');

  final Directory root;
  final Duration keepFor;
  final bool scheduleCleanup;
  final DateTime Function() _now;
  final int _pid;

  OpenedFileCopies._(
    this.root,
    this.keepFor,
    this.scheduleCleanup,
    this._now,
    this._pid,
  );

  static Future<OpenedFileCopies> open(
    Directory directory, {
    Duration keepFor = defaultKeepFor,
    bool scheduleCleanup = true,
    DateTime Function()? now,
    @visibleForTesting int? processId,
  }) async {
    await directory.parent.create(recursive: true);
    final parent = await directory.parent.resolveSymbolicLinks();
    final name = directory.absolute.uri.pathSegments
        .where((part) => part.isNotEmpty)
        .last;
    final resolved = Directory('$parent/$name');
    if (await FileSystemEntity.type(resolved.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      native.PrivateDirectories.create(resolved);
    }
    final copies = OpenedFileCopies._(
      resolved,
      keepFor,
      scheduleCleanup,
      now ?? DateTime.now,
      processId ?? pid,
    );
    await _validate(resolved);
    return copies;
  }

  static Future<OpenedFileCopies>? _shared;

  /// `<temporary directory>/chatloom_open` (Android: `cacheDir`, the path
  /// `res/xml/chatloom_open_paths.xml` exposes).
  static Future<OpenedFileCopies> shared() =>
      _shared ??= _openShared().catchError((Object error) {
        _shared = null;
        throw error;
      });

  static Future<OpenedFileCopies> _openShared() async {
    final temporary = await getTemporaryDirectory();
    return open(Directory('${temporary.path}/$folderName'));
  }

  /// App start: removes every copy an earlier process left behind.
  static Future<void> sweepShared() async {
    if (kIsWeb) return;
    try {
      await (await shared()).sweep();
    } catch (error) {
      Logs().w('opened_files_sweep_failed', error.runtimeType.toString());
    }
  }

  /// Logout: removes every copy, including this process's.
  static Future<void> clearShared() async {
    if (kIsWeb) return;
    try {
      await (await shared()).sweep(all: true);
    } catch (error) {
      Logs().w('opened_files_clear_failed', error.runtimeType.toString());
    }
  }

  /// Writes [bytes] as [fileName] into a new private folder.
  Future<OpenedFileCopy> create(Uint8List bytes, String fileName) async {
    await _validate(root);
    // Old copies of this process go when the next file is opened too.
    await sweep();
    final name = safeFileName(fileName);
    final random = Random.secure();
    final suffix = base64UrlEncode(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );
    final folder = Directory('${root.path}/${_pid}_$suffix');
    if (!native.PrivateDirectories.create(folder)) {
      throw const FileSystemException('opened file folder');
    }
    final copy = OpenedFileCopy._(File('${folder.path}/$name'), folder);
    try {
      await _validate(folder, private: true);
      await copy.file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await copy.delete();
      rethrow;
    }
    if (scheduleCleanup) {
      Timer(keepFor, () => unawaited(copy.delete()));
    }
    return copy;
  }

  /// Deletes copies of earlier processes and every copy older than
  /// [keepFor]; with [all] every copy. Returns how many were deleted.
  Future<int> sweep({bool all = false}) async {
    await _validate(root);
    final now = _now();
    var deleted = 0;
    await for (final item in root.list(followLinks: false)) {
      if (item is! Directory) continue;
      final match = _copyName.firstMatch(
        item.uri.pathSegments.where((part) => part.isNotEmpty).last,
      );
      if (match == null) continue;
      final owner = int.tryParse(match[1]!);
      final age = now.difference((await item.stat()).modified);
      if (all || owner != _pid || age >= keepFor) {
        try {
          await item.delete(recursive: true);
          deleted++;
        } on FileSystemException {
          // Retried at the next open or start.
        }
      }
    }
    return deleted;
  }

  /// The name the other app shows: the attachment's own, without path
  /// parts or characters a file system rejects, never hidden.
  static String safeFileName(String fileName) {
    var name = exportFileName(fileName, null);
    if (name.startsWith('.')) name = 'file$name';
    return name;
  }

  static Future<void> _validate(
    Directory directory, {
    bool private = false,
  }) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() != directory.path) {
      throw const FileSystemException('opened file folder');
    }
    final mode = (await directory.stat()).mode;
    // The root must not be writable by others; each copy is owner-only.
    if (mode & 0x1c0 != 0x1c0 || mode & (private ? 0x3f : 0x12) != 0) {
      throw const FileSystemException('opened file folder');
    }
  }

  @override
  String toString() => 'OpenedFileCopies(private)';
}

class OpenedFileCopy {
  final File file;
  final Directory _folder;
  Future<void>? _deleting;

  OpenedFileCopy._(this.file, this._folder);

  Future<void> delete() => _deleting ??= () async {
    try {
      if (await _folder.exists()) await _folder.delete(recursive: true);
    } catch (_) {
      // The next open or app start sweeps it.
    }
  }();

  @override
  String toString() => 'OpenedFileCopy(private)';
}

/// Logout and "clear cache" (`ProtectedMatrixDatabase.clearFileCaches`):
/// the ciphertext video cache and every opened-file copy.
Future<void> clearPrivateFileCaches() async {
  await VideoFileCache.clearShared();
  await OpenedFileCopies.clearShared();
}

/// Hands [file] to the system's default app for [mimeType]; false when no
/// app takes it.
typedef SystemFileOpener = Future<bool> Function(File file, String mimeType);

/// Android: `ACTION_VIEW` on a read-only `content://` URI (MediaStorePlugin
/// `openFile`); macOS: `NSWorkspace.open` through url_launcher.
bool get systemFileOpenSupported =>
    PlatformInfos.isAndroid || PlatformInfos.isMacOS;

Future<bool> openWithSystemApp(File file, String mimeType) async {
  if (PlatformInfos.isAndroid) {
    try {
      return await MediaStore.channel.invokeMethod<bool>('openFile', {
            'path': file.path,
            'mimeType': mimeType,
          }) ==
          true;
    } on MissingPluginException {
      return false;
    }
  }
  if (PlatformInfos.isMacOS) {
    return launcher.launchUrl(Uri.file(file.path));
  }
  return false;
}

/// MIME type for `ACTION_VIEW`: the event's, unless missing or generic,
/// then from the file name.
String openMimeType(String? mimeType, String fileName) {
  final given = (mimeType ?? '').split(';').first.trim().toLowerCase();
  if (given.isNotEmpty &&
      given != 'application/octet-stream' &&
      given.contains('/')) {
    return given;
  }
  return lookupMimeType(fileName) ?? 'application/octet-stream';
}

/// Open-in-app downloads in progress, by event id. File bubbles show a
/// ring for their entry; only they rebuild when one starts or ends.
abstract final class FileOpenDownloads {
  static final ValueNotifier<Map<String, ValueListenable<double?>>> active =
      ValueNotifier(const {});
  static final _tokens = <String, MediaDownloadToken>{};

  static bool isActive(String eventId) => _tokens.containsKey(eventId);

  static void cancel(String eventId) => _tokens[eventId]?.cancel();

  static void _start(
    String eventId,
    MediaDownloadToken token,
    ValueListenable<double?> progress,
  ) {
    _tokens[eventId] = token;
    active.value = {...active.value, eventId: progress};
  }

  static void _end(String eventId, MediaDownloadToken token) {
    if (!identical(_tokens[eventId], token)) return;
    _tokens.remove(eventId);
    active.value = Map.of(active.value)..remove(eventId);
  }
}

/// Telegram's file tap: download with the progress in the bubble (a second
/// tap cancels), then open the file in the system's default app from a
/// short-lived private copy ([OpenedFileCopies]). [guard] is the export
/// check (protected and disappearing media cannot leave the app), run
/// before and after the download. Where no system open exists, and when no
/// app takes the file, the person is offered "Save" instead ([save]).
Future<void> openEventAttachment(
  BuildContext context,
  Event event, {
  required Future<bool> Function() guard,
  required Future<void> Function() save,
  @visibleForTesting SystemFileOpener? opener,
  @visibleForTesting Future<OpenedFileCopies> Function()? copies,
  @visibleForTesting
  Future<MatrixFile> Function(
    Event event, {
    required MediaDownloadToken token,
    void Function(int bytes)? onDownloadProgress,
  })?
  download,
}) async {
  final id = event.eventId;
  if (FileOpenDownloads.isActive(id)) {
    FileOpenDownloads.cancel(id);
    return;
  }
  if (opener == null && !systemFileOpenSupported) return save();
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (!await guard()) return;
  if (FileOpenDownloads.isActive(id)) return;

  final token = MediaDownloadToken();
  final progress = ValueNotifier<double?>(null);
  final size = event.infoMap.tryGet<int>('size');
  FileOpenDownloads._start(id, token, progress);
  final MatrixFile file;
  try {
    file = await (download ?? downloadAttachmentCancellable)(
      event,
      token: token,
      onDownloadProgress: size == null || size <= 0
          ? null
          : (bytes) {
              final fraction = (bytes / size).clamp(0.0, 1.0);
              final shown = progress.value;
              // One rebuild of the ring per percent, not per chunk.
              if (shown == null || fraction - shown >= .01) {
                progress.value = fraction;
              }
            },
    );
  } on MediaDownloadCancelled {
    return;
  } catch (error) {
    Logs().w('open_file_download_failed', error.runtimeType.toString());
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'Could not download the file. Check your connection and try again.',
        ),
      ),
    );
    return;
  } finally {
    FileOpenDownloads._end(id, token);
  }
  // The message may have expired or become protected meanwhile. The file
  // opens even when its bubble scrolled away meanwhile (it was asked for).
  if (!await guard()) return;

  final name = event.content.tryGet<String>('filename') ?? event.body;
  final fileName = exportFileName(name, event.attachmentMimetype);
  OpenedFileCopy? copy;
  var opened = false;
  try {
    copy = await (await (copies ?? OpenedFileCopies.shared)()).create(
      file.bytes,
      fileName,
    );
    opened = await (opener ?? openWithSystemApp)(
      copy.file,
      openMimeType(event.attachmentMimetype, fileName),
    );
  } catch (error) {
    Logs().w('open_file_failed', error.runtimeType.toString());
  }
  if (opened) return;
  await copy?.delete();
  messenger?.showSnackBar(
    SnackBar(
      content: const Text('No app on this device can open this file.'),
      action: context.mounted
          ? SnackBarAction(label: 'Save', onPressed: () => unawaited(save()))
          : null,
    ),
  );
}

/// The file bubble's leading icon: the file glyph, or while the file is
/// being downloaded to open, Telegram's ring with an "×" (a tap on the
/// bubble cancels).
class FileOpenStatusIcon extends StatelessWidget {
  final String eventId;
  final Widget idle;

  const FileOpenStatusIcon({
    super.key,
    required this.eventId,
    required this.idle,
  });

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, ValueListenable<double?>>>(
        valueListenable: FileOpenDownloads.active,
        child: idle,
        builder: (context, active, idle) {
          final progress = active[eventId];
          if (progress == null) return idle!;
          return Semantics(
            label: 'Downloading. Tap to cancel',
            child: CircleAvatar(
              key: const ValueKey('file-open-progress'),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Icon(Icons.close, size: NotionSize.iconSm),
                  OutgoingUploadIndicator(
                    progress: progress,
                    size: NotionSize.avatar,
                    strokeWidth: 3,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
          );
        },
      );
}
