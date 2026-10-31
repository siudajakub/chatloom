// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/media/media_quality.dart';
import 'package:chatloom/personal/media/stale_recordings.dart';
import 'package:chatloom/personal/media/voice_format.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'events/audio_player.dart';
import 'recording_output_cleanup.dart';
import 'recording_waveform.dart';

/// User-facing voice capture preferences (Settings → Chats & organization →
/// Voice & video messages). Kept separate from [AppSettings] so the mapping
/// to the platform recorder stays a pure, testable function.
///
/// The defaults are Telegram's: the plain microphone with no platform
/// effects. Android's noise suppressor and gain control are tuned for calls
/// and pump or thin out a close voice (docs/voice-recording.md).
@immutable
class VoiceCaptureOptions {
  final bool noiseSuppress;
  final bool autoGain;
  final bool echoCancel;

  /// Platform voice-communication path: forces echo cancellation, noise
  /// suppression and gain control and lets the device apply its call-grade
  /// processing. Cleaner in noisy places, but may sound narrower.
  final bool isolation;

  /// Higher bitrate (Opus 96 kbps / AAC 128 kbps) for larger files.
  final bool highQuality;

  /// Record from a connected Bluetooth headset (Android SCO). Off: the
  /// phone's own microphone even while a headset plays audio, because SCO
  /// capture is 8–16 kHz call audio.
  final bool bluetoothMic;

  const VoiceCaptureOptions({
    this.noiseSuppress = false,
    this.autoGain = false,
    this.echoCancel = false,
    this.isolation = false,
    this.highQuality = false,
    this.bluetoothMic = false,
  });

  factory VoiceCaptureOptions.fromSettings() => VoiceCaptureOptions(
    noiseSuppress: AppSettings.audioRecordingNoiseSuppress.value,
    autoGain: AppSettings.audioRecordingAutoGain.value,
    echoCancel: AppSettings.audioRecordingEchoCancel.value,
    isolation: AppSettings.personalVoiceIsolation.value,
    highQuality: AppSettings.personalVoiceHighQuality.value,
    bluetoothMic: AppSettings.personalVoiceBluetoothMic.value,
  );
}

/// Maps [options] to a mono speech recording config for [encoder].
///
/// Opus records at its native 48 kHz (Ogg container, Android 10+); the AAC-LC
/// fallback uses 44.1 kHz, which every Android/iOS AAC encoder accepts. The
/// default Android source is `DEFAULT` (the plain microphone, as Telegram's
/// voice notes and rounds); voice isolation switches to
/// `VOICE_COMMUNICATION` with echo cancellation, noise suppression and gain
/// control on. Effects are attached by the plugin only when the device
/// reports them; macOS records to a file and ignores them.
RecordConfig buildVoiceRecordConfig(
  AudioEncoder encoder,
  VoiceCaptureOptions options,
) {
  final opus = encoder == AudioEncoder.opus;
  return RecordConfig(
    encoder: encoder,
    sampleRate: opus ? 48000 : 44100,
    bitRate: opus
        ? (options.highQuality
              ? MediaQuality.voiceOpusHighQualityBitrate
              : MediaQuality.voiceOpusBitrate)
        : (options.highQuality
              ? MediaQuality.voiceAacHighQualityBitrate
              : MediaQuality.voiceAacBitrate),
    numChannels: 1,
    autoGain: options.autoGain || options.isolation,
    echoCancel: options.echoCancel || options.isolation,
    noiseSuppress: options.noiseSuppress || options.isolation,
    audioInterruption: AudioInterruptionMode.pause,
    androidConfig: AndroidRecordConfig(
      audioSource: options.isolation
          ? AndroidAudioSource.voiceCommunication
          : AndroidAudioSource.defaultSource,
      manageBluetooth: options.bluetoothMic,
    ),
  );
}

class RecordingViewModel extends StatefulWidget {
  final Widget Function(BuildContext, RecordingViewModelState) builder;
  final RecordingOutputCleanup? cleanupOutput;

  const RecordingViewModel({
    required this.builder,
    this.cleanupOutput,
    super.key,
  });

  @override
  RecordingViewModelState createState() => RecordingViewModelState();
}

class RecordingViewModelState extends State<RecordingViewModel> {
  static const maxVisibleAmplitudes = 120;

  /// Safety cap: a forgotten recording pauses itself and can still be sent.
  static const maxDuration = Duration(minutes: 15);

  /// Deleting a recording longer than this asks for confirmation first.
  static const confirmDiscardAfter = Duration(seconds: 5);
  Timer? _recorderSubscription;
  Duration duration = Duration.zero;
  final Stopwatch _clock = Stopwatch();
  final RecordingWaveform _waveform = RecordingWaveform();
  int _generation = 0, _sampleGeneration = 0;
  bool _starting = false, _transitioning = false, _sending = false;
  bool _wakeHeld = false;
  bool _limitReached = false;
  Future<void> _wakeTail = Future<void>.value();
  Future<void> _cleanup = Future<void>.value();
  _VoiceRecordingSession? _session;

  bool get isRecording => _session != null;
  bool get controlsBusy => _starting || _transitioning || _sending;
  bool get isSending => _sending;
  bool get isStarting => _starting;
  bool get canResume =>
      !controlsBusy && !_limitReached && _session?.stopped != true;

  /// True once [maxDuration] paused the recording; it can only be sent or
  /// deleted afterwards.
  bool get limitReached => _limitReached;

  /// Exact recorded time (the [duration] field only advances per sample).
  Duration get elapsed => _clock.elapsed;

  final List<double> amplitudeTimeline = [];

  /// Ticks once per amplitude sample (10 Hz while recording). Only the
  /// timer and the live waveform listen; the composer around them is not
  /// rebuilt per sample.
  Listenable get samples => _samples;
  final _samples = ValueNotifier<int>(0);

  String? fileName;

  bool isPaused = false;

  /// The finished file while the user listens before sending (UX: Telegram's
  /// recorded panel, Signal's voice note draft). Set by [finishForReview].
  String? _reviewPath;

  /// Whether the recording was finished for listening: it can be played,
  /// sent or deleted, but no longer resumed (the platform recorder only
  /// writes a playable file once it stops).
  bool get isReviewing => _reviewPath != null;

  /// The whole recording's envelope, 0..1 per bar, for the review player.
  List<double> get reviewWaveform => [
    for (final peak in _waveform.samples(count: 40)) peak / 1024,
  ];

  bool _current(int generation, _VoiceRecordingSession session) =>
      mounted && generation == _generation && identical(_session, session);

  Future<void> _setAwake(bool enabled) {
    if (_wakeHeld == enabled) return _wakeTail;
    _wakeHeld = enabled;
    final operation = _wakeTail.then(
      (_) => WakelockPlus.toggle(enable: enabled),
    );
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
      unawaited(
        room.client.getConfig().then<void>((_) {}, onError: (Object _) {}),
      );
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
      session = _session = _VoiceRecordingSession(
        AudioRecorder(),
        cleanupOutput: widget.cleanupOutput ?? cleanupRecordingOutput,
      );
      final audioRecorder = session.recorder;
      setState(() {});
      final permission = await audioRecorder.hasPermission();
      if (!_current(generation, session)) return;
      if (!permission) {
        setState(_reset);
        return;
      }
      final codec =
          // Apple's record backend writes Opus in CAF, not in the Ogg
          // container advertised by our voice-message sender. Use AAC/M4A.
          !PlatformInfos.isCupertinoStyle &&
              preferOpusVoice(RoomCapabilities.declared(room)) &&
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
        // Named after this process: a crash's leftover is swept at start.
        path = path_lib.join(
          tempDir.path,
          voiceRecordingName(const Uuid().v4(), codec.fileExtension),
        );
        session.ownedNativePath = path;
      }
      await _setAwake(true);
      if (!_current(generation, session)) return;

      await session.start(
        buildVoiceRecordConfig(codec, VoiceCaptureOptions.fromSettings()),
        path: path ?? '',
      );
      if (!_current(generation, session)) return;
      _clock.reset();
      _clock.start();
      setState(() => duration = Duration.zero);
      _subscribe();
      _listenToRecorderState(generation, session);
      NotionHaptics.recordStart();
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
    _samples.dispose();
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
      if (pending || !_current(generation, session) || isPaused || _sending) {
        return;
      }
      pending = true;
      try {
        final amplitude = await session.recorder.getAmplitude();
        if (!_current(generation, session) ||
            sampleGeneration != _sampleGeneration) {
          return;
        }
        final raw = 100 + amplitude.current * 2;
        final value = raw.isFinite ? raw.clamp(1.0, 100.0) : 1.0;
        amplitudeTimeline.add(value);
        if (amplitudeTimeline.length > maxVisibleAmplitudes) {
          amplitudeTimeline.removeAt(0);
        }
        _waveform.add(value);
        duration = _clock.elapsed;
        _samples.value++;
        if (_clock.elapsed >= maxDuration && !_limitReached) {
          _limitReached = true;
          unawaited(pause());
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text(
                'Voice messages are limited to 15 minutes. '
                'Send or delete this recording.',
              ),
            ),
          );
        }
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

  /// Mirrors system-driven recorder state into the UI. With
  /// [AudioInterruptionMode.pause] the platform pauses on calls, alarms or
  /// another app taking audio focus; the clock must stop with it.
  void _listenToRecorderState(int generation, _VoiceRecordingSession session) {
    session.stateSubscription = session.recorder.onStateChanged().listen(
      (state) => _onRecorderState(generation, session, state),
      onError: (Object _) {},
    );
  }

  Future<void> _onRecorderState(
    int generation,
    _VoiceRecordingSession session,
    RecordState state,
  ) async {
    if (state == RecordState.stop) return; // Stops are always ours.
    final paused = state == RecordState.pause;
    // Our own pause/resume/stop transitions update the state themselves.
    bool stale() =>
        !_current(generation, session) ||
        controlsBusy ||
        session.stopped ||
        isPaused == paused ||
        (!paused && _limitReached);
    if (stale()) return;
    // A late event from an earlier pause/resume must not override what the
    // recorder reports now; without that query the event is trusted.
    try {
      if (await session.recorder.isPaused() != paused) return;
    } catch (_) {}
    if (stale()) return;
    if (paused) {
      _stopSampling();
      _clock.stop();
      setState(() {
        isPaused = true;
        duration = _clock.elapsed;
      });
      unawaited(_setAwake(false).catchError((Object _) {}));
    } else {
      _clock.start();
      setState(() => isPaused = false);
      unawaited(_setAwake(true).catchError((Object _) {}));
      _subscribe();
    }
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
    _reviewPath = null;
    duration = Duration.zero;
    amplitudeTimeline.clear();
    _waveform.clear();
    isPaused = false;
    _limitReached = false;
    _starting = _transitioning = _sending = false;
  }

  /// Discards the recording immediately (slide-to-cancel, too short holds).
  void cancel() {
    if (_session != null) NotionHaptics.light();
    setState(_reset);
  }

  /// Delete button: short recordings are discarded at once; longer ones are
  /// paused and need confirmation. Returns whether the recording was deleted.
  Future<bool> requestDiscard() async {
    final session = _session;
    if (session == null || _sending) return false;
    if (_clock.elapsed <= confirmDiscardAfter) {
      cancel();
      return true;
    }
    final generation = _generation;
    if (!isPaused) await pause();
    if (!mounted || !_current(generation, session) || _sending) return false;
    final result = await showOkCancelAlertDialog(
      context: context,
      title: 'Delete voice message?',
      message: 'This recording will be discarded.',
      okLabel: 'Delete',
      cancelLabel: 'Keep',
      isDestructive: true,
    );
    if (result != OkCancelResult.ok || !_current(generation, session)) {
      return false;
    }
    cancel();
    return true;
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

  /// Stops a paused recording so its file can be played before sending.
  /// Returns the playable path, or null when the recording is gone.
  Future<String?> finishForReview() async {
    final session = _session;
    if (session == null) return null;
    if (_reviewPath != null) return _reviewPath;
    if (controlsBusy || !isPaused) return null;
    final generation = _generation;
    setState(() => _transitioning = true);
    _stopSampling();
    _clock.stop();
    duration = _clock.elapsed;
    try {
      final path = await session.stop();
      if (!_current(generation, session)) return null;
      if (path == null) throw StateError('Recording failed');
      _reviewPath = path;
      return path;
    } catch (_) {
      if (_current(generation, session)) {
        _showError();
        setState(_reset);
      }
      return null;
    } finally {
      if (_current(generation, session)) setState(() => _transitioning = false);
    }
  }

  Future<void> stopAndSend(
    Future<bool> Function(
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
      NotionHaptics.send();
      // Keep the recorded file and source-bound callback until the normal send
      // path accepts it. A failed send remains available for explicit retry.
      final accepted = await onSend(
        path,
        duration.inMilliseconds,
        waveform,
        name,
      );
      if (accepted && _current(generation, session)) setState(_reset);
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
  final RecordingOutputCleanup cleanupOutput;
  String? ownedNativePath;
  String? _stoppedBlobUrl;
  StreamSubscription<RecordState>? stateSubscription;
  Future<void>? _starting;
  Future<String?>? _stop;
  Future<void>? _release;
  _VoiceRecordingSession(this.recorder, {required this.cleanupOutput});
  bool get stopped => _stop != null;
  Future<void> start(RecordConfig config, {required String path}) =>
      _starting = recorder.start(config, path: path);
  Future<String?> stop() => _stop ??= _stopAndRemember();
  Future<String?> _stopAndRemember() async {
    final output = await recorder.stop();
    if (output != null && Uri.tryParse(output)?.scheme == 'blob') {
      _stoppedBlobUrl = output;
    }
    return output;
  }

  Future<void> release() => _release ??= _close();
  Future<void> _close() async {
    try {
      try {
        await stateSubscription?.cancel();
      } catch (_) {}
      stateSubscription = null;
      // Active SDK cancel deletes its own unfinished file/blob. Standard
      // Android cancel cannot remove an already stopped output, so retain our
      // assigned path and any earlier web Blob URL for explicit cleanup below.
      try {
        await recorder.cancel();
      } catch (_) {}
      var startFailed = false;
      final starting = _starting;
      if (starting != null) {
        try {
          await starting;
        } catch (_) {
          startFailed = true;
        }
      }
      // Android's failed native start can leave a non-recording thread whose
      // stop callback never fires. Cancel/dispose plus our owned path handles
      // that partial output without waiting forever for an impossible stop.
      if (!startFailed || _stop != null) {
        try {
          await stop();
        } catch (_) {}
      }
    } finally {
      try {
        await recorder.dispose();
      } catch (_) {}
      if (ownedNativePath != null || _stoppedBlobUrl != null) {
        try {
          await cleanupOutput(
            ownedNativePath: ownedNativePath,
            stoppedBlobUrl: _stoppedBlobUrl,
          );
        } catch (_) {
          // A cleanup/storage failure never falls back to deleting other paths.
        }
      }
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
