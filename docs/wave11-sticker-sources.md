# Wave 11 — where sticker packs can come from

J (2026-10-27): "maybe connect some external sticker service, or simply allow
adding new packs — research how to do it. It must all work reliably."
Decision taken in this wave: **Telegram's own catalogue through our bridge
fork + Matrix pack rooms + packs from the user's images**. No third-party
sticker API, no key, nothing on by default that sends data somewhere new.

Everything lands in the same place: an MSC2545 pack in a Matrix room (or the
account's own pack in account data) that the library (`sticker_library.dart`)
points at. The composer panel, search, suggestions, recents and other Matrix
apps keep working with one model.

## Options

| | Source | Privacy | Reliability | Cost | Status |
|---|---|---|---|---|---|
| a | Telegram catalogue via the bridge fork | search text → Beeper relay → Telegram (the user's own login, like `@gif`) | Telegram's API; FLOOD_WAIT honoured, cached | none | **implemented** (app: feature-detected; bridge: patch, needs J's deploy) |
| b | Matrix pack rooms (MSC2545, stickerpicker) | joining a room is visible to its members; peeking a public room is not | as good as the homeserver; Beeper's federation for foreign rooms UNVERIFIED | none | **implemented**, works without deploy |
| c | Own packs from images | images uploaded unencrypted to the user's media repo; pack in account data (server-readable, like every pack) | uploads retried, one write, merge-on-write | none | **implemented**, works without deploy |
| d | GIPHY / other public APIs | every query and view goes to a new third party (with analytics); needs an API key in the app | key quotas, terms, attribution; Tenor's API was shut down on 30 June 2026 | key/approval | **not advised, not implemented** |

### (a) Telegram's catalogue through the fork

Telegram API calls (all with the user's own login, `pkg/gotd/tg` in the fork):

- `messages.searchStickerSets(q)` — set search (titles/short names); bounded
  list, no paging.
- `messages.getFeaturedStickers(hash)` then
  `messages.getOldFeaturedStickers(offset, limit)` — "trending", paged.
- `messages.installStickerSet(stickerset)` — adds a set to the Telegram
  account (archives old ones when full).
- `messages.getStickers(emoticon)` / `messages.searchStickers` — stickers by
  emoji; would need one upload per sticker shown, left for later.

New provisioning routes (branch `chatloom/sticker-search`, based on
`chatloom/voice-fix-v1.4` = the deployed v1.4; file
`pkg/connector/stickersearch.go`, registered next to the GIF routes):

```
POST /_matrix/provision/v3/sticker_sets/search   {"query": "cats"}         → {"sets": [...]}
POST /_matrix/provision/v3/sticker_sets/featured {"offset": 0}             → {"sets": [...], "next_offset": 20}
POST /_matrix/provision/v3/sticker_sets/cover    {"short_name": "Cats"}    → {"url": "mxc://…", "info": {…}}
POST /_matrix/provision/v3/sticker_sets/install  {"short_name": "Cats"}    → {"installed": true, "archived_others": false}
```

A set is `{short_name, title, url, count, emoji, official, masks, installed,
has_cover}`. Search/featured upload nothing; `cover` uploads one small static
thumbnail (cached by Telegram location ID, only for sets a recent answer of
the same login returned); the stickers themselves are previewed/imported by
the existing `/v3/image_pack/import?pack_url=` route, so nothing new writes
room state. Queries are POST bodies (not in the access log), never logged;
FLOOD_WAIT blocks further calls until it passes; errors are sentences.
`install` is exposed but the app does not call it yet (adding in ChatLoom
does not change the Telegram account).

App side (`sticker_catalog.dart`): the first `M_UNRECOGNIZED` marks the bridge
as "needs an update" for the session — one request, then a calm note; links,
the user's Telegram packs, rooms and own packs still work. One quiet retry on
no answer/502/504, 10-minute page cache, covers loaded lazily, three at a
time, failures not cached.

### (b) Matrix pack rooms

`im.ponies.room_emotes` / `m.room.image_pack` state in a room; other clients
enable them with `im.ponies.emote_rooms` / `m.image_pack.rooms` (the library
already shows those). maunium stickerpicker packs are JSON files on a web
server (no Matrix state) — importing them would mean fetching a third-party
URL and re-uploading; not done. Its users usually also publish a pack room.

Implemented (`room_sticker_packs.dart`): `matrix.to/#/#alias:server`,
`…/!id:server?via=…`, `matrix:r/…`, `matrix:roomid/…` and bare `#`/`!` ids.
Preview reads a joined room's state, else peeks (`GET /rooms/{id}/state`,
works for world-readable rooms); adding joins first (so the pack syncs to all
devices and other apps), with a note that members see the join. "Packs in
your rooms" lists packs of joined rooms the library doesn't show (no
request). Whether Beeper's server can join rooms on other homeservers is
UNVERIFIED; failures read as "The room couldn't be joined".

### (c) Own packs

`own_sticker_pack.dart` + page `Settings › Stickers › Your sticker pack`
(`/rooms/settings/chat/stickers/own`): PNG/WebP/GIF/JPEG up to 2 MB (animated
WebP/GIF stay animated), an emoji per sticker, upload to the media repo (3
attempts), one account data write (`im.ponies.user_emotes`, or `m.image_pack`
if the account already uses it) re-read just before writing so edits from
another device merge. Duplicates found by SHA-256; cap 150 stickers / 60 KB
JSON; rename, reorder (drag), change emoji, delete with Undo. MSC2545 has one
user pack per account; several own packs would need a pack room (creating
rooms on Beeper adds an inbox entry — not done).

### (d) GIPHY / Tenor / others — not advised

Tenor's public API was shut down on 30 June 2026 (new keys stopped in
January 2026). GIPHY needs an API key embedded in the app (extractable),
has quotas for unapproved keys, requires attribution and sends every query
plus usage pings to a new third party. That contradicts the product rule
"no new third party receives user data unless opt-in and explained", and the
Telegram route already gives a large catalogue with the user's own account.
If J ever wants it: opt-in switch, off by default, key in a private build
config, never in the repo.

## What needs J

- Deploy the fork patch (`wave11-packs-bridge.patch` on top of the deployed
  v1.4 + voice fix) for search/trending/covers. Until then the sheet shows
  "needs an update of your Telegram bridge" once and everything else works.
- Device check of Beeper room joins for foreign pack rooms: NOT RUN.
