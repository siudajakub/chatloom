Upstream Matrix Dart SDK commit: 355bf1d2d471ef2ab578d83a14a684cea7c07a1c
Local patch: sanitize log events before buffering/printing; cap log buffer.
Transport and cryptography remain upstream.
Local patch: optional source-bound outgoing acceptance callback for all message/media paths; callback failures cannot alter transport result.
Local patch: optional capability authorization before outgoing content and redactions; source events retain their original room.
