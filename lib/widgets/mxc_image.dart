// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/bounded_byte_cache.dart';
import 'package:fluffychat/utils/client_download_content_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class MxcImage extends StatefulWidget {
  final Uri? uri;
  final Event? event;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final bool isThumbnail;
  final bool animated;
  final Duration retryDuration;
  final Duration animationDuration;
  final Curve animationCurve;
  final ThumbnailMethod thumbnailMethod;
  final Widget Function(BuildContext context)? placeholder;
  final bool usePlaceholderOnError;
  final String? cacheKey;
  final String? cacheName;
  final Client? client;
  final BorderRadius borderRadius;

  static void clearCache(String cacheName) =>
      _MxcImageState._imageDataCache.removeWhere((key) => key.$2 == cacheName);

  const MxcImage({
    this.uri,
    this.event,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.usePlaceholderOnError = false,
    this.isThumbnail = true,
    this.animated = false,
    this.animationDuration = FluffyThemes.animationDuration,
    this.retryDuration = const Duration(seconds: 2),
    this.animationCurve = FluffyThemes.animationCurve,
    this.thumbnailMethod = ThumbnailMethod.scale,
    this.cacheKey,
    this.client,
    this.borderRadius = BorderRadius.zero,
    this.cacheName,
    super.key,
  });

  @override
  State<MxcImage> createState() => _MxcImageState();
}

typedef _ImageKey = (
  Client,
  String,
  String,
  String?,
  double?,
  double?,
  bool,
  bool,
);

class _MxcImageState extends State<MxcImage> with WidgetsBindingObserver {
  static final _imageDataCache = BoundedByteCache<_ImageKey>(
    maxBytes: 32 * 1024 * 1024,
    maxEntries: 512,
  );
  Uint8List? _imageData, _lottieData;
  Timer? _retryTimer;
  int _generation = 0, _failures = 0;
  bool _loading = false;

  /// Bytes came from the memory cache before the first frame: render them
  /// directly, without the placeholder cross-fade.
  bool _fromCache = false;
  Client? _dependencyClient;
  double? _dependencyDpr;

  bool get _active {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _accept(Uint8List data, _ImageKey? key, int generation) {
    if (!mounted || generation != _generation) return;
    if (key != null) _imageDataCache.put(key, data);
    setState(() {
      _imageData = data;
      _lottieData = _ungzipLottie(data);
      _failures = 0;
    });
  }

  _ImageKey? _cacheKey(Client client) {
    final cacheKey = widget.cacheKey;
    if (cacheKey == null) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (
      client,
      widget.cacheName ?? '',
      cacheKey,
      widget.uri?.toString() ?? widget.event?.eventId,
      widget.width == null ? null : widget.width! * dpr,
      widget.height == null ? null : widget.height! * dpr,
      widget.isThumbnail,
      widget.animated,
    );
  }

  Future<void> _load(int generation) async {
    final client =
        widget.client ?? widget.event?.room.client ?? Matrix.of(context).client;
    final uri = widget.uri;
    final event = widget.event;
    final key = _cacheKey(client);
    final cached = key == null ? null : _imageDataCache.get(key);
    if (cached != null) {
      _accept(cached, null, generation);
      return;
    }

    if (uri != null) {
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final width = widget.width;
      final realWidth = width == null ? null : width * devicePixelRatio;
      final height = widget.height;
      final realHeight = height == null ? null : height * devicePixelRatio;

      Uint8List remoteData;
      try {
        remoteData = await client.downloadMxcCached(
          uri,
          width: realWidth,
          height: realHeight,
          thumbnailMethod: widget.thumbnailMethod,
          isThumbnail: widget.isThumbnail,
          animated: widget.animated,
        );
      } on MatrixException catch (e) {
        if (!widget.isThumbnail) rethrow;
        // Some bridge and remote media has no thumbnail (404/unrecognized);
        // the original still loads.
        Logs().d('Thumbnail unavailable, loading original', e);
        remoteData = await client.downloadMxcCached(uri);
      }
      _accept(remoteData, key, generation);
      return;
    }

    if (event != null) {
      final useThumbnail = widget.isThumbnail && event.hasThumbnail;
      if (!useThumbnail &&
          !{
            MessageTypes.Image,
            MessageTypes.Sticker,
          }.contains(event.messageType)) {
        Logs().e('Event of type ${event.messageType} has no thumbnail!');
        return;
      }
      final data = await event.downloadAndDecryptAttachment(
        getThumbnail: useThumbnail,
      );
      if (data.detectFileType is MatrixImageFile) {
        _accept(data.bytes, key, generation);
        return;
      }
    }
  }

  Future<void> _tryLoad() async {
    if (!mounted ||
        !_active ||
        _loading ||
        _imageData != null ||
        (widget.uri == null && widget.event == null)) {
      return;
    }
    final generation = _generation;
    _loading = true;
    try {
      await _load(generation);
    } on IOException catch (_) {
      _scheduleRetry(generation);
    } on http.ClientException catch (_) {
      _scheduleRetry(generation);
    } on TimeoutException catch (_) {
      _scheduleRetry(generation);
    } on MatrixException catch (e) {
      Logs().d('Unable to load image', e);
    } catch (e) {
      // Authorization, unavailable keys or malformed attachments stay closed.
      // A scoped thumbnail placeholder remains usable instead of an unhandled
      // asynchronous exception or retrying protected media.
      Logs().d('Unable to load image', e);
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  void _scheduleRetry(int generation) {
    if (!mounted || generation != _generation || !_active) return;
    final multiplier = 1 << min(_failures++, 5);
    final delay = Duration(
      microseconds: min(
        widget.retryDuration.inMicroseconds * multiplier,
        const Duration(minutes: 1).inMicroseconds,
      ).clamp(1000, const Duration(minutes: 1).inMicroseconds),
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _tryLoad);
  }

  void _resetImage() {
    _generation++;
    _retryTimer?.cancel();
    _loading = false;
    _failures = 0;
    _imageData = _lottieData = null;
    _fromCache = false;
    if (widget.uri != null || widget.event != null) {
      final client =
          widget.client ??
          widget.event?.room.client ??
          Matrix.of(context).client;
      final key = _cacheKey(client);
      final cached = key == null ? null : _imageDataCache.get(key);
      if (cached != null) {
        // Synchronous memory hit: no post-frame load, no fade-in on rebuilds
        // and list reorders.
        _imageData = cached;
        _lottieData = _ungzipLottie(cached);
        _fromCache = true;
        return;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryLoad());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // didChangeDependencies (always called next) resolves the cache or
    // schedules the load.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.uri == null && widget.event == null) return;
    final owner =
        widget.client ?? widget.event?.room.client ?? Matrix.of(context).client;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_dependencyClient != owner || _dependencyDpr != dpr) {
      _dependencyClient = owner;
      _dependencyDpr = dpr;
      _resetImage();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _retryTimer?.cancel();
    if (state == AppLifecycleState.resumed) {
      _failures = 0;
      unawaited(_tryLoad());
    }
  }

  @override
  void didHaveMemoryPressure() => _imageDataCache.removeWhere((_) => true);

  @override
  void didUpdateWidget(MxcImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.event != widget.event ||
        oldWidget.client != widget.client ||
        oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.cacheName != widget.cacheName ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height ||
        oldWidget.isThumbnail != widget.isThumbnail ||
        oldWidget.animated != widget.animated) {
      _resetImage();
    }
  }

  @override
  void dispose() {
    _generation++;
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _imageData;
    final hasData = data != null && data.isNotEmpty;
    final ungzippedLottieData = _lottieData;
    int? decodeSize(double? logical) {
      if (!widget.isThumbnail ||
          logical == null ||
          !logical.isFinite ||
          logical <= 0)
        return null;
      return max(1, (logical * MediaQuery.devicePixelRatioOf(context)).ceil());
    }

    ImageProvider imageProvider(Uint8List bytes) {
      final original = MemoryImage(bytes);
      final width = decodeSize(widget.width);
      final height = decodeSize(widget.height);
      if (width == null && height == null) return original;
      return ResizeImage(
        original,
        width: width,
        height: height,
        policy: ResizeImagePolicy.fit,
      );
    }

    Widget errorFallback(
      BuildContext context,
      Object error,
      StackTrace? stackTrace,
    ) {
      Logs().d('Unable to render mxc image', error, stackTrace);
      if (widget.usePlaceholderOnError && widget.placeholder != null) {
        return widget.placeholder!(context);
      }
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Icon(
            Icons.broken_image_outlined,
            size: min(widget.height ?? 64, 64),
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      );
    }

    final placeholder = _MxcImagePlaceholder(
      width: widget.width,
      height: widget.height,
      placeholder: widget.placeholder,
    );
    // A network or disk load fades the first decoded frame in over the
    // placeholder (initials, spinner) instead of popping; memory hits and
    // synchronous decodes show at once, so scrolling never flickers.
    Widget fadeInFrame(
      BuildContext context,
      Widget child,
      int? frame,
      bool wasSynchronouslyLoaded,
    ) {
      if (wasSynchronouslyLoaded || _fromCache) return child;
      final duration = NotionMotion.reduced(context)
          ? Duration.zero
          : widget.animationDuration;
      final decoded = frame != null;
      return Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: decoded ? 0 : 1,
              duration: duration,
              curve: NotionMotion.exitFast,
              child: placeholder,
            ),
          ),
          AnimatedOpacity(
            opacity: decoded ? 1 : 0,
            duration: duration,
            curve: widget.animationCurve,
            child: child,
          ),
        ],
      );
    }

    final imageChild = data == null
        ? _MxcImagePlaceholder(
            width: widget.width,
            height: widget.height,
            placeholder: widget.placeholder,
          )
        : (ungzippedLottieData != null
              ? Lottie.memory(
                  ungzippedLottieData,
                  width: widget.width,
                  height: widget.height,
                  fit: widget.fit,
                  errorBuilder: errorFallback,
                )
              : Image(
                  image: imageProvider(data),
                  width: widget.width,
                  height: widget.height,
                  fit: widget.fit,
                  filterQuality: widget.isThumbnail
                      ? FilterQuality.low
                      : FilterQuality.medium,
                  frameBuilder: fadeInFrame,
                  errorBuilder: errorFallback,
                ));

    final clipped = widget.borderRadius == BorderRadius.zero
        ? imageChild
        : ClipRRect(borderRadius: widget.borderRadius, child: imageChild);
    if (_fromCache && hasData) return clipped;
    if (!hasData) return placeholder;
    // Images fade their first frame in (above); a Lottie sticker fades in
    // once when it arrives.
    if (ungzippedLottieData == null) return clipped;
    return NotionEntrance(
      rise: 0,
      afterRoute: false,
      duration: widget.animationDuration,
      child: clipped,
    );
  }
}

class _MxcImagePlaceholder extends StatelessWidget {
  final double? width;
  final double? height;
  final Widget Function(BuildContext context)? placeholder;

  const _MxcImagePlaceholder({
    required this.width,
    required this.height,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    return placeholder?.call(context) ??
        Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          child: const NotionDelayedSpinner(),
        );
  }
}

Uint8List? _ungzipLottie(Uint8List data) {
  // early return if the data is not gzipped
  if (data.length < 2 || data.first != 0x1f || data[1] != 0x8b) {
    return null;
  }

  // try decoding json
  try {
    final decompressed = GZipDecoder().decodeBytes(data);
    final jsonStr = utf8.decode(decompressed);
    final json = jsonDecode(jsonStr);
    if (json is Map && json.containsKey('v')) {
      return Uint8List.fromList(utf8.encode(jsonStr));
    }
  } catch (_) {
    return null;
  }

  return null;
}
