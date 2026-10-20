import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/personal/ui/notion_transcribe_button.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _samples = [128, 256, 400, 750, 500, 1024, 300, 620, 800, 240];

void main() {
  test(
    'untrusted or absent amplitudes use a flat fallback, never fake peaks',
    () {
      for (final value in [
        null,
        [],
        'bad',
        [1, null],
        [-1],
        [double.nan],
        [double.infinity],
        List.filled(1025, 1),
      ]) {
        expect(notionVoiceWaveform(value), isEmpty);
      }
      expect(notionVoiceWaveform([0, 512, 1024, 2048]), [0, .5, 1, 1]);
      expect(
        notionVoiceWaveform(List.generate(80, (i) => i.isOdd ? 1024 : 0)),
        List.filled(40, 1),
      );
      expect(notionAudioTime(const Duration(seconds: 3671)), '61:11');
    },
  );

  testWidgets(
    'drag previews time and commits once on release without replying',
    (tester) async {
      final seeks = <double>[];
      var replies = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: ConversationMessageGestures(
                  identity: 'fictional-voice',
                  interactiveContent: true,
                  onReply: () => replies++,
                  child: NotionAudioFileBlock(
                    duration: '0:18 / 1:06',
                    progress: 18 / 66,
                    seekDuration: const Duration(seconds: 66),
                    waveform: notionVoiceWaveform(_samples),
                    onSeek: seeks.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final slider = find.byKey(const ValueKey('voice-waveform'));
      final rect = tester.getRect(slider);
      final finger = await tester.startGesture(
        Offset(rect.left + rect.width * .3, rect.center.dy),
      );
      await finger.moveTo(Offset(rect.left + rect.width * .7, rect.center.dy));
      await tester.pump();
      expect(seeks, isEmpty);
      expect(find.text('0:18 / 1:06'), findsNothing);
      await finger.up();
      await tester.pump();
      expect(seeks, hasLength(1));
      expect(seeks.single, closeTo(.7, .08));
      expect(replies, 0);
      expect(find.byIcon(Icons.fullscreen), findsNothing);
      expect(find.byIcon(Icons.open_in_full), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('play, skips, speed and save are independent actions', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: NotionAudioFileBlock(
              duration: '0:18 / 1:06',
              progress: .27,
              onPlay: () => calls.add('play'),
              onSeekBack: () => calls.add('back'),
              onSeekForward: () => calls.add('forward'),
              onSpeed: () => calls.add('speed'),
              onDownload: () => calls.add('save'),
            ),
          ),
        ),
      ),
    );
    for (final tooltip in [
      'Play audio',
      'Rewind 10 seconds',
      'Forward 10 seconds',
      'Playback speed',
      'Download audio',
    ]) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
    }
    expect(calls, ['play', 'back', 'forward', 'speed', 'save']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('buffering disables transport and clears an unfinished seek', (
    tester,
  ) async {
    double? sought;
    Widget surface(bool busy) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: NotionAudioFileBlock(
            duration: '0:18 / 1:06',
            progress: .27,
            seekDuration: const Duration(seconds: 66),
            downloading: busy,
            onPlay: () {},
            onSeek: (v) => sought = v,
            onSeekBack: () {},
            onSpeed: () {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(surface(false));
    tester.widget<Slider>(find.byType(Slider)).onChanged!(.7);
    await tester.pump();
    expect(find.text('0:46 / 1:06'), findsOneWidget);
    await tester.pumpWidget(surface(true));
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull);
    expect(slider.onChangeEnd, isNull);
    expect(slider.value, .27);
    expect(find.byTooltip('Play audio'), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.replay_10_rounded),
          )
          .onPressed,
      isNull,
    );
    expect(sought, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek semantics expose time and keyboard remains usable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      double? sought;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: NotionAudioFileBlock(
                duration: '0:18 / 1:06',
                progress: 18 / 66,
                seekDuration: const Duration(seconds: 66),
                onSeek: (v) => sought = v,
              ),
            ),
          ),
        ),
      );
      expect(find.semantics.byLabel('Audio position'), findsOne);
      final data = find.semantics
          .byLabel('Audio position')
          .evaluate()
          .single
          .getSemanticsData();
      expect(data.value, '0:18');
      tester.semantics.performAction(
        find.semantics.byLabel('Audio position'),
        ui.SemanticsAction.increase,
      );
      await tester.pump();
      expect(sought, greaterThan(18 / 66));
      sought = null;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(sought, isNotNull);
    } finally {
      semantics.dispose();
    }
  });

  final output = Platform.environment['VOICE_CAPTURE_DIR'];
  final captures = <Map<String, Object?>>[];
  setUpAll(() async {
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Regular.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final scenario in [
    (
      width: 390.0,
      scale: 1.0,
      brightness: Brightness.dark,
      rtl: false,
      outgoing: false,
      waveform: true,
    ),
    (
      width: 320.0,
      scale: 2.0,
      brightness: Brightness.dark,
      rtl: false,
      outgoing: false,
      waveform: true,
    ),
    (
      width: 390.0,
      scale: 1.0,
      brightness: Brightness.light,
      rtl: false,
      outgoing: true,
      waveform: true,
    ),
    (
      width: 430.0,
      scale: 2.0,
      brightness: Brightness.light,
      rtl: true,
      outgoing: false,
      waveform: true,
    ),
    (
      width: 390.0,
      scale: 1.0,
      brightness: Brightness.dark,
      rtl: false,
      outgoing: true,
      waveform: false,
    ),
  ]) {
    final name =
        '${scenario.width.toInt()}-${scenario.scale}-${scenario.brightness.name}-${scenario.rtl ? 'rtl' : 'ltr'}-${scenario.waveform ? 'wave' : 'flat'}';
    testWidgets('responsive audio $name', (tester) async {
      await tester.binding.setSurfaceSize(Size(scenario.width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(scenario.brightness),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(scenario.width, 900),
              textScaler: TextScaler.linear(scenario.scale),
            ),
            child: Directionality(
              textDirection: scenario.rtl
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: RepaintBoundary(
                key: key,
                child: Scaffold(
                  appBar: AppBar(title: const Text('Anna')),
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        const Text('Dzisiaj · 16:44'),
                        const SizedBox(height: 24),
                        const ConversationBubble(
                          outgoing: false,
                          body: Text('Spotkamy się o piątej?'),
                        ),
                        const ConversationBubble(
                          outgoing: true,
                          body: Text('Jasne, pasuje.'),
                        ),
                        ConversationBubble(
                          outgoing: scenario.outgoing,
                          avatar: scenario.outgoing
                              ? null
                              : const CircleAvatar(child: Text('A')),
                          body: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              NotionAudioFileBlock(
                                duration: '0:18 / 1:06',
                                progress: 18 / 66,
                                playing: true,
                                seekDuration: const Duration(seconds: 66),
                                waveform: scenario.waveform
                                    ? notionVoiceWaveform(_samples)
                                    : const [],
                                onPlay: () {},
                                onSeek: (_) {},
                                onSeekBack: () {},
                                onSeekForward: () {},
                                onSpeed: () {},
                                onDownload: () {},
                              ),
                              NotionTranscribeSplitButton(
                                onTranscribe: () {},
                                onLanguageSelected: (_) {},
                              ),
                            ],
                          ),
                          footer: const Text('16:46'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Text>(find.text('0:18 / 1:06')).textDirection,
        TextDirection.ltr,
      );
      expect(
        tester.widget<Text>(find.text('1×')).textDirection,
        TextDirection.ltr,
      );
      if (output != null) {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.0);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$output/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        captures.add({'file': '$name.png', 'fictional': true});
      }
    });
  }
  tearDownAll(() async {
    if (output != null)
      await File('$output/manifest.json').writeAsString(jsonEncode(captures));
  });
}
