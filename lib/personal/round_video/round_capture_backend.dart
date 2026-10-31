// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../media/media_access.dart';
import 'round_media_preparer.dart';

class RoundCaptureProfile {
  /// Native RoundProfile.validate() limits; keep both sides identical.
  static const maxVideoBitrate = 8000000;
  static const maxAudioBitrate = 256000;

  /// High-quality rounds: larger square and bitrate, still bridge-bounded.
  static const highQualitySide = 480;
  static const highQualityVideoBitrate = 2000000;
  static const highQualityAudioBitrate = 96000;

  final int side;
  final int maxBytes;
  final int maxDurationMs;
  final int videoBitrate;
  final int audioBitrate;

  /// Camera2 video/optical stabilization when the lens advertises it.
  final bool stabilize;

  /// Voice-communication microphone path (platform noise suppression/AGC).
  /// Off: the plain microphone (`AudioSource.DEFAULT`), as Telegram rounds.
  final bool noiseReduction;
  final bool highQuality;

  /// Defaults keep the previous native behaviour for callers that predate the
  /// quality settings: no stabilization request, plain microphone.
  const RoundCaptureProfile({
    required this.maxBytes,
    this.side = 384,
    this.maxDurationMs = 60000,
    this.videoBitrate = 1000000,
    this.audioBitrate = 64000,
    this.stabilize = false,
    this.noiseReduction = false,
    this.highQuality = false,
  });

  /// Builds the capture profile from the bridge-declared encoding limits and
  /// the user's round quality settings. The side never exceeds [maxSide], and
  /// the exporter still fits the final file into [maxBytes].
  factory RoundCaptureProfile.fromBridge({
    required int maxBytes,
    required int maxSide,
    required int recommendedSide,
    required int maxDurationMs,
    required int videoBitrate,
    required int audioBitrate,
    bool highQuality = false,
    bool stabilize = true,
    bool noiseReduction = false,
  }) {
    int even(int value) => value - value % 2;
    final standardSide = even(
      recommendedSide < maxSide ? recommendedSide : maxSide,
    );
    final hqLimit = even(maxSide < highQualitySide ? maxSide : highQualitySide);
    final hq = highQuality && hqLimit >= standardSide;
    int clamp(int value, int lower, int upper) =>
        value < lower ? lower : (value > upper ? upper : value);
    return RoundCaptureProfile(
      maxBytes: maxBytes,
      side: hq ? hqLimit : standardSide,
      maxDurationMs: maxDurationMs,
      videoBitrate: hq
          ? highQualityVideoBitrate
          : clamp(videoBitrate, 100000, maxVideoBitrate),
      audioBitrate: hq
          ? clamp(
              audioBitrate > highQualityAudioBitrate
                  ? audioBitrate
                  : highQualityAudioBitrate,
              16000,
              maxAudioBitrate,
            )
          : clamp(audioBitrate, 16000, maxAudioBitrate),
      stabilize: stabilize,
      noiseReduction: noiseReduction,
      highQuality: hq,
    );
  }

  bool get isValid =>
      side >= 128 &&
      side <= 640 &&
      side.isEven &&
      maxDurationMs >= 800 &&
      maxDurationMs <= 60000 &&
      maxBytes > 0 &&
      videoBitrate >= 100000 &&
      videoBitrate <= maxVideoBitrate &&
      audioBitrate >= 16000 &&
      audioBitrate <= maxAudioBitrate;
}

class RoundCapturePreview {
  final int textureId;
  final int width;
  final int height;
  final int rotation;
  final bool mirrored;
  final bool canSwitchDuringRecording;
  final bool canSwitchCamera;
  final double minZoom;
  final double maxZoom;
  final double zoom;
  final bool torchAvailable;
  final bool torchEnabled;
  final int cameraRevision;
  const RoundCapturePreview({
    required this.textureId,
    required this.width,
    required this.height,
    required this.rotation,
    required this.mirrored,
    required this.canSwitchDuringRecording,
    this.canSwitchCamera = false,
    this.minZoom = 1,
    this.maxZoom = 1,
    this.zoom = 1,
    this.torchAvailable = false,
    this.torchEnabled = false,
    this.cameraRevision = 0,
  });

  // Keep the native RoundZoomRange.supported hardware threshold identical.
  bool get canZoom => maxZoom - minZoom > 0.0001;

  factory RoundCapturePreview.fromNative(Map<Object?, Object?> result) {
    final texture = result['textureId'];
    final width = result['width'];
    final height = result['height'];
    final rotation = result['rotation'];
    final revision = result['cameraRevision'] ?? 0;
    double zoomNumber(String key) {
      final value = result[key] ?? 1;
      if (value is! num) throw const RoundCaptureException('invalid_preview');
      return value.toDouble();
    }

    final minZoom = zoomNumber('minZoom');
    final maxZoom = zoomNumber('maxZoom');
    final zoom = zoomNumber('zoom');
    if (texture is! int ||
        texture < 0 ||
        width is! int ||
        width <= 0 ||
        height is! int ||
        height <= 0 ||
        rotation is! int ||
        !const [0, 90, 180, 270].contains(rotation) ||
        revision is! int ||
        revision < 0 ||
        !minZoom.isFinite ||
        !maxZoom.isFinite ||
        !zoom.isFinite ||
        minZoom <= 0 ||
        maxZoom < minZoom ||
        zoom < minZoom ||
        zoom > maxZoom) {
      throw const RoundCaptureException('invalid_preview');
    }
    return RoundCapturePreview(
      textureId: texture,
      width: width,
      height: height,
      rotation: rotation,
      mirrored: result['mirrored'] == true,
      canSwitchDuringRecording: result['canSwitchDuringRecording'] == true,
      canSwitchCamera: result['canSwitchCamera'] == true,
      minZoom: minZoom,
      maxZoom: maxZoom,
      zoom: zoom,
      torchAvailable: result['torchAvailable'] == true,
      torchEnabled:
          result['torchAvailable'] == true && result['torchEnabled'] == true,
      cameraRevision: revision,
    );
  }
}

class RoundCaptureNativeEvent {
  final String type;
  final Map<Object?, Object?> data;
  const RoundCaptureNativeEvent(this.type, this.data);
}

abstract interface class RoundCaptureBackend {
  Stream<RoundCaptureNativeEvent> get events;
  Future<RoundCapturePreview> initialize(RoundCaptureProfile profile);
  Future<void> start();
  Future<void> pause();
  Future<void> resume();
  Future<PreparedRoundMedia> finish();
  Future<PreparedRoundMedia> trim(int startMs, int endMs);
  Future<RoundCapturePreview> switchCamera({required int cameraRevision});
  Future<RoundCapturePreview> setZoom(
    double zoom, {
    required int cameraRevision,
  });
  Future<RoundCapturePreview> setTorch(
    bool enabled, {
    required int cameraRevision,
  });
  Future<void> cancel();
  Future<void> dispose({bool keepPrepared = false});
}

/// Callers must freeze and
/// authorize the destination before initialize(), which can show permissions.
class AndroidRoundCaptureBackend implements RoundCaptureBackend {
  static const channelName = 'pl.personal.chat/round_capture';
  static final Map<String, AndroidRoundCaptureBackend> _channelOwners = {};
  final MediaAccess mediaAccess;
  final MethodChannel _channel;
  final TargetPlatform _platform;
  final _events = StreamController<RoundCaptureNativeEvent>.broadcast();
  ManagedMediaFile? _lease;
  RoundCaptureProfile? _profile;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _disposal;
  bool _closing = false;
  bool _acceptEvents = false;
  bool _wasInterrupted = false;
  bool get wasInterrupted => _wasInterrupted;
  static int _nextCaptureId = 0;
  final String _captureId =
      '${DateTime.now().microsecondsSinceEpoch}-${++_nextCaptureId}';

  AndroidRoundCaptureBackend(
    this.mediaAccess, {
    MethodChannel? channel,
    TargetPlatform platform = TargetPlatform.android,
  }) : _platform = platform,
       _channel = channel ?? const MethodChannel(channelName) {
    _channelOwners[_channel.name] = this;
    _channel.setMethodCallHandler((call) async {
      if (_disposed ||
          _closing ||
          !_acceptEvents ||
          call.method != 'event' ||
          call.arguments is! Map) {
        return;
      }
      final data = Map<Object?, Object?>.from(call.arguments as Map);
      if (data['captureId'] != _captureId) return;
      if (data['wasInterrupted'] == true) _wasInterrupted = true;
      final type = data['type'];
      if (type is String) _events.add(RoundCaptureNativeEvent(type, data));
    });
  }

  @override
  Stream<RoundCaptureNativeEvent> get events => _events.stream;

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    if (_disposed || (_closing && method != 'dispose')) {
      throw const RoundCaptureException('disposed');
    }
    try {
      return await _channel.invokeMethod<T>(method, {
        if (arguments is Map) ...arguments,
        'captureId': _captureId,
      });
    } on PlatformException catch (error) {
      throw RoundCaptureException(error.code);
    } on MissingPluginException {
      throw const RoundCaptureException('unsupported_platform');
    }
  }

  @override
  Future<RoundCapturePreview> initialize(RoundCaptureProfile profile) async {
    if (_disposed || _closing || _profile != null) {
      throw const RoundCaptureException('disposed');
    }
    if (!profile.isValid) throw const RoundCaptureException('invalid_profile');
    if (kIsWeb || defaultTargetPlatform != _platform) {
      throw const RoundCaptureException('unsupported_platform');
    }
    _profile = profile;
    _acceptEvents = true;
    final generation = _generation;
    final lease = await mediaAccess.createWriter(extension: '.mp4');
    if (_disposed || generation != _generation) {
      await lease.close();
      throw const RoundCaptureException('canceled');
    }
    _lease = lease;
    try {
      final result = await _invoke<Map<Object?, Object?>>('initialize', {
        'directory': lease.writableDirectory,
        'outputPath': lease.file.path,
        'side': profile.side,
        'maxBytes': profile.maxBytes,
        'maxDurationMs': profile.maxDurationMs,
        'videoBitrate': profile.videoBitrate,
        'audioBitrate': profile.audioBitrate,
        'stabilize': profile.stabilize,
        'noiseReduction': profile.noiseReduction,
        'highQuality': profile.highQuality,
        'captureId': _captureId,
      });
      if (_disposed || generation != _generation) {
        throw const RoundCaptureException('canceled');
      }
      return _preview(result!);
    } catch (_) {
      await lease.close();
      if (identical(_lease, lease)) _lease = null;
      rethrow;
    }
  }

  RoundCapturePreview _preview(Map<Object?, Object?> result) {
    if (result['captureId'] != _captureId) {
      throw const RoundCaptureException('canceled');
    }
    return RoundCapturePreview.fromNative(result);
  }

  PreparedRoundMedia preparedFromEvent(Map<Object?, Object?> result) =>
      _prepared(result);

  PreparedRoundMedia _prepared(Map<Object?, Object?> result) {
    final profile = _profile;
    final lease = _lease;
    if (profile == null ||
        lease == null ||
        !_acceptEvents ||
        _closing ||
        _disposed ||
        result['captureId'] != _captureId) {
      throw const RoundCaptureException('canceled');
    }
    return PreparedRoundMedia.fromNative(
      result,
      lease,
      maxBytes: profile.maxBytes,
      maxDurationMs: profile.maxDurationMs,
      maxSide: profile.side,
    );
  }

  @override
  Future<void> start() async => _invoke<void>('start');
  @override
  Future<void> pause() async => _invoke<void>('pause');
  @override
  Future<void> resume() async => _invoke<void>('resume');
  @override
  Future<PreparedRoundMedia> finish() async {
    final generation = _generation;
    final result = await _invoke<Map<Object?, Object?>>('finish');
    _guard(generation);
    if (result?['wasInterrupted'] == true) _wasInterrupted = true;
    return _prepared(result!);
  }

  @override
  Future<PreparedRoundMedia> trim(int startMs, int endMs) async {
    final generation = _generation;
    final result = await _invoke<Map<Object?, Object?>>('trim', {
      'startMs': startMs,
      'endMs': endMs,
    });
    _guard(generation);
    return _prepared(result!);
  }

  void _guard(int generation) {
    if (_disposed || _closing || generation != _generation) {
      throw const RoundCaptureException('canceled');
    }
  }

  Future<RoundCapturePreview> _control(
    String method,
    Map<String, Object> args,
  ) async {
    final generation = _generation;
    final result = await _invoke<Map<Object?, Object?>>(method, args);
    _guard(generation);
    return _preview(result!);
  }

  @override
  Future<RoundCapturePreview> switchCamera({required int cameraRevision}) =>
      _control('switchCamera', {'cameraRevision': cameraRevision});
  @override
  Future<RoundCapturePreview> setZoom(
    double zoom, {
    required int cameraRevision,
  }) => _control('setZoom', {'zoom': zoom, 'cameraRevision': cameraRevision});
  @override
  Future<RoundCapturePreview> setTorch(
    bool enabled, {
    required int cameraRevision,
  }) => _control('setTorch', {
    'enabled': enabled,
    'cameraRevision': cameraRevision,
  });

  @override
  Future<void> cancel() async {
    _generation++;
    _acceptEvents = false;
    final lease = _lease;
    _lease = null;
    try {
      if (!_disposed && !_closing) await _invoke<void>('cancel');
    } finally {
      await lease?.close();
    }
  }

  @override
  Future<void> dispose({bool keepPrepared = false}) {
    final pending = _disposal;
    if (pending != null) return pending;
    final disposal = _dispose(keepPrepared: keepPrepared);
    _disposal = disposal;
    return disposal;
  }

  Future<void> _dispose({required bool keepPrepared}) async {
    if (_disposed) return;
    _closing = true;
    _acceptEvents = false;
    _generation++;
    // Clear before awaiting so a subsequent recorder cannot have its newly
    // registered handler removed by this recorder's late disposal callback.
    if (identical(_channelOwners[_channel.name], this)) {
      _channelOwners.remove(_channel.name);
      _channel.setMethodCallHandler(null);
    }
    try {
      await _invoke<void>('dispose', {'keepPrepared': keepPrepared});
    } finally {
      _disposed = true;
      await _events.close();
      if (!keepPrepared) await _lease?.close();
      _lease = null;
    }
  }
}

/// macOS implements the same private-lease and event protocol as Android.
/// Inheriting the protocol preserves interruption handling in the controller.
class MacOSRoundCaptureBackend extends AndroidRoundCaptureBackend {
  MacOSRoundCaptureBackend(super.mediaAccess, {super.channel})
    : super(platform: TargetPlatform.macOS);
}

RoundCaptureBackend createRoundCaptureBackend(MediaAccess mediaAccess) =>
    defaultTargetPlatform == TargetPlatform.macOS
    ? MacOSRoundCaptureBackend(mediaAccess)
    : AndroidRoundCaptureBackend(mediaAccess);
