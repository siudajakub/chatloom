# Private group conversation summaries

In an open group, choose **Conversation options → Summarize conversation**.
Select the last number of messages, hours, days, or the whole available
conversation. Presets and a custom positive number are supported. Choose
Brief, Standard, or Detailed and Polish or English, then generate.

The result is selectable and can be copied. It is never posted to the group.
Changing the range starts a new explicit request. Closing or stopping the
sheet cancels the operation; a provider request already started may still
incur a charge. Locking the app invalidates access to the sheet and cancels
its active operation.

## Model and prompt

The worker uses `google/gemini-3.1-flash-lite` through OpenRouter. The
[model catalog](https://openrouter.ai/google/gemini-3.1-flash-lite) lists a
1,048,576-token context and standard prices of $0.25 per million input tokens
and $1.50 per million output tokens, checked on 3 November 2026. Provider
routing caps prices at these rates and requires no data collection and zero
data retention. No fallback model or tool use is enabled.

The prompt treats message bodies, speaker names and transcripts as untrusted
data. It distinguishes proposals from decisions, preserves disagreements and
unanswered questions, and lists owners or deadlines only when explicitly
stated. It cannot inspect linked pages or unseen attachments. Brief output
targets 100–180 words, Standard 250–450, and Detailed 600–1000 when the source
warrants that length. Output is capped at 1,200 / 2,500 / 5,000 tokens.

## History and privacy

The client reads a separate Matrix timeline, retaining existing SDK
decryption. It sends no read receipts, typing signals or conversation events.
Edits replace original text; reply fallbacks do not duplicate quoted content.
Deleted, hidden, protected and unavailable encrypted content is excluded.
Disappearing conversations are refused. Existing completed private
transcripts may be included; summarization never requests a transcription or
downloads attachment contents.

“Whole conversation” means history available to this account, including
pagination. A bridge may not have imported earlier messages. Results disclose
content omissions. Pagination failure, stalled history or a size limit
refuses the request instead of silently shortening it. Last-N selection
counts unavailable original messages in their original positions.

The provider receives only message text, timestamps, speaker labels and
coverage information. Room, event and account identifiers stay outside the
model input. The server-only OpenRouter key reuses the worker's existing
private credential; it is never bundled into the app.

Source batches and results travel through the existing verified encrypted
private journal and encrypted local stores. The worker removes working
source copies after a terminal result; abandoned batches expire. Already
published encrypted Matrix journal history remains subject to the existing
journal retention policy. This feature does not promise deletion of that
history or its backups.

The client limits collected source to 350 KB, 10,000 readable messages and
200 history pages. The transport independently validates a 400 KB source
ceiling, ordered UTF-8 chunks and a SHA-256 digest. The worker sends one paid
request per job with an estimated ceiling below $0.12. After an uncertain
response or a restart during a paid attempt, the job becomes unknown and is
never automatically billed again.

## Availability and acceptance

The client requires a fresh authenticated worker heartbeat advertising
`summary: ready` and `summaryVersion: 1`. An older or unconfigured worker
receives no source upload. Updating local code does not update the running
worker or installed app; see [worker configuration](../worker/README.md).

Offline unit and widget tests cover history ranges, cancellation, journal
transport, prompt/request construction, privacy gates, provider failures and
worker recovery. They use fictional data and mocked provider responses.
Paid provider acceptance, real-account history and device acceptance require
separate explicit execution; they are not established by these tests.

Local verification on 3 November 2026: 75 new summary tests passed, the
application and worker analysis reported no errors or warnings, 250 core
tests and the personal storage/privacy checks passed, and the existing
401-test Notion presentation/golden harness passed without updating goldens.
Ten fictional summary screenshots were reviewed, including desktop, phone,
keyboard inset and 320 px / 200% text. The broader worker run still lacks the
native vodozemac library for an older round-crypto fixture; this is not a
passing result for that fixture.
