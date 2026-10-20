// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/personal/media/media_access.dart';
import 'package:chatloom/personal/media/media_inflight.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:ogg_caf_converter/ogg_caf_converter.dart';

import '../../../utils/matrix_sdk_extensions/event_extension.dart';
import '../../../widgets/chatloom_app.dart';
import '../../../widgets/matrix.dart';

class AudioPlayerWidget extends StatefulWidget {
  final Color color;
  final Color linkColor;
  final double fontSize;
  final Event event;

  static const int wavesCount = 40;

  const AudioPlayerWidget(
    this.event, {
    required this.color,
    required this.linkColor,
    required this.fontSize,
    super.key,
  });

  @override
  AudioPlayerState createState() => AudioPlayerState();
}

class AudioPlayerState extends State<AudioPlayerWidget> {
  double? _downloadProgress;

  late final MatrixState matrix;
  bool _starting = false;
  ScaffoldMessengerState? _messenger;

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
  void dispose() {
    super.dispose();
    final messenger = _messenger;
    final event = widget.event;
    final audioPlayer = matrix.voiceMessageEventId.value != event.eventId
        ? null
        : matrix.audioPlayer;
    if (audioPlayer == null &&
        matrix.voiceMessageEventId.value == event.eventId) {
      unawaited(matrix.closeAudioPlayer());
    }
    if (audioPlayer != null) {
      if (audioPlayer.playing && !audioPlayer.isAtEndPosition) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (messenger == null ||
              !messenger.mounted ||
              matrix.audioPlayer != audioPlayer ||
              matrix.voiceMessageEventId.value != event.eventId)
            return;
          messenger.showMaterialBanner(
            MaterialBanner(
              padding: EdgeInsets.zero,
              leading: StreamBuilder(
                stream: audioPlayer.playerStateStream.asBroadcastStream(),
                builder: (context, _) => IconButton(
                  onPressed: () {
                    if (matrix.audioPlayer != audioPlayer) return;
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
                        ? const Icon(
                            Icons.pause_outlined,
                            key: ValueKey('pause'),
                          )
                        : const Icon(
                            Icons.play_arrow_outlined,
                            key: ValueKey('play'),
                          ),
                  ),
                ),
              ),
              content: StreamBuilder(
                stream: audioPlayer.positionStream.asBroadcastStream(),
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
              ),
              actions: [
                IconButton(
                  onPressed: () {
                    if (matrix.audioPlayer != audioPlayer) return;
                    matrix.closeAudioPlayer();
                    _clearBannersAfterFrame();
                  },
                  icon: const Icon(Icons.close_outlined),
                ),
              ],
            ),
          );
        });
        return;
      }
      matrix.closeAudioPlayer();
    }
  }

  Future<void> _onButtonTap() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _downloadProgress = null;
    });
    try {
      _clearBannersAfterFrame();
      final currentPlayer =
          matrix.voiceMessageEventId.value != widget.event.eventId
          ? null
          : matrix.audioPlayer;
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

      final request = ++matrix.audioRequestGeneration;
      await matrix.closeAudioPlayer(invalidateRequests: false);
      if (request != matrix.audioRequestGeneration || !mounted) return;
      final playback = matrix.reserveAudio();
      if (!await playback.acquireAudible() ||
          !playback.isCurrent ||
          request != matrix.audioRequestGeneration ||
          !mounted)
        return;
      matrix.voiceMessageEventId.value = widget.event.eventId;
      File? file;
      ManagedMediaFile? pendingLease;
      MatrixFile? matrixFile;

      try {
        final fileSize = widget.event.content
            .tryGetMap<String, Object?>('info')
            ?.tryGet<int>('size');
        // Wait briefly for a matching prefetch; a newer play stops waiting.
        await MediaInflight.settle(
          widget.event.attachmentMxcUrl,
          cancelled: () => request != matrix.audioRequestGeneration || !mounted,
        );
        matrixFile = await widget.event.downloadAndDecryptAttachment(
          onDownloadProgress: fileSize != null && fileSize > 0
              ? (progress) {
                  final progressPercentage = progress / fileSize;
                  if (!mounted || request != matrix.audioRequestGeneration)
                    return;
                  setState(() {
                    _downloadProgress = progressPercentage < 1
                        ? progressPercentage
                        : null;
                  });
                }
              : null,
        );

        final attachmentUrl = widget.event.attachmentOrThumbnailMxcUrl();

        if (!kIsWeb && attachmentUrl != null) {
          final access = await matrix.audioMediaAccess;
          final suffix = switch (matrixFile.mimeType.toLowerCase()) {
            'audio/ogg' => '.ogg',
            'audio/mp4' => '.m4a',
            'audio/mpeg' => '.mp3',
            'audio/wav' => '.wav',
            _ => '.bin',
          };
          final lease = await access.create(
            matrixFile.bytes,
            extension: suffix,
          );
          pendingLease = lease;
          file = lease.file;

          if (Platform.isIOS &&
              matrixFile.mimeType.toLowerCase() == 'audio/ogg') {
            Logs().v('Convert ogg audio file for iOS...');
            final convertedFile = pendingLease.derivedFile('.caf');
            if (await convertedFile.exists() == false) {
              await OggCafConverter().convertOggToCaf(
                input: file.path,
                output: convertedFile.path,
              );
            }
            file = convertedFile;
          }
        }
      } catch (e, s) {
        await pendingLease?.close();
        if (request == matrix.audioRequestGeneration)
          await matrix.closeAudioPlayer();
        Logs().v('Could not download audio file', e, s);
        if (!mounted) return;
        setState(() {
          _downloadProgress = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
        return;
      }
      if (!context.mounted ||
          !playback.isCurrent ||
          request != matrix.audioRequestGeneration ||
          matrix.voiceMessageEventId.value != widget.event.eventId) {
        await pendingLease?.close();
        return;
      }
      matrix.audioLease = pendingLease;

      final audioPlayer = matrix.audioPlayer = AudioPlayer();
      setState(() {});
      audioPlayer.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .then((_) {
            if (matrix.audioPlayer == audioPlayer) matrix.closeAudioPlayer();
          })
          .catchError((Object _) {});

      try {
        if (file != null) {
          await audioPlayer.setFilePath(file.path);
        } else {
          await audioPlayer.setAudioSource(
            AudioSource.uri(
              Uri.dataFromBytes(
                matrixFile.bytes,
                mimeType: matrixFile.mimeType,
              ),
            ),
          );
        }
        if (!mounted ||
            !playback.isCurrent ||
            request != matrix.audioRequestGeneration ||
            matrix.audioPlayer != audioPlayer) {
          await pendingLease?.close();
          return;
        }
        await matrix.playAudio();
      } catch (_) {
        if (matrix.audioPlayer == audioPlayer) {
          await matrix.closeAudioPlayer();
        } else {
          await pendingLease?.close();
        }
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not play this audio. Try again.'),
            ),
          );
      }
    } catch (_) {
      if (mounted) _showPlaybackError();
    } finally {
      if (mounted) setState(() => _starting = false);
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

  Future<void> _toggleSpeed(AudioPlayer player) async {
    if (_player != player || _starting) return;
    const speeds = [1.0, 1.25, 1.5, 2.0, 0.5];
    final next = speeds[(speeds.indexOf(player.speed) + 1) % speeds.length];
    try {
      await player.setSpeed(next);
    } catch (_) {
      if (mounted && _player == player) _showPlaybackError();
    }
  }

  @override
  void initState() {
    super.initState();
    matrix = Matrix.of(context);

    if (matrix.voiceMessageEventId.value == widget.event.eventId &&
        matrix.audioPlayer != null) {
      _clearBannersAfterFrame();
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: matrix.voiceMessageEventId,
    builder: (context, eventId, _) {
      final audioPlayer = eventId == widget.event.eventId
          ? matrix.audioPlayer
          : null;
      final fileDescription = widget.event.fileDescription;
      return StreamBuilder<Object?>(
        stream: audioPlayer == null
            ? null
            : StreamGroup.merge<Object?>([
                audioPlayer.positionStream.asBroadcastStream(),
                audioPlayer.playerStateStream.asBroadcastStream(),
                audioPlayer.durationStream.asBroadcastStream(),
                audioPlayer.speedStream.asBroadcastStream(),
              ]),
        builder: (context, _) {
          final actualDuration = audioPlayer?.duration;
          final total = actualDuration != null && actualDuration > Duration.zero
              ? actualDuration
              : _metadataDuration;
          final duration = total?.inMilliseconds.toDouble() ?? 0;
          final position = audioPlayer?.position.inMilliseconds.toDouble() ?? 0;
          final fraction = duration > 0
              ? (position / duration).clamp(0.0, 1.0)
              : 0.0;
          final canSeek =
              audioPlayer != null &&
              actualDuration != null &&
              actualDuration > Duration.zero &&
              !_starting;
          final loading =
              _starting ||
              audioPlayer?.processingState == ProcessingState.loading ||
              audioPlayer?.processingState == ProcessingState.buffering;
          final waveform = notionVoiceWaveform(
            widget.event.content.tryGetMap<String, Object?>(
              'org.matrix.msc1767.audio',
            )?['waveform'],
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NotionAudioFileBlock(
                duration: total == null
                    ? '–:–'
                    : '${notionAudioTime(audioPlayer?.position ?? Duration.zero)} / ${notionAudioTime(total)}',
                seekDuration: total,
                waveform: waveform,
                foregroundColor: widget.color,
                progress: fraction,
                playing:
                    audioPlayer?.playing == true &&
                    audioPlayer?.isAtEndPosition == false,
                downloading: loading,
                downloadProgress: _downloadProgress,
                onPlay: _onButtonTap,
                onSeek: !canSeek
                    ? null
                    : (value) => _seek(
                        audioPlayer,
                        Duration(milliseconds: (duration * value).round()),
                      ),
                onSeekBack: !canSeek
                    ? null
                    : () => _seek(
                        audioPlayer,
                        audioPlayer.position - const Duration(seconds: 10),
                      ),
                onSeekForward: !canSeek
                    ? null
                    : () => _seek(
                        audioPlayer,
                        audioPlayer.position + const Duration(seconds: 10),
                      ),
                onDownload: () => widget.event.saveFile(context),
                speed: audioPlayer?.speed ?? 1,
                onSpeed: audioPlayer == null || _starting
                    ? null
                    : () => _toggleSpeed(audioPlayer),
              ),
              TranscriptPanel(
                event: widget.event,
                foregroundColor: widget.color,
              ),
              if (fileDescription != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Linkify(
                    text: fileDescription,
                    textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
                    style: TextStyle(
                      color: widget.color,
                      fontSize: widget.fontSize,
                    ),
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
        },
      );
    },
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
