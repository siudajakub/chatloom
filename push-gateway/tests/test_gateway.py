# SPDX-License-Identifier: AGPL-3.0-or-later

import concurrent.futures
from contextlib import contextmanager
from dataclasses import replace
import http.client
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "gateway.py"
spec = importlib.util.spec_from_file_location("personal_gateway", MODULE)
gateway = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gateway
spec.loader.exec_module(gateway)
try:
    import google.auth
    HAS_GOOGLE_AUTH = True
except ImportError:
    HAS_GOOGLE_AUTH = False

TOKEN = "fixture-registration-token"
NONCE = "n" * 43
APP = "pl.personal.chat.FIXTURE"


class Publisher:
    def __init__(self, outcomes=()):
        self.calls = []
        self.outcomes = list(outcomes)

    def publish(self, token, data, priority):
        self.calls.append((token, data, priority))
        return self.outcomes.pop(0) if self.outcomes else gateway.PublishResult("accepted")


def packet(event="$fixture-event", **extra):
    notification = {
        "counts": {"unread": 2},
        "devices": [{"app_id": APP, "pushkey": TOKEN,
            "data": {"format": "event_id_only", "gateway_nonce": NONCE}}],
    }
    if event is not None:
        notification.update(event_id=event, room_id="!fixture-room:invalid")
    notification.update(extra)
    return {"notification": notification}


@contextmanager
def context(outcomes=(), **settings):
    with tempfile.TemporaryDirectory() as directory:
        config = gateway.Config(project_id="fixture-project", service_account_file="/fixture/account.json",
            registrations=(gateway.Registration(TOKEN, APP, NONCE),), state_directory=directory, **settings)
        publisher = Publisher(outcomes)
        yield gateway.Gateway(config, publisher), publisher


class GatewayTests(unittest.TestCase):
    def assert_error(self, status, callable_):
        with self.assertRaises(gateway.GatewayError) as caught:
            callable_()
        self.assertEqual(caught.exception.status, status)
        self.assertNotIn(TOKEN, str(caught.exception))
        self.assertNotIn(NONCE, str(caught.exception))

    def test_payload_strips_all_content_and_private_device_data(self):
        with context() as (app, publisher):
            request = packet(content={"body":"SECRET_CANARY"}, sender="SECRET_SENDER",
                sender_display_name="SECRET_CONTACT", room_name="SECRET_ROOM",
                type="m.room.message", default_payload={"body":"SECRET_DEFAULT"})
            request["notification"]["devices"][0]["data"].update(client_name="SECRET_CLIENT", default_payload={"body":"SECRET_DEFAULT"})
            self.assertEqual(app.notify(request), {"rejected":[]})
            _, data, priority = publisher.calls[0]
            self.assertEqual(set(data), {"event_id","room_id","counts","devices"})
            self.assertEqual(json.loads(data["counts"]), {"unread":2})
            self.assertEqual(json.loads(data["devices"]), [])
            self.assertTrue(all(isinstance(v, str) for v in data.values()))
            self.assertNotIn("SECRET_", json.dumps(data))
            self.assertNotIn(NONCE, json.dumps(data))
            self.assertNotIn(TOKEN, json.dumps(data))
            self.assertEqual(priority, "high")
            self.assertNotIn("fixture-room", app.db_path.read_bytes().decode("latin1"))

    def test_registration_and_nonce_are_required(self):
        with context() as (app, publisher):
            request = packet()
            request["notification"]["devices"][0]["data"]["gateway_nonce"] = "wrong"
            self.assert_error(403, lambda: app.notify(request))
            request["notification"]["devices"][0]["data"]["gateway_nonce"] = "ź"
            self.assert_error(403, lambda: app.notify(request))
            request = packet()
            request["notification"]["devices"][0]["data"]["format"] = "full"
            self.assert_error(400, lambda: app.notify(request))
            request = packet()
            request["notification"]["devices"][0]["app_id"] = "other.app"
            self.assertEqual(app.notify(request), {"rejected":[TOKEN]})
            request = packet()
            request["notification"]["devices"][0]["pushkey"] = "unknown-token"
            self.assertEqual(app.notify(request), {"rejected":["unknown-token"]})
            self.assertEqual(publisher.calls, [])

    def test_all_auth_validation_precedes_side_effects(self):
        with context() as (app, publisher):
            request = packet()
            request["notification"]["devices"].append({"app_id":APP,"pushkey":TOKEN,
                "data":{"format":"event_id_only","gateway_nonce":"bad"}})
            self.assert_error(403, lambda: app.notify(request))
            self.assertEqual(publisher.calls, [])

    def test_dedup_concurrent_and_restart(self):
        with context() as (app, publisher):
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                results = list(pool.map(lambda _: app.notify(packet()), range(12)))
            self.assertEqual(results, [{"rejected":[]}] * 12)
            self.assertEqual(len(publisher.calls), 1)
            restarted = gateway.Gateway(app.config, publisher)
            restarted.notify(packet())
            self.assertEqual(len(publisher.calls), 1)

    def test_count_updates_repeat_normally(self):
        with context() as (app, publisher):
            app.notify(packet(None, counts={"unread":0}))
            app.notify(packet(None, counts={"unread":0}))
            self.assertEqual(len(publisher.calls), 2)
            self.assertEqual(publisher.calls[0][2], "normal")

    def test_provider_failure_is_not_silently_dropped(self):
        with context([gateway.PublishResult("transient",120),gateway.PublishResult("accepted")]) as (app, publisher):
            self.assert_error(503, lambda: app.notify(packet()))
            app.notify(packet())
            self.assertEqual(len(publisher.calls),2)
        with context([gateway.PublishResult("rejected")]) as (app,publisher):
            self.assertEqual(app.notify(packet()), {"rejected":[TOKEN]})
            self.assertEqual(app.notify(packet("$second")), {"rejected":[TOKEN]})
            restarted = gateway.Gateway(app.config,publisher)
            self.assertEqual(restarted.notify(packet("$third")), {"rejected":[TOKEN]})
            self.assertEqual(len(publisher.calls),1)

    def test_badges_counts_limits_and_missing_room(self):
        with context(rate_per_minute=1) as (app,publisher):
            for count in [True,-1,2**32,"2"]:
                self.assert_error(400,lambda:app.notify(packet(counts={"unread":count})))
            self.assert_error(400,lambda:app.notify(packet(room_id=None)))
            self.assert_error(400,lambda:app.notify(packet(devices=[{}]*9)))
            app.notify(packet())
            self.assert_error(503,lambda:app.notify(packet("$different")))
            self.assertEqual(len(publisher.calls),1)

    def test_provider_error_classification(self):
        error=lambda code:json.dumps({"error":{"details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":code}]}}).encode()
        self.assertEqual(gateway.provider_result(404,error("UNREGISTERED")).status,"rejected")
        self.assertEqual(gateway.provider_result(403,error("SENDER_ID_MISMATCH")).status,"rejected")
        for code in (400,401,403,404,429,500,503):
            self.assertEqual(gateway.provider_result(code,b'{}').status,"transient")
        self.assertEqual(gateway.provider_result(429,b'{}',"120").retry_after,120)
        self.assertEqual(gateway.provider_result(200,b'{}').status,"accepted")

    def test_fcm_http_v1_envelope_with_fake_auth_and_http(self):
        publisher=gateway.FcmPublisher.__new__(gateway.FcmPublisher)
        class Credentials:
            def before_request(self,auth,method,url,headers):
                headers['Authorization']='Bearer SECRET_AUTH_CANARY'
        publisher.credentials=Credentials()
        publisher.project_id='fixture-project'
        publisher.timeout=8
        publisher.auth_request=None
        publisher.auth_lock=threading.Lock()
        with patch.object(gateway,'http_request',return_value=(200,{},b'{}')) as request:
            outcome=publisher.publish(TOKEN,gateway.routing_data(packet()['notification']),'high')
        self.assertEqual(outcome.status,'accepted')
        self.assertEqual(request.call_args.args[0],'https://fcm.googleapis.com/v1/projects/fixture-project/messages:send')
        body=json.loads(request.call_args.kwargs['body'])
        self.assertEqual(body['message']['token'],TOKEN)
        self.assertEqual(body['message']['android']['restricted_package_name'],'pl.personal.chat')
        self.assertNotIn('notification',body['message'])
        self.assertNotIn('SECRET_AUTH_CANARY',json.dumps(body))

    @unittest.skipUnless(HAS_GOOGLE_AUTH, 'Run optional auth test in requirements.txt venv')
    def test_real_google_auth_signer_only_calls_mocked_google_endpoints(self):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        pem=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()).decode()
        with tempfile.TemporaryDirectory() as directory:
            credential=Path(directory)/'synthetic-service-account.json'
            info={'type':'service_account','project_id':'fixture-project',
                'private_key':pem,'private_key_id':'fixture-key',
                'client_email':'fixture@fixture-project.iam.gserviceaccount.com',
                'token_uri':'https://oauth2.googleapis.com/token'}
            credential.write_text(json.dumps(info));credential.chmod(0o600)
            config=gateway.Config(project_id='fixture-project',service_account_file=str(credential),
                registrations=(gateway.Registration(TOKEN,APP,NONCE),),state_directory=directory)
            publisher=gateway.FcmPublisher(config)
            responses=[(200,{},b'{"access_token":"fixture-access-token","expires_in":3600,"token_type":"Bearer"}'),
                (200,{},b'{"name":"fixture-accepted"}')]
            with patch.object(gateway,'http_request',side_effect=responses) as request:
                result=publisher.publish(TOKEN,{'event_id':'$fixture','room_id':'!fixture'},'high')
            self.assertEqual(result.status,'accepted')
            self.assertEqual([call.args[0] for call in request.call_args_list],[
                'https://oauth2.googleapis.com/token',
                'https://fcm.googleapis.com/v1/projects/fixture-project/messages:send'])
            self.assertEqual(publisher.credentials.scopes,['https://www.googleapis.com/auth/firebase.messaging'])
            info['project_id']='other-project'
            credential.write_text(json.dumps(info))
            with self.assertRaises(gateway.ConfigError):gateway.FcmPublisher(config)

    def test_offline_setup_only_writes_private_outside_repository_files(self):
        setup_spec=importlib.util.spec_from_file_location('personal_push_setup',MODULE.parent/'setup.py')
        setup=importlib.util.module_from_spec(setup_spec)
        with patch.dict(sys.modules,{'gateway':gateway}):
            setup_spec.loader.exec_module(setup)
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory)
            config=base/'config.json'
            nonce_file=base/'pusher-data.json'
            setup.atomic_private_json(config,{'project_id':'fixture-project',
                'service_account_file':'/fixture/account.json','state_directory':str(base/'state'),
                'registrations':[]})
            setup.register(config,APP,nonce_file,TOKEN,NONCE)
            self.assertEqual(gateway.Config.load(config).registrations[0].nonce,NONCE)
            self.assertEqual(nonce_file.stat().st_mode & 0o777,0o600)
            self.assertNotIn(TOKEN,nonce_file.read_text())
            android=base/'google-services.json'
            setup.atomic_private_json(android,{'project_info':{'project_id':'fixture-project'},'client':[
                {'client_info':{'android_client_info':{'package_name':'pl.personal.chat'}}}]})
            self.assertTrue(setup.check_android_config(android,'fixture-project'))
            with self.assertRaises(gateway.ConfigError):setup.check_android_config(android,'wrong-project')
            repo=base/'repository'
            repo.mkdir();(repo/'.git').write_text('fixture')
            with self.assertRaises(gateway.ConfigError):setup.atomic_private_json(repo/'credentials.json',{})

    def test_reminder_auth_minimal_payload_and_durable_dedup(self):
        with tempfile.TemporaryDirectory() as directory:
            credential=Path(directory)/'relay.json'
            credential.write_text(json.dumps({'token':'r'*43}));credential.chmod(0o600)
            hint={'hintId':'a'*64,'emittedAt':'2026-10-04T12:00:00Z'}
            with context(reminder_credential_file=str(credential)) as (app,publisher):
                self.assert_error(403,lambda:app.reminder(hint,'Bearer wrong','127.0.0.1'))
                self.assert_error(403,lambda:app.reminder(hint,'Bearer '+('r'*43),'203.0.113.1'))
                self.assert_error(400,lambda:app.reminder({**hint,'room_id':'!fixture'},'Bearer '+('r'*43),'127.0.0.1'))
                self.assert_error(400,lambda:app.reminder({**hint,'emittedAt':'2026-10-04T12:00:00'},'Bearer '+('r'*43),'127.0.0.1'))
                self.assertEqual(publisher.calls,[])
                self.assertEqual(app.reminder(hint,'Bearer '+('r'*43),'127.0.0.1'),{'accepted':True,'state':'fcm_accepted'})
                restarted=gateway.Gateway(app.config,publisher)
                restarted.reminder(hint,'Bearer '+('r'*43),'127.0.0.1')
                self.assertEqual(len(publisher.calls),1)
                self.assertEqual(publisher.calls[0][1],{'personal_wake':'reminder'})
                self.assertNotIn(hint['hintId'],app.db_path.read_bytes().decode('latin1'))
                self.assertNotIn(hint['emittedAt'],app.db_path.read_bytes().decode('latin1'))

    def test_reminder_no_devices_and_transient_preserve_worker_hint(self):
        with context() as (app,publisher):
            self.assert_error(404,lambda:app.reminder({'hintId':'a'*64,'emittedAt':'2026-10-04T12:00:00Z'},None,'127.0.0.1'))
        with tempfile.TemporaryDirectory() as directory:
            credential=Path(directory)/'relay.json'
            credential.write_text(json.dumps({'token':'r'*43}));credential.chmod(0o600)
            hint={'hintId':'b'*64,'emittedAt':'2026-10-04T12:00:00.000Z'}
            auth='Bearer '+('r'*43)
            with context([gateway.PublishResult('transient'),gateway.PublishResult('accepted')],reminder_credential_file=str(credential)) as (app,publisher):
                self.assert_error(503,lambda:app.reminder(hint,auth,'127.0.0.1'))
                app.reminder(hint,auth,'127.0.0.1')
                self.assertEqual(len(publisher.calls),2)
                empty=gateway.Gateway(replace(app.config,registrations=()),publisher)
                self.assert_error(503,lambda:empty.reminder(hint,auth,'127.0.0.1'))

    def test_private_config_permissions_and_loopback(self):
        with context() as (app,_):
            with self.assertRaises(gateway.ConfigError): replace(app.config,bind="0.0.0.0").validate()
            with self.assertRaises(gateway.ConfigError): gateway.Server(app,address=("0.0.0.0",0))
            configfile=Path(app.config.state_directory)/"config.json"
            configfile.write_text('{"fixture":true}')
            configfile.chmod(0o644)
            with self.assertRaises(gateway.ConfigError):gateway.private_json(configfile)
            configfile.chmod(0o600)
            self.assertEqual(gateway.private_json(configfile),{"fixture":True})
            link=Path(app.config.state_directory)/"link"
            link.symlink_to(configfile)
            with self.assertRaises(OSError):gateway.private_json(link)

    def test_http_contract_no_provider_calls_for_bad_requests(self):
        with context() as (app,publisher):
            server=gateway.Server(app,address=("127.0.0.1",0))
            thread=threading.Thread(target=server.serve_forever,daemon=True)
            thread.start()
            try:
                for method,path,body,headers,expected in [
                    ("GET",gateway.ENDPOINT,None,{},405),
                    ("POST","/unknown",b'{}',{"Content-Type":"application/json"},404),
                    ("POST",gateway.ENDPOINT,b'{' ,{"Content-Type":"application/json"},400),
                    ("POST",gateway.ENDPOINT,b'x'*17000,{"Content-Type":"application/json"},413),
                    ("POST",gateway.ENDPOINT,b'{}',{"Content-Type":"text/plain"},415),
                ]:
                    connection=http.client.HTTPConnection(*server.server_address,timeout=2)
                    connection.request(method,path,body,headers)
                    response=connection.getresponse()
                    self.assertEqual(response.status,expected)
                    self.assertIn("errcode",json.loads(response.read()))
                    connection.close()
                self.assertEqual(publisher.calls,[])
                connection=http.client.HTTPConnection(*server.server_address,timeout=2)
                connection.request("POST",gateway.ENDPOINT,json.dumps(packet()),{"Content-Type":"application/json"})
                response=connection.getresponse()
                self.assertEqual(response.status,200)
                self.assertEqual(json.loads(response.read()),{"rejected":[]})
                connection.close()
            finally:
                server.shutdown();server.server_close();thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
