// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../storage/storage_failure.dart';
import 'private_directories_stub.dart'
    if (dart.library.ffi) 'private_directories_native.dart'
    as native;

/// Short-lived plaintext files for native codecs that cannot consume bytes.
/// Filenames never include contact, source event or original attachment names.
/// Lease locks prevent a different process cleaning a live playback/download.
class MediaAccess {
  final Directory _root;
  final Set<String> _active = {};
  MediaAccess._(this._root);

  /// Call once from the UI isolate, not from notification background isolates.
  /// Startup removes unlocked leftovers from previous processes/crashes. Files
  /// from the current process are left alone to avoid isolate lock ambiguity.
  static Future<MediaAccess> open({required Directory directory}) async {
    try {
      // Resolve system temp aliases once, but never follow the managed root.
      if (await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const StorageFailure(StorageFailureCode.mediaUnavailable);
      }
      await directory.parent.create(recursive: true);
      final parent = await directory.parent.resolveSymbolicLinks();
      final name = directory.absolute.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      if (name == '.' || name == '..') {
        throw const StorageFailure(StorageFailureCode.mediaUnavailable);
      }
      final root = Directory('$parent/$name');
      if (await FileSystemEntity.type(root.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        // mkdir(0700) is atomic and can only be made stricter by the umask.
        // A concurrent opener may have created the same root; validate below.
        native.PrivateDirectories.create(root);
      }
      final access = MediaAccess._(root);
      await access._validateRoot();
      await access.cleanupStale();
      return access;
    } catch (_) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
  }

  Future<ManagedMediaFile> create(
    Uint8List bytes, {
    required String extension,
  }) async {
    if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
    RandomAccessFile? lock;
    Directory? lease;
    try {
      await _validateRoot();
      final random = Random.secure();
      final suffix = base64UrlEncode(
        List<int>.generate(24, (_) => random.nextInt(256)),
      );
      final candidate = Directory('${_root.path}/lease_${pid}_$suffix');
      // Dart createTemp does not guarantee 0700 on every runtime. Native mkdir
      // establishes privacy atomically, before lock, plaintext or encoder path.
      if (!native.PrivateDirectories.create(candidate)) {
        throw const StorageFailure(StorageFailureCode.mediaUnavailable);
      }
      lease =
          candidate; // Only this operation's successfully created directory.
      await _validateDirectory(lease, private: true);
      await _validateRoot();
      _active.add(lease.path);
      lock = await File('${lease.path}/.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      final file = File('${lease.path}/media$extension');
      await file.writeAsBytes(bytes, flush: true);
      return ManagedMediaFile._(file, lease, lock, _active);
    } catch (_) {
      if (lease != null) {
        try {
          // A failed mode check may leave an empty 0000 directory. rmdir can
          // remove it without opening it; recursive traversal cannot on Linux.
          try {
            await lease.delete();
          } on FileSystemException {
            await lease.delete(recursive: true);
          }
        } catch (_) {}
        _active.remove(lease.path);
      }
      try {
        await lock?.close();
      } catch (_) {}
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
  }

  /// Native camera/encoder output stays in the same locked, private lease.
  Future<ManagedMediaFile> createWriter({required String extension}) =>
      create(Uint8List(0), extension: extension);

  Future<T> withFile<T>(
    Uint8List bytes, {
    required String extension,
    required Future<T> Function(File file) action,
  }) async {
    final lease = await create(bytes, extension: extension);
    try {
      return await action(lease.file);
    } on StorageFailure {
      rethrow;
    } catch (_) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    } finally {
      await lease.close();
    }
  }

  Future<void> _validateRoot() => _validateDirectory(_root);

  static Future<void> _validateDirectory(
    Directory directory, {
    bool private = false,
  }) async {
    if (!(Platform.isAndroid ||
            Platform.isLinux ||
            Platform.isMacOS ||
            Platform.isIOS) ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() != directory.path) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
    final mode = (await directory.stat()).mode;
    // A managed root may already be 0755. Others must never replace its leases.
    // The lease itself must be exactly owner-only before anything is written.
    if (mode & 0x1c0 != 0x1c0 || mode & (private ? 0x3f : 0x12) != 0) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
  }

  /// Sweeps only our managed lease directories, never arbitrary temp files.
  Future<void> cleanupStale() async {
    try {
      await _validateRoot();
      await for (final item in _root.list(followLinks: false)) {
        if (item is! Directory || _active.contains(item.path)) continue;
        final name = item.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        final match = RegExp(
          r'^lease_(\d+)_[A-Za-z0-9_-]{32}(?:_[A-Za-z0-9_-]+)?$',
        ).firstMatch(name);
        if (match == null) continue;
        final ownerPid = int.tryParse(match[1]!);
        if (ownerPid == null || ownerPid > 0x7fffffff) continue;
        // Lock-file creation and lock acquisition are separate async steps.
        // A living owner may be in either setup window, including an existing
        // .lock that is not locked yet. Sweep only conclusively dead owners.
        if (ownerPid == pid ||
            native.PrivateDirectories.processMayBeAlive(ownerPid)) {
          continue;
        }
        final lockPath = '${item.path}/.lock';
        if (await FileSystemEntity.type(lockPath, followLinks: false) !=
            FileSystemEntityType.file) {
          await item.delete(recursive: true);
          continue;
        }
        RandomAccessFile? lock;
        try {
          lock = await File(lockPath).open(mode: FileMode.append);
          await lock.lock(FileLock.exclusive);
          await item.delete(recursive: true);
        } on FileSystemException {
          // A live process holds the lock, or cleanup temporarily cannot run.
        } finally {
          await lock?.close();
        }
      }
    } catch (_) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
  }

  @override
  String toString() => 'MediaAccess(managed)';
}

/// Holds plaintext only while a native player/converter needs a real file.
/// Keep it alive until playback stops or the player is disposed, not merely
/// until the asynchronous `play()` method resolves on a pause.
class ManagedMediaFile {
  final File file;
  final Directory _directory;
  final RandomAccessFile _lock;
  final Set<String> _active;
  bool _closed = false;
  Future<void>? _closing;

  ManagedMediaFile._(this.file, this._directory, this._lock, this._active);

  String get writableDirectory {
    if (_closed) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
    return _directory.path;
  }

  File siblingFile(String name) {
    if (_closed || !RegExp(r'^[a-zA-Z0-9_-]+\.[a-z0-9]{1,8}$').hasMatch(name)) {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
    return File('${_directory.path}/$name');
  }

  /// Codec conversions must stay inside the same lease, so close removes both.
  File derivedFile(String extension) {
    if (_closed || !RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) {
      throw const StorageFailure(StorageFailureCode.invalidData);
    }
    return File('${_directory.path}/converted$extension');
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      if (await _directory.exists()) {
        await _directory.delete(recursive: true);
      }
    } catch (_) {
      // Next process startup retries leftovers; never leak paths in errors.
    } finally {
      _active.remove(_directory.path);
      await _lock.close();
    }
  }

  @override
  String toString() => 'ManagedMediaFile(protected lease)';
}
