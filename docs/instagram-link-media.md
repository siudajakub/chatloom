# Instagram links in conversations

Instagram reel, post, story and highlight links are recognized independently
of the conversation network. The original message text is preserved.
Shared Instagram media uses two thirds of the normal media width.

On the first tap, the client requests metadata through the connected
Instagram bridge's authenticated provisioning transport, then reuses the
native media viewer for file playback and ordered albums. Normal bridged
link cards, timeline photo albums, sticker rendering and the viewer's
current-page playback behavior retain their existing paths. Instagram text
links use one native share card instead of a duplicate generic link card.

## Bridge requirement

This optional feature needs a compatible bridge exposing
POST /v3/chatloom/link_media with a JSON request containing url, index and
download. Metadata returns an assets list with type, width and height;
file requests return mime and base64 data. The client never receives the
Instagram cookies or signed CDN URLs. A missing bridge or inaccessible
material offers retry and Open in Instagram.

The existing account file cache is bounded and account scoped. Synthetic
media events are local presentation adapters, not Matrix timeline messages.
They are not offered to the native message-forwarding action.

## Current limits and evidence

- The first untapped state is a download button; a separately loaded poster
  has not been implemented. Full-video download starts after a tap.
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
