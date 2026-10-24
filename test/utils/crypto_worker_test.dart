// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:chatloom/utils/crypto_worker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Per isolate: counts the jobs one isolate ran.
int _jobsHere = 0;
int _initsHere = 0;
Future<void>? _ready;

Future<void> _initOnce() => _ready ??= Future(() => _initsHere++);

Future<(int, int)> _countJob(int _) async {
  await _initOnce();
  return (++_jobsHere, _initsHere);
}

Uint8List _reverse(Uint8List bytes) =>
    Uint8List.fromList(bytes.reversed.toList());

int _fails(int _) => throw StateError('synthetic worker failure');

Future<R> _noFallback<Q, R>(
  FutureOr<R> Function(Q message) callback,
  Q message, {
  String? debugLabel,
}) => throw StateError('fallback must not run');

/// BP-04: one long-lived isolate for attachment decryption.
void main() {
  test('20 jobs share one worker isolate and one initialisation', () async {
    final worker = PersonalCryptoWorker(fallback: _noFallback);
    addTearDown(worker.shutdown);
    final results = await Future.wait([
      for (var i = 0; i < 20; i++) worker.run(_countJob, i),
    ]);
    expect(worker.debugSpawns, 1);
    expect(results.map((r) => r.$1).toSet(), {for (var i = 1; i <= 20; i++) i});
    expect(results.map((r) => r.$2).toSet(), {1}, reason: 'init ran once');
    // Bytes in, bytes out, as with compute.
    expect(
      await worker.run(_reverse, Uint8List.fromList([1, 2, 3])),
      Uint8List.fromList([3, 2, 1]),
    );
    expect(worker.debugSpawns, 1);
  });

  test('errors reach the caller unchanged; the worker keeps running', () async {
    final worker = PersonalCryptoWorker(fallback: _noFallback);
    addTearDown(worker.shutdown);
    await expectLater(worker.run(_fails, 0), throwsA(isA<StateError>()));
    expect((await worker.run(_countJob, 0)).$1, 1);
    expect(worker.debugSpawns, 1);
  });

  test('the worker stops when idle and starts again on demand', () async {
    final worker = PersonalCryptoWorker(
      idle: const Duration(milliseconds: 50),
      fallback: _noFallback,
    );
    addTearDown(worker.shutdown);
    await worker.run(_countJob, 0);
    expect(worker.running, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(worker.running, isFalse);
    final (jobs, inits) = await worker.run(_countJob, 0);
    expect(worker.debugSpawns, 2);
    expect((jobs, inits), (1, 1), reason: 'a fresh isolate');
  });

  test('a worker that cannot start falls back to compute', () async {
    var fallbacks = 0;
    Future<R> fallback<Q, R>(
      FutureOr<R> Function(Q message) callback,
      Q message, {
      String? debugLabel,
    }) async {
      fallbacks++;
      return callback(message);
    }

    final worker = PersonalCryptoWorker(
      spawn: (_, _) => Future<Isolate>.error(UnsupportedError('no isolates')),
      fallback: fallback,
    );
    expect(await worker.run(_reverse, Uint8List.fromList([1, 2])), [2, 1]);
    expect(fallbacks, 1);
    expect(worker.running, isFalse);
  });
}
