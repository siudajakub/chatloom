import 'package:chatloom/utils/uia_stage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  test('password avoids an unsupported browser stage offered first', () {
    expect(
      preferredUiaStage({'org.example.web', AuthenticationTypes.password}),
      AuthenticationTypes.password,
    );
  });

  test('dummy authentication needs no credentials or browser', () {
    expect(
      preferredUiaStage({
        'org.example.web',
        AuthenticationTypes.password,
        AuthenticationTypes.dummy,
      }),
      AuthenticationTypes.dummy,
    );
  });

  test('only a server-offered stage can be selected', () {
    expect(preferredUiaStage({'org.example.web'}), 'org.example.web');
  });

  test('fallback preserves the homeserver origin and encodes its session', () {
    final uri = uiaFallbackUrl(
      Uri.parse('https://matrix.example.org:8448?old=value#old'),
      'm.login.sso',
      'synthetic & session',
    );
    expect(uri.origin, 'https://matrix.example.org:8448');
    expect(uri.path, '/_matrix/client/v3/auth/m.login.sso/fallback/web');
    expect(uri.queryParameters, {'session': 'synthetic & session'});
    expect(uri.fragment, isEmpty);
  });
}
