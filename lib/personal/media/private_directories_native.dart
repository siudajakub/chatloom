// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../storage/storage_failure.dart';

/// libc is part of Android/iOS/macOS/Linux, including sandboxed app processes.
/// No shell command, package allocator, global umask change or chmod is needed.
class PrivateDirectories {
  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final Pointer<Uint8> Function(int) _malloc = _libc
      .lookupFunction<
        Pointer<Uint8> Function(UintPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  static final void Function(Pointer<Uint8>) _free = _libc
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('free');
  // Darwin's mode_t is unsigned short; Android/Linux use unsigned int.
  static final int Function(Pointer<Uint8>, int) _mkdir =
      Platform.isMacOS || Platform.isIOS
      ? _libc.lookupFunction<
          Int32 Function(Pointer<Uint8>, Uint16),
          int Function(Pointer<Uint8>, int)
        >('mkdir')
      : _libc.lookupFunction<
          Int32 Function(Pointer<Uint8>, Uint32),
          int Function(Pointer<Uint8>, int)
        >('mkdir');

  static final int Function(int, int) _kill = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'kill',
      );
  static final Pointer<Int32> Function() _errno = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS || Platform.isIOS
            ? '__error'
            : Platform.isAndroid
            ? '__errno'
            : '__errno_location',
      );

  static bool processMayBeAlive(int process) {
    if (process <= 0) return false;
    // Signal zero performs a permission/existence check, never sends a signal.
    // ESRCH is the only conclusive evidence that no process owns this lease.
    return _kill(process, 0) == 0 || _errno().value != 3;
  }

  static bool create(Directory directory) {
    if (!(Platform.isAndroid ||
            Platform.isLinux ||
            Platform.isMacOS ||
            Platform.isIOS) ||
        directory.path.contains('\u0000')) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
    final encoded = utf8.encode(directory.path);
    final path = _malloc(encoded.length + 1);
    if (path == nullptr) {
      throw const StorageFailure(StorageFailureCode.mediaUnavailable);
    }
    try {
      path.asTypedList(encoded.length + 1)
        ..setAll(0, encoded)
        ..[encoded.length] = 0;
      return _mkdir(path, 0x1c0) == 0;
    } finally {
      _free(path);
    }
  }
}
