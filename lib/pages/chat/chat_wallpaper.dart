// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/account_config.dart';
import 'package:chatloom/utils/client_download_content_extension.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show ChatTheme;

typedef ChatBackgroundSelection = ({
  Uri? photo,
  double opacity,
  double blur,
  NotionWallpaperPreset preset,
  double strength,
  Color? solid,
  bool hasWallpaper,
});

NotionWallpaperPreset? _conversationPreset(ChatTheme? theme) =>
    NotionWallpaperPreset.values
        .where((preset) => preset.name == theme?.wallpaperAsset)
        .firstOrNull;

/// Older clients saved an empty object when resetting a conversation.
ChatTheme? effectiveChatTheme(ChatTheme? theme) =>
    theme?.backgroundColor != null ||
        theme?.incomingColor != null ||
        theme?.outgoingColor != null ||
        _conversationPreset(theme) != null
    ? theme
    : null;

Color? chatSolidBackground(ChatTheme? theme) {
  final color = theme?.backgroundColor;
  return color == null || _conversationPreset(theme) != null
      ? null
      : Color(color);
}

/// A private background choice takes priority over the device defaults.
/// Unknown preset IDs fall back to the saved solid or the app default.
ChatBackgroundSelection resolveChatBackground(
  BuildContext context,
  ApplicationAccountConfig accountConfig, {
  ChatTheme? theme,
  NotionDisplayPreferences? display,
}) {
  final preferences = display ?? NotionDisplayPreferences.of(context);
  final override = _conversationPreset(theme);
  final solid = chatSolidBackground(theme);
  final photo =
      override == null && solid == null && preferences.accountWallpaperEnabled
      ? accountConfig.wallpaperUrl
      : null;
  final preset =
      override ??
      (solid != null || photo != null
          ? NotionWallpaperPreset.none
          : preferences.wallpaperPreset);
  return (
    photo: photo,
    opacity: accountConfig.wallpaperOpacity ?? .5,
    blur: accountConfig.wallpaperBlur ?? 0,
    preset: preset,
    strength: preferences.wallpaperStrength,
    solid: solid,
    hasWallpaper: photo != null || preset != NotionWallpaperPreset.none,
  );
}

/// The decorative layer shared by the timeline and appearance previews.
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.selection, this.client});

  final ChatBackgroundSelection selection;
  final Client? client;

  @override
  Widget build(BuildContext context) {
    final (
      :photo,
      :opacity,
      :blur,
      :preset,
      :strength,
      :solid,
      hasWallpaper: _,
    ) = selection;
    if (photo != null) {
      return Positioned.fill(
        child: IgnorePointer(
          child: ChatWallpaper(
            key: ValueKey(photo),
            uri: photo,
            opacity: opacity,
            blur: blur,
            client: client,
          ),
        ),
      );
    }
    if (solid != null) {
      return Positioned.fill(child: ColoredBox(color: solid));
    }
    return NotionPresetWallpaper(preset: preset, strength: strength);
  }
}

/// The rows depend only on whether their metadata needs a backing chip.
/// Photo changes and slider edits leave the scrolling list mounted.
class ChatBackgroundStack extends StatefulWidget {
  const ChatBackgroundStack({
    super.key,
    required this.client,
    required this.theme,
    required this.children,
  });

  final Client client;
  final ChatTheme? theme;
  final List<Widget> children;

  static bool? wallpaperModeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ChatWallpaperMode>()
      ?.hasWallpaper;

  @override
  State<ChatBackgroundStack> createState() => _ChatBackgroundStackState();
}

class _ChatBackgroundStackState extends State<ChatBackgroundStack> {
  late Stream<SyncUpdate> _accountUpdates = _updatesOf(widget.client);

  Stream<SyncUpdate> _updatesOf(Client client) => client.onSync.stream.where(
    (sync) =>
        sync.accountData?.any(
          (data) =>
              data.type == ApplicationAccountConfigExtension.accountDataKey,
        ) ??
        false,
  );

  @override
  void didUpdateWidget(ChatBackgroundStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      _accountUpdates = _updatesOf(widget.client);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: _accountUpdates,
    builder: (context, _) {
      final selection = resolveChatBackground(
        context,
        widget.client.applicationAccountConfig,
        theme: widget.theme,
      );
      return _ChatWallpaperMode(
        hasWallpaper: selection.hasWallpaper,
        child: Stack(
          children: [
            ChatBackground(selection: selection, client: widget.client),
            ...widget.children,
          ],
        ),
      );
    },
  );
}

class _ChatWallpaperMode extends InheritedWidget {
  const _ChatWallpaperMode({required this.hasWallpaper, required super.child});

  final bool hasWallpaper;

  @override
  bool updateShouldNotify(_ChatWallpaperMode oldWidget) =>
      hasWallpaper != oldWidget.hasWallpaper;
}

/// The account wallpaper behind a conversation (single and merged chats).
///
/// It sits under the scrolling timeline and both glass bars, so it is kept
/// cheap per frame: its own [RepaintBoundary] (timeline scrolls never
/// re-record it), decoded only as large as the screen it covers instead of
/// at the original photo resolution, and its opacity painted by the image
/// itself rather than through an `Opacity` compositing layer.
///
/// A blurred wallpaper is blurred once into a small bitmap
/// ([BlurredWallpaper]) instead of through a live image filter, which
/// Impeller (no raster cache) would redo on every scroll frame.
class ChatWallpaper extends StatelessWidget {
  final Uri uri;
  final double opacity;
  final Client? client;

  /// Static blur sigma chosen in the style settings; 0 adds no filter.
  final double blur;

  const ChatWallpaper({
    super.key,
    required this.uri,
    required this.opacity,
    this.blur = 0,
    this.client,
  });

  @override
  Widget build(BuildContext context) {
    if (blur > 0) {
      final account = client ?? Matrix.of(context).client;
      return RepaintBoundary(
        child: BlurredWallpaper(
          cacheKey: uri.toString(),
          blur: blur,
          opacity: opacity.clamp(0.0, 1.0),
          load: () => account.downloadMxcCached(uri),
        ),
      );
    }
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = MediaQuery.sizeOf(context);
          return MxcImage(
            client: client,
            cacheKey: uri.toString(),
            uri: uri,
            fit: BoxFit.cover,
            height: constraints.hasBoundedHeight
                ? constraints.maxHeight
                : viewport.height,
            width: constraints.hasBoundedWidth
                ? constraints.maxWidth
                : viewport.width,
            isThumbnail: false,
            decodeToCover: true,
            opacity: opacity.clamp(0.0, 1.0),
            placeholder: (_) => const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}

/// A full-screen picture blurred once: the bytes from [load] are decoded at
/// a reduced resolution (a blur needs no detail), cover-fitted to the screen
/// and blurred into one bitmap, which is afterwards only drawn. The bitmap is
/// kept for the last [cacheEntries] (picture, blur, size) combinations, so
/// reopening a chat shows it in the first frame. Sizes are bucketed, so a
/// resizing desktop window does not blur again on every step.
class BlurredWallpaper extends StatefulWidget {
  final String cacheKey;
  final double blur;
  final double opacity;
  final Future<Uint8List> Function() load;

  const BlurredWallpaper({
    super.key,
    required this.cacheKey,
    required this.blur,
    required this.opacity,
    required this.load,
  });

  /// Bitmaps kept across chats (each a few hundred KB).
  static const int cacheEntries = 2;

  /// Screen sizes are rounded up to this many logical pixels.
  static const double sizeBucket = 256;

  static final _cache = <_BlurKey, ui.Image>{};

  /// The cached bitmap for [key], marked as most recently used.
  static ui.Image? _cached(_BlurKey key) {
    final image = _cache.remove(key);
    if (image != null) _cache[key] = image;
    return image;
  }

  static void _store(_BlurKey key, ui.Image image) {
    _cache.remove(key)?.dispose();
    _cache[key] = image;
    while (_cache.length > cacheEntries) {
      _cache.remove(_cache.keys.first)?.dispose();
    }
  }

  @visibleForTesting
  static int get debugCachedBitmaps => _cache.length;

  @visibleForTesting
  static void debugClearCache() {
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
  }

  /// Bitmap pixels per logical pixel: enough for the blur to stay smooth (a
  /// sigma of at least about 4 bitmap pixels), never more than the screen.
  static double rasterScale(double blur, double devicePixelRatio) {
    final ceiling = math.max(.25, devicePixelRatio);
    return (4 / blur).clamp(.25, ceiling);
  }

  @override
  State<BlurredWallpaper> createState() => _BlurredWallpaperState();
}

typedef _BlurKey = (String, double, int, int);

class _BlurredWallpaperState extends State<BlurredWallpaper> {
  /// This widget's own handle of the shared bitmap.
  ui.Image? _image;
  _BlurKey? _key;
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  void _show(ui.Image? image) {
    _image?.dispose();
    _image = image?.clone();
  }

  void _resolve(_BlurKey key, Size size, double scale) {
    if (key == _key) return;
    _key = key;
    final generation = ++_generation;
    final cached = BlurredWallpaper._cached(key);
    if (cached != null) {
      _show(cached);
      return;
    }
    unawaited(
      _render(size, scale, key.$2).then(
        (image) {
          BlurredWallpaper._store(key, image);
          if (!mounted || generation != _generation) return;
          setState(() => _show(image));
        },
        onError: (Object error, StackTrace stack) {
          // No wallpaper is better than a broken one; the chat is unchanged.
          Logs().d('Wallpaper could not be blurred', error, stack);
        },
      ),
    );
  }

  Future<ui.Image> _render(Size size, double scale, double blur) async {
    final bytes = await widget.load();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final width = math.max(1, (size.width * scale).round());
      final height = math.max(1, (size.height * scale).round());
      // Decode just large enough to cover the bitmap.
      final cover = math.max(
        width / descriptor.width,
        height / descriptor.height,
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * cover).ceil()),
        targetHeight: math.max(1, (descriptor.height * cover).ceil()),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final source = frame.image;
      try {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final sigma = blur * scale;
        final target = Offset.zero & Size(width.toDouble(), height.toDouble());
        canvas.drawImageRect(
          source,
          Rect.fromCenter(
            center: Offset(source.width / 2, source.height / 2),
            width: math.min(width.toDouble(), source.width.toDouble()),
            height: math.min(height.toDouble(), source.height.toDouble()),
          ),
          target,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.clamp,
            ),
        );
        final picture = recorder.endRecording();
        try {
          return await picture.toImage(width, height);
        } finally {
          picture.dispose();
        }
      } finally {
        source.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    double bucket(double extent) =>
        math.max(1, (extent / BlurredWallpaper.sizeBucket).ceil()) *
        BlurredWallpaper.sizeBucket;
    final covered = Size(bucket(size.width), bucket(size.height));
    _resolve(
      (
        widget.cacheKey,
        widget.blur,
        covered.width.round(),
        covered.height.round(),
      ),
      covered,
      BlurredWallpaper.rasterScale(widget.blur, dpr),
    );
    final image = _image;
    return SizedBox.expand(
      child: image == null
          ? null
          : RawImage(
              image: image,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              opacity: AlwaysStoppedAnimation(widget.opacity),
            ),
    );
  }
}
