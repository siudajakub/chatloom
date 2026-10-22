# SPDX-License-Identifier: AGPL-3.0-or-later
import copy
from contextlib import closing
from datetime import datetime, timezone
import http.client
import importlib.util
from pathlib import Path
import unittest
import tempfile
import sqlite3
import json
import os
import socket
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sources', Path(__file__).with_name('local_sources.py'))
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


class LocalSourcePolicyTests(unittest.TestCase):
    def setUp(self):
        self.message = {'isDeleted': False, 'behavior': None, 'disappearingTimer': {},
                        'attachments': [{'isVoiceNote': True, 'type': 'audio',
                                         'mimeType': 'audio/ogg', 'fileSize': 10,
                                         'srcURL': 'mxc://fixture/audio'}]}

    def test_only_ordinary_voice_is_exportable(self):
        self.assertIsNotNone(sources.ordinary_voice(self.message))
        for field, value in [('isDeleted', True), ('behavior', {'viewOnce': True}),
                             ('disappearingTimer', {'seconds': 30}),
                             ('extra', {'protected': True})]:
            m = copy.deepcopy(self.message); m[field] = value
            self.assertIsNone(sources.ordinary_voice(m))
        # Videos are never voice notes; Telegram rounds use exportable_media().
        for field, value in [('isVoiceNote', False), ('type', 'video'),
                             ('mimeType', 'application/octet-stream'), ('fileSize', 0),
                             ('extra', {'view_once': True})]:
            m = copy.deepcopy(self.message); m['attachments'][0][field] = value
            self.assertIsNone(sources.ordinary_voice(m))

    def test_existing_transcript_never_changes_source_policy(self):
        self.message['attachments'][0]['transcription'] = {'transcription': 'private fixture'}
        self.assertIsNotNone(sources.ordinary_voice(self.message))
        self.message['attachments'].append(copy.deepcopy(self.message['attachments'][0]))
        self.assertIsNone(sources.ordinary_voice(self.message))

    def test_canonical_restrictions_are_not_lost_when_api_omits_them(self):
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / 'index.db'
            with sqlite3.connect(index) as db:
                db.execute('CREATE TABLE mx_room_messages(id,isDeleted,isEdited,message,roomID,eventID)')
                message = copy.deepcopy(self.message)
                message['disappearingTimer'] = {'seconds': 30}
                db.execute('INSERT INTO mx_room_messages VALUES(1,0,0,?,?,?)',
                           (json.dumps(message), '!fixture:beeper.local', '$fixture'))
            def api(method, path):
                self.assertEqual((method, path), ('GET', '/v1/app/setup'),
                                 'A restricted source must not reach message/media API calls')
                return {'matrix': {'userID': '@fixture:example.invalid'}}
            source = {'conversation': {'roomId': '!fixture:beeper.local', 'accountId': '@fixture:example.invalid'},
                      'eventId': '$fixture'}
            with patch.object(sources, 'INDEX', index), patch.object(sources, 'BeeperAPI') as client:
                client.return_value.request.side_effect = api
                _, attachment = sources.selected_source(source)
                self.assertIsNone(attachment)


def round_message(**attachment):
    base = {'id': 'round', 'type': 'video', 'mimeType': 'video/mp4', 'fileSize': 4096,
            'isVoiceNote': False, 'isGif': False, 'isSticker': False,
            'size': {'width': 384, 'height': 384}, 'duration': 12,
            'srcURL': 'mxc://fixture/round', 'extra': {'fi.mau.telegram.round_message': True}}
    base.update(attachment)
    return {'isDeleted': False, 'behavior': None, 'disappearingTimer': {},
            'accountID': 'local-telegram_ba_fixture', 'attachments': [base]}


class LocalRoundPolicyTests(unittest.TestCase):
    def test_round_with_explicit_flag_is_exportable_as_round(self):
        for flag in ({'extra': {'fi.mau.telegram.round_message': True}},
                     {'extra': None, 'isVideoNote': True},
                     {'extra': {'info': {'round_message': True}}},
                     {'extra': None, 'isRoundVideo': True}):
            with self.subTest(flag=flag):
                attachment, kind = sources.exportable_media(round_message(**flag), kinds=sources.LEGACY_KINDS)
                self.assertEqual(kind, 'round')
                self.assertEqual(attachment['mimeType'], 'video/mp4')
        # A voice note stays a voice note.
        voice = {'attachments': [{'isVoiceNote': True, 'type': 'audio', 'mimeType': 'audio/ogg',
                                  'fileSize': 10}]}
        self.assertEqual(sources.exportable_media(voice, kinds=sources.LEGACY_KINDS)[1], 'voice')

    def test_documented_fallback_needs_telegram_square_and_duration(self):
        message = round_message(extra=None)
        self.assertEqual(sources.exportable_media(message, kinds=sources.LEGACY_KINDS)[1], 'round')
        message['accountID'] = 'local-whatsapp_fixture'
        self.assertEqual(sources.exportable_media(message, kinds=sources.LEGACY_KINDS), (None, None))
        # The requesting device's Telegram room label also qualifies.
        self.assertEqual(sources.exportable_media(message, telegram=True, kinds=sources.LEGACY_KINDS)[1], 'round')
        for missing in ('size', 'duration'):
            with self.subTest(missing=missing):
                m = round_message(extra=None)
                del m['attachments'][0][missing]
                self.assertEqual(sources.exportable_media(m, telegram=True, kinds=sources.LEGACY_KINDS), (None, None))

    def test_round_bounds_and_protections_fail_closed(self):
        cases = [
            {'isGif': True}, {'isSticker': True}, {'mimeType': 'video/quicktime'},
            {'mimeType': 'video/MP4'}, {'type': 'img'}, {'fileSize': 0},
            {'fileSize': sources.ROUND_MAX_BYTES + 1}, {'fileSize': True},
            {'duration': 62}, {'duration': 0}, {'duration': 'long'}, {'durationMs': 62000},
            {'size': {'width': 384, 'height': 216}}, {'size': {'width': 720, 'height': 720}},
            {'size': {'width': 'x', 'height': 384}},
            {'extra': {'fi.mau.telegram.round_message': False}},
            {'extra': {'fi.mau.telegram.round_message': 'yes'}},
            {'extra': {'view_once': True}}, {'extra': {'protected': True}},
            {'extra': {'ttl_seconds': 30}}, {'canExport': False},
        ]
        for patch_ in cases:
            with self.subTest(attachment=patch_):
                self.assertEqual(sources.exportable_media(round_message(**patch_), telegram=True, kinds=sources.LEGACY_KINDS),
                                 (None, None))
        for field, value in [('isDeleted', True), ('behavior', {'viewOnce': True}),
                             ('disappearingTimer', {'seconds': 30}), ('extra', {'protected': True})]:
            with self.subTest(message=field):
                m = round_message(); m[field] = value
                self.assertEqual(sources.exportable_media(m, telegram=True, kinds=sources.LEGACY_KINDS), (None, None))
        two = round_message()
        two['attachments'].append(copy.deepcopy(two['attachments'][0]))
        self.assertEqual(sources.exportable_media(two, telegram=True, kinds=sources.LEGACY_KINDS), (None, None))

    def test_index_video_note_shape_is_a_round(self):
        # Shape observed on the production index (2026-10-18): video/mp4 with
        # isVoiceNote true, length only in extra.duration, no dimensions and
        # no account/network fields on the message.
        def video_note(**attachment):
            base = {'id': 'vn', 'type': 'audio', 'mimeType': 'video/mp4', 'fileSize': 4096,
                    'isVoiceNote': True, 'srcURL': 'mxc://fixture/vn', 'fileName': 'video.mp4',
                    'extra': {'duration': 12}}
            base.update(attachment)
            return {'isDeleted': False, 'behavior': None, 'disappearingTimer': {},
                    'attachments': [base]}
        attachment, kind = sources.exportable_media(video_note(), kinds=sources.LEGACY_KINDS)
        self.assertEqual(kind, 'round')
        self.assertEqual(attachment['mimeType'], 'video/mp4')
        self.assertEqual(sources.duration_ms(attachment), 12000)
        self.assertEqual(sources.exportable_media(video_note(extra={'duration': 12000}), kinds=sources.LEGACY_KINDS)[1], 'round')
        for patch_ in ({'isGif': True}, {'isSticker': True}, {'mimeType': 'video/webm'},
                       {'extra': {'duration': 75}}, {'extra': {'duration': 'long'}},
                       {'isVoiceNote': 'true'}, {'fileSize': sources.ROUND_MAX_BYTES + 1},
                       {'extra': {'duration': 12, 'protected': True}}):
            with self.subTest(attachment=patch_):
                self.assertEqual(sources.exportable_media(video_note(**patch_), kinds=sources.LEGACY_KINDS), (None, None))
        for field, value in [('isDeleted', True), ('behavior', {'viewOnce': True}),
                             ('disappearingTimer', {'seconds': 30})]:
            with self.subTest(message=field):
                m = video_note(); m[field] = value
                self.assertEqual(sources.exportable_media(m, kinds=sources.LEGACY_KINDS), (None, None))
        # The same note typed as video also counts; audio typed MP4 without the
        # voice-note flag, and an unflagged video outside Telegram, do not.
        self.assertEqual(sources.exportable_media(video_note(type='video'), kinds=sources.LEGACY_KINDS)[1], 'round')
        self.assertEqual(sources.exportable_media(video_note(isVoiceNote=False), kinds=sources.LEGACY_KINDS), (None, None))
        self.assertEqual(sources.exportable_media(video_note(type='video', isVoiceNote=False), kinds=sources.LEGACY_KINDS), (None, None))
        # Ordinary voice notes are unchanged.
        voice = video_note(mimeType='audio/ogg')
        self.assertEqual(sources.exportable_media(voice, kinds=sources.LEGACY_KINDS)[1], 'voice')

    def test_duration_units_are_seconds_or_milliseconds(self):
        self.assertEqual(sources.duration_ms({'duration': 12}), 12000)
        self.assertEqual(sources.duration_ms({'duration': 12.4}), 12400)
        self.assertEqual(sources.duration_ms({'duration': 12000}), 12000)
        self.assertEqual(sources.duration_ms({'durationMs': 900}), 900)
        self.assertIsNone(sources.duration_ms({}))
        self.assertEqual(sources.duration_ms({'duration': -1}), -1)

    def test_canonical_round_resolves_api_copy_and_rejects_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / 'index.db'
            canonical = round_message()
            with sqlite3.connect(index) as db:
                db.execute('CREATE TABLE mx_room_messages(id,isDeleted,isEdited,message,roomID,eventID)')
                db.execute('INSERT INTO mx_room_messages VALUES(5,0,0,?,?,?)',
                           (json.dumps(canonical), '!tg:beeper.local', '$round'))
            # The public API omits the flag but keeps documented size/duration.
            api_message = {'id': '5', 'chatID': '!tg:beeper.local',
                           'attachments': [{**canonical['attachments'][0], 'extra': None}]}
            calls = []

            def api(method, path):
                calls.append(path)
                if path == '/v1/app/setup':
                    return {'matrix': {'userID': '@fixture:example.invalid'}}
                return api_message
            source = {'conversation': {'roomId': '!tg:beeper.local', 'accountId': '@fixture:example.invalid',
                                       'network': 'telegram'}, 'eventId': '$round'}
            with patch.object(sources, 'INDEX', index), patch.object(sources, 'BeeperAPI') as client:
                client.return_value.request.side_effect = api
                _, attachment = sources.selected_source(source)
                self.assertEqual(attachment['_kind'], 'round')
                self.assertEqual(len(calls), 2)
                api_message['attachments'][0]['fileSize'] = 4097
                with self.assertRaises(sources.SourceFailure):
                    sources.selected_source(source)
                api_message['attachments'][0]['fileSize'] = 4096
                api_message['attachments'][0]['isVideoNote'] = False
                self.assertIsNone(sources.selected_source(source)[1])

    def test_unflagged_round_may_take_size_and_duration_from_api(self):
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / 'index.db'
            canonical = round_message(extra=None)
            del canonical['attachments'][0]['size']
            del canonical['attachments'][0]['duration']
            del canonical['accountID']
            with sqlite3.connect(index) as db:
                db.execute('CREATE TABLE mx_room_messages(id,isDeleted,isEdited,message,roomID,eventID)')
                db.execute('INSERT INTO mx_room_messages VALUES(5,0,0,?,?,?)',
                           (json.dumps(canonical), '!tg:beeper.local', '$round'))
            api_message = {'id': '5', 'chatID': '!tg:beeper.local',
                           'attachments': [{**canonical['attachments'][0], 'duration': 9,
                                            'size': {'width': 240, 'height': 240}}]}
            calls = []

            def api(method, path):
                calls.append(path)
                if path == '/v1/app/setup':
                    return {'matrix': {'userID': '@fixture:example.invalid'}}
                return api_message
            source = {'conversation': {'roomId': '!tg:beeper.local', 'accountId': '@fixture:example.invalid',
                                       'network': 'telegram'}, 'eventId': '$round'}
            with patch.object(sources, 'INDEX', index), patch.object(sources, 'BeeperAPI') as client:
                client.return_value.request.side_effect = api
                self.assertEqual(sources.selected_source(source)[1]['_kind'], 'round')
                # Not square: not a round, but still an ordinary video.
                api_message['attachments'][0]['size'] = {'width': 640, 'height': 360}
                self.assertEqual(sources.selected_source(source)[1]['_kind'], 'video')
                # Without the Telegram label it is an ordinary video directly.
                calls.clear()
                source['conversation']['network'] = 'whatsapp'
                self.assertEqual(sources.selected_source(source)[1]['_kind'], 'video')
                self.assertEqual(calls[0], '/v1/app/setup')
                # Rounds stay rounds only with the Telegram evidence; with
                # video transcription excluded (legacy kinds) nothing else is.
                self.assertIsNone(sources.exportable_media(canonical, kinds=sources.LEGACY_KINDS)[0])


class LocalSourceHTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.index = root / 'index.db'
        self.target_path = root / 'server.json'
        self.target = {'dataDir': str(root), 'baseURL': sources.BASE_URL,
                       'auth': {'accessToken': 'synthetic-private-token'}}
        self.write_target()
        self.source = {'conversation': {'roomId': '!fixture/a?b:beeper.local',
                                        'accountId': '@fixture:example.invalid'},
                       'eventId': '$fixture'}
        self.message = {'id': '7', 'chatID': self.source['conversation']['roomId'],
                        'attachments': [{'id': 'audio', 'isVoiceNote': True, 'type': 'audio',
                                         'mimeType': 'audio/ogg', 'fileSize': 10,
                                         'srcURL': 'mxc://fixture/audio'}]}
        with sqlite3.connect(self.index) as db:
            db.execute('CREATE TABLE mx_room_messages(id,isDeleted,isEdited,message,roomID,eventID)')
            db.execute('INSERT INTO mx_room_messages VALUES(7,0,0,?,?,?)',
                       (json.dumps(self.message), self.source['conversation']['roomId'], '$fixture'))
        self.requests = []
        self.status = 200
        self.raw_reply = None
        self.include_length = True
        self.extra_length = 0
        self.reply_delay = 0
        test = self

        class FixtureHandler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                test.requests.append((self.command, self.path, self.headers.get('Authorization'), body))
                time.sleep(test.reply_delay)
                if self.path == '/v1/app/setup':
                    value = {'matrix': {'userID': '@fixture:example.invalid'}}
                elif self.path == '/v1/assets/download':
                    value = {'srcURL': 'file:///fixture/audio'}
                else:
                    value = test.message
                data = test.raw_reply if test.raw_reply is not None else json.dumps(value).encode()
                self.send_response(test.status)
                self.send_header('Connection', 'close')
                if test.status == 302:
                    self.send_header('Location', 'http://example.invalid/forbidden')
                if test.include_length:
                    self.send_header('Content-Length', str(len(data) + test.extra_length))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.thread.join, 2)
        self.addCleanup(self.server.shutdown)
        original_connection = http.client.HTTPConnection

        def fixture_connection(host, port, **kwargs):
            self.assertEqual((host, port), ('127.0.0.1', 23374))
            return original_connection('127.0.0.1', self.server.server_port, **kwargs)

        for name, value in [('TARGET', self.target_path), ('INDEX', self.index)]:
            patcher = patch.object(sources, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(sources.http.client, 'HTTPConnection', side_effect=fixture_connection)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_target(self):
        self.target_path.write_text(json.dumps(self.target))
        self.target_path.chmod(0o600)

    def test_exact_source_uses_encoded_read_only_http_without_any_processes_or_proxy(self):
        with patch('subprocess.Popen', side_effect=AssertionError('Adapter must never spawn a process')), \
                patch.dict(os.environ, {'HTTP_PROXY': 'http://example.invalid:1',
                                        'http_proxy': 'http://example.invalid:1', 'NO_PROXY': ''}):
            message, attachment = sources.selected_source(self.source)
        self.assertEqual(message['id'], '7')
        self.assertIsNotNone(attachment)
        self.assertEqual([(r[0], r[1]) for r in self.requests],
                         [('GET', '/v1/app/setup'),
                          ('GET', '/v1/chats/%21fixture%2Fa%3Fb%3Abeeper.local/messages/7')])
        self.assertTrue(all(r[2] == 'Bearer synthetic-private-token' for r in self.requests))

    def test_account_mismatch_refuses_message_or_asset_access(self):
        self.source['conversation']['accountId'] = '@different:example.invalid'
        with self.assertRaises(sources.SourceFailure):
            sources.selected_source(self.source)
        self.assertEqual([(r[0], r[1]) for r in self.requests], [('GET', '/v1/app/setup')])

    def test_repeated_metadata_reads_close_sqlite_without_waiting_for_garbage_collection(self):
        original_connect = sqlite3.connect
        connections = []

        def tracked_connect(*args, **kwargs):
            connection = original_connect(*args, **kwargs)
            # Keep strong references: garbage collection cannot hide a leaked
            # descriptor by destroying the connection after selected_source().
            connections.append(connection)
            return connection

        try:
            with patch.object(sources.sqlite3, 'connect', side_effect=tracked_connect):
                for _ in range(25):
                    _, attachment = sources.selected_source(self.source)
                    self.assertIsNotNone(attachment)
                    with self.assertRaises(sqlite3.ProgrammingError):
                        connections[-1].execute('SELECT 1')
            self.assertEqual(len(connections), 25)
        finally:
            for connection in connections:
                connection.close()

    def test_sqlite_read_error_closes_connection_before_propagating(self):
        # A malformed/unavailable index must release the connection as well.
        setup = sqlite3.connect(self.index)
        setup.execute('DROP TABLE mx_room_messages')
        setup.commit()
        setup.close()
        connection = sqlite3.connect(f'file:{self.index}?mode=ro', uri=True)
        try:
            with patch.object(sources.sqlite3, 'connect', return_value=connection):
                with self.assertRaises(sqlite3.DatabaseError):
                    sources.selected_source(self.source)
            with self.assertRaises(sqlite3.ProgrammingError):
                connection.execute('SELECT 1')
        finally:
            connection.close()

    def test_connection_close_response_is_supported_and_timeouts_fail_closed(self):
        self.assertEqual(sources.BeeperAPI().request('GET', '/v1/app/setup'),
                         {'matrix': {'userID': '@fixture:example.invalid'}})
        self.reply_delay = 0.2
        with patch.object(sources, 'API_TIMEOUT', 0.05):
            with self.assertRaises(sources.SourceFailure):
                sources.BeeperAPI().request('GET', '/v1/app/setup')

    def test_target_is_private_owned_regular_and_profile_and_origin_are_pinned(self):
        for origin in ('https://127.0.0.1:23374', 'http://localhost:23374',
                       sources.BASE_URL + '/', sources.BASE_URL + '?redirect=1',
                       'http://user@127.0.0.1:23374'):
            with self.subTest(origin=origin):
                self.target['baseURL'] = origin
                self.write_target()
                with self.assertRaises(sources.SourceFailure):
                    sources.BeeperAPI()
        self.target['baseURL'] = sources.BASE_URL
        self.target['dataDir'] = '/unrelated/profile'
        self.write_target()
        with self.assertRaises(sources.SourceFailure):
            sources.BeeperAPI()
        self.target['dataDir'] = str(self.index.parent)
        self.write_target()
        self.target_path.chmod(0o640)
        with self.assertRaises(sources.SourceFailure):
            sources.BeeperAPI()
        self.target_path.chmod(0o600)
        with patch.object(sources.os, 'geteuid', return_value=os.geteuid() + 1):
            with self.assertRaises(sources.SourceFailure):
                sources.BeeperAPI()
        other = self.target_path.with_name('other.json')
        self.target_path.rename(other)
        self.target_path.symlink_to(other)
        with self.assertRaises(sources.SourceFailure):
            sources.BeeperAPI()
        self.assertEqual(self.requests, [])

    def test_redirect_errors_and_response_content_do_not_escape_as_secrets(self):
        for status in (302, 401, 503):
            with self.subTest(status=status):
                self.status = status
                self.raw_reply = b'synthetic-private-token private response content'
                with self.assertRaises(sources.SourceFailure) as caught:
                    sources.BeeperAPI().request('GET', '/v1/app/setup')
                formatted = ''.join(traceback.format_exception(type(caught.exception), caught.exception,
                                                               caught.exception.__traceback__))
                self.assertNotIn('synthetic-private-token', formatted)
                self.assertNotIn('private response content', formatted)
        self.assertEqual(len(self.requests), 3, 'Redirects and errors must not be retried')

    def test_oversized_declared_or_streamed_json_and_truncated_body_fail_closed(self):
        self.raw_reply = json.dumps({'padding': 'x' * 1000}).encode()
        for include_length in (True, False):
            with self.subTest(include_length=include_length):
                self.include_length = include_length
                with patch.object(sources, 'MAX_JSON_BYTES', 100):
                    with self.assertRaises(sources.SourceFailure):
                        sources.BeeperAPI().request('GET', '/v1/app/setup')
        self.include_length = True
        self.extra_length = 10
        with self.assertRaises(sources.SourceFailure):
            sources.BeeperAPI().request('GET', '/v1/app/setup')

    def test_only_explicit_read_endpoints_and_asset_materialization_are_permitted(self):
        api = sources.BeeperAPI()
        for method, path in [('POST', '/v1/chats/fixture/messages'),
                             ('GET', 'http://example.invalid/'),
                             ('GET', '//example.invalid/'),
                             ('GET', '/v1/chats/fixture/messages/7?markRead=true')]:
            with self.subTest(method=method, path=path):
                with self.assertRaises(sources.SourceFailure):
                    api.request(method, path)
        self.assertEqual(self.requests, [])
        self.assertEqual(api.request('POST', '/v1/assets/download', {'url': 'mxc://fixture/audio'}),
                         {'srcURL': 'file:///fixture/audio'})
        self.assertEqual(json.loads(self.requests[0][3]), {'url': 'mxc://fixture/audio'})


class LocalSourceResourceTests(unittest.TestCase):
    def test_server_bounds_live_handlers_and_recovers_after_disconnect(self):
        started = threading.Event()
        released = threading.Event()
        finished = threading.Event()

        class BlockingHandler:
            def __init__(self, request, client_address, server):
                started.set()
                released.wait(3)
                finished.set()

        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'source.sock')
            with sources.Server(path, BlockingHandler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                first = socket.socket(socket.AF_UNIX)
                second = socket.socket(socket.AF_UNIX)
                try:
                    first.connect(path)
                    self.assertTrue(started.wait(2))
                    second.settimeout(2)
                    second.connect(path)
                    self.assertEqual(second.recv(1), b'')
                    released.set()
                    self.assertTrue(finished.wait(2))
                finally:
                    released.set()
                    first.close()
                    second.close()
                    server.shutdown()
                    thread.join(2)
                self.assertTrue(server._request_slot.acquire(blocking=False))
                server._request_slot.release()

    def test_audio_response_streams_bounded_chunks_with_exact_content_length(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / 'fixture.ogg'
            payload = b'audio fixture\x00' * 15000
            audio.write_bytes(payload)
            reads = []

            class BoundedStream:
                def __enter__(self):
                    self.stream = audio.open('rb')
                    return self

                def __exit__(self, *args):
                    self.stream.close()

                def fileno(self):
                    return self.stream.fileno()

                def read(self, size=-1):
                    if not 0 < size <= sources.TRANSFER_CHUNK:
                        raise AssertionError('Audio must not be copied into one giant buffer')
                    reads.append(size)
                    return self.stream.read(size)

            class AudioFile:
                def open(self, mode):
                    return BoundedStream()

            path = str(Path(directory) / 'source.sock')
            attachment = {'id': 'fixture', 'mimeType': 'audio/ogg', 'fileSize': len(payload)}
            with patch.object(sources, 'selected_source', return_value=({}, attachment)), \
                    patch.object(sources, 'audio_file', return_value=AudioFile()), \
                    sources.Server(path, sources.Handler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                client = socket.socket(socket.AF_UNIX)
                try:
                    client.settimeout(2)
                    client.connect(path)
                    request = json.dumps({'source': {}, 'mode': 'audio'}).encode()
                    client.sendall(b'POST /source HTTP/1.1\r\nHost: localhost\r\nContent-Length: ' +
                                   str(len(request)).encode() + b'\r\n\r\n' + request)
                    response = http.client.HTTPResponse(client)
                    response.begin()
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.getheader('Content-Length'), str(len(payload)))
                    self.assertEqual(response.read(), payload)
                    self.assertGreater(len(reads), 1)
                finally:
                    client.close()
                    server.shutdown()
                    thread.join(2)



def video_message(**attachment):
    base = {'id': 'clip', 'type': 'video', 'mimeType': 'video/mp4', 'fileSize': 4096,
            'isVoiceNote': False, 'isGif': False, 'isSticker': False,
            'size': {'width': 1280, 'height': 720}, 'duration': 95, 'srcURL': 'mxc://fixture/clip'}
    base.update(attachment)
    return {'isDeleted': False, 'behavior': None, 'disappearingTimer': {},
            'accountID': 'local-whatsapp_ba_fixture', 'attachments': [base]}


class LocalVideoAudioPolicyTests(unittest.TestCase):
    def test_ordinary_videos_of_common_containers_are_exportable(self):
        for mime in ('video/mp4', 'video/webm', 'video/quicktime', 'video/3gpp',
                     'video/x-matroska', 'video/x-m4v'):
            with self.subTest(mime=mime):
                attachment, kind = sources.exportable_media(video_message(mimeType=mime))
                self.assertEqual(kind, 'video')
                self.assertEqual(attachment['mimeType'], mime)
        # A video sent as a file.
        attachment, kind = sources.exportable_media(video_message(type='unknown', mimeType='video/quicktime'))
        self.assertEqual(kind, 'video')

    def test_gifs_stickers_unknown_containers_and_protections_are_refused(self):
        for change in ({'isGif': True}, {'isSticker': True}, {'mimeType': 'video/x-flv'},
                       {'mimeType': 'image/gif', 'type': 'img'}, {'fileSize': 0},
                       {'fileSize': sources.MAX_BYTES + 1}, {'extra': {'view_once': True}}):
            with self.subTest(change=change):
                self.assertEqual(sources.exportable_media(video_message(**change)), (None, None))
        message = video_message()
        message['disappearingTimer'] = {'seconds': 30}
        self.assertEqual(sources.exportable_media(message), (None, None))

    def test_round_wins_over_video_and_voice_over_audio(self):
        _, kind = sources.exportable_media(round_message())
        self.assertEqual(kind, 'round')
        voice = {'isDeleted': False, 'attachments': [{'isVoiceNote': True, 'type': 'audio',
                                                      'mimeType': 'audio/ogg', 'fileSize': 10}]}
        self.assertEqual(sources.exportable_media(voice)[1], 'voice')
        music = {'isDeleted': False, 'attachments': [{'isVoiceNote': False, 'type': 'audio',
                                                      'mimeType': 'audio/mpeg', 'fileSize': 10}]}
        self.assertEqual(sources.exportable_media(music)[1], 'audio')
        playlist = {'isDeleted': False, 'attachments': [{'type': 'unknown', 'mimeType': 'audio/x-mpegurl',
                                                         'fileSize': 10}]}
        self.assertEqual(sources.exportable_media(playlist), (None, None))

    def test_square_video_outside_round_bounds_is_an_ordinary_video(self):
        message = round_message(size={'width': 720, 'height': 720})
        self.assertEqual(sources.exportable_media(message, kinds=sources.LEGACY_KINDS), (None, None))
        self.assertEqual(sources.exportable_media(message)[1], 'video')

    def test_legacy_kinds_hide_video_and_audio(self):
        self.assertEqual(sources.exportable_media(video_message(), kinds=sources.LEGACY_KINDS), (None, None))
        self.assertEqual(sources.exportable_media(round_message(), kinds=sources.LEGACY_KINDS)[1], 'round')


def reel_message(**change):
    message = video_message(size={'width': 720, 'height': 1280})
    message['accountID'] = 'local-instagram_ba_fixture'
    message['text'] = 'fixture\nCaption of the shared post\nhttps://www.instagram.com/reel/Cfixture/'
    message.update(change)
    return message


class LocalReelPolicyTests(unittest.TestCase):
    """J (2026-10-20): Instagram reels are transcribed only on demand."""

    def test_instagram_shares_are_reels(self):
        for text in ('https://www.instagram.com/reel/Cfixture/?igsh=x',
                     'Caption\nhttps://instagram.com/p/Cfixture/',
                     'https://www.instagram.com/fixture/reel/Cfixture/',
                     'https://www.instagram.com/stories/fixture/123/',
                     'http://instagr.am/tv/Cfixture'):
            with self.subTest(text=text):
                self.assertEqual(sources.exportable_media(reel_message(text=text))[1], 'reel')
        # The bridge's external_url, wherever the index model keeps it.
        for place in ('top', 'extra', 'attachment'):
            with self.subTest(place=place):
                message = video_message()
                url = 'https://www.instagram.com/reel/Cfixture/'
                if place == 'top':
                    message['external_url'] = url
                elif place == 'extra':
                    message['extra'] = {'externalURL': url}
                else:
                    message['attachments'][0]['externalUrl'] = url
                self.assertEqual(sources.exportable_media(message)[1], 'reel')

    def test_other_videos_are_not_reels(self):
        # Recorded and sent in an Instagram chat: no shared link.
        self.assertEqual(sources.exportable_media(reel_message(text='look at this'))[1], 'video')
        self.assertEqual(sources.exportable_media(reel_message(text=None))[1], 'video')
        # A link typed into another network's caption is not a share.
        self.assertEqual(sources.exportable_media(video_message(
            text='https://www.instagram.com/reel/Cfixture/'))[1], 'video')
        for url in ('https://www.facebook.com/reel/1', 'https://notinstagram.com/reel/x',
                    'https://instagram.com.example.org/p/x', 'ftp://instagram.com/p/x', 42):
            with self.subTest(url=url):
                message = video_message()
                message['external_url'] = url
                self.assertEqual(sources.exportable_media(message)[1], 'video')
        # Shared loops and protected shares stay refused.
        self.assertEqual(sources.exportable_media(reel_message(
            attachments=[{**reel_message()['attachments'][0], 'isGif': True}])), (None, None))
        self.assertEqual(sources.exportable_media(reel_message(extra={'view_once': True})), (None, None))

    def test_reels_are_exported_only_for_workers_that_ask(self):
        everything_but_reels = ('voice', 'round', 'video', 'audio')
        self.assertEqual(sources.exportable_media(reel_message(), kinds=everything_but_reels), (None, None))
        self.assertEqual(sources.exportable_media(reel_message(), kinds=sources.LEGACY_KINDS), (None, None))
        self.assertEqual(sources.exportable_media(reel_message(), kinds=('reel',))[1], 'reel')
        self.assertEqual(sources.exportable_media(video_message(), kinds=('reel',)), (None, None))

    def test_selected_reel_is_a_video_with_the_reel_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / 'index.db'
            canonical = reel_message()
            with sqlite3.connect(index) as db:
                db.execute('CREATE TABLE mx_room_messages(id,isDeleted,isEdited,message,roomID,eventID)')
                db.execute('INSERT INTO mx_room_messages VALUES(5,0,0,?,?,?)',
                           (json.dumps(canonical), '!ig:beeper.local', '$reel'))
            api_message = {'id': '5', 'chatID': '!ig:beeper.local', 'attachments': canonical['attachments']}

            def api(method, path):
                if path == '/v1/app/setup':
                    return {'matrix': {'userID': '@fixture:example.invalid'}}
                return api_message
            source = {'conversation': {'roomId': '!ig:beeper.local', 'accountId': '@fixture:example.invalid',
                                       'network': 'instagram'}, 'eventId': '$reel'}
            with patch.object(sources, 'INDEX', index), patch.object(sources, 'BeeperAPI') as client:
                client.return_value.request.side_effect = api
                _, attachment = sources.selected_source(source)
            self.assertEqual(attachment['_kind'], 'video')
            self.assertTrue(attachment['_reel'])


class LocalRecentTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.index = Path(directory.name) / 'index.db'
        voice = {'isSender': False, 'senderID': '@ghost:beeper.local', 'timestamp': '2026-10-17T12:00:00.000Z',
                 'text': 'private text', 'accountID': 'local-telegram_ba_fixture',
                 'attachments': [{'id': 'v', 'isVoiceNote': True, 'type': 'audio', 'mimeType': 'audio/ogg',
                                  'fileSize': 10, 'duration': 7}]}
        rows = [
            (1, '!a:beeper.local', '$voice', 0, 0, voice),
            (2, '!a:beeper.local', '$own', 0, 0, {**voice, 'isSender': True}),
            (3, '!a:beeper.local', '$deleted', 1, 0, voice),
            (4, '!a:beeper.local', '$edited', 0, 1, voice),
            (5, '!cloud:example.org', '$cloud', 0, 0, voice),
            (6, '!a:beeper.local', '$protected', 0, 0, {**voice, 'extra': {'view_once': True}}),
            (7, '!a:beeper.local', '$old', 0, 0, {**voice, 'timestamp': 1760000000000}),
            (8, '!a:beeper.local', '$round', 0, 0, {**round_message(), 'timestamp': 1792238400}),
            (9, '!a:beeper.local', '$text', 0, 0, {'text': 'hello', 'attachments': []}),
            (10, '!a:beeper.local', '$self', 0, 0, {**voice, 'senderID': '@fixture:example.invalid'}),
        ]
        clip = {**video_message(), 'isSender': False, 'senderID': '@ghost:beeper.local',
                'timestamp': '2026-10-17T12:00:01.000Z'}
        gif = {**video_message(isGif=True), 'isSender': False, 'timestamp': '2026-10-17T12:00:02.000Z'}
        self.extra_rows = [(12, '!a:beeper.local', '$clip', 0, 0, clip),
                           (13, '!a:beeper.local', '$gif', 0, 0, gif)]
        with sqlite3.connect(self.index) as db:
            db.execute('CREATE TABLE mx_room_messages(id,isDeleted,isEdited,message,roomID,eventID)')
            for row_id, room, event, deleted, edited, message in rows:
                db.execute('INSERT INTO mx_room_messages VALUES(?,?,?,?,?,?)',
                           (row_id, deleted, edited, json.dumps(message), room, event))
            db.execute('INSERT INTO mx_room_messages VALUES(11,0,0,?,?,?)',
                       ('{not json', '!a:beeper.local', '$broken'))
        self.account = '@fixture:example.invalid'
        self.api_calls = []

        def api(method, path):
            self.api_calls.append((method, path))
            return {'matrix': {'userID': self.account}}
        for name, value in [('INDEX', self.index)]:
            patcher = patch.object(sources, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(sources, 'BeeperAPI')
        client = patcher.start()
        self.addCleanup(patcher.stop)
        client.return_value.request.side_effect = api

    def recent(self, **request):
        return sources.recent_media({'accountId': '@fixture:example.invalid', **request})

    def add_media_rows(self):
        with closing(sqlite3.connect(self.index)) as db, db:
            for row_id, room, event, deleted, edited, message in self.extra_rows:
                db.execute('INSERT INTO mx_room_messages VALUES(?,?,?,?,?,?)',
                           (row_id, deleted, edited, json.dumps(message), room, event))

    def test_videos_are_listed_only_when_the_worker_asks(self):
        self.add_media_rows()
        legacy = self.recent(cursor=11, limit=10)
        self.assertEqual(legacy, {'cursor': 13, 'items': []})
        page = self.recent(cursor=11, limit=10, kinds=['voice', 'round', 'video', 'audio'])
        self.assertEqual([(i['eventId'], i['kind'], i['durationMs'], i['network']) for i in page['items']],
                         [('$clip', 'video', 95000, 'whatsapp')])
        for kinds in ([], ['image'], 'video', [1], ['voice'] * 5, ['voice', 'voice'], ['voice'] * 6):
            with self.subTest(kinds=kinds):
                with self.assertRaises(sources.SourceFailure):
                    self.recent(cursor=11, kinds=kinds)

    def test_reels_are_listed_only_when_the_worker_asks(self):
        reel = {**reel_message(), 'isSender': False, 'senderID': '@ghost:beeper.local',
                'timestamp': '2026-10-17T12:00:03.000Z'}
        with closing(sqlite3.connect(self.index)) as db, db:
            db.execute('INSERT INTO mx_room_messages VALUES(?,?,?,?,?,?)',
                       (14, 0, 0, json.dumps(reel), '!ig:beeper.local', '$reel'))
        page = self.recent(cursor=11, limit=10, kinds=['voice', 'round', 'video', 'audio'])
        self.assertEqual(page, {'cursor': 14, 'items': []})
        page = self.recent(cursor=11, limit=10, kinds=['voice', 'round', 'video', 'audio', 'reel'])
        self.assertEqual([(i['eventId'], i['kind'], i['network']) for i in page['items']],
                         [('$reel', 'reel', 'instagram')])

    def test_null_cursor_returns_current_end_without_history(self):
        self.assertEqual(self.recent(cursor=None), {'cursor': 11, 'items': []})

    def test_lists_only_incoming_exportable_media_identifiers(self):
        since = int(datetime(2026, 10, 17, 11, tzinfo=timezone.utc).timestamp() * 1000)
        page = self.recent(cursor=0, sinceMs=since, limit=200)
        self.assertEqual(page['cursor'], 11)
        self.assertEqual([(i['eventId'], i['kind']) for i in page['items']],
                         [('$voice', 'voice'), ('$round', 'round')])
        voice = page['items'][0]
        self.assertEqual(set(voice), {'roomId', 'eventId', 'kind', 'durationMs', 'network', 'timestampMs'})
        self.assertEqual(voice['durationMs'], 7000)
        self.assertEqual(voice['network'], 'telegram')
        self.assertEqual(page['items'][1]['timestampMs'], 1792238400000)
        self.assertNotIn('private text', json.dumps(page))
        self.assertEqual(self.api_calls, [('GET', '/v1/app/setup')],
                         'A scan reads only the index; no message or media API calls')

    def test_limit_advances_cursor_past_filtered_rows(self):
        first = self.recent(cursor=1, limit=3)
        self.assertEqual(first, {'cursor': 4, 'items': []})
        second = self.recent(cursor=first['cursor'], limit=4)
        self.assertEqual(second['cursor'], 8)
        self.assertEqual([i['eventId'] for i in second['items']], ['$old', '$round'])

    def test_unknown_timestamp_counts_as_too_old(self):
        voice = {'isSender': False, 'senderID': '@ghost:beeper.local',
                 'accountID': 'local-telegram_ba_fixture',
                 'attachments': [{'id': 'v', 'isVoiceNote': True, 'type': 'audio', 'mimeType': 'audio/ogg',
                                  'fileSize': 10, 'duration': 7}]}
        with closing(sqlite3.connect(self.index)) as db, db:
            for row_id, event, extra in [(12, '$undated', {}), (13, '$garbled', {'timestamp': 'yesterday'}),
                                         (14, '$zero', {'timestamp': 0})]:
                db.execute('INSERT INTO mx_room_messages VALUES(?,?,?,?,?,?)',
                           (row_id, 0, 0, json.dumps({**voice, **extra}), '!a:beeper.local', event))
        for request in ({}, {'sinceMs': 0}):
            with self.subTest(request=request):
                self.assertEqual(self.recent(cursor=11, limit=10, **request), {'cursor': 14, 'items': []})

    def test_invalid_requests_and_foreign_account_fail_closed(self):
        for request in ({'cursor': -1}, {'cursor': True}, {'cursor': '1'}, {'cursor': 0, 'limit': 0},
                        {'cursor': 0, 'limit': 201}, {'cursor': 0, 'sinceMs': 'yesterday'},
                        {'cursor': 0, 'accountId': 'fixture'}):
            with self.subTest(request=request):
                with self.assertRaises(sources.SourceFailure):
                    self.recent(**request)
        self.account = '@other:example.invalid'
        with self.assertRaises(sources.SourceFailure):
            self.recent(cursor=0)

    def test_http_route_serves_recent_and_rejects_unknown_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'source.sock')
            with sources.Server(path, sources.Handler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    for route, status in (('/recent', 200), ('/other', 503)):
                        client = socket.socket(socket.AF_UNIX)
                        try:
                            client.settimeout(2)
                            client.connect(path)
                            body = json.dumps({'accountId': self.account, 'cursor': None}).encode()
                            client.sendall(b'POST ' + route.encode() + b' HTTP/1.1\r\nHost: localhost\r\n'
                                           b'Content-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
                            response = http.client.HTTPResponse(client)
                            response.begin()
                            self.assertEqual(response.status, status)
                            data = json.loads(response.read())
                            if status == 200:
                                self.assertEqual(data, {'cursor': 11, 'items': []})
                            response.close()
                        finally:
                            client.close()
                finally:
                    server.shutdown()
                    thread.join(2)


class LocalRoundHTTPTests(unittest.TestCase):
    def serve(self, attachment, payload, mode):
        with tempfile.TemporaryDirectory() as directory:
            media = Path(directory) / 'round.mp4'
            media.write_bytes(payload)
            path = str(Path(directory) / 'source.sock')
            with patch.object(sources, 'selected_source', return_value=({}, attachment)), \
                    patch.object(sources, 'audio_file', return_value=media), \
                    sources.Server(path, sources.Handler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                client = socket.socket(socket.AF_UNIX)
                try:
                    client.settimeout(2)
                    client.connect(path)
                    source = {'conversation': {'accountId': '@a:x', 'roomId': '!r:beeper.local'},
                              'eventId': '$e'}
                    body = json.dumps({'source': source, 'mode': mode}).encode()
                    client.sendall(b'POST /source HTTP/1.1\r\nHost: localhost\r\nContent-Length: ' +
                                   str(len(body)).encode() + b'\r\n\r\n' + body)
                    response = http.client.HTTPResponse(client)
                    response.begin()
                    try:
                        return response.status, response.getheader('Content-Type'), response.read()
                    finally:
                        response.close()
                finally:
                    client.close()
                    server.shutdown()
                    thread.join(2)

    def test_round_metadata_reports_kind_and_streams_video_bytes(self):
        attachment = {'id': 'round', 'mimeType': 'video/mp4', 'fileSize': 70000, '_kind': 'round'}
        status, _, data = self.serve(attachment, b'', 'metadata')
        self.assertEqual(status, 200)
        metadata = json.loads(data)
        self.assertEqual((metadata['kind'], metadata['mimeType'], metadata['transcriptionAllowed']),
                         ('round', 'video/mp4', True))
        payload = b'\x00\x00\x00\x18ftypmp42' + b'video fixture' * 5000
        status, mime, data = self.serve(attachment, payload, 'audio')
        self.assertEqual((status, mime), (200, 'application/octet-stream'))
        self.assertEqual(data, payload)

    def test_video_metadata_declares_duration_and_size(self):
        attachment = {'id': 'clip', 'mimeType': 'video/webm', 'fileSize': 5000, 'duration': 95,
                      '_kind': 'video'}
        status, _, data = self.serve(attachment, b'', 'metadata')
        self.assertEqual(status, 200)
        metadata = json.loads(data)
        self.assertEqual((metadata['kind'], metadata['durationMs'], metadata['fileSize']),
                         ('video', 95000, 5000))
        status, _, data = self.serve(attachment, b'webm fixture' * 10, 'audio')
        self.assertEqual((status, data), (200, b'webm fixture' * 10))

    def test_reel_metadata_is_a_video_with_the_reel_flag(self):
        attachment = {'id': 'clip', 'mimeType': 'video/mp4', 'fileSize': 5000, 'duration': 30,
                      '_kind': 'video', '_reel': True}
        status, _, data = self.serve(attachment, b'', 'metadata')
        self.assertEqual(status, 200)
        metadata = json.loads(data)
        self.assertEqual((metadata['kind'], metadata['reel'], metadata['transcriptionAllowed']),
                         ('video', True, True))
        status, _, data = self.serve({**attachment, '_reel': False}, b'', 'metadata')
        self.assertNotIn('reel', json.loads(data))

    def test_round_file_above_round_cap_is_refused(self):
        attachment = {'id': 'round', 'mimeType': 'video/mp4', 'fileSize': 70000, '_kind': 'round'}
        with patch.object(sources, 'ROUND_MAX_BYTES', 1000):
            status, _, _ = self.serve(attachment, b'x' * 1001, 'audio')
        self.assertEqual(status, 503)


if __name__ == '__main__':
    unittest.main()
