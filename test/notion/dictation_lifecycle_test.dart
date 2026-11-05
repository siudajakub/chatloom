// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline capture/route fixtures. No real microphone, network or paid API.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/dictation_dialog.dart';
import 'package:chatloom/personal/dictation/dictation_service.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart'
    show wakelockPlusPlatformInstance;
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'dictation_dialog_test.dart'
    show dictationConversationFixture, loadDictationCaptureFonts;

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No account access');
}

class _Client extends Client {
  _Client() : super('offline dictation', database: _NoDatabase());
  @override
  String get userID => '@owner:example.invalid';
  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async => MediaConfig();
}

class _Paths extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => '/offline-dictation-fixture';
}

class _Wake extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

class _Record extends RecordPlatform {
  int starts = 0, stops = 0, cancels = 0, disposals = 0, resumes = 0;
  bool paused = false;
  Completer<void>? startGate;
  Completer<void>? resumeGate;
  final states = StreamController<RecordState>.broadcast();
  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;
  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;
  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    starts++;
    await startGate?.future;
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) => states.stream;
  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -20, max: 0);
  @override
  Future<void> pause(String recorderId) async => paused = true;
  @override
  Future<void> resume(String recorderId) async {
    await resumeGate?.future;
    resumes++;
    paused = false;
  }

  @override
  Future<bool> isPaused(String recorderId) async => paused;
  @override
  Future<String?> stop(String recorderId) async {
    stops++;
    return '/offline-dictation-fixture/voice.ogg';
  }

  @override
  Future<void> cancel(String recorderId) async => cancels++;
  @override
  Future<void> dispose(String recorderId) async => disposals++;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected recorder call');
}

const _capture = Key('dictation-route-capture');
const _sample =
    'Hej, będę za jakieś piętnaście minut. '
    'Możesz zamówić mi kawę? Poproszę cappuccino z mlekiem owsianym.\n\n'
    'Daj znać, czy udało się znaleźć stolik przy oknie. Do zobaczenia!';

Future<void> capture(WidgetTester tester, String name) async {
  final output = Platform.environment['NOTION_CAPTURE_DIR'];
  if (output == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$output/phone-$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void foreground() {
  final binding = TestWidgetsFlutterBinding.instance;
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState == AppLifecycleState.inactive) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

void main() {
  late _Record recorder;
  late RecordPlatform originalRecord;
  late PathProviderPlatform originalPaths;
  late WakelockPlusPlatformInterface originalWake;
  late WakelockPlusPlatformInterface originalWakeFacade;
  late BuildContext routeContext;
  var transcriptions = 0;
  var cancels = 0;
  final sent = <String>[];
  late Future<String> Function() transcription;
  late Future<bool> Function(String) send;
  var contextValid = true;

  setUpAll(() async {
    await loadDictationCaptureFonts();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() {
    originalRecord = RecordPlatform.instance;
    originalPaths = PathProviderPlatform.instance;
    originalWake = WakelockPlusPlatformInterface.instance;
    originalWakeFacade = wakelockPlusPlatformInstance;
    RecordPlatform.instance = recorder = _Record();
    PathProviderPlatform.instance = _Paths();
    WakelockPlusPlatformInterface.instance = _Wake();
    wakelockPlusPlatformInstance = WakelockPlusPlatformInterface.instance;
    transcriptions = cancels = 0;
    sent.clear();
    contextValid = true;
    PersonalPrivacy.surfaceUnlocked = true;
    transcription = () async => _sample;
    send = (text) async {
      sent.add(text);
      return true;
    };
  });
  tearDown(() async {
    PersonalPrivacy.surfaceUnlocked = true;
    foreground();
    await recorder.states.close();
    RecordPlatform.instance = originalRecord;
    PathProviderPlatform.instance = originalPaths;
    WakelockPlusPlatformInterface.instance = originalWake;
    wakelockPlusPlatformInstance = originalWakeFacade;
  });

  Future<void> drain(WidgetTester tester, bool Function() ready) async {
    for (var turn = 0; turn < 40 && !ready(); turn++) {
      await tester.runAsync(() => Future<void>(() {}));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue);
  }

  void background(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    double keyboard = 0,
    bool waitForRecording = true,
    bool captureComposer = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: _capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          supportedLocales: L10n.supportedLocales,
          localizationsDelegates: L10n.localizationsDelegates,
          theme: NotionTheme.build(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: const Size(390, 844),
              padding: const EdgeInsets.only(top: 32, bottom: 24),
              viewInsets: EdgeInsets.only(bottom: keyboard),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: NotionGlassScope(
            mode: NotionGlassMode.on,
            child: Builder(
              builder: (context) {
                routeContext = context;
                return dictationConversationFixture();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (captureComposer) await capture(tester, 'composer');
    unawaited(
      showDictationDialog(
        routeContext,
        room: Room(id: '!dictation:example.invalid', client: _Client()),
        transcribe: (path, duration, fileName) async {
          transcriptions++;
          expect(path, '/offline-dictation-fixture/voice.ogg');
          return transcription();
        },
        canSend: () => contextValid,
        onSend: (text) => send(text),
        onCancel: () async {
          cancels++;
        },
      ),
    );
    await drain(
      tester,
      () =>
          recorder.starts == 1 &&
          (!waitForRecording ||
              find.text('Recording · up to 5 min').evaluate().isNotEmpty),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('dictation-primary')));
    await drain(
      tester,
      () => find.byKey(const Key('dictation-editor')).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester, () => recorder.disposals == 1);
    await tester.pump();
  }

  testWidgets(
    'record to transcript to edit requires explicit send exactly once',
    (tester) async {
      await mount(tester);
      await capture(tester, 'recording');
      expect(transcriptions, 0);
      expect(sent, isEmpty);
      await finish(tester);
      expect(transcriptions, 1);
      expect(sent, isEmpty);
      expect(recorder.stops, 1);
      await capture(tester, 'review');
      final field = find.descendant(
        of: find.byKey(const Key('dictation-editor')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '  Poprawiona wiadomość.  ');
      await tester.tap(find.byKey(const Key('dictation-primary')));
      await drain(
        tester,
        () => find.byType(DictationDialog).evaluate().isEmpty,
      );
      expect(sent, ['Poprawiona wiadomość.']);
      expect(cancels, 0);
      await drain(tester, () => recorder.disposals == 1);
    },
  );

  testWidgets(
    'failed transcription retries the same stopped audio without sending',
    (tester) async {
      transcription = () async {
        if (transcriptions == 1) {
          throw const DictationException('transcription_failed');
        }
        return _sample;
      };
      await mount(tester);
      await tester.tap(find.byKey(const Key('dictation-primary')));
      await drain(tester, () => find.text('Try again').evaluate().isNotEmpty);
      expect(recorder.starts, 1);
      expect(recorder.stops, 1);
      expect(recorder.disposals, 0);
      await finish(tester);
      expect(transcriptions, 2);
      expect(recorder.starts, 1);
      expect(recorder.stops, 1);
      expect(sent, isEmpty);
      await unmount(tester);
    },
  );

  testWidgets(
    'failed send preserves the edited transcript for explicit retry',
    (tester) async {
      send = (text) async {
        sent.add(text);
        return false;
      };
      await mount(tester);
      await finish(tester);
      final field = find.descendant(
        of: find.byKey(const Key('dictation-editor')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Edytowany tekst');
      await tester.tap(find.byKey(const Key('dictation-primary')));
      await drain(
        tester,
        () => find
            .textContaining('The message could not be sent.')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Edytowany tekst',
      );
      expect(sent, ['Edytowany tekst']);
      expect(transcriptions, 1);
      await unmount(tester);
    },
  );

  testWidgets(
    'system back confirms discard then cancels worker and stops microphone',
    (tester) async {
      await mount(tester);
      await tester.binding.handlePopRoute();
      await drain(tester, () => find.text('Discard').evaluate().isNotEmpty);
      expect(recorder.paused, isTrue);
      expect(cancels, 0);
      await tester.tap(find.text('Discard'));
      await drain(tester, () => recorder.disposals == 1);
      expect(cancels, 1);
      expect(recorder.cancels, greaterThanOrEqualTo(1));
      expect(sent, isEmpty);
      expect(transcriptions, 0);
    },
  );

  testWidgets('changed conversation retains returned transcript for copying', (
    tester,
  ) async {
    final gate = Completer<String>();
    transcription = () => gate.future;
    await mount(tester, captureComposer: true);
    await tester.tap(find.byKey(const Key('dictation-primary')));
    await drain(tester, () => transcriptions == 1);
    contextValid = false;
    gate.complete(_sample);
    await drain(
      tester,
      () => find.byKey(const Key('dictation-editor')).evaluate().isNotEmpty,
    );
    await tester.pump();
    expect(
      find.textContaining('Your text stays here to copy.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('dictation-primary')));
    await tester.pump();
    expect(sent, isEmpty);
    await unmount(tester);
  });

  testWidgets('actual dialog route stays keyboard safe at phone size', (
    tester,
  ) async {
    await mount(tester, keyboard: 320);
    await finish(tester);
    expect(tester.takeException(), isNull);
    final button = tester.getRect(find.byKey(const Key('dictation-primary')));
    expect(button.bottom, lessThanOrEqualTo(844 - 320));
    await capture(tester, 'keyboard');
    await unmount(tester);
  });

  testWidgets(
    'locked review closes rather than retaining plaintext on rejected send',
    (tester) async {
      await mount(tester);
      await finish(tester);
      contextValid = false;
      PersonalPrivacy.surfaceUnlocked = false;
      await tester.tap(find.byKey(const Key('dictation-primary')));
      await drain(
        tester,
        () => find.byType(DictationDialog).evaluate().isEmpty,
      );
      expect(sent, isEmpty);
      expect(cancels, 1);
      await drain(tester, () => recorder.disposals == 1);
    },
  );

  testWidgets(
    'background while native start is pending invalidates late capture',
    (tester) async {
      recorder.startGate = Completer<void>();
      await mount(tester, waitForRecording: false);
      background(tester);
      await tester.pump();
      recorder.startGate!.complete();
      await drain(tester, () => recorder.disposals == 1);
      expect(find.text('Recording · up to 5 min'), findsNothing);
      expect(recorder.cancels, greaterThanOrEqualTo(1));
      expect(transcriptions, 0);
      expect(sent, isEmpty);
      foreground();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'background while native resume is pending pauses after completion',
    (tester) async {
      await mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await drain(tester, () => recorder.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      recorder.resumeGate = Completer<void>();
      await tester.tap(find.text('Resume recording'));
      await tester.pump();
      background(tester);
      recorder.resumeGate!.complete();
      await drain(tester, () => recorder.resumes == 1 && recorder.paused);
      await tester.pump();
      expect(recorder.paused, isTrue);
      expect(transcriptions, 0);
      foreground();
      await unmount(tester);
    },
  );
}
