// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/bounded_byte_cache.dart';
import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:chatloom/widgets/cover_resize_image.dart';
import 'package:chatloom/widgets/lottie_sticker_data.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Where an [MxcImage] stands, for callers that draw their own progress.
enum MxcImageLoad {
  /// No frame yet: downloading, decrypting or decoding.
  loading,

  /// The first frame is on screen.
  ready,

  /// The media could not be loaded or decoded. Network errors keep retrying
  /// in the background and may still turn into [ready].
  failed,
}

/// Fetches the bytes of an unencrypted `mxc://` [uri] in place of
/// `downloadMxcCached` (the same request: [isThumbnail] at physical [width]
/// × [height]). The sticker panel keeps its own long-lived disk cache this
/// way without a fork of [MxcImage].
typedef MxcBytesLoader =
    Future<Uint8List> Function(
      Client client,
      Uri uri, {
      num? width,
      num? height,
      required bool isThumbnail,
      required bool animated,
      required ThumbnailMethod thumbnailMethod,
    });

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

  /// Decode a full-size image ([isThumbnail] false) only as large as needed
  /// to cover [width] × [height] (see [CoverResizeImage]).
  final bool decodeToCover;

  /// Paint opacity applied while drawing the image (no compositing layer).
  final double opacity;

  /// Caps the decode of a full-size image ([isThumbnail] false) to this many
  /// physical pixels on its long side (never upscaled), so a 50 MP original
  /// does not take 200 MB of RAM. A change keeps the previous frame until
  /// the new decode is ready (the viewer sharpens on zoom). The decodes are
  /// evicted from the shared [ImageCache] when they are replaced or the
  /// widget goes away, so they never push avatars and thumbnails out.
  final int? maxDecodeSide;

  /// Encryption of an [uri] attachment (an `EncryptedFile` JSON without
  /// `url`, as in `com.beeper.linkpreviews` `beeper:image:encryption`): the
  /// original is downloaded and decrypted locally; no thumbnail is asked for.
  final Map<String, Object?>? encryption;

  /// Called after the frame in which the state changes (never during
  /// build); the widget starts in [MxcImageLoad.loading].
  final ValueChanged<MxcImageLoad>? onLoadStateChanged;

  /// Loads an [uri] without [encryption] instead of the default download
  /// (which goes through the SQLCipher media cache and falls back from a
  /// missing thumbnail to the original). The memory cache, decoding and
  /// Lottie handling stay the same.
  final MxcBytesLoader? loadBytes;

  static void clearCache(String cacheName) =>
      _MxcImageState._imageDataCache.removeWhere((key) => key.$2 == cacheName);

  /// Whether [bytes] may hold more than one frame: a GIF, an animated WebP
  /// (`VP8X` with the animation flag) or an APNG (`acTL` before the image
  /// data). A cheap header sniff; a still GIF counts too (it costs only the
  /// visibility gate).
  static bool isAnimatedImage(Uint8List bytes) {
    bool at(int offset, String tag) {
      if (bytes.length < offset + tag.length) return false;
      for (var i = 0; i < tag.length; i++) {
        if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
      }
      return true;
    }

    if (at(0, 'GIF8')) return true;
    if (at(0, 'RIFF') && at(8, 'WEBP')) {
      return at(12, 'VP8X') && bytes.length > 20 && bytes[20] & 0x02 != 0;
    }
    if (at(0, '\x89PNG')) {
      // Chunks: length (4) + type (4) + data + CRC (4), from offset 8.
      var offset = 8;
      while (offset + 8 <= bytes.length) {
        final length =
            (bytes[offset] << 24) |
            (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3];
        if (at(offset + 4, 'acTL')) return true;
        if (at(offset + 4, 'IDAT') || length < 0) return false;
        offset += 12 + length;
      }
    }
    return false;
  }

  /// Drops parsed Lottie stickers (tests, memory pressure).
  static void clearLottieCache() => _MxcImageState._lottieCache.clear();

  /// Encoded bytes another [MxcImage] already holds in memory for [event]'s
  /// media (a timeline bubble, the media grid), whatever size it asked for;
  /// the largest copy wins. Lets the photo viewer start from the picture the
  /// user just tapped instead of an empty frame.
  static Uint8List? cachedPreviewOf(Event event) {
    final client = event.room.client;
    final transactionId = event.transactionId;
    return _MxcImageState._imageDataCache.largestWhere(
      (key) =>
          identical(key.$1, client) &&
          (key.$4 == event.eventId ||
              (transactionId != null && key.$3 == transactionId)),
    );
  }

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
    this.animationDuration = ChatLoomThemes.animationDuration,
    this.retryDuration = const Duration(seconds: 2),
    this.animationCurve = ChatLoomThemes.animationCurve,
    this.thumbnailMethod = ThumbnailMethod.scale,
    this.cacheKey,
    this.client,
    this.borderRadius = BorderRadius
        .zero, // design-lint: allow unclipped by default; callers pass a radius
    this.cacheName,
    this.decodeToCover = false,
    this.opacity = 1,
    this.maxDecodeSide,
    this.encryption,
    this.onLoadStateChanged,
    this.loadBytes,
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

/// Identity of a source for the parsed-Lottie cache: the same sticker shown
/// in two rows or scrolled back into view parses once.
typedef _LottieKey = (Client, String, bool);

class _MxcImageState extends State<MxcImage> with WidgetsBindingObserver {
  static final _imageDataCache = BoundedByteCache<_ImageKey>(
    maxBytes: 32 * 1024 * 1024,
    maxEntries: 512,
  );
  static final _lottieCache = LottieCompositionCache<_LottieKey>();
  Uint8List? _imageData;
  LottieComposition? _lottie;
  Timer? _retryTimer;
  int _generation = 0, _failures = 0;
  bool _loading = false;

  /// A terminal failure (unavailable, unsupported, undecryptable): a static
  /// fallback replaces the loader, so nothing animates forever.
  bool _failed = false;

  /// Bytes came from the memory cache before the first frame: render them
  /// directly, without the placeholder cross-fade.
  bool _fromCache = false;
  MxcImageLoad _reported = MxcImageLoad.loading;

  /// A frame of the current bytes is on screen.
  bool _shown = false;

  /// The decode size changed after a frame was shown ([MxcImage.maxDecodeSide]):
  /// the new decode swaps in place, without the placeholder fade.
  bool _swapped = false;

  /// The capped decode in use (see [MxcImage.maxDecodeSide]).
  ImageProvider? _capped;
  Client? _dependencyClient;
  double? _dependencyDpr;

  /// Bytes last sniffed by [_loops] and the answer, so a rebuild does not
  /// sniff again.
  Uint8List? _sniffed;
  bool _sniffedAnimated = false;

  /// The content animates (Lottie, animated GIF/WebP/PNG): it plays only
  /// while visible ([NotionContentLoopGate]).
  bool _loops(Uint8List? data, LottieComposition? lottie) {
    if (lottie != null) return true;
    if (data == null) return false;
    if (!identical(data, _sniffed)) {
      _sniffed = data;
      _sniffedAnimated = MxcImage.isAnimatedImage(data);
    }
    return _sniffedAnimated;
  }

  /// Tells [MxcImage.onLoadStateChanged] after this frame, once per change.
  void _report(MxcImageLoad state) {
    if (widget.onLoadStateChanged == null || _reported == state) return;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || _reported == state) return;
      _reported = state;
      widget.onLoadStateChanged?.call(state);
    });
  }

  bool get _active {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  Client _client() =>
      widget.client ?? widget.event?.room.client ?? Matrix.of(context).client;

  _LottieKey? _lottieKey(Client client) {
    final source = widget.uri?.toString() ?? widget.event?.eventId;
    return source == null ? null : (client, source, widget.isThumbnail);
  }

  void _accept(
    Uint8List data,
    _ImageKey? key,
    int generation, {
    LottieComposition? lottie,
  }) {
    if (!mounted || generation != _generation) return;
    if (key != null) _imageDataCache.put(key, data);
    setState(() {
      _imageData = data;
      _lottie = lottie;
      _failures = 0;
      _failed = false;
    });
  }

  void _fail(int generation) {
    if (!mounted || generation != _generation) return;
    _report(MxcImageLoad.failed);
    setState(() => _failed = true);
  }

  /// Accepts [data] as a Lottie sticker (TGS or Lottie JSON), parsing it once
  /// per source; false when it is not one.
  Future<bool> _acceptLottie(
    Uint8List data,
    _ImageKey? key,
    int generation,
    Client client,
  ) async {
    final lottieKey = _lottieKey(client);
    final composition =
        (lottieKey == null ? null : _lottieCache.get(lottieKey)) ??
        await LottieStickerData.decode(data);
    if (composition == null) return false;
    if (lottieKey != null) _lottieCache.put(lottieKey, composition);
    _accept(data, key, generation, lottie: composition);
    return true;
  }

  Future<Uint8List> _decrypt(
    Client client,
    Uint8List data,
    Map<String, Object?> file,
  ) async {
    final key = file.tryGetMap<String, Object?>('key');
    if (key?.tryGetList<String>('key_ops')?.contains('decrypt') != true) {
      throw StateError('Attachment key cannot decrypt');
    }
    final decrypted = await client.nativeImplementations.decryptFile(
      EncryptedFile(
        data: data,
        iv: file.tryGet<String>('iv')!,
        k: key!.tryGet<String>('k')!,
        sha256: file
            .tryGetMap<String, Object?>('hashes')!
            .tryGet<String>('sha256')!,
      ),
    );
    if (decrypted == null) throw StateError('Unable to decrypt attachment');
    return decrypted;
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
    final client = _client();
    final uri = widget.uri;
    final event = widget.event;
    final key = _cacheKey(client);
    final cached = key == null ? null : _imageDataCache.get(key);
    if (cached != null) {
      if (await _acceptLottie(cached, null, generation, client)) return;
      _accept(cached, null, generation);
      return;
    }

    final encryption = widget.encryption;
    if (uri != null && encryption != null) {
      // Encrypted media has no server-side thumbnail: the original only.
      final data = await _decrypt(
        client,
        await client.downloadMxcCached(uri),
        encryption,
      );
      if (!mounted || generation != _generation) return;
      _accept(data, key, generation);
      return;
    }

    if (uri != null) {
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final width = widget.width;
      final realWidth = width == null ? null : width * devicePixelRatio;
      final height = widget.height;
      final realHeight = height == null ? null : height * devicePixelRatio;

      Uint8List remoteData;
      final loadBytes = widget.loadBytes;
      if (loadBytes != null) {
        remoteData = await loadBytes(
          client,
          uri,
          width: realWidth,
          height: realHeight,
          isThumbnail: widget.isThumbnail,
          animated: widget.animated,
          thumbnailMethod: widget.thumbnailMethod,
        );
        if (!mounted || generation != _generation) return;
        if (await _acceptLottie(remoteData, key, generation, client)) return;
        _accept(remoteData, key, generation);
        return;
      }
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
      if (await _acceptLottie(remoteData, key, generation, client)) return;
      _accept(remoteData, key, generation);
      return;
    }

    if (event != null) {
      // A Lottie sticker animates from its original; its thumbnail (if the
      // bridge made one) is a still.
      final lottieMime = LottieStickerData.isLottieMime(
        event.attachmentMimetype,
      );
      final useThumbnail =
          widget.isThumbnail && event.hasThumbnail && !lottieMime;
      if (!useThumbnail &&
          !lottieMime &&
          !{
            MessageTypes.Image,
            MessageTypes.Sticker,
          }.contains(event.messageType)) {
        Logs().d('Event of type ${event.messageType} has no thumbnail');
        _fail(generation);
        return;
      }
      final data = await event.downloadAndDecryptAttachment(
        getThumbnail: useThumbnail,
      );
      if (!mounted || generation != _generation) return;
      if (data.detectFileType is MatrixImageFile && !lottieMime) {
        _accept(data.bytes, key, generation);
        return;
      }
      if (await _acceptLottie(data.bytes, key, generation, client)) return;
      // An image whose mimetype was wrong still renders as an image.
      if (data.detectFileType is MatrixImageFile) {
        _accept(data.bytes, key, generation);
        return;
      }
      Logs().d('Unsupported media for an image: ${event.attachmentMimetype}');
      _fail(generation);
    }
  }

  /// Rate limits and server errors are worth another try; anything else a
  /// server says about media (not found, forbidden, too large) is final.
  static bool _retriable(MatrixException e) {
    final status = e.response?.statusCode ?? 0;
    return e.error == MatrixError.M_LIMIT_EXCEEDED || status >= 500;
  }

  Future<void> _tryLoad() async {
    if (!mounted ||
        !_active ||
        _loading ||
        _failed ||
        _imageData != null ||
        (widget.uri == null && widget.event == null)) {
      return;
    }
    final generation = _generation;
    _loading = true;
    try {
      await _load(generation);
      // No thumbnail, or the attachment is not an image.
      if (generation == _generation && _imageData == null) {
        _report(MxcImageLoad.failed);
      }
    } on IOException catch (_) {
      _scheduleRetry(generation);
    } on http.ClientException catch (_) {
      _scheduleRetry(generation);
    } on TimeoutException catch (_) {
      _scheduleRetry(generation);
    } on MatrixException catch (e) {
      Logs().d('Unable to load image', e);
      if (_retriable(e)) {
        _scheduleRetry(generation);
      } else {
        _fail(generation);
      }
    } catch (e) {
      // Authorization, unavailable keys or malformed attachments stay closed.
      // A static fallback replaces the loader instead of an unhandled
      // asynchronous exception or retrying protected media.
      Logs().d('Unable to load image', e);
      _fail(generation);
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  void _scheduleRetry(int generation) {
    if (!mounted || generation != _generation) return;
    _report(MxcImageLoad.failed);
    if (!_active) return;
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
    _failed = false;
    _imageData = null;
    _lottie = null;
    _fromCache = false;
    _shown = false;
    _swapped = false;
    _reported = MxcImageLoad.loading;
    if (widget.uri != null || widget.event != null) {
      final client = _client();
      final key = _cacheKey(client);
      final cached = key == null ? null : _imageDataCache.get(key);
      final lottieKey = _lottieKey(client);
      final lottie = lottieKey == null ? null : _lottieCache.get(lottieKey);
      // Synchronous memory hit: no post-frame load, no fade-in on rebuilds
      // and list reorders. A Lottie sticker needs its parsed composition
      // too; without it the bytes are parsed once by the load below.
      if (cached != null &&
          (lottie != null || LottieStickerData.jsonBytes(cached) == null)) {
        _imageData = cached;
        _lottie = lottie;
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
  void didHaveMemoryPressure() {
    _imageDataCache.removeWhere((_) => true);
    _lottieCache.clear();
  }

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
        oldWidget.animated != widget.animated ||
        oldWidget.encryption != widget.encryption) {
      _resetImage();
    }
  }

  /// Remembers the capped provider in use; a replaced one leaves the cache.
  ImageProvider _track(ImageProvider provider) {
    final previous = _capped;
    if (previous != null && previous != provider) {
      if (_shown) _swapped = true;
      unawaited(previous.evict().catchError((Object _) => false));
    }
    return _capped = provider;
  }

  @override
  void dispose() {
    final capped = _capped;
    if (capped != null) {
      unawaited(capped.evict().catchError((Object _) => false));
    }
    _generation++;
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _imageData;
    final hasData = data != null && data.isNotEmpty;
    final lottie = _lottie;
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
      if (widget.decodeToCover && !widget.isThumbnail) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final width = widget.width, height = widget.height;
        if (width != null &&
            height != null &&
            width.isFinite &&
            height.isFinite &&
            width > 0 &&
            height > 0) {
          return CoverResizeImage(
            original,
            width: max(1, (width * dpr).ceil()),
            height: max(1, (height * dpr).ceil()),
          );
        }
      }
      final side = widget.maxDecodeSide;
      if (side != null && side > 0 && !widget.isThumbnail) {
        return _track(
          ResizeImage(
            original,
            width: side,
            height: side,
            policy: ResizeImagePolicy.fit,
          ),
        );
      }
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
      _report(MxcImageLoad.failed);
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
    if (_failed && !hasData) {
      // Static: the caller's placeholder (with a broken-image mark unless it
      // asked for the placeholder alone) or the broken-image tile.
      final custom = widget.placeholder;
      if (custom == null) {
        return errorFallback(context, 'unavailable', null);
      }
      if (widget.usePlaceholderOnError) return custom(context);
      return Stack(
        alignment: Alignment.center,
        children: [custom(context), const _MxcImageFailureMark()],
      );
    }
    // A network or disk load fades the first decoded frame in over the
    // placeholder (initials, spinner) instead of popping; memory hits and
    // synchronous decodes show at once, so scrolling never flickers.
    Widget fadeInFrame(
      BuildContext context,
      Widget child,
      int? frame,
      bool wasSynchronouslyLoaded,
    ) {
      if (frame != null) {
        _report(MxcImageLoad.ready);
        _shown = true;
      }
      if (wasSynchronouslyLoaded || _fromCache || _swapped) return child;
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

    final loops = hasData && _loops(data, lottie);
    // A gated loop shows its first frame at once: a fade-in would be stuck
    // under the gate's muted tickers.
    Widget firstFrame(
      BuildContext context,
      Widget child,
      int? frame,
      bool wasSynchronouslyLoaded,
    ) {
      if (frame != null) _report(MxcImageLoad.ready);
      return child;
    }

    var imageChild = data == null
        ? _MxcImagePlaceholder(
            width: widget.width,
            height: widget.height,
            placeholder: widget.placeholder,
          )
        : (lottie != null
              ? Lottie(
                  composition: lottie,
                  width: widget.width,
                  height: widget.height,
                  fit: widget.fit,
                  // Reduced motion shows the first frame, like a still.
                  animate: !NotionMotion.reduced(context),
                )
              : Image(
                  image: imageProvider(data),
                  width: widget.width,
                  height: widget.height,
                  fit: widget.fit,
                  opacity: widget.opacity < 1
                      ? AlwaysStoppedAnimation(widget.opacity.clamp(0.0, 1.0))
                      : null,
                  filterQuality: widget.isThumbnail
                      ? FilterQuality.low
                      : FilterQuality.medium,
                  // A new decode size keeps the old frame until it is ready.
                  gaplessPlayback: widget.maxDecodeSide != null,
                  frameBuilder: loops ? firstFrame : fadeInFrame,
                  errorBuilder: errorFallback,
                ));
    if (loops) {
      // Animated stickers and GIF images loop only while on screen
      // (DESIGN.md motion rule 4); timeline and grid media also follow the
      // "autoplay" setting, the viewer (originals) always plays.
      imageChild = NotionContentLoopGate(
        enabled: !widget.isThumbnail || AppSettings.autoplayImages.value,
        child: imageChild,
      );
    }

    final clipped =
        widget.borderRadius ==
            BorderRadius
                .zero // design-lint: allow sentinel
        ? imageChild
        : ClipRRect(borderRadius: widget.borderRadius, child: imageChild);
    if (_fromCache && hasData) return clipped;
    if (!hasData) return placeholder;
    // Images fade their first frame in (above); a Lottie sticker fades in
    // once when it arrives.
    if (lottie == null) return clipped;
    _report(MxcImageLoad.ready);
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

/// A small static mark over a placeholder whose media could not be loaded.
class _MxcImageFailureMark extends StatelessWidget {
  const _MxcImageFailureMark();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: ShapeDecoration(
      color: NotionMediaColors.scrim,
      shape: CircleBorder(),
    ),
    child: Padding(
      padding: EdgeInsets.all(NotionSpace.xs),
      child: Icon(
        Icons.broken_image_outlined,
        color: NotionMediaColors.onScrim,
        size: NotionSize.icon,
        semanticLabel: 'Media unavailable',
      ),
    ),
  );
}
