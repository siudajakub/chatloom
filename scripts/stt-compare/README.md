# Speech-to-text comparison (OpenRouter)

`compare.py` sends the same recordings to several OpenRouter speech-to-text
models and writes a Markdown report. Use it to choose a model for the
transcription worker (`worker/lib/src/transcriber.dart`). It needs Python 3.10+
(standard library only), `ffmpeg` and `ffprobe`. Dart is optional and is used
for the worker anchoring check.

## Privacy and cost

- The API key is read at runtime from `~/.config/chatloom/openrouter.key`
  (override with `--key-file`). The file must be mode 600. The key is never
  printed, logged or saved.
- Raw answers and the report contain transcripts. They are written to
  `<project>/artifacts/stt-results/<UTC timestamp>/`, which is outside this
  repository. The script refuses an output folder inside a Git checkout
  unless Git ignores it. Files are created with mode 600 and folders with
  mode 700.
- Requests ask providers not to collect data (`provider.data_collection =
  deny`). Pass `--zdr` to require zero-data-retention endpoints. This can
  exclude some models (`404 No endpoints`). Pass `--data-collection allow`
  to lift the default.
- `--max-cost` (default $0.50) is a hard cap. Each call reserves its
  list-price estimate × 1.25 before it starts, and calls that no longer fit
  are skipped (`skipped_budget`). The estimate assumes a 10 s billing minimum
  because some endpoints charge one. The spent amount uses `usage.cost` from
  each answer.

## Modes

```sh
python3 compare.py --list-models                 # free GET, slugs + $/min, $/h
python3 compare.py --dry-run [--samples DIR]     # durations, planned calls, estimate; no request
python3 compare.py --run --language pl           # paid
python3 compare.py --report RUN_DIR              # rebuild report.md offline
python3 compare.py --smoke [--dry-run]           # paid: 2 s 440 Hz tone, Whisper Turbo, cap $0.001
python3 -m unittest test_compare                 # offline tests (fake answers)
```

Common options:

- `--models a,b,c`: OpenRouter slugs (default below).
- `--reference SLUG`: the model the WER is measured against (default
  `openai/gpt-transcribe`).
- `--samples PATH`: a file or a folder; repeatable. The default is
  `<project>/artifacts/stt-samples`.
- `--language pl|auto`: `auto` omits `language`.
- `--transport json|multipart`: base64 `input_audio` (default; it carries
  provider preferences) or the OpenAI-style multipart form the worker uses.
- `--concurrency 2`.
- `--max-duration 900`: skips longer samples (900 s is the worker's chunk
  length).
- `--json-only`: skips timestamps.
- `--models-json FILE`: a saved models API answer, for offline use.
- `--dart PATH`, `--no-dart`.

Default models: `elevenlabs/scribe-v2`, `openai/whisper-large-v3-turbo`,
`mistralai/voxtral-mini-transcribe-3-0`, `deepgram/nova-3`,
`openai/gpt-transcribe`.

## What a run does

1. Each sample is converted to the worker's upload format: first audio
   stream, mono 16 kHz MP3 at 32 kbit/s, no metadata. `--no-convert` sends
   `.mp3` files unchanged.
2. Every sample goes to every model with `response_format=verbose_json` and
   `timestamp_granularities=[segment, word]`. If a model answers 400, the
   request is repeated once as `json`, and the result is recorded as "no
   timestamps". Rejected requests are not billed.
3. Retries follow the worker's rules. 429, 502, 503 and connections that
   never opened are retried up to 3 times with 1, 2 and 4 s backoff, or
   `Retry-After` up to 20 s. Timeouts, 500, 504 and dropped connections may
   already have been billed. They are recorded as `paid_unknown`, counted at
   the estimate, and never retried.
4. Each answer is saved as `<run>/<provider__model>/<sample>.json`, with the
   request parameters (no audio), HTTP status, latency, attempts, the
   generation id and the raw answer.
5. `report.md` covers:
   - per model: mean and p95 latency, real-time factor, cost, $/h, billed
     seconds, timestamp coverage (word, segment, none) and word count;
   - pairwise WER between models, and WER against the reference;
   - flags for empty, possibly truncated or repetitive output;
   - timestamp sanity: monotonic starts, spans inside the audio, overlaps and
     gaps;
   - side-by-side transcripts for each sample;
   - the worker anchoring check.

WER normalisation applies NFC, lowercases the text, turns punctuation and
symbols into spaces and joins apostrophes. Polish diacritics are kept.
Numbers are not spelled out, so "5" and "pięć" count as different words.
Between two models the WER measures disagreement, not accuracy.

## Worker anchoring check

`anchor_check.dart` runs the worker's own `chunkTimestamps` and
`transcriptTimingRecord` on every saved answer. The result shows whether the
worker would keep each provider's segment and word times as they arrive. For
example, words nested in `segments[].words`, or words without punctuation,
are dropped. The check needs `dart pub get` in `worker/` to have been run
once:

```sh
dart --packages=worker/.dart_tool/package_config.json \
  scripts/stt-compare/anchor_check.dart RUN_DIR/*/*.json
```

`--report` and `--run` call it automatically when `dart` is on `PATH` or
passed with `--dart`. Otherwise the section reads NOT RUN.

## Limits

- One request per sample, with no chunking. OpenRouter documents a 60 s
  upstream processing timeout and a 25 MB upload limit, so very long samples
  can fail.
- Token-priced models (for example `google/gemini-3.5-transcribe` and
  `openai/gpt-4o-transcribe`) only get a rough estimate: 32 audio tokens
  and 8 output tokens per second. The real cost is in `usage.cost`.
- OpenRouter ignores `order`, `only` and `ignore` routing for transcription.
  The serving provider of a model can differ between calls; for Whisper Turbo
  it is DeepInfra or Groq, at different prices.
