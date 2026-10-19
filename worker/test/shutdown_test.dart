import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'SIGTERM interrupts hanging session, local metadata and relay HTTP; '
    'process exits after closing storage',
    () async {
      final directory = await Directory('/tmp').createTemp('worker-stop-');
      final socket = '${directory.path}/source.sock';
      final tcp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final unix = await HttpServer.bind(
        InternetAddress(socket, type: InternetAddressType.unix),
        0,
      );
      final connected = Completer<void>();
      var requests = 0;
      void hang(HttpRequest request) {
        unawaited(request.drain<void>());
        if (++requests == 3) connected.complete();
        // Deliberately never write response headers or close the response.
      }

      tcp.listen(hang);
      unix.listen(hang);
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/worker_shutdown_probe.dart',
        'http://127.0.0.1:${tcp.port}',
        socket,
      ]);
      final output = utf8.decoder.bind(process.stdout).join();
      final error = utf8.decoder.bind(process.stderr).join();
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await tcp.close(force: true);
        await unix.close(force: true);
        await directory.delete(recursive: true);
      });
      await connected.future.timeout(const Duration(seconds: 30));
      final elapsed = Stopwatch()..start();
      expect(process.kill(ProcessSignal.sigterm), isTrue);
      expect(
        await process.exitCode.timeout(const Duration(seconds: 5)),
        0,
        reason: await error,
      );
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await output, contains('shutdown-clean'));
    },
    skip: Platform.isWindows ? 'Production service uses POSIX signals.' : false,
  );
}
