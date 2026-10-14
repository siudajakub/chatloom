// Synthetic web-only smoke: no login, provider calls or real account data.
import 'dart:async';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/personal_hub.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Isolate this synthetic test from browser preferences and real accounts.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  await AppSettings.init(loadWebConfigFile: false);
  final key = GlobalKey();
  final result = ValueNotifier<String>(
    'RUNNING synthetic Material scope smoke',
  );
  final client = Client('synthetic-hub-scope', database: _UnusedDatabase());
  runApp(
    MaterialApp(
      home: PersonalHub(key: key, client: client),
      builder: (context, child) => Stack(
        children: [
          child!,
          Positioned(
            top: 0,
            right: 0,
            child: ValueListenableBuilder<String>(
              valueListenable: result,
              builder: (context, value, _) => ColoredBox(
                color: Colors.white,
                child: Text(value, textDirection: TextDirection.ltr),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(() async {
      try {
        final dynamic state = key.currentState;
        await state.run(() async {
          throw StateError('synthetic failure');
        });
        result.value = 'PASS synthetic Material scope smoke';
      } catch (_) {
        result.value = 'FAIL synthetic Material scope smoke';
      }
    }());
  });
}
