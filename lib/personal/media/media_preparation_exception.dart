// SPDX-License-Identifier: AGPL-3.0-or-later

/// A media encoder could not safely produce the selected send quality.
/// Never replace this failure with an implicit upload of the original.
class MediaPreparationException implements Exception {
  const MediaPreparationException();

  String get message =>
      'This media could not be compressed. Retry, or choose File from the '
      'attachment menu to send the original with its full size and metadata.';
}
