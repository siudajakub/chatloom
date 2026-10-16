import 'dart:convert';
import 'dart:io';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/local_sources.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:test/test.dart';

class NoMatrix implements FeatureTransport {
  @override
  String get accountId => '@fixture:example.invalid';
  @override
  String get deviceId => 'fixture';
  @override
  bool get verified => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected Matrix operation');
}

void main() {
  const source = SourceEventRef(
    conversation: ConversationRef(
      accountId: '@fixture:example.invalid',
      roomId: '!source:beeper.local',
    ),
    eventId: r'$source',
  );
  for (final scenario in [
    'ordinary',
    'protected',
    'wrongBinding',
    'deletedAfterDownload',
  ]) {
    test(
      'local source $scenario is bound and rechecked before provider handoff',
      () async {
        final directory = await Directory(
          '/tmp',
        ).createTemp('personal-source-');
        final socket = '${directory.path}/source.sock';
        final server = await HttpServer.bind(
          InternetAddress(socket, type: InternetAddressType.unix),
          0,
        );
        var audioRequests = 0;
        var metadataRequests = 0;
        server.listen((r) async {
          expect(
            r.contentLength,
            greaterThan(0),
            reason: 'The bounded source server requires Content-Length.',
          );
          final request = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
          if (request['mode'] == 'metadata') {
            metadataRequests++;
            final bytes = utf8.encode(
              jsonEncode({
                'sourceKey': scenario == 'wrongBinding' ? 'wrong' : source.key,
                'redacted':
                    scenario == 'deletedAfterDownload' && metadataRequests > 1,
                'transcriptionAllowed': scenario != 'protected',
                'mimeType': 'audio/ogg',
              }),
            );
            r.response.contentLength = bytes.length;
            r.response.add(bytes);
          } else {
            audioRequests++;
            r.response.contentLength = 3;
            r.response.add([1, 2, 3]);
          }
          await r.response.close();
        });
        addTearDown(() async {
          await server.close(force: true);
          await directory.delete(recursive: true);
        });
        final transport = LocalSourceTransport(NoMatrix(), socket);
        if (scenario == 'ordinary') {
          final result = await transport.loadAudio(source, Cancellation());
          expect(result.bytes, [1, 2, 3]);
          expect(metadataRequests, 2);
          expect(audioRequests, 1);
        } else {
          await expectLater(
            transport.loadAudio(source, Cancellation()),
            throwsA(isA<WorkerFailure>()),
          );
          expect(audioRequests, scenario == 'deletedAfterDownload' ? 1 : 0);
        }
      },
    );
  }
}
