# Notice

ChatLoom is a modified version of [FluffyChat](https://github.com/krille-chan/fluffychat)
v2.10.0, © 2019-Present Christian Kußowski and the FluffyChat contributors,
licensed under the GNU Affero General Public License v3.0 or later
([LICENSE](LICENSE)).

ChatLoom's modifications started in October 2026 (first ChatLoom commit:
2026-10-14) and are licensed under the same terms. They include, among others:

- a new user interface and design system (`lib/ui/notion/`, `DESIGN.md`) and
  rebranding to ChatLoom;
- Beeper-oriented features in `lib/personal/` and `packages/personal_core/`
  (merged conversations, private organization, drafts, bookmarks, reminders,
  scheduled messages, transcription, Incognito privacy filters);
- changes throughout upstream files in `lib/`, `android/` and `macos/`; their
  original copyright headers are kept and the Git history records every change;
- a vendored and patched Famedly Matrix Dart SDK (`packages/matrix/`, see its
  `UPSTREAM-PIN.md`);
- the self-hosted worker (`worker/`) and push gateway (`push-gateway/`).

Third-party material keeps its own licence: the Roboto font (Apache-2.0,
`assets/notion/fonts/Roboto_LICENSE.txt`), notification sounds (CC-BY-4.0,
Pixabay) and Matrix emoji verification data (Apache-2.0, Matrix Foundation).
See `REUSE.toml` and `LICENSES/`.

"FluffyChat" is the name of the upstream project; ChatLoom is not affiliated
with or endorsed by it.
