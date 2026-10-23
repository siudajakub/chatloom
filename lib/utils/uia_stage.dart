import 'package:matrix/matrix.dart';

String preferredUiaStage(Set<String> stages) {
  for (final stage in [
    AuthenticationTypes.dummy,
    AuthenticationTypes.password,
  ]) {
    if (stages.contains(stage)) return stage;
  }
  return stages.first;
}

Uri uiaFallbackUrl(Uri homeserver, String stage, String? session) =>
    homeserver.replace(
      path: '/_matrix/client/v3/auth/$stage/fallback/web',
      queryParameters: {'session': session},
      fragment: '',
    );
