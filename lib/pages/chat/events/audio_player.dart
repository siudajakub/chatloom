// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/personal/media/media_access.dart';
import 'package:fluffychat/personal/transcript_panel.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:ogg_caf_converter/ogg_caf_converter.dart';

import '../../../utils/matrix_sdk_extensions/event_extension.dart';
import '../../../widgets/fluffy_chat_app.dart';
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

enum AudioPlayerStatus { notDownloaded, downloading, downloaded }

class AudioPlayerState extends State<AudioPlayerWidget> {
  static const double buttonSize = 36;

  AudioPlayerStatus status = AudioPlayerStatus.notDownloaded;
  double? _downloadProgress;

  late final MatrixState matrix;
  String? _durationString;

  @override
  void dispose() {
    super.dispose();
    final audioPlayer = matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (audioPlayer != null) {
      if (audioPlayer.playing && !audioPlayer.isAtEndPosition) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.of(matrix.context).showMaterialBanner(
            MaterialBanner(
              padding: EdgeInsets.zero,
              leading: StreamBuilder(
                stream: audioPlayer.playerStateStream.asBroadcastStream(),
                builder: (context, _) => IconButton(
                  onPressed: () {
                    if (audioPlayer.isAtEndPosition) {
                      audioPlayer.seek(Duration.zero);
                    } else if (audioPlayer.playing) {
                      audioPlayer.pause();
                    } else {
                      matrix.playAudio();
                    }
                  },
                  icon: audioPlayer.playing && !audioPlayer.isAtEndPosition
                      ? const Icon(Icons.pause_outlined)
                      : const Icon(Icons.play_arrow_outlined),
                ),
              ),
              content: StreamBuilder(
                stream: audioPlayer.positionStream.asBroadcastStream(),
                builder: (context, _) => GestureDetector(
                  onTap: () => FluffyChatApp.router.go(
                    '/rooms/${widget.event.room.id}?event=${widget.event.eventId}',
                  ),
                  child: Text(
                    '🎙️ ${audioPlayer.position.minuteSecondString} / ${audioPlayer.duration?.minuteSecondString} - ${widget.event.senderFromMemoryOrFallback.calcDisplayname()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              actions: [
                IconButton(
                  onPressed: () {
                    matrix.closeAudioPlayer();

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      ScaffoldMessenger.of(
                        matrix.context,
                      ).clearMaterialBanners();
                    });
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(matrix.context).clearMaterialBanners();
    });
    final currentPlayer =
        matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (currentPlayer != null && !currentPlayer.isAtEndPosition) {
      if (currentPlayer.playing) {
        currentPlayer.pause();
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

    setState(() => status = AudioPlayerStatus.downloading);
    try {
      final fileSize = widget.event.content
          .tryGetMap<String, Object?>('info')
          ?.tryGet<int>('size');
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
        final lease = await access.create(matrixFile.bytes, extension: suffix);
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

      if (mounted && request == matrix.audioRequestGeneration)
        setState(() {
          status = AudioPlayerStatus.downloaded;
        });
    } catch (e, s) {
      await pendingLease?.close();
      if (request == matrix.audioRequestGeneration)
        await matrix.closeAudioPlayer();
      Logs().v('Could not download audio file', e, s);
      if (!mounted) rethrow;
      setState(() {
        status = AudioPlayerStatus.notDownloaded;
        _downloadProgress = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      rethrow;
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
            Uri.dataFromBytes(matrixFile.bytes, mimeType: matrixFile.mimeType),
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
  }

  Future<void> _toggleSpeed() async {
    final audioPlayer = matrix.audioPlayer;
    if (audioPlayer == null) return;
    switch (audioPlayer.speed) {
      case 1.0:
        await audioPlayer.setSpeed(1.25);
        break;
      case 1.25:
        await audioPlayer.setSpeed(1.5);
        break;
      case 1.5:
        await audioPlayer.setSpeed(2.0);
        break;
      case 2.0:
        await audioPlayer.setSpeed(0.5);
        break;
      case 0.5:
      default:
        await audioPlayer.setSpeed(1.0);
        break;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    matrix = Matrix.of(context);

    if (matrix.voiceMessageEventId.value == widget.event.eventId &&
        matrix.audioPlayer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(matrix.context).clearMaterialBanners();
      });
    }

    final durationInt = widget.event.content
        .tryGetMap<String, Object?>('info')
        ?.tryGet<int>('duration');
    if (durationInt != null) {
      final duration = Duration(milliseconds: durationInt);
      _durationString = duration.minuteSecondString;
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
      return StreamBuilder<Object>(
        stream: audioPlayer == null
            ? null
            : StreamGroup.merge([
                audioPlayer.positionStream.asBroadcastStream(),
                audioPlayer.playerStateStream.asBroadcastStream(),
              ]),
        builder: (context, _) {
          final duration =
              audioPlayer?.duration?.inMilliseconds.toDouble() ?? 1.0;
          final position =
              audioPlayer?.position.inMilliseconds.toDouble() ?? 0.0;
          final fraction = duration > 0
              ? (position / duration).clamp(0.0, 1.0)
              : 0.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NotionAudioFileBlock(
                duration:
                    audioPlayer?.position.minuteSecondString ??
                    _durationString ??
                    '–:–',
                progress: fraction,
                playing:
                    audioPlayer?.playing == true &&
                    audioPlayer?.isAtEndPosition == false,
                downloading: status == AudioPlayerStatus.downloading,
                downloadProgress: _downloadProgress,
                onPlay: _onButtonTap,
                onSeek: audioPlayer == null
                    ? null
                    : (value) => audioPlayer.seek(
                        Duration(milliseconds: (duration * value).round()),
                      ),
                onDownload: () => widget.event.saveFile(context),
                speedAction: audioPlayer == null
                    ? null
                    : TextButton(
                        onPressed: _toggleSpeed,
                        child: Text(
                          'Playback speed: ${audioPlayer.speed}×',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
              ),
              TranscriptPanel(event: widget.event),
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
