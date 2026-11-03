#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Speech-to-text comparison harness for the ChatLoom transcription worker.

Sends the same recordings to several OpenRouter speech-to-text models and
writes a Markdown report: latency, real-time factor, cost, timestamp
coverage and sanity, and word-level agreement between the models.

Modes (see README.md in this folder):
  --list-models   free GET of the transcription models and their prices
  --dry-run       planned calls, durations and estimated cost; no paid call
  --run           paid calls, raw responses saved, report written
  --report DIR    rebuild the report of an earlier run offline
  --smoke         one 2-second synthetic tone to one model (< $0.001)

The API key is read at runtime from ~/.config/chatloom/openrouter.key (or
--key-file) and never printed, logged or saved. Raw responses contain
transcripts: they are written outside the repository (see --out).
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import datetime as dt
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.error
import urllib.request

API = 'https://openrouter.ai/api/v1'
TRANSCRIBE_URL = f'{API}/audio/transcriptions'
MODELS_URL = f'{API}/models?output_modalities=transcription'
DEFAULT_KEY_FILE = '~/.config/chatloom/openrouter.key'
DEFAULT_MODELS = [
    'elevenlabs/scribe-v2',
    'openai/whisper-large-v3-turbo',
    'mistralai/voxtral-mini-transcribe-3-0',
    'deepgram/nova-3',
    'openai/gpt-transcribe',
]
DEFAULT_REFERENCE = 'openai/gpt-transcribe'
SMOKE_MODEL = 'openai/whisper-large-v3-turbo'
SAMPLE_SUFFIXES = {
    '.ogg', '.oga', '.opus', '.mp3', '.m4a', '.mp4', '.wav', '.webm', '.aac',
    '.flac', '.amr', '.mkv', '.mov', '.3gp',
}
# Worker parity: mono 16 kHz MP3 at 32 kbit/s (lib/src/transcriber.dart).
SEND_SAMPLE_RATE = '16000'
SEND_BITRATE = '32k'
SEND_BYTES_PER_SECOND = 4000
MAX_UPLOAD_BYTES = 25_000_000
# Token-priced models: rough audio and output token rates per second of
# audio, used only for estimates and the budget gate (usage.cost is exact).
AUDIO_TOKENS_PER_SECOND = 32
OUTPUT_TOKENS_PER_SECOND = 8
# Reservations before a call are this much above the list-price estimate.
BUDGET_MARGIN = 1.25
MIN_BILLED_SECONDS = 10.0
RETRYABLE_STATUS = {429, 502, 503}
ATTEMPTS = 3
REQUEST_TIMEOUT = 150
USER_AGENT = 'chatloom-stt-compare/1'
SCHEMA = 1

SCRIPT = Path(__file__).resolve()
CLIENT_ROOT = SCRIPT.parents[2]
PROJECT_ROOT = Path(os.environ.get('PERSONAL_CHAT_ROOT') or SCRIPT.parents[3])
DEFAULT_SAMPLES = PROJECT_ROOT / 'artifacts' / 'stt-samples'
DEFAULT_OUT = PROJECT_ROOT / 'artifacts' / 'stt-results'
WORKER_ROOT = CLIENT_ROOT / 'worker'
ANCHOR_CHECK = SCRIPT.parent / 'anchor_check.dart'


class HarnessError(Exception):
    pass


# --------------------------------------------------------------------------
# Key, files, media


def read_key(path: str) -> str:
    """The API key from [path]; refuses files readable by group or others."""
    file = Path(path).expanduser()
    try:
        info = file.stat()
    except FileNotFoundError:
        raise HarnessError(f'key file missing: {path}') from None
    if not stat.S_ISREG(info.st_mode):
        raise HarnessError(f'key file is not a regular file: {path}')
    if info.st_mode & 0o077:
        raise HarnessError(f'key file must be mode 600 (chmod 600 {path})')
    key = file.read_text(encoding='utf-8').strip()
    if not key or any(c.isspace() for c in key):
        raise HarnessError(f'key file has no single-line key: {path}')
    return key


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def write_private(path: Path, text: str) -> None:
    private_dir(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as handle:
        handle.write(text)


def guard_out_dir(out: Path, allow_in_repo: bool) -> None:
    """Results hold transcripts: refuse a folder a Git checkout would track."""
    if allow_in_repo:
        return
    probe = out
    while not probe.exists():
        probe = probe.parent
    try:
        top = subprocess.run(
            ['git', '-C', str(probe), 'rev-parse', '--show-toplevel'],
            capture_output=True, text=True, check=False,
        )
    except FileNotFoundError:
        return
    if top.returncode != 0:
        return
    ignored = subprocess.run(
        ['git', '-C', top.stdout.strip(), 'check-ignore', '-q', str(out)],
        capture_output=True, check=False,
    )
    if ignored.returncode != 0:
        raise HarnessError(
            f'output folder {out} is inside a Git checkout and not ignored; '
            'results contain transcripts. Use a private folder or --allow-in-repo.')


def find_samples(paths: list[str]) -> list[Path]:
    found: list[Path] = []
    for raw in paths:
        path = Path(raw).expanduser()
        if path.is_dir():
            found.extend(sorted(
                p for p in path.iterdir()
                if p.is_file() and p.suffix.lower() in SAMPLE_SUFFIXES))
        elif path.is_file():
            found.append(path)
        else:
            raise HarnessError(f'no such sample file or folder: {raw}')
    if not found:
        raise HarnessError('no audio samples found')
    names = [sample_name(p) for p in found]
    if len(set(names)) != len(names):
        raise HarnessError('two samples share a name; rename one')
    return found


def sample_name(path: Path) -> str:
    return re.sub(r'[^A-Za-z0-9._-]+', '_', path.stem)[:80] or 'sample'


def model_dir_name(model: str) -> str:
    return model.replace('/', '__')


def probe_duration(path: Path, ffprobe: str = 'ffprobe') -> float:
    result = subprocess.run(
        [ffprobe, '-v', 'error', '-show_entries', 'format=duration',
         '-of', 'json', str(path)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise HarnessError(f'ffprobe failed for {path.name}')
    try:
        duration = float(json.loads(result.stdout)['format']['duration'])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        raise HarnessError(f'ffprobe found no duration for {path.name}') from None
    if not math.isfinite(duration) or duration <= 0:
        raise HarnessError(f'invalid duration for {path.name}')
    return duration


def convert_for_upload(source: Path, target: Path, ffmpeg: str = 'ffmpeg') -> None:
    """The worker's upload format: first audio stream, mono 16 kHz MP3."""
    result = subprocess.run(
        [ffmpeg, '-nostdin', '-v', 'error', '-y', '-i', str(source),
         '-map', '0:a:0', '-map_metadata', '-1', '-vn', '-sn', '-dn',
         '-ac', '1', '-ar', SEND_SAMPLE_RATE, '-c:a', 'libmp3lame',
         '-b:a', SEND_BITRATE, str(target)],
        capture_output=True, check=False,
    )
    if result.returncode != 0 or not target.exists():
        raise HarnessError(f'ffmpeg could not convert {source.name}')


def make_tone(target: Path, seconds: float = 2.0, ffmpeg: str = 'ffmpeg') -> None:
    result = subprocess.run(
        [ffmpeg, '-nostdin', '-v', 'error', '-y', '-f', 'lavfi', '-i',
         f'sine=frequency=440:sample_rate=16000:duration={seconds}',
         '-ac', '1', '-c:a', 'libmp3lame', '-b:a', SEND_BITRATE, str(target)],
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise HarnessError('ffmpeg could not generate the smoke tone')


# --------------------------------------------------------------------------
# Models and prices


def fetch_models(models_json: str | None = None) -> list[dict]:
    """Transcription models; from a saved models API answer when given."""
    if models_json:
        data = json.loads(Path(models_json).read_text(encoding='utf-8'))
    else:
        request = urllib.request.Request(
            MODELS_URL, headers={'User-Agent': USER_AGENT})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.loads(response.read())
    models = data.get('data') if isinstance(data, dict) else data
    if not isinstance(models, list):
        raise HarnessError('unexpected models API answer')
    return models


def price_info(model: dict) -> dict:
    pricing = model.get('pricing') or {}

    def number(key: str) -> float:
        try:
            return float(pricing.get(key) or 0)
        except (TypeError, ValueError):
            return 0.0

    prompt, completion, request = number('prompt'), number('completion'), number('request')
    kind = 'per_second' if completion == 0 else 'tokens'
    if kind == 'per_second':
        per_hour = prompt * 3600
    else:
        per_hour = (AUDIO_TOKENS_PER_SECOND * prompt
                    + OUTPUT_TOKENS_PER_SECOND * completion) * 3600
    description = model.get('description') or ''
    return {
        'id': model.get('id'),
        'name': model.get('name'),
        'kind': kind,
        'prompt': prompt,
        'completion': completion,
        'request': request,
        'per_hour': per_hour,
        # A prompt price above $0.01 per second ($36/h) is not a plain
        # per-second rate; estimates for it are unreliable.
        'suspicious': kind == 'per_second' and prompt > 0.01,
        'mentions_word_timestamps': bool(
            re.search(r'word[- ]level timestamps', description, re.I)),
        'mentions_timestamps': 'timestamp' in description.lower(),
    }


def estimate_cost(price: dict, seconds: float) -> float:
    # Some endpoints bill a minimum (Whisper Turbo billed 10 s for a 7.5 s
    # clip on 2026-10-31); estimates assume it everywhere.
    seconds = max(seconds, MIN_BILLED_SECONDS)
    if price['kind'] == 'per_second':
        return price['prompt'] * seconds + price['request']
    return ((AUDIO_TOKENS_PER_SECOND * price['prompt']
             + OUTPUT_TOKENS_PER_SECOND * price['completion']) * seconds
            + price['request'])


def list_models(args: argparse.Namespace) -> int:
    models = fetch_models(args.models_json)
    rows = sorted((price_info(m) for m in models), key=lambda p: p['per_hour'])
    print(f'{len(rows)} transcription models (prices from the OpenRouter models API)')
    print(f'{"slug":52} {"pricing":10} {"$/min":>9} {"$/hour":>9}  notes')
    for p in rows:
        notes = []
        if p['kind'] == 'tokens':
            notes.append(f'token-priced in {p["prompt"]:.3g}/out {p["completion"]:.3g} per token, rate estimated')
        if p['suspicious']:
            notes.append('price looks per-minute or per-request, check')
        if p['mentions_word_timestamps']:
            notes.append('describes word timestamps')
        elif p['mentions_timestamps']:
            notes.append('describes timestamps')
        if p['id'] in DEFAULT_MODELS:
            notes.append('default set')
        print(f'{p["id"]:52} {p["kind"]:10} {p["per_hour"] / 60:9.5f} {p["per_hour"]:9.4f}  {"; ".join(notes)}')
    return 0


# --------------------------------------------------------------------------
# Requests


def multipart_body(fields: list[tuple[str, str]], file_field: str,
                   filename: str, content: bytes, content_type: str) -> tuple[bytes, str]:
    boundary = f'----chatloom{random.getrandbits(64):016x}'
    parts: list[bytes] = []
    for name, value in fields:
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
            f'{value}\r\n'.encode())
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; '
        f'filename="{filename}"\r\nContent-Type: {content_type}\r\n\r\n'.encode())
    parts.append(content)
    parts.append(f'\r\n--{boundary}--\r\n'.encode())
    return b''.join(parts), f'multipart/form-data; boundary={boundary}'


def request_options(model: str, verbose: bool, language: str | None,
                    provider: dict | None, temperature: float | None) -> dict:
    """The request's parameters without audio (also saved with the result)."""
    options: dict = {'model': model, 'response_format': 'verbose_json' if verbose else 'json'}
    if verbose:
        options['timestamp_granularities'] = ['segment', 'word']
    if language:
        options['language'] = language
    if temperature is not None:
        options['temperature'] = temperature
    if provider:
        options['provider'] = provider
    return options


def build_request(options: dict, audio: bytes, transport: str) -> tuple[bytes, str]:
    if transport == 'json':
        body = dict(options)
        body['input_audio'] = {'data': base64.b64encode(audio).decode('ascii'), 'format': 'mp3'}
        return json.dumps(body).encode(), 'application/json'
    fields = []
    for key, value in options.items():
        if key == 'provider':
            continue  # multipart has no routing object; JSON transport only
        if isinstance(value, list):
            fields.extend((f'{key}[]', str(v)) for v in value)
        else:
            fields.append((key, str(value)))
    return multipart_body(fields, 'file', 'audio.mp3', audio, 'audio/mpeg')


def classify_exception(error: BaseException) -> str:
    """'never_sent' when the provider cannot have processed the request."""
    reason = getattr(error, 'reason', error)
    if isinstance(reason, (ConnectionRefusedError, socket.gaierror)):
        return 'never_sent'
    if isinstance(reason, OSError) and getattr(reason, 'errno', None) in (101, 111, 113):
        return 'never_sent'
    return 'uncertain'


def post(url: str, body: bytes, content_type: str, key: str,
         timeout: float) -> tuple[int, dict, bytes]:
    request = urllib.request.Request(url, data=body, method='POST', headers={
        'Authorization': f'Bearer {key}',
        'Content-Type': content_type,
        'User-Agent': USER_AGENT,
        'X-Title': 'ChatLoom STT comparison',
    })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers or {}), error.read()


def parse_json(raw: bytes):
    try:
        return json.loads(raw.decode('utf-8', 'replace'))
    except json.JSONDecodeError:
        return None


def retry_wait(attempt: int, headers: dict) -> float:
    wait = float(1 << (attempt - 1))
    value = {k.lower(): v for k, v in headers.items()}.get('retry-after')
    try:
        if value is not None and float(value) > wait:
            wait = min(float(value), 20.0)
    except ValueError:
        pass
    return wait


def send_with_retries(options: dict, audio: bytes, transport: str, key: str,
                      poster=post, sleep=time.sleep, timeout: float = REQUEST_TIMEOUT) -> dict:
    """One logical request. Retries only answers that prove the request was
    not processed (429/502/503, connection never opened), like the worker;
    timeouts and other 5xx are 'paid_unknown' and never retried."""
    body, content_type = build_request(options, audio, transport)
    started = time.monotonic()
    for attempt in range(1, ATTEMPTS + 1):
        attempt_start = time.monotonic()
        try:
            status, headers, raw = poster(TRANSCRIBE_URL, body, content_type, key, timeout)
        except Exception as error:  # noqa: BLE001 - classified below
            if classify_exception(error) == 'never_sent' and attempt < ATTEMPTS:
                sleep(retry_wait(attempt, {}))
                continue
            return {'outcome': 'never_sent' if classify_exception(error) == 'never_sent' else 'paid_unknown',
                    'http_status': None, 'error': type(error).__name__,
                    'attempts': attempt, 'total_s': time.monotonic() - started}
        latency = time.monotonic() - attempt_start
        payload = parse_json(raw)
        generation = {k.lower(): v for k, v in headers.items()}.get('x-generation-id')
        result = {'http_status': status, 'attempts': attempt, 'latency_s': latency,
                  'total_s': time.monotonic() - started, 'generation_id': generation}
        if status == 200 and isinstance(payload, dict):
            return {**result, 'outcome': 'ok', 'response': payload}
        result['error_body'] = payload if payload is not None else raw[:2000].decode('utf-8', 'replace')
        if status in RETRYABLE_STATUS and attempt < ATTEMPTS:
            sleep(retry_wait(attempt, headers))
            continue
        if status == 200 or (status >= 500 and status not in (502, 503)):
            return {**result, 'outcome': 'paid_unknown'}
        return {**result, 'outcome': 'rejected'}
    raise AssertionError('unreachable')


class Budget:
    """Hard cap: a call starts only if its reservation still fits."""

    def __init__(self, cap: float):
        self.cap = cap
        self.spent = 0.0
        self.reserved = 0.0
        self.lock = threading.Lock()

    def reserve(self, amount: float) -> bool:
        with self.lock:
            if self.spent + self.reserved + amount > self.cap + 1e-12:
                return False
            self.reserved += amount
            return True

    def settle(self, reserved: float, actual: float) -> None:
        with self.lock:
            self.reserved -= reserved
            self.spent += actual


def usage_cost(response: dict | None) -> float | None:
    usage = response.get('usage') if isinstance(response, dict) else None
    cost = usage.get('cost') if isinstance(usage, dict) else None
    return float(cost) if isinstance(cost, (int, float)) else None


def transcribe_one(job: dict, key: str, budget: Budget, args, poster=post,
                   sleep=time.sleep) -> dict:
    """verbose_json with segment+word timestamps, json after a 400."""
    record = {
        'schema': SCHEMA, 'model': job['model'], 'sample': job['sample'],
        'audio': job['audio_meta'], 'status': 'error', 'fallback': None,
    }
    formats = [True, False] if not args.json_only else [False]
    for verbose in formats:
        options = request_options(job['model'], verbose, args.language_param,
                                  args.provider, args.temperature)
        reservation = job['estimate'] * BUDGET_MARGIN
        if not budget.reserve(reservation):
            record['status'] = 'skipped_budget'
            record['error'] = f'budget cap ${budget.cap:.4f} reached'
            break
        outcome = send_with_retries(options, job['audio'], args.transport, key,
                                    poster=poster, sleep=sleep)
        cost = usage_cost(outcome.get('response'))
        if outcome['outcome'] == 'ok':
            budget.settle(reservation, cost if cost is not None else job['estimate'])
        elif outcome['outcome'] == 'paid_unknown':
            budget.settle(reservation, job['estimate'])
        else:
            budget.settle(reservation, 0.0)
        record['request'] = {k: v for k, v in options.items() if k != 'model'}
        record['request']['transport'] = args.transport
        for field in ('http_status', 'attempts', 'latency_s', 'total_s',
                      'generation_id', 'error', 'error_body'):
            if field in outcome:
                record[field] = outcome[field]
        if outcome['outcome'] == 'ok':
            record['status'] = 'ok'
            record['response'] = outcome['response']
            record['cost'] = cost
            record['cost_estimated'] = cost is None
            break
        record['status'] = outcome['outcome']
        if verbose and outcome['outcome'] == 'rejected' and outcome.get('http_status') == 400:
            record['fallback'] = 'json after verbose_json was rejected (400): no timestamps'
            record['verbose_error'] = outcome.get('error_body')
            continue
        break
    return record


# --------------------------------------------------------------------------
# Planning and running


def load_prices(models: list[str], args) -> dict[str, dict]:
    available = {m.get('id'): price_info(m) for m in fetch_models(args.models_json)}
    prices = {}
    missing = [m for m in models if m not in available]
    if missing:
        raise HarnessError('unknown model slug(s): ' + ', '.join(missing)
                           + ' (see --list-models)')
    for model in models:
        prices[model] = available[model]
    return prices


def plan(samples: list[Path], models: list[str], prices: dict, args) -> dict:
    entries = []
    for path in samples:
        duration = probe_duration(path, args.ffprobe)
        entry = {'path': path, 'sample': sample_name(path), 'duration': duration,
                 'send_bytes': int(duration * SEND_BYTES_PER_SECOND) + 1000,
                 'skip': None}
        if duration > args.max_duration:
            entry['skip'] = f'longer than --max-duration {args.max_duration:.0f}s'
        elif entry['send_bytes'] > MAX_UPLOAD_BYTES:
            entry['skip'] = 'converted upload would exceed 25 MB'
        entries.append(entry)
    calls = []
    for entry in entries:
        if entry['skip']:
            continue
        for model in models:
            calls.append({'sample': entry['sample'], 'model': model,
                          'estimate': estimate_cost(prices[model], entry['duration'])})
    total = sum(c['estimate'] for c in calls)
    return {'entries': entries, 'calls': calls, 'total': total}


def print_plan(planned: dict, models: list[str], prices: dict, args) -> None:
    print('Samples (duration from ffprobe; upload = worker format, mono 16 kHz MP3 32 kbit/s):')
    for e in planned['entries']:
        note = f'  SKIP: {e["skip"]}' if e['skip'] else ''
        print(f'  {e["sample"]:40} {e["duration"]:8.2f} s  ~{e["send_bytes"] / 1000:8.1f} kB{note}')
    seconds = sum(e['duration'] for e in planned['entries'] if not e['skip'])
    print(f'Audio to send: {seconds:.1f} s ({seconds / 60:.2f} min) per model')
    print('Models:')
    for model in models:
        p = prices[model]
        cost = sum(c['estimate'] for c in planned['calls'] if c['model'] == model)
        flag = ' (token-priced: rough)' if p['kind'] == 'tokens' else ''
        flag += ' (price looks odd)' if p['suspicious'] else ''
        print(f'  {model:44} ${p["per_hour"]:8.4f}/h  est ${cost:.5f}{flag}')
    print(f'Planned calls: {len(planned["calls"])} (a verbose_json 400 adds one json call, rejected calls are not billed)')
    print(f'Request: response_format=verbose_json, timestamp_granularities=[segment, word], '
          f'language={args.language_param or "auto"}, transport={args.transport}, '
          f'provider={json.dumps(args.provider) if args.provider else "default"}, concurrency={args.concurrency}')
    margin = planned['total'] * BUDGET_MARGIN
    print(f'Estimated total: ${planned["total"]:.5f} (budget reservations with margin ${margin:.5f}); '
          f'cap --max-cost ${args.max_cost:.4f}')
    if margin > args.max_cost:
        print('  WARNING: the cap will stop the run before every call is made; raise --max-cost or trim samples/models.')


def execute(planned: dict, models: list[str], prices: dict, args, key: str,
            run_dir: Path, poster=post, sleep=time.sleep) -> list[dict]:
    budget = Budget(args.max_cost)
    records: list[dict] = []
    with tempfile.TemporaryDirectory(prefix='stt-compare-') as temp:
        jobs = []
        for entry in planned['entries']:
            if entry['skip']:
                continue
            target = Path(temp) / f'{entry["sample"]}.mp3'
            if args.no_convert and entry['path'].suffix.lower() == '.mp3':
                shutil.copyfile(entry['path'], target)
            else:
                convert_for_upload(entry['path'], target, args.ffmpeg)
            audio = target.read_bytes()
            if len(audio) > MAX_UPLOAD_BYTES:
                print(f'skip {entry["sample"]}: upload over 25 MB', file=sys.stderr)
                continue
            sent = probe_duration(target, args.ffprobe)
            meta = {'duration_s': entry['duration'], 'sent_duration_s': sent,
                    'bytes': len(audio), 'format': 'mp3'}
            for model in models:
                jobs.append({'model': model, 'sample': entry['sample'], 'audio': audio,
                             'audio_meta': meta,
                             'estimate': estimate_cost(prices[model], entry['duration'])})
        # Interleave models so a budget stop leaves comparable coverage.
        jobs.sort(key=lambda j: ([e['sample'] for e in planned['entries']].index(j['sample']),
                                 models.index(j['model'])))
        lock = threading.Lock()

        def work(job):
            record = transcribe_one(job, key, budget, args, poster=poster, sleep=sleep)
            path = run_dir / model_dir_name(job['model']) / f'{job["sample"]}.json'
            write_private(path, json.dumps(record, ensure_ascii=False, indent=1))
            with lock:
                cost = record.get('cost')
                print(f'  {record["status"]:14} {job["model"]:40} {job["sample"]:30} '
                      f'{record.get("latency_s", 0):6.2f} s  '
                      f'{"$%.6f" % cost if cost is not None else "-":>10}'
                      f'{"  (json fallback)" if record.get("fallback") else ""}')
            return record

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            records = list(pool.map(work, jobs))
    print(f'Spent ${budget.spent:.6f} of ${args.max_cost:.4f} (usage.cost, estimate where missing)')
    return records


# --------------------------------------------------------------------------
# Analysis


def normalise(text: str) -> list[str]:
    """Lowercase words without punctuation; Polish diacritics are kept."""
    text = unicodedata.normalize('NFC', text or '').lower()
    text = re.sub(r"['’ʼ`]", '', text)  # apostrophes join (don't -> dont)
    out = []
    for ch in text:
        category = unicodedata.category(ch)
        out.append(ch if category[0] in 'LNM' else ' ')
    return ''.join(out).split()


def edit_distance(a: list[str], b: list[str]) -> int:
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def wer(reference: list[str], hypothesis: list[str]) -> float | None:
    if not reference:
        return None if not hypothesis else 1.0
    return edit_distance(reference, hypothesis) / len(reference)


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(q * len(ordered)) - 1)]


def _spans(raw) -> list[dict] | None:
    if not isinstance(raw, list):
        return None
    spans = []
    for item in raw:
        if not isinstance(item, dict):
            return None
        start, end = item.get('start'), item.get('end')
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            return None
        spans.append({'start': float(start), 'end': float(end),
                      'text': item.get('word', item.get('text', ''))})
    return spans


def timestamps_of(response: dict | None) -> dict:
    """Timestamp level and shape notes of one answer."""
    response = response if isinstance(response, dict) else {}
    words = _spans(response.get('words'))
    segments = _spans(response.get('segments'))
    notes = []
    nested = None
    if not words and isinstance(response.get('segments'), list):
        flat = []
        for segment in response['segments']:
            if isinstance(segment, dict) and isinstance(segment.get('words'), list):
                flat.extend(segment['words'])
        nested = _spans(flat) if flat else None
        if nested:
            notes.append('words only nested in segments[].words (worker reads top-level words)')
    if response.get('words') is not None and words is None:
        notes.append('words present but not {word,start,end}')
    if response.get('segments') is not None and segments is None:
        notes.append('segments present but not {text,start,end}')
    if words and any(not str(w['text']).strip() for w in words):
        notes.append('blank word entries (spacing tokens?)')
    level = 'word' if (words or nested) else 'segment' if segments else 'none'
    return {'level': level, 'words': words or nested or [], 'segments': segments or [],
            'notes': notes}


def span_sanity(spans: list[dict], duration: float, tolerance: float = 0.5) -> dict:
    if not spans:
        return {'count': 0}
    non_monotonic = sum(1 for a, b in zip(spans, spans[1:]) if b['start'] < a['start'] - 1e-6)
    inverted = sum(1 for s in spans if s['end'] < s['start'] - 1e-6)
    outside = sum(1 for s in spans if s['start'] < -1e-6 or s['end'] > duration + tolerance)
    overlaps = sum(1 for a, b in zip(spans, spans[1:]) if b['start'] < a['end'] - 0.05)
    gaps = [b['start'] - a['end'] for a, b in zip(spans, spans[1:])]
    return {
        'count': len(spans), 'non_monotonic': non_monotonic, 'inverted': inverted,
        'outside_duration': outside, 'overlaps': overlaps,
        'max_gap': max(gaps) if gaps else 0.0,
        'gaps_over_2s': sum(1 for g in gaps if g > 2.0),
        'first_start': spans[0]['start'], 'last_end': max(s['end'] for s in spans),
    }


def load_run(run_dir: Path) -> tuple[dict, list[dict]]:
    meta_path = run_dir / 'run.json'
    meta = json.loads(meta_path.read_text(encoding='utf-8')) if meta_path.exists() else {}
    records = []
    for path in sorted(run_dir.glob('*/*.json')):
        try:
            record = json.loads(path.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict) and record.get('schema') == SCHEMA:
            record['_path'] = str(path)
            records.append(record)
    return meta, records


def text_of(record: dict) -> str:
    response = record.get('response')
    text = response.get('text') if isinstance(response, dict) else None
    return text.strip() if isinstance(text, str) else ''


def md_cell(text: str) -> str:
    return (text.replace('\\', '\\\\').replace('|', '\\|')
            .replace('\r', ' ').replace('\n', ' <br> ')) or '∅'


def fmt(value, pattern='{:.2f}', missing='–'):
    return missing if value is None else pattern.format(value)


def analyse(meta: dict, records: list[dict], reference: str | None) -> dict:
    models = meta.get('models') or sorted({r['model'] for r in records})
    for r in records:
        if r['model'] not in models:
            models.append(r['model'])
    samples = sorted({r['sample'] for r in records})
    by = {(r['model'], r['sample']): r for r in records}
    tokens = {key: normalise(text_of(r)) for key, r in by.items() if r.get('status') == 'ok'}
    per_model = {}
    flags: list[str] = []
    sanity: dict = {}
    for model in models:
        rows = [by[(model, s)] for s in samples if (model, s) in by]
        ok = [r for r in rows if r.get('status') == 'ok']
        latencies = [r['latency_s'] for r in ok if isinstance(r.get('latency_s'), (int, float))]
        audio = sum(r['audio']['duration_s'] for r in ok)
        rtf = (sum(latencies) / audio) if ok and audio > 0 else None
        cost = sum(r.get('cost') or 0 for r in ok)
        estimated = any(r.get('cost_estimated') for r in ok)
        levels = {'word': 0, 'segment': 0, 'none': 0}
        words = 0
        billed = 0.0
        for r in ok:
            ts = timestamps_of(r.get('response'))
            levels[ts['level']] += 1
            words += len(tokens.get((model, r['sample']), []))
            usage = r['response'].get('usage') if isinstance(r.get('response'), dict) else None
            if isinstance(usage, dict) and isinstance(usage.get('seconds'), (int, float)):
                billed += usage['seconds']
            duration = r['audio']['duration_s']
            sanity[(model, r['sample'])] = {
                'level': ts['level'], 'notes': ts['notes'],
                'words': span_sanity(ts['words'], duration),
                'segments': span_sanity(ts['segments'], duration),
                'duration': duration,
                'provider_duration': r['response'].get('duration'),
            }
        per_model[model] = {
            'calls': len(rows), 'ok': len(ok),
            'failed': [f'{r["sample"]}: {r.get("status")} {r.get("http_status") or ""}'.strip()
                       for r in rows if r.get('status') != 'ok'],
            'fallbacks': sum(1 for r in ok if r.get('fallback')),
            'mean_latency': sum(latencies) / len(latencies) if latencies else None,
            'p95_latency': percentile(latencies, 0.95),
            'rtf': rtf, 'cost': cost, 'cost_estimated': estimated,
            'per_hour': cost / audio * 3600 if audio > 0 and ok else None,
            'audio_s': audio, 'billed_s': billed or None,
            'levels': levels, 'words': words,
        }
    # Empty or truncated outputs.
    for sample in samples:
        counts = {m: len(tokens[(m, sample)]) for m in models if (m, sample) in tokens}
        for model, count in counts.items():
            others = sorted(c for m, c in counts.items() if m != model)
            median = others[len(others) // 2] if others else None
            if count == 0:
                flags.append(f'`{model}` / `{sample}`: empty transcript')
            elif median and median >= 10 and count < 0.6 * median:
                flags.append(f'`{model}` / `{sample}`: {count} words vs median {median} of the others (possibly truncated)')
            elif median and count > 1.6 * median and median >= 10:
                flags.append(f'`{model}` / `{sample}`: {count} words vs median {median} of the others (repetition/hallucination?)')
            s = sanity.get((model, sample))
            if s and s['words'].get('count'):
                if s['words']['last_end'] < 0.7 * s['duration'] and count < (median or count):
                    flags.append(f'`{model}` / `{sample}`: last word ends at {s["words"]["last_end"]:.1f} s of {s["duration"]:.1f} s')
    # Pairwise WER (corpus level over samples both transcribed).
    pairwise: dict = {}
    for hyp in models:
        for ref in models:
            if hyp == ref:
                continue
            edits = total = 0
            for sample in samples:
                if (hyp, sample) in tokens and (ref, sample) in tokens:
                    r_tokens = tokens[(ref, sample)]
                    edits += edit_distance(r_tokens, tokens[(hyp, sample)])
                    total += len(r_tokens)
            pairwise[(hyp, ref)] = edits / total if total else None
    agreement = {}
    for model in models:
        values = [pairwise[(model, other)] for other in models
                  if other != model and pairwise.get((model, other)) is not None]
        agreement[model] = sum(values) / len(values) if values else None
    return {'models': models, 'samples': samples, 'by': by, 'per_model': per_model,
            'pairwise': pairwise, 'agreement': agreement, 'flags': flags,
            'sanity': sanity, 'reference': reference if reference in models else None}


def anchor_check(records: list[dict], dart: str | None) -> dict | None:
    """Runs the worker's chunkTimestamps/transcriptTimingRecord on each saved
    answer (anchor_check.dart). None when Dart or the worker setup is absent."""
    dart = dart or shutil.which('dart')
    config = WORKER_ROOT / '.dart_tool' / 'package_config.json'
    paths = [r['_path'] for r in records if r.get('status') == 'ok' and r.get('_path')]
    if not dart or not config.exists() or not ANCHOR_CHECK.exists() or not paths:
        return None
    result = subprocess.run(
        [dart, f'--packages={config}', str(ANCHOR_CHECK), *paths],
        capture_output=True, text=True, check=False, timeout=300,
    )
    if result.returncode != 0:
        return {'error': (result.stderr or result.stdout)[-800:]}
    try:
        rows = json.loads(result.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return {'error': 'unreadable anchor_check output'}
    return {'rows': rows}


def render_report(meta: dict, analysis: dict, anchors: dict | None) -> str:
    models, samples, per = analysis['models'], analysis['samples'], analysis['per_model']
    ref = analysis['reference']
    lines = ['# Speech-to-text comparison', '']
    lines.append(f'Run: {meta.get("started", "?")} · language: {meta.get("language") or "auto"} · '
                 f'transport: {meta.get("transport", "?")} · provider: '
                 f'{json.dumps(meta.get("provider")) if meta.get("provider") else "default"} · '
                 f'cap ${meta.get("max_cost", 0):.4f}')
    lines.append(f'Samples: {len(samples)} · models: {len(models)} · reference: {ref or "none"}')
    lines.append('')
    lines.append('Uploads use the worker format (mono 16 kHz MP3, 32 kbit/s). Latency is the '
                 'wall-clock time of the successful HTTP request (upload + processing). RTF = '
                 'latency / audio duration (lower is faster). Cost is `usage.cost`; $/h is '
                 'cost per hour of audio sent.')
    lines += ['', '## Per model', '',
              '| Model | OK | Mean latency s | p95 latency s | RTF | Cost $ | $/h | List $/h | '
              'Billed s / audio s | Timestamps word/segment/none | Words | Mean WER vs others | WER vs reference |',
              '|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    prices = meta.get('prices', {})
    for model in models:
        p = per[model]
        vs_ref = analysis['pairwise'].get((model, ref)) if ref and model != ref else None
        list_price = prices.get(model, {}).get('per_hour')
        lines.append(
            f'| `{model}` | {p["ok"]}/{p["calls"]} | {fmt(p["mean_latency"])} | {fmt(p["p95_latency"])} | '
            f'{fmt(p["rtf"], "{:.3f}")} | {fmt(p["cost"], "{:.6f}")}{"*" if p["cost_estimated"] else ""} | '
            f'{fmt(p["per_hour"], "{:.4f}")} | {fmt(list_price, "{:.4f}")} | '
            f'{fmt(p["billed_s"], "{:.1f}")} / {p["audio_s"]:.1f} | '
            f'{p["levels"]["word"]}/{p["levels"]["segment"]}/{p["levels"]["none"]} | {p["words"]} | '
            f'{fmt(analysis["agreement"][model], "{:.1%}")} | {fmt(vs_ref, "{:.1%}") if model != ref else "ref"} |')
    if any(per[m]['cost_estimated'] for m in models):
        lines.append('')
        lines.append('\\* no `usage.cost` in at least one answer; the list-price estimate was used.')
    failed = [(m, f) for m in models for f in per[m]['failed']]
    fallbacks = [m for m in models if per[m]['fallbacks']]
    if failed or fallbacks:
        lines.append('')
        for m in fallbacks:
            lines.append(f'- `{m}` rejected `verbose_json` (400) on {per[m]["fallbacks"]} sample(s); json fallback, no timestamps.')
        for m, f in failed:
            lines.append(f'- `{m}` failed: {f}')
    lines += ['', '## Pairwise word error rate', '',
              'Row = hypothesis, column = reference. Normalisation: NFC, lowercase, punctuation '
              'and symbols removed, apostrophes joined, Polish diacritics kept; numbers are not '
              'spelled out, so "5" vs "pięć" counts as an error. Corpus-level over samples both '
              'models transcribed. Between models this is disagreement, not accuracy.', '',
              '| hyp \\ ref | ' + ' | '.join(f'`{m.split("/")[-1]}`' for m in models) + ' |',
              '|---' * (len(models) + 1) + '|']
    for hyp in models:
        cells = ['–' if hyp == ref_m else fmt(analysis['pairwise'].get((hyp, ref_m)), '{:.1%}')
                 for ref_m in models]
        lines.append(f'| `{hyp.split("/")[-1]}` | ' + ' | '.join(cells) + ' |')
    lines += ['', '## Flags', '']
    lines += [f'- {f}' for f in analysis['flags']] or ['- none']
    lines += ['', '## Timestamp sanity', '',
              'Per answer: level, word/segment counts, non-monotonic starts, inverted spans, '
              'spans beyond the audio (+0.5 s), overlaps, gaps > 2 s, largest gap, last end vs duration.', '',
              '| Model | Sample | Level | Words | Segs | Non-mono | Inverted | Outside | Overlaps | Gaps >2s | Max gap s | Last end / dur s | Notes |',
              '|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    for model in models:
        for sample in samples:
            s = analysis['sanity'].get((model, sample))
            if not s:
                continue
            w, g = s['words'], s['segments']
            main = w if w.get('count') else g
            bad = lambda key: (w.get(key, 0) or 0) + (g.get(key, 0) or 0)  # noqa: E731
            last = main.get('last_end')
            lines.append(
                f'| `{model.split("/")[-1]}` | `{sample}` | {s["level"]} | {w.get("count", 0)} | {g.get("count", 0)} | '
                f'{bad("non_monotonic")} | {bad("inverted")} | {bad("outside_duration")} | {bad("overlaps")} | '
                f'{main.get("gaps_over_2s", "–")} | {fmt(main.get("max_gap"))} | '
                f'{fmt(last, "{:.1f}")} / {s["duration"]:.1f} | {md_cell("; ".join(s["notes"])) if s["notes"] else ""} |')
    lines += ['', '## Worker timestamp anchoring', '']
    if anchors is None:
        lines.append('NOT RUN (Dart or `worker/.dart_tool/package_config.json` missing, or no answers). '
                     'Re-run with `--report DIR --dart <dart>` after `dart pub get` in the worker.')
    elif 'error' in anchors:
        lines.append('anchor_check.dart failed: `' + md_cell(anchors['error'][-300:]) + '`')
    else:
        lines += ['`chunkTimestamps` + `transcriptTimingRecord` from `worker/lib/src/transcript_timestamps.dart` '
                  'on each saved answer: would the worker keep these timestamps?', '',
                  '| Model | Sample | Raw segs | Raw words | Anchored segs | Anchored words | Timing record | Note |',
                  '|---|---|---|---|---|---|---|---|']
        for row in anchors['rows']:
            lines.append(
                f'| `{str(row.get("model", "")).split("/")[-1]}` | `{row.get("sample")}` | {row.get("raw_segments")} | '
                f'{row.get("raw_words")} | {row.get("segments")} | {row.get("words")} | '
                f'{"yes (%s B)" % row.get("timing_bytes") if row.get("timing") else "no"} | {md_cell(row["note"]) if row.get("note") else ""} |')
    lines += ['', '## Transcripts per sample', '']
    for sample in samples:
        duration = next((analysis['by'][(m, sample)]['audio']['duration_s'] for m in models
                         if (m, sample) in analysis['by']), None)
        lines += [f'### `{sample}` ({fmt(duration, "{:.1f}")} s)', '',
                  '| Model | Latency s | Words | WER vs ref | Timestamps | Transcript |', '|---|---|---|---|---|---|']
        ref_tokens = normalise(text_of(analysis['by'][(ref, sample)])) if ref and (ref, sample) in analysis['by'] else None
        for model in models:
            r = analysis['by'].get((model, sample))
            if not r:
                continue
            if r.get('status') != 'ok':
                lines.append(f'| `{model.split("/")[-1]}` | – | – | – | – | **{r.get("status")}** {r.get("http_status") or ""} |')
                continue
            tokens = normalise(text_of(r))
            vs = wer(ref_tokens, tokens) if ref_tokens is not None and model != ref else None
            lines.append(
                f'| `{model.split("/")[-1]}` | {fmt(r.get("latency_s"))} | {len(tokens)} | '
                f'{"ref" if model == ref else fmt(vs, "{:.1%}")} | {analysis["sanity"][(model, sample)]["level"]} | '
                f'{md_cell(text_of(r))} |')
        lines.append('')
    return '\n'.join(lines) + '\n'


def write_report(run_dir: Path, reference: str | None, dart: str | None,
                 skip_dart: bool = False) -> Path:
    meta, records = load_run(run_dir)
    if not records:
        raise HarnessError(f'no results in {run_dir}')
    analysis = analyse(meta, records, reference or meta.get('reference'))
    anchors = None if skip_dart else anchor_check(records, dart)
    report = run_dir / 'report.md'
    write_private(report, render_report(meta, analysis, anchors))
    return report


# --------------------------------------------------------------------------
# CLI


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--list-models', action='store_true', help='free: list transcription models and prices')
    mode.add_argument('--run', action='store_true', help='paid: transcribe every sample with every model')
    mode.add_argument('--report', metavar='RUN_DIR', help='rebuild report.md of an earlier run (offline)')
    mode.add_argument('--smoke', action='store_true', help='paid (< $0.001): 2 s synthetic tone, one model')
    parser.add_argument('--dry-run', action='store_true',
                        help='plan and estimate only, no paid call (alone, or with --run/--smoke)')
    parser.add_argument('--models', default=','.join(DEFAULT_MODELS), help='comma-separated OpenRouter slugs')
    parser.add_argument('--reference', default=DEFAULT_REFERENCE, help='model used as the WER reference')
    parser.add_argument('--samples', action='append', help=f'sample file or folder (default {DEFAULT_SAMPLES})')
    parser.add_argument('--out', default=str(DEFAULT_OUT), help='results root; a timestamped run folder is created')
    parser.add_argument('--language', default='auto', help='ISO-639-1 code, or auto (default) to omit it')
    parser.add_argument('--max-cost', type=float, default=0.50, help='hard budget cap in USD (default 0.50)')
    parser.add_argument('--concurrency', type=int, default=2)
    parser.add_argument('--max-duration', type=float, default=900.0,
                        help='skip samples longer than this many seconds (worker chunk length 900)')
    parser.add_argument('--transport', choices=['json', 'multipart'], default='json',
                        help='json (input_audio base64, carries provider prefs) or multipart (worker-like)')
    parser.add_argument('--data-collection', choices=['deny', 'allow'], default='deny',
                        help='provider data_collection preference (default deny)')
    parser.add_argument('--zdr', action='store_true', help='require zero-data-retention endpoints')
    parser.add_argument('--temperature', type=float, default=None)
    parser.add_argument('--json-only', action='store_true', help='skip verbose_json (no timestamps)')
    parser.add_argument('--no-convert', action='store_true', help='send .mp3 samples unchanged')
    parser.add_argument('--key-file', default=DEFAULT_KEY_FILE)
    parser.add_argument('--models-json', help='saved models API answer instead of the live GET (offline)')
    parser.add_argument('--dart', help='Dart executable for the worker anchoring check (default: dart on PATH)')
    parser.add_argument('--no-dart', action='store_true', help='skip the worker anchoring check')
    parser.add_argument('--allow-in-repo', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--ffprobe', default='ffprobe')
    args = parser.parse_args(argv)
    args.models_list = [m.strip() for m in args.models.split(',') if m.strip()]
    args.language_param = None if args.language in ('', 'auto') else args.language
    provider: dict = {}
    if args.data_collection == 'deny':
        provider['data_collection'] = 'deny'
    if args.zdr:
        provider['zdr'] = True
    args.provider = provider or None
    if not (args.list_models or args.run or args.report or args.smoke or args.dry_run):
        parser.error('choose --list-models, --dry-run, --run, --report or --smoke')
    if args.dry_run and (args.list_models or args.report):
        parser.error('--dry-run combines only with --run or --smoke')
    if args.concurrency < 1 or args.max_cost <= 0:
        parser.error('--concurrency must be >= 1 and --max-cost > 0')
    return args


def run_mode(args, samples: list[Path], models: list[str], label: str = '') -> int:
    prices = load_prices(models, args)
    planned = plan(samples, models, prices, args)
    print_plan(planned, models, prices, args)
    if args.dry_run:
        print('Dry run: no request was sent.')
        return 0
    out = Path(args.out).expanduser().resolve()
    guard_out_dir(out, args.allow_in_repo)
    key = read_key(args.key_file)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + label
    run_dir = private_dir(out / stamp)
    meta = {
        'schema': SCHEMA, 'started': stamp, 'models': models, 'reference': args.reference,
        'language': args.language_param, 'transport': args.transport, 'provider': args.provider,
        'max_cost': args.max_cost, 'concurrency': args.concurrency,
        'prices': {m: {k: prices[m][k] for k in ('kind', 'prompt', 'completion', 'per_hour')} for m in models},
        'samples': {e['sample']: {'duration_s': e['duration'], 'skip': e['skip']} for e in planned['entries']},
    }
    write_private(run_dir / 'run.json', json.dumps(meta, indent=1))
    print(f'Running into {run_dir}')
    execute(planned, models, prices, args, key, run_dir)
    report = write_report(run_dir, args.reference, args.dart, args.no_dart)
    print(f'Report: {report}')
    return 0


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        if args.list_models:
            return list_models(args)
        if args.report:
            report = write_report(Path(args.report).expanduser(), args.reference, args.dart, args.no_dart)
            print(f'Report: {report}')
            return 0
        if args.smoke:
            models = args.models_list if args.models != ','.join(DEFAULT_MODELS) else [SMOKE_MODEL]
            if len(models) != 1:
                raise HarnessError('--smoke takes exactly one model')
            args.max_cost = min(args.max_cost, 0.001)
            args.reference = models[0]
            with tempfile.TemporaryDirectory(prefix='stt-smoke-') as temp:
                tone = Path(temp) / 'smoke-tone-2s.mp3'
                make_tone(tone, 2.0, args.ffmpeg)
                return run_mode(args, [tone], models, '-smoke')
        samples = find_samples(args.samples or [str(DEFAULT_SAMPLES)])
        return run_mode(args, samples, args.models_list)
    except HarnessError as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    except urllib.error.URLError as error:
        print(f'error: network: {getattr(error, "reason", error)}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
