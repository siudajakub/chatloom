// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/media/media_inflight.dart';
import 'package:chatloom/personal/media/voice_remux.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/round_playback_queue.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/personal/voice_playback.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../../utils/matrix_sdk_extensions/event_extension.dart';
import '../../../widgets/chatloom_app.dart';
import '../../../widgets/matrix.dart';

class AudioPlayerWidget extends StatefulWidget {
  final Color color;
  final Color linkColor;
  final double fontSize;
  final Event event;

  /// Loaded events of this chat, read only when the note ends, to continue
  /// with the following voice notes (Telegram). Null: no continuation.
  final Iterable<Event> Function()? continuationHistory;

  static const int wavesCount = 40;

  const AudioPlayerWidget(
    this.event, {
    required this.color,
    required this.linkColor,
    required this.fontSize,
    this.continuationHistory,
    super.key,
  });

  @override
  AudioPlayerState createState() => AudioPlayerState();
}

class AudioPlayerState extends State<AudioPlayerWidget>
    implements RoundContinuationTarget {
  double? _downloadProgress;

  late final MatrixState matrix;
  bool _starting = false;
  ScaffoldMessengerState? _messenger;

  /// Player updates rebuild only the transport, never the transcript or the
  /// caption below it. The subscriptions are made once per player.
  final _transport = ValueNotifier<int>(0);
  AudioPlayer? _bound;
  RawDialogRoute<void>? _stageRoute;
  List<StreamSubscription<Object?>> _subscriptions = const [];
  List<double> _waveform = const [];

  AudioPlayer? get _player =>
      matrix.voiceMessageEventId.value == widget.event.eventId
      ? matrix.audioPlayer
      : null;

  Duration? get _metadataDuration {
    final audio = widget.event.content.tryGetMap<String, Object?>(
      'org.matrix.msc1767.audio',
    );
    final value =
        widget.event.content
            .tryGetMap<String, Object?>('info')
            ?.tryGet<int>('duration') ??
        audio?.tryGet<int>('duration');
    return value != null && value > 0 ? Duration(milliseconds: value) : null;
  }

  List<double> _parseWaveform() => notionVoiceWaveform(
    widget.event.content.tryGetMap<String, Object?>(
      'org.matrix.msc1767.audio',
    )?['waveform'],
  );

  void _tick(Object? _) {
    if (mounted) _transport.value++;
  }

  /// Follows the shared player when it starts, ends or moves to another note.
  void _rebind() {
    final player = _player;
    if (player == null) _releaseStage();
    if (identical(player, _bound)) return;
    _cancelSubscriptions();
    _bound = player;
    if (player != null) {
      void ignore(Object _) {}
      _subscriptions = [
        matrix.audioProgress(player).listen(_tick, onError: ignore),
        player.playerStateStream.listen(_tick, onError: ignore),
        player.durationStream.listen(_tick, onError: ignore),
        player.speedStream.listen(_tick, onError: ignore),
      ];
    }
    _tick(null);
  }

  void _cancelSubscriptions() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    _subscriptions = const [];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  void _clearBannersAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = _messenger;
      if (messenger != null && messenger.mounted) {
        messenger.clearMaterialBanners();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    matrix = Matrix.of(context);
    _waveform = _parseWaveform();
    matrix.voiceMessageEventId.addListener(_rebind);
    // The unplayed dot follows plays here and the private store's load.
    matrix.voicePlayed.addListener(_onPlayedChanged);
    VoicePlayback.targets.register(widget.event, this);
    _rebind();

    if (matrix.voiceMessageEventId.value == widget.event.eventId &&
        matrix.audioPlayer != null) {
      _clearBannersAfterFrame();
    }
  }

  @override
  void didUpdateWidget(AudioPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.event, widget.event)) {
      if (oldWidget.event.eventId != widget.event.eventId ||
          !identical(oldWidget.event.room.client, widget.event.room.client)) {
        _releaseStage();
      }
      VoicePlayback.targets.unregister(oldWidget.event, this);
      VoicePlayback.targets.register(widget.event, this);
      _waveform = _parseWaveform();
      _rebind();
    }
  }

  void _onPlayedChanged() => _tick(null);

  @override
  void dispose() {
    matrix.voicePlayed.removeListener(_onPlayedChanged);
    matrix.voiceMessageEventId.removeListener(_rebind);
    VoicePlayback.targets.unregister(widget.event, this);
    _cancelSubscriptions();
    _releaseStage();
    _transport.dispose();
    final shared = matrix;
    final messenger = _messenger;
    final event = widget.event;
    final owner = shared.voiceMessageEventId.value == event.eventId;
    final audioPlayer = owner ? shared.audioPlayer : null;
    super.dispose();
    if (!owner) return;
    // Closing notifies every voice row: never while the tree is unmounting
    // (the round players defer the same way).
    void closeAfterFrame() => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (shared.voiceMessageEventId.value == event.eventId &&
          identical(shared.audioPlayer, audioPlayer)) {
        unawaited(shared.closeAudioPlayer().catchError((Object _) {}));
      }
    });
    // Still preparing (scrolled away right after the tap), or ended.
    if (audioPlayer == null || audioPlayer.isAtEndPosition) {
      closeAfterFrame();
      return;
    }
    // Paused: keep the single player and its position for when the row
    // comes back (Telegram); the next note, a lock or an account switch
    // releases it.
    if (!audioPlayer.playing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (messenger == null ||
          !messenger.mounted ||
          shared.audioPlayer != audioPlayer ||
          shared.voiceMessageEventId.value != event.eventId) {
        return;
      }
      messenger.showMaterialBanner(
        _detachedVoiceBanner(shared, messenger, audioPlayer, event),
      );
    });
  }

  Future<void> _onButtonTap() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _downloadProgress = null;
    });
    _tick(null);
    try {
      _clearBannersAfterFrame();
      final currentPlayer = _player;
      if (currentPlayer != null) {
        if (currentPlayer.isAtEndPosition) {
          await currentPlayer.seek(Duration.zero);
          if (!mounted || _player != currentPlayer) return;
          await matrix.playAudio();
          return;
        }
        if (currentPlayer.playing) {
          await currentPlayer.pause();
        } else {
          await matrix.playAudio();
        }
        return;
      }
      await _load();
    } catch (_) {
      if (mounted) _showPlaybackError();
    } finally {
      if (mounted) {
        setState(() => _starting = false);
        _tick(null);
      }
    }
  }

  /// Autoplay reached this note: scroll it into view and play it here.
  @override
  Future<RoundStartResult> startContinuation(
    List<Event> rest, {
    required RoundContinuationToken token,
    required double speed,
    required bool enlarge,
  }) async {
    if (!mounted || !token.active || _starting) return RoundStartResult.failed;
    setState(() {
      _starting = true;
      _downloadProgress = null;
    });
    _tick(null);
    _reveal();
    try {
      return await _load(continuation: token, queue: rest);
    } catch (_) {
      return RoundStartResult.failed;
    } finally {
      if (mounted) {
        setState(() => _starting = false);
        _tick(null);
      }
    }
  }

  void _reveal() {
    try {
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: .5,
          duration: NotionMotion.reduced(context)
              ? Duration.zero
              : NotionMotion.medium,
          curve: NotionMotion.standard,
        ).catchError((Object _) {}),
      );
    } catch (_) {
      /* Not in a scrollable: play in place. */
    }
  }

  /// The voice notes after this one, built only when it ends. Starting from
  /// an unplayed incoming note, Telegram plays only the unplayed incoming
  /// ones; from any other note, every later note of the run.
  List<Event> Function()? _continuationFromHere({required bool unplayedOnly}) {
    final history = widget.continuationHistory;
    if (history == null) return null;
    final source = widget.event;
    final played = matrix.voicePlayed;
    return () => VoicePlaybackQueue.after(
      source,
      history(),
      unplayedOnly: unplayedOnly,
      played: played.contains,
    );
  }

  /// Downloads, decrypts and plays this note in the shared player. With a
  /// [continuation] it is autoplay after the previous note ended: [queue]
  /// plays next, a failure is silent (the walk skips the note) and nothing
  /// the user started meanwhile loses its audio.
  Future<RoundStartResult> _load({
    RoundContinuationToken? continuation,
    List<Event>? queue,
  }) async {
    final autoplay = continuation != null;
    final request = ++matrix.audioRequestGeneration;
    await matrix.closeAudioPlayer(invalidateRequests: false);
    if (request != matrix.audioRequestGeneration || !mounted) {
      return RoundStartResult.aborted;
    }
    final playback = matrix.reserveAudio();
    if (!await playback.acquireAudible(continuation: continuation) ||
        !playback.isCurrent ||
        request != matrix.audioRequestGeneration ||
        !mounted) {
      return RoundStartResult.aborted;
    }
    final event = widget.event;
    final unplayedOnly =
        !autoplay &&
        event.senderId != event.room.client.userID &&
        !matrix.voicePlayed.contains(event);
    matrix.voiceMessageEventId.value = event.eventId;
    File? file;
    ManagedMediaFile? pendingLease;
    MatrixFile? matrixFile;

    try {
      final fileSize = event.content
          .tryGetMap<String, Object?>('info')
          ?.tryGet<int>('size');
      // Wait briefly for a matching prefetch; a newer play stops waiting.
      await MediaInflight.settle(
        event.attachmentMxcUrl,
        cancelled: () => request != matrix.audioRequestGeneration || !mounted,
      );
      matrixFile = await event.downloadAndDecryptAttachment(
        onDownloadProgress: fileSize != null && fileSize > 0
            ? (progress) {
                final progressPercentage = progress / fileSize;
                if (!mounted || request != matrix.audioRequestGeneration) {
                  return;
                }
                setState(() {
                  _downloadProgress = progressPercentage < 1
                      ? progressPercentage
                      : null;
                });
                _tick(null);
              }
            : null,
      );

      final attachmentUrl = event.attachmentOrThumbnailMxcUrl();

      if (!kIsWeb && attachmentUrl != null) {
        final access = await matrix.audioMediaAccess;
        // `audio/ogg; codecs=opus` (Android, WhatsApp, our macOS notes) is
        // Ogg as well; the bytes decide when the label does not.
        final ogg = isOggData(matrixFile.bytes);
        final suffix = ogg
            ? '.ogg'
            : switch (matrixFile.mimeType
                  .split(';')
                  .first
                  .trim()
                  .toLowerCase()) {
                'audio/ogg' => '.ogg',
                'audio/mp4' => '.m4a',
                'audio/mpeg' => '.mp3',
                'audio/wav' => '.wav',
                _ => '.bin',
              };
        final lease = await access.create(matrixFile.bytes, extension: suffix);
        pendingLease = lease;
        file = lease.file;

        if (Platform.isMacOS && ogg) {
          Logs().v('Remux Ogg voice audio for the native Apple player');
          final convertedFile = pendingLease.derivedFile('.caf');
          if (await convertedFile.exists() == false) {
            await convertedFile.writeAsBytes(
              await oggVoiceToCaf(matrixFile.bytes),
              flush: true,
            );
          }
          file = convertedFile;
        }
      }
    } catch (e, s) {
      await pendingLease?.close();
      if (request == matrix.audioRequestGeneration) {
        await matrix.closeAudioPlayer();
      }
      Logs().v('Could not download audio file', e, s);
      if (!mounted) return RoundStartResult.aborted;
      setState(() {
        _downloadProgress = null;
      });
      _tick(null);
      if (!autoplay) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
      return RoundStartResult.failed;
    }
    if (!mounted ||
        !playback.isCurrent ||
        request != matrix.audioRequestGeneration ||
        matrix.voiceMessageEventId.value != event.eventId) {
      await pendingLease?.close();
      return RoundStartResult.aborted;
    }
    matrix.audioLease = pendingLease;

    final audioPlayer = matrix.audioPlayer = AudioPlayer();
    matrix.watchAudio(
      audioPlayer,
      continuation: queue != null
          ? () => queue
          : _continuationFromHere(unplayedOnly: unplayedOnly),
    );
    _rebind();

    try {
      if (file != null) {
        await audioPlayer.setFilePath(file.path);
      } else {
        await audioPlayer.setAudioSource(
          AudioSource.uri(
            Uri.dataFromBytes(matrixFile.bytes, mimeType: matrixFile.mimeType),
          ),
        );
      }
      // The remembered speed (Telegram keeps 1.5×/2× for every note).
      final speed = matrix.voiceSpeed;
      if (speed != 1) await audioPlayer.setSpeed(speed);
      if (!mounted ||
          !playback.isCurrent ||
          request != matrix.audioRequestGeneration ||
          matrix.audioPlayer != audioPlayer) {
        if (matrix.audioPlayer == audioPlayer) {
          await matrix.closeAudioPlayer();
        } else {
          await pendingLease?.close();
        }
        return RoundStartResult.aborted;
      }
      matrix.voicePlayed.add(event);
      await matrix.playAudio();
      return RoundStartResult.started;
    } catch (_) {
      if (matrix.audioPlayer == audioPlayer) {
        await matrix.closeAudioPlayer();
      } else {
        await pendingLease?.close();
      }
      if (mounted && !autoplay) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not play this audio. Try again.'),
          ),
        );
      }
      return RoundStartResult.failed;
    }
  }

  Future<void> _seek(AudioPlayer player, Duration position) async {
    if (_player != player || _starting) return;
    final duration = player.duration;
    if (duration == null || duration <= Duration.zero) return;
    try {
      await player.seek(
        Duration(
          milliseconds: position.inMilliseconds.clamp(
            0,
            duration.inMilliseconds,
          ),
        ),
      );
    } catch (_) {
      if (mounted && _player == player) _showPlaybackError();
    }
  }

  void _showPlaybackError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not change playback. Try again.')),
    );
  }

  /// Cycles the speed; the choice applies to every later note too.
  Future<void> _toggleSpeed(AudioPlayer player) async {
    if (_player != player || _starting) return;
    try {
      await matrix.setVoiceSpeed(player, VoicePlayback.nextSpeed(player.speed));
    } catch (_) {
      if (mounted && _player == player) _showPlaybackError();
    }
  }

  /// Enlarges the existing transport, keeping the shared engine and position.
  Future<void> _openStage() async {
    if (_stageRoute != null || !mounted) return;
    if (_player == null) {
      await _onButtonTap();
      if (!mounted || _player == null || _stageRoute != null) return;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    late final RawDialogRoute<void> route;
    route = RawDialogRoute<void>(
      barrierColor: NotionMediaColors.stageScrim,
      barrierDismissible: true,
      barrierLabel: 'Close audio player',
      transitionDuration: NotionMotion.reduced(context)
          ? Duration.zero
          : NotionMotion.short,
      pageBuilder: (context, _, _) => RepaintBoundary(
        key: const ValueKey('voice-expanded-stage'),
        child: SafeArea(
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.all(NotionSpace.md),
              child: Column(
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: IconButton(
                      tooltip: 'Close audio player',
                      color: NotionMediaColors.onScrim,
                      onPressed: navigator.pop,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: NotionSize.dialogMaxWidth,
                        ),
                        child: ValueListenableBuilder<int>(
                          valueListenable: _transport,
                          builder: (context, _, _) => !mounted
                              ? const SizedBox.shrink()
                              : _buildTransport(context, expanded: true),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: NotionSize.touchTarget),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    _stageRoute = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_stageRoute, route)) _stageRoute = null;
      }),
    );
  }

  void _releaseStage() {
    final route = _stageRoute;
    _stageRoute = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  Widget _buildTransport(BuildContext context, {bool expanded = false}) {
    final audioPlayer = _player;
    final actualDuration = audioPlayer?.duration;
    final total = actualDuration != null && actualDuration > Duration.zero
        ? actualDuration
        : _metadataDuration;
    final duration = total?.inMilliseconds.toDouble() ?? 0;
    final position = audioPlayer?.position.inMilliseconds.toDouble() ?? 0;
    final fraction = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final canSeek =
        audioPlayer != null &&
        actualDuration != null &&
        actualDuration > Duration.zero &&
        !_starting;
    final loading =
        _starting ||
        audioPlayer?.processingState == ProcessingState.loading ||
        audioPlayer?.processingState == ProcessingState.buffering;
    return NotionAudioFileBlock(
      duration: total == null
          ? '–:–'
          : '${notionAudioTime(audioPlayer?.position ?? Duration.zero)} / ${notionAudioTime(total)}',
      seekDuration: total,
      waveform: _waveform,
      foregroundColor: expanded ? NotionMediaColors.onScrim : widget.color,
      progress: fraction,
      playing:
          audioPlayer?.playing == true && audioPlayer?.isAtEndPosition == false,
      downloading: loading,
      downloadProgress: _downloadProgress,
      // Speed stays beside the time; secondary actions live in the menu.
      controls: audioPlayer != null,
      unplayed:
          !expanded &&
          audioPlayer == null &&
          matrix.voicePlayed.unplayed(widget.event),
      onPlay: _onButtonTap,
      onSeek: !canSeek
          ? null
          : (value) => _seek(
              audioPlayer,
              Duration(milliseconds: (duration * value).round()),
            ),
      onExpand: expanded ? null : _openStage,
      onDownload: () => widget.event.saveFile(context),
      speed: audioPlayer?.speed ?? matrix.voiceSpeed,
      onSpeed: audioPlayer == null || _starting
          ? null
          : () => _toggleSpeed(audioPlayer),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileDescription = widget.event.fileDescription;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RepaintBoundary(
          child: ValueListenableBuilder<int>(
            valueListenable: _transport,
            builder: (context, _, _) => _buildTransport(context),
          ),
        ),
        MarkListenedButton(event: widget.event, color: widget.color),
        TranscriptPanel(event: widget.event, foregroundColor: widget.color),
        if (fileDescription != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Linkify(
              text: fileDescription,
              textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
              style: TextStyle(color: widget.color, fontSize: widget.fontSize),
              options: const LinkifyOptions(humanize: false),
              linkStyle: TextStyle(
                color: widget.linkColor,
                fontSize: widget.fontSize,
                decoration: TextDecoration.underline,
                decorationColor: widget.linkColor,
              ),
              onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
            ),
          ),
      ],
    );
  }
}

/// Marks an incoming Telegram voice note listened on Telegram, on tap only.
/// Playing the note or reading its transcript never sends this; the button
/// disappears once Telegram accepted it (remembered across restarts), or
/// once the bridge reports the note listened elsewhere.
@visibleForTesting
class MarkListenedButton extends StatefulWidget {
  final Event event;

  /// The bubble's foreground: the button sits inside the bubble, whose
  /// colours (private chat palettes, own/incoming) the theme does not know.
  final Color color;

  const MarkListenedButton({
    required this.event,
    required this.color,
    super.key,
  });

  @override
  State<MarkListenedButton> createState() => _MarkListenedButtonState();
}

class _MarkListenedButtonState extends State<MarkListenedButton> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      TelegramRoundService.of(
        widget.event.room.client,
      ).loadVoiceState(widget.event),
    );
  }

  Future<void> _mark(TelegramRoundService service) async {
    setState(() => _busy = true);
    try {
      await service.markVoiceListened(widget.event);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not mark as listened on Telegram.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = TelegramRoundService.of(widget.event.room.client);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final visible = service.canMarkVoiceListened(widget.event);
        return NotionSizeReveal(
          visible: visible,
          child: Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xxs),
            child: NotionButton.ghost(
              label: 'Mark listened',
              icon: Icons.hearing_outlined,
              busy: _busy,
              foreground: widget.color,
              onPressed: _busy || !visible ? null : () => _mark(service),
            ),
          ),
        );
      },
    );
  }
}

/// A playing note whose row left the screen. It removes itself once the
/// player ends or another note takes over.
MaterialBanner _detachedVoiceBanner(
  MatrixState matrix,
  ScaffoldMessengerState messenger,
  AudioPlayer audioPlayer,
  Event event,
) {
  void clear() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (messenger.mounted) messenger.clearMaterialBanners();
  });
  bool current() =>
      identical(matrix.audioPlayer, audioPlayer) &&
      matrix.voiceMessageEventId.value == event.eventId;
  return MaterialBanner(
    padding: EdgeInsets.zero,
    leading: StreamBuilder(
      stream: audioPlayer.playerStateStream,
      builder: (context, _) => IconButton(
        onPressed: () {
          if (!current()) return;
          if (audioPlayer.isAtEndPosition) {
            audioPlayer.seek(Duration.zero);
          } else if (audioPlayer.playing) {
            audioPlayer.pause();
          } else {
            matrix.playAudio();
          }
        },
        icon: NotionMorphSwitcher(
          child: audioPlayer.playing && !audioPlayer.isAtEndPosition
              ? const Icon(Icons.pause_outlined, key: ValueKey('pause'))
              : const Icon(Icons.play_arrow_outlined, key: ValueKey('play')),
        ),
      ),
    ),
    content: ValueListenableBuilder(
      valueListenable: matrix.voiceMessageEventId,
      builder: (context, _, _) {
        if (!current()) {
          clear();
          return const SizedBox.shrink();
        }
        return StreamBuilder(
          stream: matrix.audioProgress(audioPlayer),
          builder: (context, _) => GestureDetector(
            onTap: () => ChatLoomApp.router.go(
              conversationLocation(event.room, eventId: event.eventId),
            ),
            child: Text(
              '🎙️ ${audioPlayer.position.minuteSecondString} / ${audioPlayer.duration?.minuteSecondString} - ${event.senderFromMemoryOrFallback.calcDisplayname()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    ),
    actions: [
      IconButton(
        onPressed: () {
          if (current()) matrix.closeAudioPlayer();
          clear();
        },
        icon: const Icon(Icons.close_outlined),
      ),
    ],
  );
}

extension on AudioPlayer {
  bool get isAtEndPosition {
    final duration = this.duration;
    if (duration == null) return true;
    return position >= duration;
  }
}

extension on Duration {
  String get minuteSecondString =>
      '${inMinutes.toString().padLeft(2, '0')}:${(inSeconds % 60).toString().padLeft(2, '0')}';
}
