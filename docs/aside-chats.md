# Aside chats

Aside holds chats you occasionally want to read, away from the main list.
It is available as an inbox tab and in the dock's Show chats menu; selecting
a network still filters this category.

Hold a chat and choose **Move to Aside**. In Aside the same action becomes
**Move to Inbox**. Both moves offer Undo. Chat visibility preferences and the
merged person page expose the same destination. Networks & chat rules can also
choose Aside as the default for a network's groups.

- Chats in Aside stay there after new messages and when pinned. They do not
  appear in the main list, Unread, Groups or the other inbox categories.
- Search can still find them and labels results Aside. The recent people
  suggestions leave them out.
- Only an explicit `m.mentions.user_ids` mention of the account can alert.
  Ordinary messages, room-wide mentions and thread replies without a direct
  mention stay silent. Own messages stay silent too.
- An explicitly fully muted chat or a fully muted inherited notification
  policy can still suppress mentions, as can account push restrictions.
  Moving back restores the chat's saved notification preference.
- Moving clears archive, low priority and ignore visibility flags for that
  selected conversation. It preserves pins, labels, appearance, names and
  notification preferences. No existing Ignored chat moves automatically.
- A merged person uses one placement for all source chats. This does not
  alter source selection, send routing, room membership or message history.

The placement uses the existing private encrypted journal as `placement:
aside`, including durable queueing, restart, acknowledgement and synchronization
between updated clients. Older clients do not understand this new destination;
update both Android and macOS to use it consistently.

Aside itself does not create a server mute rule: the server cannot inspect
encrypted mentions. Foreground and background notification eligibility check
the decrypted event on the device. Existing stricter mute rules retain their
behavior. Ignored remains fully silent, including mentions.

Synthetic tests cover filtering, activity, serialization, replica persistence
and acknowledgement, merged sources, notification eligibility and category
navigation. They do not establish real account synchronization or phone push
delivery; those require device acceptance after releasing the updated app.
