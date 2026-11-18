// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/round_video/upload_limit_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  final original = UploadLimitProbe.fetch;
  late Client client;
  setUp(
    () => client = Client('upload-limit-probe-test', database: _NoDatabase()),
  );
  tearDown(() => UploadLimitProbe.fetch = original);

  test('one dropped request is retried', () async {
    var calls = 0;
    UploadLimitProbe.fetch = (_) async {
      if (calls++ == 0) throw Exception('dropped');
      return 1000;
    };
    expect(await UploadLimitProbe.measure(client), 1000);
    expect(calls, 2);
  });

  test('a recent measurement covers an unreachable server', () async {
    final now = DateTime(2026, 11, 18, 12);
    UploadLimitProbe.fetch = (_) async => 2000;
    expect(await UploadLimitProbe.measure(client, now: now), 2000);
    UploadLimitProbe.fetch = (_) async => throw Exception('offline');
    expect(
      await UploadLimitProbe.measure(
        client,
        now: now.add(const Duration(hours: 1)),
      ),
      2000,
    );
    // Too old, or forgotten (logout): unknown fails closed again.
    await expectLater(
      UploadLimitProbe.measure(client, now: now.add(const Duration(days: 2))),
      throwsException,
    );
    UploadLimitProbe.forget(client);
    await expectLater(
      UploadLimitProbe.measure(client, now: now),
      throwsException,
    );
  });

  test('a server without a limit stays unknown', () async {
    UploadLimitProbe.fetch = (_) async => 3000;
    await UploadLimitProbe.measure(client);
    UploadLimitProbe.fetch = (_) async => null;
    expect(await UploadLimitProbe.measure(client), isNull);
    UploadLimitProbe.fetch = (_) async => throw Exception('offline');
    await expectLater(UploadLimitProbe.measure(client), throwsException);
  });
}

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation _) =>
      throw StateError('Unexpected database access');
}
