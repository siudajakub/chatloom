# Private conversation summaries and questions

In an open group, choose **Conversation options → Summarize conversation**.
Select the last number of messages, hours, days, or the whole available
conversation. Presets and a custom positive number are supported. Choose
Brief, Standard, or Detailed and Polish or English, then generate.

In a group, direct chat or merged conversation, choose **Ask about
conversation** in the conversation menu. Select the latest N messages or the
whole available history. Follow-ups keep the range and read current history. The
worker receives the latest question and up to four previous questions for
context. The follow-up thread is visible while its sheet is open. Choose
**New thread** to pick another range.

Merged conversations also support summaries. One selection spans the
currently available linked chats in merged timeline order. The sheet and
result show how many linked chats the selection covers. A change in which
chats belong to the conversation invalidates the open request.

The result is selectable and can be copied. It is never posted to the group.
Changing the range starts a new explicit request. Closing or stopping the
sheet cancels the operation; a provider request already started may still
incur a charge. Locking the app invalidates access to the sheet and cancels
its active operation.

## Model and prompt

The worker uses [Nemotron 3.5 Lightning](https://openrouter.ai/nvidia/nemotron-3.5-lightning)
through OpenRouter for brief and standard summaries and for questions. It
caps eligible provider rates at $0.07 per million input and $0.20 per million
output tokens. Detailed summaries and inputs above 240,000 UTF-8 bytes use
[Gemini 3.1 Flash Lite](https://openrouter.ai/google/gemini-3.1-flash-lite)
at caps of $0.25 input and $1.50 output per million tokens. Provider routing
prioritizes throughput and requires zero data retention and no data collection.
The model has no tools or browsing access.

The prompt treats message bodies, speaker names and transcripts as untrusted
data. It distinguishes proposals from decisions, preserves disagreements and
unanswered questions, and lists owners or deadlines only when explicitly
stated. It cannot inspect linked pages or unseen attachments. Brief output
targets 100–180 words, Standard 250–450, and Detailed 600–1000 when the source
warrants that length. Output is capped at 1,200 / 2,500 / 5,000 tokens. An
answer is capped at 1,000 tokens, follows the language of the question, and
uses dates or names when they help explain the evidence.

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

The provider receives readable message text, timestamps, speaker labels,
coverage information and the explicitly submitted questions. Room, event
and account identifiers stay outside the model input. The OpenRouter key
stays in the worker's private credentials.

The Matrix timeline in the existing encrypted store is the source of truth.
The app creates no additional history index. Source batches and results
travel through the existing verified encrypted private journal and encrypted
local stores. Question text is in the temporary, digest-checked batch. The
worker removes working source copies after a terminal result and expires
abandoned batches. Published encrypted events and backups follow the current
journal retention policy.

The client limits collected source to 350 KB, 10,000 readable messages and
200 history pages. The transport independently validates a 400 KB source
ceiling, ordered UTF-8 chunks and a SHA-256 digest. The worker sends one paid
request per job with an estimated ceiling below $0.12. After an uncertain
response or a restart during a paid attempt, the job becomes unknown and is
never automatically billed again.

## Availability and acceptance

The client requires a fresh authenticated worker heartbeat advertising
`summary: ready` and `summaryVersion: 1`. Questions also require
`summaryQuestions: 1`. The app checks these capabilities before collecting
or uploading history. See [worker configuration](../worker/README.md).

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
