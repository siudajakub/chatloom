// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/pages/chat/chat_wallpaper.dart';
import 'package:chatloom/personal/stickers/sticker_convert.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Releases rebuildable in-memory media caches while the app is off screen
/// and when the system reports memory pressure.
///
/// * Android/iOS `paused`: at once. The process may be frozen or killed
///   soon after, and a smaller cached process is the one the system keeps.
/// * `hidden` (desktop) and, on macOS, the window hidden to the menu bar
///   ([MacDesktopWindow.visible]): after [hiddenDelay], so switching away
///   for a moment costs nothing.
/// * `didHaveMemoryPressure`: at once, and the encoded image cache is
///   emptied completely.
///
/// What goes: decoded images that no widget shows (Flutter's [ImageCache]
/// keep-alive and pending entries), parsed Lottie stickers, blur-hash
/// placeholders, blurred wallpaper bitmaps and converted stickers. In the
/// background, encoded images in [MxcImage]'s memory cache are trimmed to
/// [MxcImage.backgroundRetainedBytes], and only those with a disk cache.
///
/// What stays: everything a mounted widget shows (its frame and bytes), so
/// the screen the user returns to is unchanged; anything that would cost a
/// download or an upload again. Live images are deliberately not cleared
/// ([ImageCache.clearLiveImages] frees nothing while they are shown, and a
/// rebuild would then decode a second copy and flash).
abstract final class MemoryTrim {
  /// How long a desktop window stays hidden before its caches are trimmed.
  static const Duration hiddenDelay = Duration(seconds: 30);

  static _MemoryTrimObserver? _observer;
  static final _caches = <VoidCallback>[];
  static final _pressureCaches = <VoidCallback>[];
  static int _trims = 0;

  /// Starts watching the app lifecycle (and the macOS window). Call once
  /// from `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
  static void install() {
    if (_observer != null) return;
    final observer = _observer = _MemoryTrimObserver(
      macOS: !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS,
    );
    WidgetsBinding.instance.addObserver(observer);
    if (observer.macOS) {
      MacDesktopWindow.visible.addListener(observer.update);
    }
    observer.update();
  }

  /// Registers another memory-only cache to clear on every trim (for
  /// example a feature's own thumbnail cache). Clearing must be safe at any
  /// time and must not drop anything that costs network to restore.
  static void addCache(VoidCallback clear) => _caches.add(clear);

  /// Registers a cache whose entries cost network or decryption to restore:
  /// cleared only under memory pressure, never on a background trim.
  static void addPressureCache(VoidCallback clear) =>
      _pressureCaches.add(clear);

  /// Trims now. [background] keeps a small recent part of the encoded image
  /// cache; memory pressure (the default) empties it.
  static void trim({bool background = false}) {
    _trims++;
    PaintingBinding.instance.imageCache.clear();
    MxcImage.trimMemory(background: background);
    BlurHash.trimMemory();
    BlurredWallpaper.trimMemory();
    StickerConvertedMedia.trimMemory();
    for (final clear in [..._caches, if (!background) ..._pressureCaches]) {
      try {
        clear();
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
      }
    }
  }

  @visibleForTesting
  static int get debugTrims => _trims;

  @visibleForTesting
  static bool get debugTrimPending => _observer?._timer != null;

  @visibleForTesting
  static void debugReset() {
    final observer = _observer;
    _observer = null;
    if (observer != null) {
      observer._timer?.cancel();
      WidgetsBinding.instance.removeObserver(observer);
      if (observer.macOS) {
        MacDesktopWindow.visible.removeListener(observer.update);
      }
    }
    _caches.clear();
    _pressureCaches.clear();
    _trims = 0;
  }
}

class _MemoryTrimObserver with WidgetsBindingObserver {
  _MemoryTrimObserver({required this.macOS});

  final bool macOS;
  Timer? _timer;

  /// Trimmed since the app last came to the screen: one trim per absence.
  bool _trimmed = false;

  bool get _hidden {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        (macOS && !MacDesktopWindow.visible.value);
  }

  void _trim() {
    _timer?.cancel();
    _timer = null;
    if (_trimmed) return;
    _trimmed = true;
    MemoryTrim.trim(background: true);
  }

  void update() {
    if (!_hidden) {
      _timer?.cancel();
      _timer = null;
      _trimmed = false;
      return;
    }
    if (_trimmed || _timer != null) return;
    _timer = Timer(MemoryTrim.hiddenDelay, _trim);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _trim();
      return;
    }
    update();
  }

  @override
  void didHaveMemoryPressure() => MemoryTrim.trim();
}
