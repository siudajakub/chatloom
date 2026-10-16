// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

// HandshakeException is a TlsException; filesystem failures stay actionable.
bool isNativeNetworkFailure(Object error) =>
    error is SocketException || error is TlsException;
