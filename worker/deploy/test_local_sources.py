import copy
import importlib.util
from pathlib import Path
import unittest
import tempfile
import sqlite3
import json
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
            status = {'target': {'dataDir': directory, 'baseURL': 'http://127.0.0.1:23374', 'id': 'fixture'},
                      'readiness': {'app': {'matrix': {'userID': '@fixture:example.invalid'}}}}
            def api(*args, **kwargs):
                self.assertEqual(args, ('status',), 'A restricted source must not reach message/media API calls')
                return status
            source = {'conversation': {'roomId': '!fixture:beeper.local', 'accountId': '@fixture:example.invalid'},
                      'eventId': '$fixture'}
            with patch.object(sources, 'INDEX', index), patch.object(sources, 'beeper', side_effect=api):
                _, attachment = sources.selected_source(source)
                self.assertIsNone(attachment)


if __name__ == '__main__':
    unittest.main()
