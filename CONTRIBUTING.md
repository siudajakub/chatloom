<!--
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Contributing

ChatLoom is a personal project maintained by the repository owner. Unsolicited
pull requests are not expected and may not be reviewed. Bug reports and
questions are welcome as GitHub issues; security issues go through
[SECURITY.md](SECURITY.md).

If you do send a change:

- keep it small and focused, with a [Conventional Commits](https://www.conventionalcommits.org) message;
- follow [DESIGN.md](DESIGN.md) for UI and keep Matrix encryption, SQLCipher storage and the privacy filters intact;
- run `flutter analyze lib` and the tests for the area you changed (see the [README](README.md#build-from-source));
- by contributing you agree that your change is licensed under AGPL-3.0-or-later, like the rest of ChatLoom.

ChatLoom is a modified version of [FluffyChat](https://github.com/krille-chan/fluffychat);
changes that belong upstream are better sent there.
