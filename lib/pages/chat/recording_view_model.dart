// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'events/audio_player.dart';
import 'recording_waveform.dart';

class RecordingViewModel extends StatefulWidget {
  final Widget Function(BuildContext, RecordingViewModelState) builder;

  const RecordingViewModel({required this.builder, super.key});

  @override
  RecordingViewModelState createState() => RecordingViewModelState();
}

class RecordingViewModelState extends State<RecordingViewModel> {
  static const maxVisibleAmplitudes = 120;
  Timer? _recorderSubscription;
  Duration duration = Duration.zero;
  final Stopwatch _clock = Stopwatch();
  final RecordingWaveform _waveform = RecordingWaveform();
  int _generation = 0, _sampleGeneration = 0;
  bool _starting = false, _transitioning = false, _sending = false;
  bool _wakeHeld = false;
  Future<void> _wakeTail = Future<void>.value();
  Future<void> _cleanup = Future<void>.value();
  _VoiceRecordingSession? _session;

  bool get isRecording => _session != null;
  bool get controlsBusy => _starting || _transitioning || _sending;
  bool get isSending => _sending;
  bool get canResume => !controlsBusy && _session?.stopped != true;

  final List<double> amplitudeTimeline = [];

  String? fileName;

  bool isPaused = false;

  bool _current(int generation, _VoiceRecordingSession session) =>
      mounted && generation == _generation && identical(_session, session);

  Future<void> _setAwake(bool enabled) {
    if (_wakeHeld == enabled) return _wakeTail;
    _wakeHeld = enabled;
    final operation = _wakeTail.then((_) => WakelockPlus.toggle(enable: enabled));
    _wakeTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> startRecording(Room room) async {
    if (!mounted || _starting || _session != null) return;
    _starting = true;
    final generation = ++_generation;
    _VoiceRecordingSession? session;
    try {
      await _cleanup;
      if (!mounted || generation != _generation) return;
      // Server configuration preloading must not turn a failed request into an
      // unhandled asynchronous error while microphone permission is pending.
      unawaited(room.client.getConfig().then<void>((_) {}, onError: (Object _) {}));
      if (PlatformInfos.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        if (!mounted || generation != _generation) return;
        if (info.version.sdkInt < 19) {
          showOkAlertDialog(
            context: context,
            title: L10n.of(context).unsupportedAndroidVersion,
            message: L10n.of(context).unsupportedAndroidVersionLong,
            okLabel: L10n.of(context).close,
          );
          return;
        }
      }
      session = _session = _VoiceRecordingSession(AudioRecorder());
      final audioRecorder = session.recorder;
      setState(() {});
      final permission = await audioRecorder.hasPermission();
      if (!_current(generation, session)) return;
      if (!permission) {
        setState(_reset);
        return;
      }
      final codec =
          !PlatformInfos
                  .isIOS && // Blocked by https://github.com/llfbandit/record/issues/560
              await audioRecorder.isEncoderSupported(AudioEncoder.opus)
          ? AudioEncoder.opus
          : AudioEncoder.aacLc;
      if (!_current(generation, session)) return;
      fileName =
          'voice_message_${DateTime.now().millisecondsSinceEpoch}.${codec.fileExtension}';
      String? path;
      if (!kIsWeb) {
        final tempDir = await getTemporaryDirectory();
        if (!_current(generation, session)) return;
        path = path_lib.join(tempDir.path, fileName);
      }
      await _setAwake(true);
      if (!_current(generation, session)) return;

      await audioRecorder.start(
        RecordConfig(
          bitRate: AppSettings.audioRecordingBitRate.value,
          sampleRate: AppSettings.audioRecordingSamplingRate.value,
          numChannels: AppSettings.audioRecordingNumChannels.value,
          autoGain: AppSettings.audioRecordingAutoGain.value,
          echoCancel: AppSettings.audioRecordingEchoCancel.value,
          noiseSuppress: AppSettings.audioRecordingNoiseSuppress.value,
          encoder: codec,
        ),
        path: path ?? '',
      );
      if (!_current(generation, session)) return;
      _clock.reset();
      _clock.start();
      setState(() => duration = Duration.zero);
      _subscribe();
    } catch (_) {
      if (mounted && generation == _generation) {
        _showError();
        setState(_reset);
      }
    } finally {
      if (session != null && !_current(generation, session)) {
        await session.release();
      }
      if (mounted && generation == _generation) {
        setState(() => _starting = false);
      }
    }
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void _subscribe() {
    _stopSampling();
    final session = _session;
    if (session == null) return;
    final generation = _generation;
    final sampleGeneration = _sampleGeneration;
    var pending = false;
    _recorderSubscription = Timer.periodic(const Duration(milliseconds: 100), (
      _,
    ) async {
      if (pending || !_current(generation, session) || isPaused || _sending) return;
      pending = true;
      try {
        final amplitude = await session.recorder.getAmplitude();
        if (!_current(generation, session) ||
            sampleGeneration != _sampleGeneration) {
          return;
        }
        final raw = 100 + amplitude.current * 2;
        final value = raw.isFinite ? raw.clamp(1.0, 100.0) : 1.0;
        setState(() {
          amplitudeTimeline.add(value);
          if (amplitudeTimeline.length > maxVisibleAmplitudes) {
            amplitudeTimeline.removeAt(0);
          }
          _waveform.add(value);
          duration = _clock.elapsed;
        });
      } catch (_) {
        // Device interruptions or a rejected sample must not escape the timer
        // or leave a recorder/wakelock running without a working UI.
        if (_current(generation, session)) {
          _showError();
          setState(_reset);
        }
      } finally {
        pending = false;
      }
    });
  }

  void _stopSampling() {
    ++_sampleGeneration;
    _recorderSubscription?.cancel();
    _recorderSubscription = null;
  }

  void _reset() {
    ++_generation;
    _stopSampling();
    _clock.stop();
    _clock.reset();
    final session = _session;
    _session = null;
    _cleanup = Future.wait<void>([
      if (session != null) session.release(),
      _setAwake(false).catchError((Object _) {}),
    ]).then<void>((_) {});

    fileName = null;
    duration = Duration.zero;
    amplitudeTimeline.clear();
    _waveform.clear();
    isPaused = false;
    _starting = _transitioning = _sending = false;
  }

  void cancel() {
    setState(_reset);
  }

  Future<void> pause() async {
    final session = _session;
    if (session == null || controlsBusy || isPaused) return;
    final generation = _generation;
    setState(() => _transitioning = true);
    _stopSampling();
    try {
      await session.recorder.pause();
      if (!_current(generation, session)) return;
      _clock.stop();
      isPaused = true;
      duration = _clock.elapsed;
      await _setAwake(false);
    } catch (_) {
      if (_current(generation, session)) {
        _showError();
        setState(_reset);
      }
    } finally {
      if (_current(generation, session)) setState(() => _transitioning = false);
    }
  }

  Future<void> resume() async {
    final session = _session;
    if (session == null || !canResume || !isPaused) return;
    final generation = _generation;
    setState(() => _transitioning = true);
    try {
      await _setAwake(true);
      if (!_current(generation, session)) return;
      await session.recorder.resume();
      if (!_current(generation, session)) return;
      _clock.start();
      isPaused = false;
      _subscribe();
    } catch (_) {
      if (_current(generation, session)) {
        _showError();
        setState(_reset);
      }
    } finally {
      if (_current(generation, session)) setState(() => _transitioning = false);
    }
  }

  Future<void> stopAndSend(
    Future<void> Function(
      String path,
      int duration,
      List<int> waveform,
      String fileName,
    )
    onSend,
  ) async {
    final session = _session;
    final name = fileName;
    if (session == null || name == null || controlsBusy) return;
    final generation = _generation;
    setState(() => _sending = true);
    _stopSampling();
    _clock.stop();
    duration = _clock.elapsed;
    final waveform = _waveform.samples(count: AudioPlayerWidget.wavesCount);
    try {
      final path = await session.stop();
      if (!_current(generation, session)) return;
      isPaused = true;
      await _setAwake(false);
      if (!_current(generation, session)) return;
      if (path == null) throw StateError('Recording failed');
      // Keep the recorded file and source-bound callback until the normal send
      // path accepts it. A failed send remains available for explicit retry.
      await onSend(path, duration.inMilliseconds, waveform, name);
      if (_current(generation, session)) setState(_reset);
    } catch (_) {
      if (_current(generation, session)) {
        isPaused = true;
        unawaited(_setAwake(false).catchError((Object _) {}));
        _showError();
      }
    } finally {
      if (_current(generation, session)) setState(() => _sending = false);
    }
  }

  void _showError() {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
    );
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, this);
}

/// Owns one platform recorder, including permission-only and failed sessions.
/// Stop/dispose is idempotent even when cancellation races a native callback.
class _VoiceRecordingSession {
  final AudioRecorder recorder;
  Future<String?>? _stop;
  Future<void>? _release;
  _VoiceRecordingSession(this.recorder);
  bool get stopped => _stop != null;
  Future<String?> stop() => _stop ??= recorder.stop();
  Future<void> release() => _release ??= _close();
  Future<void> _close() async {
    try {
      await stop();
    } catch (_) {
      // Even a rejected stop must release the native recorder/state stream.
    } finally {
      try {
        await recorder.dispose();
      } catch (_) {}
    }
  }
}

extension on AudioEncoder {
  String get fileExtension {
    switch (this) {
      case AudioEncoder.aacLc:
      case AudioEncoder.aacEld:
      case AudioEncoder.aacHe:
        return 'm4a';
      case AudioEncoder.opus:
        return 'ogg';
      case AudioEncoder.wav:
        return 'wav';
      case AudioEncoder.amrNb:
      case AudioEncoder.amrWb:
      case AudioEncoder.flac:
      case AudioEncoder.pcm16bits:
        throw UnsupportedError('Not yet used');
    }
  }
}
