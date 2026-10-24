// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// The shape of Flutter's `compute` (the SDK's `ComputeCallback`, which the
/// SDK does not export).
typedef PersonalCompute =
    Future<R> Function<Q, R>(
      FutureOr<R> Function(Q message) callback,
      Q message, {
      String? debugLabel,
    });

/// `ComputeCallback` for the SDK's `NativeImplementationsIsolate` (BP-04).
///
/// Attachment decryption ([EncryptedFile]: thumbnails, avatars, voice, round
/// and media prefetch reads) runs on one long-lived worker isolate per
/// process instead of a fresh `compute` isolate per file, so the
/// flutter_rust_bridge bindings load once instead of once per file. Every
/// other job (image shrinking, metadata, key derivation) still gets its own
/// `compute` isolate, so a long resize never queues a thumbnail behind it.
///
/// A top-level function on purpose: the SDK sends its whole
/// `NativeImplementationsIsolate` (including this callback) to the isolate
/// with each job, and only a static tear-off is sendable.
Future<R> personalCryptoCompute<Q, R>(
  FutureOr<R> Function(Q message) callback,
  Q message, {
  String? debugLabel,
}) => message is EncryptedFile
    ? PersonalCryptoWorker.shared.run(callback, message)
    : compute(callback, message, debugLabel: debugLabel);

/// One lazily started worker isolate that runs the same closures `compute`
/// would. It shuts down after [idle] without work, so a push wake does not
/// keep it alive. If the isolate cannot be started, a job cannot be sent to
/// it or the isolate dies, the job runs through [fallback] (`compute`), so
/// nothing ever fails only because of the worker.
class PersonalCryptoWorker {
  PersonalCryptoWorker({
    this.idle = const Duration(seconds: 30),
    @visibleForTesting
    Future<Isolate> Function(void Function(SendPort), SendPort)? spawn,
    @visibleForTesting PersonalCompute? fallback,
  }) : _spawn = spawn ?? Isolate.spawn<SendPort>,
       _fallback = fallback ?? compute;

  static final shared = PersonalCryptoWorker();

  final Duration idle;
  final Future<Isolate> Function(void Function(SendPort), SendPort) _spawn;
  final PersonalCompute _fallback;

  Future<_Worker?>? _starting;
  _Worker? _worker;
  Timer? _idleTimer;
  int _nextId = 0;

  /// A failed start is not retried in this process: every job then takes
  /// the fallback directly instead of paying for another spawn attempt.
  bool _unavailable = false;

  /// Isolates started so far (tests and diagnostics).
  @visibleForTesting
  int debugSpawns = 0;

  /// Whether the worker isolate is currently running.
  bool get running => _worker != null;

  Future<R> run<Q, R>(FutureOr<R> Function(Q message) callback, Q message) =>
      _run(callback, message);

  Future<R> _run<Q, R>(
    FutureOr<R> Function(Q message) callback,
    Q message,
  ) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_unavailable) return _fallback(callback, message);
    final worker = _worker ?? await (_starting ??= _start());
    if (worker == null || worker.closed) {
      return _fallback(callback, message);
    }
    final id = _nextId++;
    final job = _Job(() => _fallback(callback, message));
    worker.pending[id] = job;
    try {
      worker.send.send(_Request(id, callback, message));
    } catch (_) {
      // Not sendable to this isolate group member (should not happen for
      // SDK closures, which `compute` sends the same way): run it there.
      worker.pending.remove(id);
      _scheduleIdle();
      return _fallback(callback, message);
    }
    try {
      return await job.completer.future as R;
    } finally {
      _scheduleIdle();
    }
  }

  Future<_Worker?> _start() async {
    final port = RawReceivePort();
    final ready = Completer<SendPort?>();
    _Worker? worker;
    Isolate? isolate;
    port.handler = (Object? message) {
      if (!ready.isCompleted) {
        ready.complete(message is SendPort ? message : null);
        return;
      }
      if (message is _Response) {
        worker?.complete(message);
      } else if (message == null) {
        // The exit listener: the isolate is gone (an uncaught error is fatal).
        final dead = worker;
        if (dead != null) _retire(dead);
      }
    };
    try {
      isolate = await _spawn(_workerMain, port.sendPort);
      debugSpawns++;
      isolate.addOnExitListener(port.sendPort);
      final send = await ready.future.timeout(const Duration(seconds: 10));
      if (send == null) throw StateError('crypto worker did not start');
      worker = _Worker(isolate, send, port);
      _worker = worker;
      return worker;
    } catch (_) {
      _unavailable = true;
      isolate?.kill(priority: Isolate.immediate);
      port.close();
      return null;
    } finally {
      _starting = null;
    }
  }

  /// The isolate died with jobs in flight: each runs again through the
  /// fallback (decryption is idempotent).
  void _retire(_Worker worker) {
    if (worker.closed) return;
    worker.closed = true;
    if (identical(_worker, worker)) _worker = null;
    worker.port.close();
    final pending = Map<int, _Job>.of(worker.pending);
    worker.pending.clear();
    for (final job in pending.values) {
      job.completer.complete(Future.sync(job.retry));
    }
  }

  void _scheduleIdle() {
    final worker = _worker;
    if (worker == null || worker.pending.isNotEmpty) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, () {
      _idleTimer = null;
      final current = _worker;
      if (current == null || current.pending.isNotEmpty) return;
      shutdown();
    });
  }

  /// Stops the worker; the next job starts a new one.
  void shutdown() {
    _idleTimer?.cancel();
    _idleTimer = null;
    final worker = _worker;
    if (worker == null) return;
    _worker = null;
    worker.isolate.kill(priority: Isolate.beforeNextEvent);
    _retire(worker);
  }
}

class _Worker {
  _Worker(this.isolate, this.send, this.port);
  final Isolate isolate;
  final SendPort send;
  final RawReceivePort port;
  final pending = <int, _Job>{};
  bool closed = false;

  void complete(_Response response) {
    final job = pending.remove(response.id);
    if (job == null) return;
    if (response.failed) {
      job.completer.completeError(
        response.value ?? StateError('crypto worker job failed'),
        response.stack,
      );
    } else {
      job.completer.complete(response.value);
    }
  }
}

class _Job {
  _Job(this.retry);
  final Future<Object?> Function() retry;
  final completer = Completer<Object?>();
}

class _Request {
  const _Request(this.id, this.callback, this.message);
  final int id;
  final Function callback;
  final Object? message;
}

class _Response {
  const _Response(this.id, this.value, {this.failed = false, this.stack});
  final int id;
  final Object? value;
  final bool failed;
  final StackTrace? stack;
}

void _workerMain(SendPort reply) {
  final port = RawReceivePort();
  port.handler = (Object? message) {
    if (message is! _Request) return;
    unawaited(_handle(message, reply));
  };
  reply.send(port.sendPort);
}

Future<void> _handle(_Request request, SendPort reply) async {
  try {
    final value = await Function.apply(request.callback, [request.message]);
    try {
      reply.send(_Response(request.id, value));
    } catch (error) {
      reply.send(
        _Response(request.id, RemoteError(error.toString(), ''), failed: true),
      );
    }
  } catch (error, stack) {
    try {
      // The original error, as `Isolate.run` delivers it, when sendable.
      reply.send(_Response(request.id, error, failed: true, stack: stack));
    } catch (_) {
      reply.send(
        _Response(
          request.id,
          RemoteError(error.toString(), stack.toString()),
          failed: true,
        ),
      );
    }
  }
}
