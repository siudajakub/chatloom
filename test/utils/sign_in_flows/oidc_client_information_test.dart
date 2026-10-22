// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/utils/sign_in_flows/oidc_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default OIDC registration metadata is ChatLoom and omits empty URIs',
      () {
    final info = oidcClientInformation(
      clientName: AppSettings.applicationName.defaultValue,
      clientUri: Uri.parse(AppSettings.website.defaultValue),
      logoUrl: AppSettings.logoUrl.defaultValue,
      tosUrl: AppSettings.tos.defaultValue,
      policyUrl: AppSettings.privacyPolicy.defaultValue,
    );
    final json = info.toJson();
    expect(json['client_name'], 'ChatLoom');
    expect(json['client_uri'], 'https://github.com/siudajakub/chatloom');
    expect(json.keys, unorderedEquals(['client_name', 'client_uri']));
    expect(json.toString().toLowerCase(), isNot(contains('fluffy')));
  });

  test('configured optional URIs are kept', () {
    final info = oidcClientInformation(
      clientName: 'ChatLoom',
      clientUri: Uri.parse('https://example.com'),
      logoUrl: 'https://example.com/logo.png',
      tosUrl: 'https://example.com/tos',
      policyUrl: 'https://example.com/privacy',
    );
    expect(info.toJson().keys, hasLength(5));
  });
}
