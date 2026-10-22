// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/sign_in/view_model/sign_in_view_model.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  test('offers the default homeserver at once, without a fetched list', () {
    final viewModel = SignInViewModel();
    addTearDown(viewModel.dispose);
    final state = viewModel.value;
    final defaultServer = AppSettings.defaultHomeserver.value;

    // Ready synchronously: there is no network request to wait for.
    expect(state.publicHomeservers.connectionState, ConnectionState.done);
    expect(state.publicHomeservers.data!.map((server) => server.name), [
      defaultServer,
    ]);
    expect(state.selectedHomeserver?.name, defaultServer);
    expect(state.filteredPublicHomeservers.map((server) => server.name), [
      defaultServer,
    ]);
  });

  test('a typed homeserver can be chosen instead of the default', () {
    final viewModel = SignInViewModel();
    addTearDown(viewModel.dispose);

    viewModel.filterTextController.text = 'matrix.example.org';

    expect(
      viewModel.value.filteredPublicHomeservers.map((server) => server.name),
      ['matrix.example.org'],
    );
  });
}
