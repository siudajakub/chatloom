// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../storage/storage_failure.dart';

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
      await directory.create(recursive: true);
      final access = MediaAccess._(directory);
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
      final random = Random.secure();
      final suffix = base64UrlEncode(
        List<int>.generate(24, (_) => random.nextInt(256)),
      );
      // mkdtemp creates the lease with owner-only permissions on native POSIX
      // platforms; regular mkdir would inherit a potentially permissive umask.
      lease = await _root.createTemp('lease_${pid}_${suffix}_');
      _active.add(lease.path);
      lock = await File('${lease.path}/.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      final file = File('${lease.path}/media$extension');
      await file.writeAsBytes(bytes, flush: true);
      return ManagedMediaFile._(file, lease, lock, _active);
    } catch (_) {
      if (lease != null) {
        try {
          if (await lease.exists()) await lease.delete(recursive: true);
        } catch (_) {}
        _active.remove(lease.path);
      }
      await lock?.close();
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

  /// Sweeps only our managed lease directories, never arbitrary temp files.
  Future<void> cleanupStale() async {
    try {
      await for (final item in _root.list(followLinks: false)) {
        if (item is! Directory || _active.contains(item.path)) continue;
        final name = item.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        final match = RegExp(
          r'^lease_(\d+)_[A-Za-z0-9_-]{32}(?:_[A-Za-z0-9_-]+)?$',
        ).firstMatch(name);
        if (match == null || int.tryParse(match[1]!) == pid) continue;
        final lockPath = '${item.path}/.lock';
        if (await FileSystemEntity.type(lockPath, followLinks: false) !=
            FileSystemEntityType.file) {
          // No completed lease setup: safe to clean a previous process dir.
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

  Future<void> close() async {
    if (_closed) return;
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
