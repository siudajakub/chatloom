#!/usr/bin/env python3
"""Read-only, account-bound local Beeper sources over a private Unix socket.

No OpenAI key or new Matrix session is configured here. The existing Beeper CLI
authenticates under its own account. The only allowed API write is the server's
asset-download/cache operation for a selected voice note.
"""
import json
import os
from pathlib import Path
import socketserver
import sqlite3
import subprocess
from http.server import BaseHTTPRequestHandler
from urllib.parse import unquote, urlparse

MAX_BYTES = 250_000_000
SOCKET = '/run/personal-worker-source/source.sock'
INDEX = Path('/home/eouser/.beeper/profiles/server/server/index.db')


class SourceFailure(Exception):
    pass


def beeper(*args, target=None):
    if target is not None:
        args = (*args, '--target', target)
    r = subprocess.run(['/usr/local/bin/beeper', *args, '--json'],
                       capture_output=True, text=True, timeout=90, check=True)
    value = json.loads(r.stdout)
    if not value.get('success'):
        raise SourceFailure()
    return value['data']


def ordinary_voice(message):
    if message.get('isDeleted') or message.get('behavior') or message.get('disappearingTimer'):
        return None
    def restricted(value):
        if isinstance(value, dict):
            for key, item in value.items():
                name = key.lower().replace('_', '').replace('-', '')
                if name in ('canexport', 'canforward', 'cansave', 'canshare', 'cantranscribe') and item is False:
                    return True
                if any(x in name for x in ('viewonce', 'protected', 'ephemeral', 'noforward', 'noexport', 'disappearing', 'expire', 'expiry', 'expiration', 'lifetime', 'selfdestruct', 'ttl')) and item:
                    return True
                if restricted(item):
                    return True
        elif isinstance(value, list):
            return any(restricted(x) for x in value)
        return False
    if restricted({k: v for k, v in message.items() if k != 'attachments'}):
        return None
    attachments = message.get('attachments') or []
    if len(attachments) != 1:
        return None
    attachment = attachments[0]
    # Existing provider transcripts are deliberately excluded from this path.
    if restricted({k: v for k, v in attachment.items() if k != 'transcription'}):
        return None
    if (not attachment.get('isVoiceNote') or attachment.get('type') != 'audio'
            or not str(attachment.get('mimeType', '')).startswith('audio/')):
        return None
    size = attachment.get('fileSize')
    if not isinstance(size, int) or not 0 < size <= MAX_BYTES:
        return None
    return attachment


def selected_source(source):
    conversation = source['conversation']
    room, event = conversation['roomId'], source['eventId']
    if not room.startswith('!') or not room.endswith(':beeper.local') or not event.startswith('$'):
        raise SourceFailure()
    status = beeper('status')
    target = status['target']
    base = urlparse(target['baseURL'])
    if (Path(target['dataDir']).resolve() != INDEX.parent.resolve()
            or base.hostname != '127.0.0.1' or base.port != 23374):
        raise SourceFailure()
    account = status['readiness']['app']['matrix']['userID']
    if account != conversation['accountId']:
        raise SourceFailure()
    with sqlite3.connect(f'file:{INDEX}?mode=ro', uri=True) as db:
        db.execute('PRAGMA query_only=ON')
        rows = db.execute('SELECT id,isDeleted,isEdited,message FROM mx_room_messages WHERE roomID=? AND eventID=?',
                          (room, event)).fetchall()
    if len(rows) != 1:
        raise SourceFailure()
    if rows[0][1]:
        return {'isDeleted': True}, None
    canonical = json.loads(rows[0][3])
    original = ordinary_voice(canonical)
    # The public message API omits some behavior/timer fields. The canonical
    # stored model must approve export before the API is used to resolve bytes.
    if rows[0][2] or original is None:
        return canonical, None
    message = beeper('messages', 'show', '--chat', room, '--id', str(rows[0][0]), '--read-only', target=target['id'])
    if str(message['id']) != str(rows[0][0]) or message['chatID'] != room:
        raise SourceFailure()
    attachment = ordinary_voice(message)
    if attachment is not None:
        if any(attachment.get(k) != original.get(k) for k in ('id', 'mimeType', 'fileSize')):
            raise SourceFailure()
        attachment = {**attachment, '_sourceTarget': target['id']}
    return message, attachment


def audio_file(attachment):
    url = attachment['srcURL']
    if url.startswith(('mxc://', 'localmxc://')):
        value = beeper('api', 'post', '/v1/assets/download', '--body', json.dumps({'url': url}), target=attachment['_sourceTarget'])
        url = value.get('srcURL', '')
    parsed = urlparse(url)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        raise SourceFailure()
    file = Path(unquote(parsed.path)).resolve(strict=True)
    if not file.is_relative_to(Path('/home/eouser/.beeper')) or not file.is_file():
        raise SourceFailure()
    if not 0 < file.stat().st_size <= MAX_BYTES:
        raise SourceFailure()
    return file


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if self.path != '/source' or not 0 < length <= 16384:
                raise SourceFailure()
            request = json.loads(self.rfile.read(length))
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
                    'mimeType': attachment['mimeType'] if attachment else None}).encode(), 'application/json')
                return
            if attachment is None:
                self.reply(403, b'{}', 'application/json')
                return
            file = audio_file(attachment)
            # Fresh source policy after download; never export deleted/limited media.
            _, after = selected_source(source)
            if after is None or any(after.get(k) != attachment.get(k) for k in ('id', 'mimeType', 'fileSize')):
                raise SourceFailure()
            with file.open('rb') as stream:
                data = stream.read(MAX_BYTES + 1)
            if not 0 < len(data) <= MAX_BYTES:
                raise SourceFailure()
            self.reply(200, data, 'application/octet-stream')
        except Exception:
            self.reply(503, b'{"error":"local_source_unavailable"}', 'application/json')

    def reply(self, status, data, mime):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if __name__ == '__main__':
    os.umask(0o007)
    # systemd supplies a fresh RuntimeDirectory; never unlink an unknown socket.
    with Server(SOCKET, Handler) as server:
        os.chmod(SOCKET, 0o660)
        server.serve_forever()
