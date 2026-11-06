# Instagram links in conversations

The beta implements inline reel playback and linked captions. The original
requirements and follow-up work are in [reels-playback-plan.md](reels-playback-plan.md).

Instagram reel, post, story and highlight links are recognized independently
of the conversation network. The original message text is preserved.
Shared Instagram media uses two thirds of the normal media width.

On the first tap, the client requests metadata through the connected
Instagram bridge's authenticated provisioning transport, then plays video
inline using an explicitly started player. The native viewer remains for
images and ordered albums. Normal bridged
link cards, timeline photo albums, sticker rendering and the viewer's
current-page playback behavior retain their existing paths. Instagram text
links use one native share card instead of a duplicate generic link card.
The recognized raw permalink is removed only from presentation; the sender's
comment and other links remain. The original Matrix message is not changed.

The author's caption below the video is the link to the original. Missing
captions show an explicit `Open reel in Instagram` link. Video files already
delivered by the Meta bridge also play inline, including Facebook shares;
their `caption_body_text`/`full_post_title` is preferred over a raw URL.

The same native decoder and position are retained in full screen. Playback
is explicit, coordinated with other audible media, and stops on leaving the
viewport, chat, account, or foreground. No media is played in the inbox peek.

## Bridge requirement

This optional feature needs a compatible bridge exposing
POST /v3/chatloom/link_media with a JSON request containing url, index and
download. Metadata returns an assets list with type, width and height;
file requests return mime and base64 data. Metadata optionally includes
`caption`, `canonical_url` and `author`. The canonical URL must identify the
requested post. A matching Matrix link preview can supply a fallback caption
and an encrypted MXC thumbnail. Metadata cache is account scoped with a one-day
TTL; video download starts only after Play. The client never receives the
Instagram cookies or signed CDN URLs. A missing bridge or inaccessible
material offers retry and the original-post link.

The current server fork returns assets only. The compatible caption extension
is provided in [scripts/bridges](../scripts/bridges/README.md); an operator must
build and deploy it to obtain original captions from that endpoint. No live
VPS change is implied by installing the client branch.

The existing account file cache is bounded and account scoped. Synthetic
media events are local presentation adapters, not Matrix timeline messages.
They are not offered to the native message-forwarding action.

## Current limits and evidence

- A Matrix bridge-provided poster is shown when present and thumbnails are
  enabled. Otherwise Play is shown before metadata. This version does not
  scrape websites or fetch an arbitrary external thumbnail from the client.
- Bare Facebook/Threads links without a bridged video file have no resolver.
- The route recognizes stories/highlights, but private posts, active stories
  and highlights do not yet have complete end-to-end acceptance.
- Parser, compact-layout, transport and media-viewer tests use fictional
  fixtures. They do not prove playback on a physical device or delivery
  through every messenger.
- This integration was ported onto the current public repository rather than
  merging an unrelated legacy repository history. Conflicts in Message and
  MessageContent were resolved by preserving the newer chat UI and combining
  its generic bridged previews with Instagram handling.

## Repository migration verification (2026-10-23)

The combined source passed 177 focused tests across Instagram parsing and
transport, bubble sizing, link-card coexistence, albums and inline loops,
media-viewer motion, progressive photos, SDK room-preview recovery, outgoing
voice formats, activity state, notification replies, inbox styling and
ordinary/merged conversation flows.

Full lib analysis completed with no errors or warnings; 77 informational
lint notices remain. Design-token checks passed without baseline growth.
These are source/integration checks, not a new signed release, deployment or
physical-device acceptance.
