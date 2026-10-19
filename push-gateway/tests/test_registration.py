# SPDX-License-Identifier: AGPL-3.0-or-later
from dataclasses import replace
import concurrent.futures
import hashlib
import http.client
import json
import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from test_gateway import gateway, Publisher, TOKEN, APP, NONCE, packet

USER = "@fixture:matrix.beeper.com"
OWNER = hashlib.sha256(USER.encode()).hexdigest()


def enrollment(**values):
    return {"app_id": APP, "pushkey": TOKEN, "nonce": NONCE, "account_sha256": OWNER,
            "openid": {"access_token": "SHORT_LIVED_PROOF_CANARY", "expires_in": 3600,
                       "token_type": "Bearer", "matrix_server_name": "matrix.beeper.com"}, **values}


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = gateway.Config(project_id="fixture-project", service_account_file="/fixture/account.json",
            registrations=(), state_directory=self.directory.name, registration_allowed_users_sha256=(OWNER,))
        self.publisher = Publisher()
        self.app = gateway.Gateway(self.config, self.publisher)
        self.identity = patch.object(gateway, "http_request", return_value=(200, {}, json.dumps({"sub": USER}).encode()))
        self.http = self.identity.start()
        self.addCleanup(self.identity.stop)

    def error(self, status, value):
        with self.assertRaises(gateway.GatewayError) as caught:
            self.app.register(value)
        self.assertEqual(caught.exception.status, status)
        self.assertNotIn("CANARY", str(caught.exception))
        self.assertEqual(self.publisher.calls, [])

    def test_enrollment_idempotence_restart_and_token_rotation(self):
        self.assertEqual(self.app.register(enrollment()), {"registered": True})
        self.app.register(enrollment())
        self.assertEqual(self.app.db_path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("SHORT_LIVED_PROOF_CANARY", self.app.db_path.read_bytes().decode("latin1"))
        self.assertEqual(self.publisher.calls, [])
        restarted = gateway.Gateway(self.config, self.publisher)
        self.assertEqual(restarted.notify(packet()), {"rejected": []})
        self.assertEqual(len(self.publisher.calls), 1)
        new_token = "fixture-rotated-token"
        restarted.register(enrollment(pushkey=new_token))
        self.assertEqual(restarted.notify(packet("$old")), {"rejected": [TOKEN]})
        request = packet("$new")
        request["notification"]["devices"][0]["pushkey"] = new_token
        self.assertEqual(restarted.notify(request), {"rejected": []})
        self.assertEqual(self.publisher.calls[-1][0], new_token)
        with restarted.database() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM registrations").fetchone()[0], 1)

    def test_untrusted_accounts_issuers_and_malformed_inputs_never_call_identity(self):
        for value in [None, {}, enrollment(account_sha256="a" * 64), enrollment(app_id="other.app"),
                      enrollment(nonce="bad"), enrollment(pushkey="short"), enrollment(extra="forbidden")]:
            self.error(403 if isinstance(value, dict) and value.get("account_sha256") == "a" * 64 else 400, value)
        for changes in [{"matrix_server_name": "127.0.0.1"}, {"matrix_server_name": "evil.invalid"},
                        {"token_type": "Other"}, {"expires_in": 0}, {"expires_in": True}, {"access_token": ""}]:
            value = enrollment()
            value["openid"].update(changes)
            self.error(403, value)
        self.http.assert_not_called()

    def test_wrong_subject_expired_proof_and_unavailable_identity_fail_closed(self):
        for reply, status in [((200, {}, b'{"sub":"@other:invalid"}'), 403),
                              ((401, {}, b'{}'), 403), ((403, {}, b'{}'), 403),
                              ((503, {}, b'{}'), 503), ((302, {}, b'{}'), 503),
                              ((200, {}, b'not json'), 503)]:
            self.http.return_value = reply
            self.error(status, enrollment())
        self.http.side_effect = TimeoutError()
        self.error(503, enrollment())
        self.assertEqual(self.app.notify(packet()), {"rejected": [TOKEN]})

    def test_identity_url_is_operator_pinned_and_proof_is_not_persisted(self):
        self.app.register(enrollment())
        url = self.http.call_args.args[0]
        self.assertTrue(url.startswith("https://matrix.beeper.com/_matrix/federation/v1/openid/userinfo?"))
        self.assertEqual(set(self.http.call_args.kwargs), {"timeout"})
        self.assertNotIn(TOKEN, url)
        with self.app.database() as db:
            rows = db.execute("SELECT * FROM registrations").fetchall()
        self.assertNotIn(USER, str(rows))
        self.assertNotIn("CANARY", str(rows))

    def test_rate_limit_and_per_account_device_limit_are_bounded(self):
        limit = gateway.MAX_DEVICES_PER_ACCOUNT
        for index in range(limit + 2):
            self.app.register(enrollment(app_id=f"pl.personal.chat.FIXTURE_{index}", pushkey=f"fixture-token-number-{index}"))
        with self.app.database() as db:
            apps = {row[0] for row in db.execute("SELECT app_id FROM registrations")}
        # The least recently registered rows of the same account are evicted.
        self.assertEqual(len(apps), limit)
        self.assertNotIn("pl.personal.chat.FIXTURE_0", apps)
        self.assertNotIn("pl.personal.chat.FIXTURE_1", apps)
        self.assertIn(f"pl.personal.chat.FIXTURE_{limit + 1}", apps)
        self.assertNotIn("fixture-token-number-0", self.app.active)
        for _ in range(20 - (limit + 2)):
            self.app.register(enrollment(app_id="pl.personal.chat.FIXTURE_2", pushkey="fixture-token-number-2"))
        self.error(429, enrollment())
        self.assertEqual(self.http.call_count, 20)

    def test_same_account_relogin_moves_the_token_to_the_new_device_app_id(self):
        self.app.register(enrollment())
        relogin = "pl.personal.chat.RELOGIN"
        self.assertEqual(self.app.register(enrollment(app_id=relogin, nonce="m" * 43)), {"registered": True})
        with self.app.database() as db:
            rows = db.execute("SELECT app_id FROM registrations").fetchall()
        self.assertEqual(rows, [(relogin,)])
        # The old pusher (old app id) is refused; the new one publishes.
        self.assertEqual(self.app.notify(packet()), {"rejected": [TOKEN]})
        request = packet("$after-relogin")
        request["notification"]["devices"][0].update(app_id=relogin)
        request["notification"]["devices"][0]["data"]["gateway_nonce"] = "m" * 43
        self.assertEqual(self.app.notify(request), {"rejected": []})
        self.assertEqual(len(self.publisher.calls), 1)
        restarted = gateway.Gateway(self.config, self.publisher)
        self.assertEqual(restarted.active[TOKEN].app_id, relogin)
        # Moving back is just as idempotent.
        self.app.register(enrollment())
        with self.app.database() as db:
            self.assertEqual(db.execute("SELECT app_id FROM registrations").fetchall(), [(APP,)])

    def test_eviction_follows_the_latest_registration_and_keeps_the_schema(self):
        limit = gateway.MAX_DEVICES_PER_ACCOUNT
        for index in range(limit):
            self.app.register(enrollment(app_id=f"pl.personal.chat.FIXTURE_{index}", pushkey=f"fixture-token-number-{index}"))
        # Refreshing the oldest makes it the newest: the next new device evicts FIXTURE_1.
        self.app.register(enrollment(app_id="pl.personal.chat.FIXTURE_0", pushkey="fixture-token-number-0"))
        self.app.register(enrollment(app_id="pl.personal.chat.NEW", pushkey="fixture-token-new"))
        with self.app.database() as db:
            apps = {row[0] for row in db.execute("SELECT app_id FROM registrations")}
            columns = [row[1] for row in db.execute("PRAGMA table_info(registrations)")]
        self.assertIn("pl.personal.chat.FIXTURE_0", apps)
        self.assertNotIn("pl.personal.chat.FIXTURE_1", apps)
        self.assertEqual(len(apps), limit)
        # Unchanged schema: a rollback to the previous gateway keeps working.
        self.assertEqual(columns, ["owner", "app_id", "pushkey", "nonce"])

    def test_revoked_account_and_disabled_service_do_not_accept_registrations(self):
        self.app.register(enrollment())
        disabled = gateway.Gateway(replace(self.config, registration_allowed_users_sha256=()), self.publisher)
        self.assertEqual(disabled.notify(packet()), {"rejected": [TOKEN]})
        with self.assertRaises(gateway.GatewayError) as caught:
            disabled.register(enrollment())
        self.assertEqual(caught.exception.code, "M_REGISTRATION_DISABLED")

    def test_another_allowed_account_cannot_claim_a_registered_token(self):
        self.app.register(enrollment())
        second_user = "@second:matrix.beeper.com"
        second = hashlib.sha256(second_user.encode()).hexdigest()
        self.app.config = replace(self.config, registration_allowed_users_sha256=(OWNER, second))
        self.http.return_value = (200, {}, json.dumps({"sub": second_user}).encode())
        self.error(409, enrollment(account_sha256=second))

    def test_registration_http_endpoint_and_no_redirect_contract(self):
        server = gateway.Server(self.app, address=("127.0.0.1", 0))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = http.client.HTTPConnection(*server.server_address, timeout=2)
            connection.request("POST", gateway.REGISTER_ENDPOINT, json.dumps(enrollment()), {"Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            self.assertEqual(json.loads(response.read()), {"registered": True})
            connection.close()
            self.assertEqual(self.publisher.calls, [])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.assertIsNone(gateway.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.invalid"))

    def test_config_requires_https_pin_and_valid_account_fingerprints(self):
        for values in [{"registration_openid_origin": "http://matrix.beeper.com"},
                       {"registration_openid_origin": "https://matrix.beeper.com/?token=bad"},
                       {"registration_openid_origin": "https://user:password@matrix.beeper.com"},
                       {"registration_allowed_users_sha256": (USER,)},
                       {"registration_openid_server": "https://evil.invalid"}]:
            with self.assertRaises(gateway.ConfigError):
                replace(self.config, **values).validate()

    def test_static_migration_never_resurrects_old_token_after_rotation_or_revocation(self):
        config = replace(self.config, registrations=(gateway.Registration(TOKEN, APP, NONCE),))
        app = gateway.Gateway(config, self.publisher)
        app.register(enrollment(nonce="r" * 43))
        with app.database() as db:
            self.assertEqual(app.active_registrations(db)[TOKEN].nonce, "r" * 43)
        new_token = "fixture-migrated-token"
        app.register(enrollment(pushkey=new_token, nonce="r" * 43))
        self.assertEqual(app.notify(packet()), {"rejected": [TOKEN]})
        restarted = gateway.Gateway(replace(config, registration_allowed_users_sha256=()), self.publisher)
        self.assertEqual(restarted.notify(packet()), {"rejected": [TOKEN]})
        self.assertEqual(self.publisher.calls, [])

    def test_concurrent_retries_keep_only_one_registration_per_app(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.app.register(enrollment()), range(12)))
        self.assertEqual(results, [{"registered": True}] * 12)
        with self.app.database() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM registrations").fetchone()[0], 1)

    def test_operator_setup_adds_only_account_digest_and_preserves_private_config(self):
        spec = importlib.util.spec_from_file_location("personal_enrollment_setup", Path(gateway.__file__).with_name("setup.py"))
        setup = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"gateway": gateway}):
            spec.loader.exec_module(setup)
        path = Path(self.directory.name) / "private-config.json"
        initial = {"project_id": "fixture-project", "service_account_file": "/fixture/account.json",
                   "state_directory": self.directory.name, "registrations": []}
        setup.atomic_private_json(path, initial)
        setup.enable_enrollment(path, USER, "matrix.beeper.com", "https://matrix.beeper.com")
        setup.enable_enrollment(path, USER, "matrix.beeper.com", "https://matrix.beeper.com")
        self.assertEqual(gateway.Config.load(path).registration_allowed_users_sha256, [OWNER])
        self.assertNotIn(USER, path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        before = path.read_bytes()
        with self.assertRaises(gateway.ConfigError):
            setup.enable_enrollment(path, USER, "matrix.beeper.com", "http://invalid")
        self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
