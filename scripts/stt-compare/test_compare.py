#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Offline tests of compare.py: no network, no key, no paid call."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare  # noqa: E402

MODELS = {'data': [
    {'id': 'openai/whisper-large-v3-turbo', 'name': 'Whisper Turbo',
     'pricing': {'prompt': '0.00000333', 'completion': '0'}, 'description': ''},
    {'id': 'elevenlabs/scribe-v2', 'name': 'Scribe',
     'pricing': {'prompt': '0.0000611111111111', 'completion': '0'},
     'description': 'transcribes with word-level timestamps'},
    {'id': 'openai/gpt-transcribe', 'name': 'GPT Transcribe',
     'pricing': {'prompt': '0.000075', 'completion': '0'}, 'description': ''},
    {'id': 'google/token-model', 'name': 'Token',
     'pricing': {'prompt': '0.000002', 'completion': '0.000012'}, 'description': ''},
]}

TEXT = 'Cześć, to jest test. Zażółć gęślą jaźń!'


def verbose(text=TEXT, duration=7.5, cost=0.0004, nested=False):
    words = []
    t = 0.2
    for word in text.split():
        words.append({'word': word, 'start': round(t, 2), 'end': round(t + 0.4, 2)})
        t += 0.5
    segments = [{'id': 0, 'start': 0.0, 'end': 2.6, 'text': ' Cześć, to jest test.'},
                {'id': 1, 'start': 2.7, 'end': t, 'text': ' Zażółć gęślą jaźń!'}]
    answer = {'text': text, 'duration': duration, 'segments': segments,
              'usage': {'seconds': duration, 'cost': cost}}
    if nested:
        segments[0]['words'] = words[:4]
        segments[1]['words'] = words[4:]
    else:
        answer['words'] = words
    return answer


class FakePoster:
    """Scripted answers per model: list of (status, headers, payload)."""

    def __init__(self, script):
        self.script = {k: list(v) for k, v in script.items()}
        self.calls = []

    def __call__(self, url, body, content_type, key, timeout):
        assert url == compare.TRANSCRIBE_URL
        request = json.loads(body) if content_type == 'application/json' else {}
        assert request.get('input_audio', {}).get('format') == 'mp3'
        self.calls.append(request)
        status, headers, payload = self.script[request['model']].pop(0)
        if isinstance(payload, Exception):
            raise payload
        return status, headers, json.dumps(payload).encode()


class Args:
    language_param = 'pl'
    provider = {'data_collection': 'deny'}
    temperature = None
    json_only = False
    transport = 'json'
    max_cost = 0.5
    concurrency = 2
    max_duration = 900.0
    ffmpeg = 'ffmpeg'
    ffprobe = 'ffprobe'
    no_convert = False
    models_json = None


class NormaliseTest(unittest.TestCase):
    def test_keeps_polish_diacritics_and_drops_punctuation(self):
        self.assertEqual(compare.normalise('Zażółć, GĘŚLĄ jaźń!'), ['zażółć', 'gęślą', 'jaźń'])

    def test_nfc_and_apostrophes_and_hyphens(self):
        decomposed = 'Zą'  # a + combining ogonek
        self.assertEqual(compare.normalise(decomposed), ['zą'])
        self.assertEqual(compare.normalise("Don't — e-mail…"), ['dont', 'e', 'mail'])
        self.assertEqual(compare.normalise(''), [])

    def test_wer(self):
        ref = compare.normalise('ala ma kota')
        self.assertEqual(compare.wer(ref, compare.normalise('Ala ma kota.')), 0)
        self.assertAlmostEqual(compare.wer(ref, compare.normalise('ala ma psa')), 1 / 3)
        self.assertAlmostEqual(compare.wer(ref, compare.normalise('ala kota i psa')), 1.0)  # del ma, ins i, ins psa
        self.assertEqual(compare.wer(ref, []), 1.0)
        self.assertIsNone(compare.wer([], []))
        self.assertEqual(compare.edit_distance(['a', 'b'], ['b', 'a', 'b']), 1)

    def test_percentile(self):
        self.assertEqual(compare.percentile([3, 1, 2], 0.95), 3)
        self.assertEqual(compare.percentile(list(range(1, 21)), 0.95), 19)
        self.assertIsNone(compare.percentile([], 0.95))


class TimestampTest(unittest.TestCase):
    def test_levels(self):
        self.assertEqual(compare.timestamps_of(verbose())['level'], 'word')
        nested = compare.timestamps_of(verbose(nested=True))
        self.assertEqual(nested['level'], 'word')
        self.assertTrue(nested['notes'])
        segs = verbose()
        del segs['words']
        self.assertEqual(compare.timestamps_of(segs)['level'], 'segment')
        self.assertEqual(compare.timestamps_of({'text': 'x'})['level'], 'none')

    def test_sanity(self):
        spans = [{'start': 0.0, 'end': 1.0}, {'start': 0.5, 'end': 0.4},
                 {'start': 4.0, 'end': 9.0}]
        s = compare.span_sanity(spans, 8.0)
        self.assertEqual(s['non_monotonic'], 0)
        self.assertEqual(s['inverted'], 1)
        self.assertEqual(s['outside_duration'], 1)
        self.assertEqual(s['overlaps'], 1)
        self.assertEqual(s['gaps_over_2s'], 1)
        self.assertEqual(compare.span_sanity([{'start': 2, 'end': 3}, {'start': 1, 'end': 2}], 5)['non_monotonic'], 1)


class PricingBudgetTest(unittest.TestCase):
    def test_estimates(self):
        prices = {m['id']: compare.price_info(m) for m in MODELS['data']}
        self.assertAlmostEqual(prices['openai/gpt-transcribe']['per_hour'], 0.27)
        self.assertAlmostEqual(compare.estimate_cost(prices['openai/gpt-transcribe'], 60), 0.0045)
        self.assertEqual(prices['google/token-model']['kind'], 'tokens')
        self.assertTrue(prices['elevenlabs/scribe-v2']['mentions_word_timestamps'])
        # Short clips are estimated at the 10 s minimum some endpoints bill.
        self.assertAlmostEqual(compare.estimate_cost(prices['openai/gpt-transcribe'], 0.2), 0.00075)

    def test_budget(self):
        budget = compare.Budget(0.01)
        self.assertTrue(budget.reserve(0.006))
        self.assertFalse(budget.reserve(0.006))
        budget.settle(0.006, 0.001)
        self.assertTrue(budget.reserve(0.009))
        self.assertFalse(budget.reserve(0.0001))


class RequestTest(unittest.TestCase):
    def test_json_body(self):
        options = compare.request_options('m/x', True, 'pl', {'zdr': True}, None)
        body, kind = compare.build_request(options, b'abc', 'json')
        data = json.loads(body)
        self.assertEqual(kind, 'application/json')
        self.assertEqual(data['timestamp_granularities'], ['segment', 'word'])
        self.assertEqual(data['response_format'], 'verbose_json')
        self.assertEqual(data['input_audio'], {'data': 'YWJj', 'format': 'mp3'})
        self.assertEqual(data['provider'], {'zdr': True})

    def test_multipart_body(self):
        options = compare.request_options('m/x', True, None, {'zdr': True}, None)
        body, kind = compare.build_request(options, b'\x00audio', 'multipart')
        self.assertTrue(kind.startswith('multipart/form-data; boundary='))
        self.assertEqual(body.count(b'name="timestamp_granularities[]"'), 2)
        self.assertIn(b'filename="audio.mp3"', body)
        self.assertNotIn(b'provider', body)
        self.assertNotIn(b'language', body)

    def test_retries_and_classification(self):
        waits = []
        poster = FakePoster({'m/x': [(429, {'Retry-After': '3'}, {'error': 'slow'}),
                                     (503, {}, {'error': 'busy'}),
                                     (200, {'X-Generation-Id': 'g1'}, {'text': 'ok'})]})
        options = compare.request_options('m/x', False, None, None, None)
        out = compare.send_with_retries(options, b'a', 'json', 'k', poster=poster, sleep=waits.append)
        self.assertEqual(out['outcome'], 'ok')
        self.assertEqual(out['attempts'], 3)
        self.assertEqual(waits, [3.0, 2.0])
        self.assertEqual(out['generation_id'], 'g1')
        for status, expected in ((500, 'paid_unknown'), (504, 'paid_unknown'), (400, 'rejected'), (401, 'rejected')):
            poster = FakePoster({'m/x': [(status, {}, {'error': 'x'})]})
            out = compare.send_with_retries(options, b'a', 'json', 'k', poster=poster, sleep=waits.append)
            self.assertEqual(out['outcome'], expected, status)
            self.assertEqual(out['attempts'], 1)
        poster = FakePoster({'m/x': [(0, {}, TimeoutError())]})
        out = compare.send_with_retries(options, b'a', 'json', 'k', poster=poster, sleep=waits.append)
        self.assertEqual(out['outcome'], 'paid_unknown')

    def test_key_file_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            key = Path(temp) / 'k'
            key.write_text('sk-test-123\n')
            os.chmod(key, 0o644)
            with self.assertRaises(compare.HarnessError):
                compare.read_key(str(key))
            os.chmod(key, 0o600)
            self.assertEqual(compare.read_key(str(key)), 'sk-test-123')
            with self.assertRaises(compare.HarnessError):
                compare.read_key(str(Path(temp) / 'missing'))


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'needs ffmpeg')
class EndToEndTest(unittest.TestCase):
    """Fake provider answers through execute() and the report."""

    def test_run_and_report(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            samples = temp / 'samples'
            samples.mkdir()
            for name, seconds in (('one', 7.5), ('two', 3.0)):
                subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                                f'sine=frequency=300:duration={seconds}', str(samples / f'{name}.ogg')],
                               check=True)
            models_json = temp / 'models.json'
            models_json.write_text(json.dumps(MODELS))
            args = Args()
            args.models_json = str(models_json)
            models = ['openai/whisper-large-v3-turbo', 'elevenlabs/scribe-v2', 'openai/gpt-transcribe']
            prices = compare.load_prices(models, args)
            planned = compare.plan(compare.find_samples([str(samples)]), models, prices, args)
            poster = FakePoster({
                'openai/whisper-large-v3-turbo': [
                    (200, {}, verbose(TEXT.replace('test', 'tekst'), cost=0.00001)),
                    (200, {}, verbose('Cześć.', duration=3.0, cost=0.00001))],
                'elevenlabs/scribe-v2': [
                    (200, {}, verbose(nested=True)),
                    (200, {}, {'text': '', 'usage': {'seconds': 3, 'cost': 0.0002}})],
                'openai/gpt-transcribe': [
                    (400, {}, {'error': {'message': 'verbose_json not supported'}}),
                    (200, {}, {'text': TEXT, 'usage': {'seconds': 7.5, 'cost': 0.0006}}),
                    (400, {}, {'error': {'message': 'verbose_json not supported'}}),
                    (200, {}, {'text': 'Cześć.', 'usage': {'seconds': 3}})],
            })
            run_dir = temp / 'run'
            compare.write_private(run_dir / 'run.json', json.dumps({
                'schema': 1, 'models': models, 'reference': 'openai/gpt-transcribe',
                'language': 'pl', 'transport': 'json', 'max_cost': 0.5,
                'prices': {m: {'per_hour': prices[m]['per_hour']} for m in models}}))
            args.concurrency = 1  # deterministic order of the scripted answers
            records = compare.execute(planned, models, prices, args, 'fake-key', run_dir,
                                      poster=poster, sleep=lambda s: None)
            self.assertEqual(len(records), 6)
            self.assertTrue(all(c['language'] == 'pl' for c in poster.calls))
            self.assertEqual(sum(1 for c in poster.calls if c['response_format'] == 'json'), 2)
            saved = json.loads((run_dir / 'openai__gpt-transcribe' / 'one.json').read_text())
            self.assertEqual(saved['status'], 'ok')
            self.assertIn('400', saved['fallback'])
            self.assertNotIn('fake-key', (run_dir / 'openai__gpt-transcribe' / 'one.json').read_text())
            self.assertEqual(oct((run_dir / 'run.json').stat().st_mode & 0o777), '0o600')
            report_path = compare.write_report(run_dir, None, None, skip_dart=True)
            report = report_path.read_text()
            self.assertIn('| `openai/whisper-large-v3-turbo` | 2/2 |', report)
            self.assertIn('empty transcript', report)
            self.assertIn('words only nested in segments', report)
            self.assertIn('rejected `verbose_json` (400)', report)
            self.assertIn('Zażółć gęślą jaźń!', report)
            meta, loaded = compare.load_run(run_dir)
            analysis = compare.analyse(meta, loaded, 'openai/gpt-transcribe')
            # Whisper differs from the reference in one word of 7 + 0 of 1.
            self.assertAlmostEqual(analysis['pairwise'][('openai/whisper-large-v3-turbo', 'openai/gpt-transcribe')], 1 / 8)
            self.assertEqual(analysis['per_model']['openai/gpt-transcribe']['levels'], {'word': 0, 'segment': 0, 'none': 2})
            self.assertTrue(analysis['per_model']['openai/gpt-transcribe']['cost_estimated'])

    def test_budget_stops_calls(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            sample = temp / 'long.ogg'
            subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                            'sine=frequency=300:duration=60', str(sample)], check=True)
            models_json = temp / 'models.json'
            models_json.write_text(json.dumps(MODELS))
            args = Args()
            args.models_json = str(models_json)
            args.max_cost = 0.005  # gpt-transcribe 60 s = 0.0045 x 1.25 margin > cap
            models = ['openai/gpt-transcribe']
            prices = compare.load_prices(models, args)
            planned = compare.plan([sample], models, prices, args)
            poster = FakePoster({'openai/gpt-transcribe': []})
            records = compare.execute(planned, models, prices, args, 'k', temp / 'run',
                                      poster=poster, sleep=lambda s: None)
            self.assertEqual(records[0]['status'], 'skipped_budget')
            self.assertEqual(poster.calls, [])


if __name__ == '__main__':
    unittest.main()
