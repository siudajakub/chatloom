// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/sign_in/view_model/model/public_homeserver_data.dart';
import 'package:chatloom/pages/sign_in/view_model/sign_in_state.dart';
import 'package:flutter/widgets.dart';

class SignInViewModel extends ValueNotifier<SignInState> {
  final TextEditingController filterTextController = TextEditingController();

  SignInViewModel() : super(SignInState()) {
    refreshPublicHomeservers();
    filterTextController.addListener(_filterHomeservers);
  }

  @override
  void dispose() {
    filterTextController.removeListener(_filterHomeservers);
    filterTextController.dispose();
    super.dispose();
  }

  void _filterHomeservers() {
    final filterText = filterTextController.text.trim().toLowerCase();
    final filteredPublicHomeservers =
        value.publicHomeservers.data
            ?.where(
              (homeserver) =>
                  homeserver.name?.toLowerCase().contains(filterText) ?? false,
            )
            .toList() ??
        [];
    if (filterText.length >= 3 &&
        (filterText.contains('.') || filterText.endsWith('localhost')) &&
        Uri.tryParse(filterText) != null &&
        !filteredPublicHomeservers.any(
          (homeserver) => homeserver.name == filterText,
        )) {
      filteredPublicHomeservers.add(PublicHomeserverData(name: filterText));
    }
    value.filteredPublicHomeservers = filteredPublicHomeservers;
    notifyListeners();
  }

  /// Offers the default homeserver (Beeper); any other server can be typed
  /// into the filter. No public list is fetched, so opening sign-in sends
  /// no request to a third party.
  void refreshPublicHomeservers() {
    final defaultHomeserverData = PublicHomeserverData(
      name: AppSettings.defaultHomeserver.value,
    );
    value.selectedHomeserver ??= defaultHomeserverData;
    value.publicHomeservers = AsyncSnapshot.withData(ConnectionState.done, [
      defaultHomeserverData,
    ]);
    _filterHomeservers();
  }

  void selectHomeserver(PublicHomeserverData? publicHomeserverData) {
    value.selectedHomeserver = publicHomeserverData;
    notifyListeners();
  }

  void setLoginLoading(AsyncSnapshot<bool> loginLoading) {
    value.loginLoading = loginLoading;
    notifyListeners();
  }
}
