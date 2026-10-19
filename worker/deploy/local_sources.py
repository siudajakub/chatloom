#!/usr/bin/env python3
"""Read-only, account-bound local Beeper sources over a private Unix socket.

No OpenAI key or new Matrix session is configured here. The existing Beeper
target authenticates under its own account. The only allowed API write is the
server's asset-download/cache operation for a selected voice note or Telegram
round video. `POST /recent` lists identifiers of newly indexed incoming voice
and round messages for opt-in automatic transcription; it returns no sender,
text, media or paths.
"""
from datetime import datetime
import json
import http.client
import math
import os
from pathlib import Path
import re
import socketserver
import sqlite3
import stat
import threading
import time
from contextlib import closing
from http.server import BaseHTTPRequestHandler
from urllib.parse import quote, unquote, urlparse

MAX_BYTES = 250_000_000
SOCKET = '/run/personal-worker-source/source.sock'
INDEX = Path('/home/eouser/.beeper/profiles/server/server/index.db')
TARGET = Path('/home/eouser/.beeper/targets/server.json')
BASE_URL = 'http://127.0.0.1:23374'
API_TIMEOUT = 30
MAX_JSON_BYTES = 2 * 1024 * 1024
IO_TIMEOUT = 15
TRANSFER_CHUNK = 64 * 1024
MESSAGE_PATH = re.compile(r'/v1/chats/[^/?#]+/messages/[^/?#]+\Z')
# Telegram round videos ("video notes"): square, at most 640 px and 60 s.
ROUND_MAX_BYTES = 64 * 1024 * 1024
ROUND_MAX_MS = 61_500  # 60 s plus container rounding tolerance
ROUND_MAX_SIDE = 640
ROUND_SQUARE_TOLERANCE = 2
RECENT_MAX_LIMIT = 200
MAX_RECENT_BYTES = 256 * 1024
MAX_ID_LENGTH = 255
# Normalized (lowercase, alphanumeric) field names that explicitly mark a
# round video in the canonical index model. The exact field is unverified on
# the production index, so the plausible spellings are all honoured; any
# non-boolean or false value fails closed.
ROUND_FLAGS = frozenset({
    'fimautelegramroundmessage', 'roundmessage', 'isroundmessage',
    'videonote', 'isvideonote', 'roundvideo', 'isroundvideo', 'isround',
})
NETWORK_FIELDS = ('accountID', 'accountId', 'platform', 'platformName',
                  'network', 'networkID', 'protocol')
NETWORKS = (('telegram', 'telegram'), ('whatsapp', 'whatsapp'), ('signal', 'signal'),
            ('instagram', 'instagram'), ('facebook', 'facebook'), ('messenger', 'facebook'),
            ('discord', 'discord'), ('slack', 'slack'), ('linkedin', 'linkedin'),
            ('twitter', 'twitter'), ('gmessages', 'gmessages'),
            ('googlechat', 'googlechat'), ('imessage', 'imessage'))


class SourceFailure(Exception):
    pass


class BeeperAPI:
    """Pinned loopback HTTP; never start the CLI or its detached update hook."""

    def __init__(self):
        try:
            # Refuse a substituted, shared, or writable credential file. Read
            # it from the Beeper account only; never send it to the worker.
            fd = os.open(TARGET, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or info.st_mode & 0o077 or info.st_size > 65536):
                    raise SourceFailure()
                data = stream.read(65537)
            if len(data) > 65536:
                raise SourceFailure()
            target = json.loads(data)
            if (target['baseURL'] != BASE_URL
                    or Path(target['dataDir']).resolve() != INDEX.parent.resolve()):
                raise SourceFailure()
            token = target['auth']['accessToken']
            if (not isinstance(token, str) or not 0 < len(token) <= 8192
                    or '\r' in token or '\n' in token):
                raise SourceFailure()
            self._token = token
        except (OSError, ValueError, KeyError, TypeError):
            raise SourceFailure() from None

    def request(self, method, path, body=None):
        if not ((method == 'GET' and (path == '/v1/app/setup' or MESSAGE_PATH.fullmatch(path)))
                or (method == 'POST' and path == '/v1/assets/download')):
            raise SourceFailure()
        # http.client ignores proxy environment variables and follows no
        # redirects. The destination is a constant, not an input URL.
        connection = http.client.HTTPConnection('127.0.0.1', 23374, timeout=API_TIMEOUT)
        deadline = time.monotonic() + API_TIMEOUT
        response = None
        try:
            encoded = json.dumps(body).encode() if body is not None else None
            headers = {'Authorization': 'Bearer ' + self._token, 'Accept': 'application/json'}
            if encoded is not None:
                headers['Content-Type'] = 'application/json'
            connection.request(method, path, body=encoded, headers=headers)
            connection_socket = connection.sock
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SourceFailure()
            connection_socket.settimeout(remaining)
            response = connection.getresponse()
            if response.status != 200 or response.getheader('Content-Encoding') not in (None, 'identity'):
                raise SourceFailure()
            length = response.getheader('Content-Length')
            if length is not None and not 0 <= int(length) <= MAX_JSON_BYTES:
                raise SourceFailure()
            data = bytearray()
            while not response.isclosed():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SourceFailure()
                connection_socket.settimeout(remaining)
                chunk = response.read1(min(TRANSFER_CHUNK, MAX_JSON_BYTES + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > MAX_JSON_BYTES:
                    raise SourceFailure()
            if length is not None and len(data) != int(length):
                raise SourceFailure()
            value = json.loads(data)
            if not isinstance(value, dict):
                raise SourceFailure()
            return value
        except (OSError, ValueError, TypeError, http.client.HTTPException):
            # HTTP exceptions can contain private URLs or response content.
            raise SourceFailure() from None
        finally:
            if response is not None:
                response.close()
            connection.close()


def restricted(value):
    if isinstance(value, dict):
        for key, item in value.items():
            name = str(key).lower().replace('_', '').replace('-', '')
            if name in ('canexport', 'canforward', 'cansave', 'canshare', 'cantranscribe') and item is False:
                return True
            if any(x in name for x in ('viewonce', 'protected', 'ephemeral', 'noforward', 'noexport', 'disappearing', 'expire', 'expiry', 'expiration', 'lifetime', 'selfdestruct', 'ttl')) and item:
                return True
            if restricted(item):
                return True
    elif isinstance(value, list):
        return any(restricted(x) for x in value)
    return False


def single_attachment(message):
    """The one attachment of an ordinary, unrestricted message, or None."""
    if not isinstance(message, dict):
        return None
    if message.get('isDeleted') or message.get('behavior') or message.get('disappearingTimer'):
        return None
    if restricted({k: v for k, v in message.items() if k != 'attachments'}):
        return None
    attachments = message.get('attachments') or []
    if not isinstance(attachments, list) or len(attachments) != 1 or not isinstance(attachments[0], dict):
        return None
    attachment = attachments[0]
    # Existing provider transcripts are deliberately excluded from this path.
    if restricted({k: v for k, v in attachment.items() if k != 'transcription'}):
        return None
    return attachment


def _size(attachment, limit):
    size = attachment.get('fileSize')
    return isinstance(size, int) and not isinstance(size, bool) and 0 < size <= limit


def ordinary_voice(message):
    attachment = single_attachment(message)
    if attachment is None:
        return None
    if (not attachment.get('isVoiceNote') or attachment.get('type') != 'audio'
            or not str(attachment.get('mimeType', '')).startswith('audio/')):
        return None
    if not _size(attachment, MAX_BYTES):
        return None
    return attachment


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value if math.isfinite(value) else None


def duration_ms(attachment):
    """Advisory duration; None when absent, -1 when malformed.

    Beeper's public API documents `duration` in seconds while Matrix
    `info.duration` is milliseconds. No round lasts 1000 s, so larger values
    can only be milliseconds. The worker measures the real duration anyway.
    """
    for key in ('durationMs', 'duration_ms'):
        if key in attachment:
            value = _number(attachment[key])
            return -1 if value is None or value < 0 else int(value)
    duration = attachment.get('duration')
    extra = attachment.get('extra')
    if duration is None and isinstance(extra, dict):
        # The local index keeps a video note's length in `extra.duration`.
        duration = extra.get('duration')
    if duration is None:
        return None
    value = _number(duration)
    if value is None or value < 0:
        return -1
    return int(round(value * 1000)) if value <= 1000 else int(value)


def dimensions(attachment):
    """(width, height), None when absent, or 'invalid'."""
    size = attachment.get('size')
    candidates = []
    if isinstance(size, dict):
        candidates.append((size.get('width'), size.get('height')))
    candidates += [(attachment.get('width'), attachment.get('height')),
                   (attachment.get('w'), attachment.get('h'))]
    for width, height in candidates:
        if width is None and height is None:
            continue
        width, height = _number(width), _number(height)
        if width is None or height is None:
            return 'invalid'
        return width, height
    return None


def network_of(message):
    """Network label from the source account fields, or None."""
    if not isinstance(message, dict):
        return None
    for key in NETWORK_FIELDS:
        value = message.get(key)
        if isinstance(value, str):
            lowered = value.lower()
            for needle, name in NETWORKS:
                if needle in lowered:
                    return name
    return None


def _round_flags(value, depth=0):
    found = []
    if depth > 4:
        return found
    if isinstance(value, dict):
        for key, item in value.items():
            if re.sub('[^a-z0-9]', '', str(key).lower()) in ROUND_FLAGS:
                found.append(item)
            found += _round_flags(item, depth + 1)
    elif isinstance(value, list):
        for item in value:
            found += _round_flags(item, depth + 1)
    return found


def round_flag(message, attachment):
    """True/False from an explicit round field, None when there is none."""
    values = (_round_flags({k: v for k, v in message.items() if k != 'attachments'})
              + _round_flags({k: v for k, v in attachment.items() if k != 'transcription'}))
    if not values:
        return None
    if any(not isinstance(v, bool) for v in values):
        return False
    return any(values)


def round_candidate(message):
    """An ordinary single MP4 video within round bounds (where known)."""
    attachment = single_attachment(message)
    if attachment is None:
        return None
    # Beeper's local index stores Telegram video notes as a voice note with an
    # MP4 container: type `audio`, mimeType `video/mp4`, isVoiceNote true.
    video_note = attachment.get('type') == 'audio' and attachment.get('isVoiceNote') is True
    if ((attachment.get('type') != 'video' and not video_note)
            or attachment.get('mimeType') != 'video/mp4'
            or attachment.get('isGif') or attachment.get('isSticker')):
        return None
    if not _size(attachment, ROUND_MAX_BYTES):
        return None
    duration = duration_ms(attachment)
    if duration is not None and not 0 < duration <= ROUND_MAX_MS:
        return None
    size = dimensions(attachment)
    if size == 'invalid':
        return None
    if size is not None:
        width, height = size
        if (not 0 < width <= ROUND_MAX_SIDE or not 0 < height <= ROUND_MAX_SIDE
                or abs(width - height) > ROUND_SQUARE_TOLERANCE):
            return None
    return attachment


def round_evidence(message, attachment, telegram=False):
    """Explicit round field, else the documented fallback heuristic:
    video/mp4 (checked by round_candidate) + square <= 640 px + <= 60 s,
    both measured, in a Telegram source."""
    flag = round_flag(message, attachment)
    if flag is not None:
        return flag
    # Beeper's local index marks Telegram video notes with `isVoiceNote: true`
    # on a single video/mp4 attachment (row type VOICE, attachment type audio,
    # no dimensions); verified on the production index 2026-10-18. Only the
    # literal boolean counts; anything else falls through to the fail-closed
    # heuristic.
    if attachment.get('isVoiceNote') is True:
        return True
    size = dimensions(attachment)
    return ((telegram or network_of(message) == 'telegram')
            and size not in (None, 'invalid') and duration_ms(attachment) is not None)


def ordinary_round(message, telegram=False):
    attachment = round_candidate(message)
    if attachment is None or not round_evidence(message, attachment, telegram):
        return None
    return attachment


def exportable_media(message, telegram=False):
    """(attachment, kind) for an exportable voice note or round, else (None, None)."""
    voice = ordinary_voice(message)
    if voice is not None:
        return voice, 'voice'
    video = ordinary_round(message, telegram)
    if video is not None:
        return video, 'round'
    return None, None


def selected_source(source):
    conversation = source['conversation']
    room, event = conversation['roomId'], source['eventId']
    if not room.startswith('!') or not room.endswith(':beeper.local') or not event.startswith('$'):
        raise SourceFailure()
    # The requesting device's bridge state labels the room. It only feeds the
    # round heuristic; every protection check still applies.
    telegram = conversation.get('network') == 'telegram'
    api = BeeperAPI()
    account = api.request('GET', '/v1/app/setup')['matrix']['userID']
    if account != conversation['accountId']:
        raise SourceFailure()
    # sqlite3.Connection's context manager controls transactions, not lifetime.
    # Explicitly close it per request so descriptors and page caches cannot
    # accumulate until cyclic garbage collection eventually runs.
    with closing(sqlite3.connect(f'file:{INDEX}?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        rows = db.execute('SELECT id,isDeleted,isEdited,message FROM mx_room_messages WHERE roomID=? AND eventID=?',
                          (room, event)).fetchall()
    if len(rows) != 1:
        raise SourceFailure()
    if rows[0][1]:
        return {'isDeleted': True}, None
    canonical = json.loads(rows[0][3])
    original, kind = exportable_media(canonical, telegram)
    # A Telegram round whose canonical row lacks both an explicit flag and
    # measured size/duration may still be completed by the API's documented
    # size/duration fields. Every restriction was already checked above.
    pending = None
    if original is None and telegram:
        candidate = round_candidate(canonical)
        if candidate is not None and round_flag(canonical, candidate) is None:
            pending = candidate
    # The public message API omits some behavior/timer fields. The canonical
    # stored model must approve export before the API is used to resolve bytes.
    if rows[0][2] or (original is None and pending is None):
        return canonical, None
    message = api.request('GET', '/v1/chats/' + quote(room, safe='') +
                          '/messages/' + quote(str(rows[0][0]), safe=''))
    if str(message['id']) != str(rows[0][0]) or message['chatID'] != room:
        raise SourceFailure()
    if kind == 'voice':
        attachment = ordinary_voice(message)
    else:
        attachment = round_candidate(message)
        if attachment is not None:
            if original is None:
                original, kind = pending, 'round'
                if not round_evidence(message, attachment, telegram):
                    attachment = None
            # An explicit negative or malformed flag in the API copy refuses.
            elif round_flag(message, attachment) is False:
                attachment = None
    if attachment is not None:
        if any(attachment.get(k) != original.get(k) for k in ('id', 'mimeType', 'fileSize')):
            raise SourceFailure()
        attachment = {**attachment, '_sourceAPI': api, '_kind': kind}
    return message, attachment


def audio_file(attachment):
    limit = ROUND_MAX_BYTES if attachment.get('_kind') == 'round' else MAX_BYTES
    url = attachment['srcURL']
    if url.startswith(('mxc://', 'localmxc://')):
        value = attachment['_sourceAPI'].request('POST', '/v1/assets/download', {'url': url})
        url = value.get('srcURL', '')
    parsed = urlparse(url)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        raise SourceFailure()
    file = Path(unquote(parsed.path)).resolve(strict=True)
    if not file.is_relative_to(Path('/home/eouser/.beeper')) or not file.is_file():
        raise SourceFailure()
    if not 0 < file.stat().st_size <= limit:
        raise SourceFailure()
    return file


def timestamp_ms(value):
    """Epoch milliseconds from ISO-8601 or epoch seconds/milliseconds."""
    number = _number(value)
    if number is not None:
        if number <= 0:
            return None
        return int(number if number >= 1e11 else number * 1000)
    if isinstance(value, str) and 0 < len(value) <= 64:
        try:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            return None
        return int(parsed.timestamp() * 1000)
    return None


def _recent_item(account, row_id, room, event, deleted, edited, raw, since):
    if (not isinstance(room, str) or not room.startswith('!') or not room.endswith(':beeper.local')
            or len(room) > MAX_ID_LENGTH or not isinstance(event, str)
            or not event.startswith('$') or len(event) > MAX_ID_LENGTH or deleted or edited):
        return None
    try:
        message = json.loads(raw)
    except (TypeError, ValueError):
        return None
    if not isinstance(message, dict) or message.get('isSender') or message.get('senderID') == account:
        return None
    attachment, kind = exportable_media(message)
    if attachment is None:
        return None
    when = timestamp_ms(message.get('timestamp'))
    # Late-indexed history (backfill) is older than the window: skip it. An
    # unknown age counts as too old: it never starts paid background work.
    if when is None or (since is not None and when < since):
        return None
    duration = duration_ms(attachment)
    return {'roomId': room, 'eventId': event, 'kind': kind,
            'durationMs': duration if duration is not None and duration >= 0 else None,
            'network': network_of(message) or 'unknown', 'timestampMs': when}


def recent_media(request):
    """Identifiers of incoming voice/round messages indexed after `cursor`.

    A null cursor returns the current end of the index and no items, so the
    first scan never sweeps history. Read-only; nothing is downloaded."""
    account, cursor = request.get('accountId'), request.get('cursor')
    limit, since = request.get('limit', 100), request.get('sinceMs')
    if (not isinstance(account, str) or not account.startswith('@')
            or (cursor is not None and (not isinstance(cursor, int) or isinstance(cursor, bool) or cursor < 0))
            or not isinstance(limit, int) or isinstance(limit, bool) or not 0 < limit <= RECENT_MAX_LIMIT
            or (since is not None and (not isinstance(since, int) or isinstance(since, bool) or since < 0))):
        raise SourceFailure()
    if BeeperAPI().request('GET', '/v1/app/setup')['matrix']['userID'] != account:
        raise SourceFailure()
    with closing(sqlite3.connect(f'file:{INDEX}?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        if cursor is None:
            top = db.execute('SELECT MAX(id) FROM mx_room_messages').fetchone()[0]
            if top is not None and (not isinstance(top, int) or isinstance(top, bool) or top < 0):
                raise SourceFailure()
            return {'cursor': top or 0, 'items': []}
        rows = db.execute('SELECT id,roomID,eventID,isDeleted,isEdited,message FROM mx_room_messages '
                          'WHERE id>? ORDER BY id LIMIT ?', (cursor, limit)).fetchall()
    items, position = [], cursor
    for row in rows:
        if not isinstance(row[0], int) or isinstance(row[0], bool):
            raise SourceFailure()
        position = max(position, row[0])
        item = _recent_item(account, *row, since)
        if item is not None:
            items.append(item)
    return {'cursor': position, 'items': items}


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(IO_TIMEOUT)
        super().setup()

    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if self.path not in ('/source', '/recent') or not 0 < length <= 16384:
                raise SourceFailure()
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict):
                raise SourceFailure()
            if self.path == '/recent':
                data = json.dumps(recent_media(request), separators=(',', ':')).encode()
                if len(data) > MAX_RECENT_BYTES:
                    raise SourceFailure()
                self.reply(200, data, 'application/json')
                return
            source = request['source']
            mode = request['mode']
            if mode not in ('metadata', 'audio'):
                raise SourceFailure()
            message, attachment = selected_source(source)
            if mode == 'metadata':
                self.reply(200, json.dumps({'sourceKey': json.dumps([
                    source['conversation']['accountId'], source['conversation']['roomId'], source['eventId']],
                    separators=(',', ':'), ensure_ascii=False),
                    'redacted': bool(message.get('isDeleted')), 'transcriptionAllowed': attachment is not None,
                    'mimeType': attachment['mimeType'] if attachment else None,
                    'kind': attachment.get('_kind', 'voice') if attachment else None}).encode(), 'application/json')
                return
            if attachment is None:
                self.reply(403, b'{}', 'application/json')
                return
            file = audio_file(attachment)
            # Fresh source policy after download; never export deleted/limited media.
            _, after = selected_source(source)
            if after is None or any(after.get(k) != attachment.get(k) for k in ('id', 'mimeType', 'fileSize', '_kind')):
                raise SourceFailure()
            limit = ROUND_MAX_BYTES if attachment.get('_kind') == 'round' else MAX_BYTES
            with file.open('rb') as stream:
                size = os.fstat(stream.fileno()).st_size
                if not 0 < size <= limit:
                    raise SourceFailure()
                self.headers_for(200, size, 'application/octet-stream')
                remaining = size
                while remaining:
                    chunk = stream.read(min(remaining, TRANSFER_CHUNK))
                    if not chunk:
                        raise SourceFailure()
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except Exception:
            # Once a response has started, terminate it rather than appending a
            # second HTTP response to a partial audio stream.
            if not getattr(self, '_response_started', False):
                try:
                    self.reply(503, b'{"error":"local_source_unavailable"}', 'application/json')
                except OSError:
                    pass

    def reply(self, status, data, mime):
        self.headers_for(status, len(data), mime)
        self.wfile.write(data)

    def headers_for(self, status, size, mime):
        self._response_started = True
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(size))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 1

    def __init__(self, *args, **kwargs):
        self._request_slot = threading.BoundedSemaphore(1)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        # Bound threads and transfers. Excess requests fail fast so
        # repeated worker retries cannot build an in-memory queue during OOM.
        if not self._request_slot.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slot.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slot.release()


if __name__ == '__main__':
    os.umask(0o007)
    # systemd supplies a fresh RuntimeDirectory; never unlink an unknown socket.
    with Server(SOCKET, Handler) as server:
        os.chmod(SOCKET, 0o660)
        server.serve_forever()
