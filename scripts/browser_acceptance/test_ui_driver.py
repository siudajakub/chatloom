"""Account-free publisher-cadence regressions. No Playwright import or browser."""
import datetime
import collections
import json
from types import SimpleNamespace
import unittest

from ui_driver import Driver, Refused, console_source_location, fresh_guard_after


def snapshot(heartbeat=1000, blocked=0, pid=7, started='1970-01-01T00:01:00+00:00'):
    return {'pid': pid, 'started_at': started, 'blocked_attempts': blocked,
            'heartbeat_at': datetime.datetime.fromtimestamp(heartbeat, datetime.timezone.utc).isoformat()}


class FreshGuardTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.pumps = 0

    def pump(self, milliseconds):
        self.now += milliseconds / 1000
        self.pumps += 1

    def run_after(self, read):
        return fresh_guard_after(read, self.pump, snapshot(), 1000,
                                 timeout_ms=2500, monotonic=lambda: self.now)

    def test_same_valid_heartbeat_does_not_hide_new_block(self):
        records = iter([snapshot(), snapshot(1001, blocked=1)])
        result = self.run_after(lambda: next(records))
        self.assertEqual(result['blocked_attempts'], 1)
        self.assertEqual(self.pumps, 1)

    def test_heartbeat_equal_to_completion_is_not_new_enough(self):
        records = iter([snapshot(), snapshot(1000.001)])
        self.run_after(lambda: next(records))
        self.assertEqual(self.pumps, 1)

    def test_fresh_same_generation_snapshot_succeeds(self):
        self.assertEqual(self.run_after(lambda: snapshot(1001))['blocked_attempts'], 0)
        self.assertEqual(self.pumps, 0)

    def test_stale_publisher_times_out_within_bound(self):
        with self.assertRaisesRegex(Refused, '') as error:
            self.run_after(snapshot)
        self.assertEqual(error.exception.code, 'FRESH_GUARD_TIMEOUT')
        self.assertLessEqual(self.now, 2.501)

    def test_pid_restart_is_refused(self):
        with self.assertRaises(Refused) as error:
            self.run_after(lambda: snapshot(1001, pid=8))
        self.assertEqual(error.exception.code, 'GUARD_GENERATION_CHANGED')

    def test_reused_pid_new_generation_is_refused(self):
        with self.assertRaises(Refused) as error:
            self.run_after(lambda: snapshot(1001, started='1970-01-01T00:02:00+00:00'))
        self.assertEqual(error.exception.code, 'GUARD_GENERATION_CHANGED')

    def test_counter_reset_is_refused(self):
        with self.assertRaises(Refused) as error:
            fresh_guard_after(lambda: snapshot(1001), self.pump,
                              snapshot(blocked=1), 1000, monotonic=lambda: self.now)
        self.assertEqual(error.exception.code, 'GUARD_COUNTER_REGRESSED')

    def test_new_fault_refuses_during_wait(self):
        def broken_guard():
            raise Refused('GUARD_NOT_READY')
        with self.assertRaises(Refused) as error:
            self.run_after(broken_guard)
        self.assertEqual(error.exception.code, 'GUARD_NOT_READY')


class ConsoleDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        # Exercise the production reducer without constructing a browser driver.
        self.driver = Driver.__new__(Driver)
        self.driver.counts = collections.Counter()
        self.driver.codes = collections.Counter()
        self.driver.positions = set()
        self.driver.source_locations = set()

    def emit(self, text, kind='error', location=None):
        self.driver.console(SimpleNamespace(type=kind, text=text, location=location or {}))

    def test_known_asset_console_locations_convert_to_one_based(self):
        for asset in ('main.dart.js', 'native_executor.js'):
            location = {'url': 'http://127.0.0.1:5183/' + asset,
                        'lineNumber': 0, 'columnNumber': 4}
            self.assertEqual(console_source_location(location), (asset, 1, 5))
            self.emit('Unclassified fictional error', location=location)
            self.assertIn((asset, 1, 5), self.driver.source_locations)
        self.assertIn(('1', '5'), self.driver.positions)
        self.assertEqual(self.driver.counts['console_error'], 2)
        self.assertEqual(self.driver.counts['console_error_unclassified'], 2)

    def test_unknown_asset_query_fragment_and_invalid_coordinates_are_ignored(self):
        base = {'url': 'http://127.0.0.1:5183/main.dart.js', 'lineNumber': 0, 'columnNumber': 0}
        for url in ('http://synthetic.invalid/private.js',
                    'http://synthetic.invalid/main.dart.js.map',
                    'http://synthetic.invalid/main.dart.js?fiction=1',
                    'http://synthetic.invalid/main.dart.js?',
                    'http://synthetic.invalid/native_executor.js#fiction',
                    'http://synthetic.invalid/native_executor.js#',
                    'file:///fiction/main.dart.js', 'main.dart.js', 'http://[invalid'):
            self.assertIsNone(console_source_location({**base, 'url': url}))
        for field in ('lineNumber', 'columnNumber'):
            for value in (None, -1, True, '17', 1.5, 2**31):
                self.assertIsNone(console_source_location({**base, field: value}))
        self.assertIsNone(console_source_location(None))

    def test_flutter_phrases_emit_fixed_nonexclusive_codes(self):
        self.emit('EXCEPTION CAUGHT BY RENDERING LIBRARY: A RenderFlex overflowed by 11 pixels')
        self.emit('Failed assertion: fictional condition; SemanticsNode update')
        self.emit('AssertionError: fictional condition')
        self.assertEqual(self.driver.codes['flutter_exception_caught'], 1)
        self.assertEqual(self.driver.codes['flutter_renderflex_overflow'], 1)
        self.assertEqual(self.driver.codes['flutter_assertion'], 2)
        self.assertEqual(self.driver.codes['flutter_semantics'], 1)
        self.assertEqual(self.driver.counts['console_error'], 3)
        self.assertEqual(self.driver.counts['console_error_unclassified'], 0)

    def test_existing_codes_and_unknown_counts_are_preserved_without_private_output(self):
        self.emit('invalid_state missing_value databaseUnavailable mediaUnavailable')
        self.emit('Another exception was thrown: FICTIONAL_PRIVATE_EXCEPTION')
        self.emit('FICTIONAL_PRIVATE_CONTENT https://synthetic.invalid/private?fiction=secret')
        self.emit('FICTIONAL_PRIVATE_WARNING', kind='warning')
        self.assertEqual(self.driver.counts['console_error'], 3)
        self.assertEqual(self.driver.counts['console_error_unclassified'], 1)
        self.assertEqual(self.driver.codes['flutter_exception_thrown'], 1)
        self.assertEqual(self.driver.counts['console_warning'], 1)
        self.assertEqual(self.driver.counts['console_warning_unclassified'], 1)
        for code in ('invalid_state', 'missing_value', 'databaseUnavailable', 'mediaUnavailable'):
            self.assertEqual(self.driver.codes[code], 1)
        reduced = json.dumps([dict(self.driver.counts), dict(self.driver.codes),
                              sorted(self.driver.positions), sorted(self.driver.source_locations)])
        for private in ('FICTIONAL_PRIVATE', 'https://', 'secret', 'synthetic.invalid'):
            self.assertNotIn(private, reduced)

    def test_stack_positions_keep_existing_one_based_coordinates_and_asset(self):
        self.emit('Fictional stack main.dart.js:17:23 native_executor.js:7:9')
        self.driver.page_error(SimpleNamespace(stack='main.dart.js:31:12'))
        self.assertIn(('17', '23'), self.driver.positions)
        self.assertIn(('native_executor.js', 7, 9), self.driver.source_locations)
        self.assertIn(('main.dart.js', 31, 12), self.driver.source_locations)
        self.assertEqual(self.driver.counts['page_errors'], 1)

    def test_browser_resource_and_policy_phrases_emit_only_fixed_codes(self):
        self.emit('Failed to load resource: net::ERR_CONNECTION_REFUSED '
                  'https://synthetic.invalid/FICTIONAL_PRIVATE_RESOURCE?fiction=secret')
        self.emit('Access to https://synthetic.invalid/FICTIONAL_PRIVATE_CORS '
                  'has been blocked by CORS policy')
        self.emit('Cross-Origin-Embedder-Policy: net::ERR_BLOCKED_BY_RESPONSE.'
                  'NotSameOriginAfterDefaultedToSameOriginByCoep')
        for code in ('resource_load_failed', 'browser_net_ERR_CONNECTION_REFUSED',
                     'browser_cors', 'browser_coep', 'browser_net_ERR_BLOCKED_BY_RESPONSE'):
            self.assertEqual(self.driver.codes[code], 1)
        self.assertEqual(self.driver.counts['console_error'], 3)
        self.assertEqual(self.driver.counts['console_error_unclassified'], 0)
        reduced = json.dumps([dict(self.driver.codes), dict(self.driver.counts)])
        for private in ('https://', 'synthetic.invalid', 'FICTIONAL_PRIVATE', 'secret'):
            self.assertNotIn(private, reduced)

    def test_unknown_network_codes_remain_unclassified_and_are_never_exported(self):
        self.emit('net::ERR_FICTIONAL_PRIVATE_FAILURE')
        self.assertEqual(self.driver.counts['console_error'], 1)
        self.assertEqual(self.driver.counts['console_error_unclassified'], 1)
        self.assertEqual(dict(self.driver.codes), {})

    def test_request_failure_reads_only_type_and_reduces_known_error_code(self):
        class Request:
            resource_type = 'fetch'
            failure = ('net::ERR_ABORTED '
                       'https://synthetic.invalid/FICTIONAL_PRIVATE_REQUEST?fiction=secret')

            def __getattr__(self, name):
                raise AssertionError('Unexpected access to request metadata')

        self.driver.request_failed(Request())
        self.assertEqual(self.driver.counts['request_failed'], 1)
        self.assertEqual(self.driver.counts['request_failed_type_fetch'], 1)
        self.assertEqual(self.driver.counts['request_failed_ERR_ABORTED'], 1)
        self.assertEqual(self.driver.counts['request_failed_unclassified'], 0)
        reduced = json.dumps(dict(self.driver.counts))
        for private in ('https://', 'synthetic.invalid', 'FICTIONAL_PRIVATE', 'secret'):
            self.assertNotIn(private, reduced)

    def test_unknown_request_failure_and_resource_type_are_counted_without_values(self):
        self.driver.request_failed(SimpleNamespace(
            resource_type='FICTIONAL_PRIVATE_TYPE',
            failure='net::ERR_FICTIONAL_PRIVATE_FAILURE https://synthetic.invalid/private',
        ))
        self.driver.request_failed(SimpleNamespace(resource_type='image', failure=None))
        self.assertEqual(self.driver.counts['request_failed'], 2)
        self.assertEqual(self.driver.counts['request_failed_type_other'], 1)
        self.assertEqual(self.driver.counts['request_failed_type_image'], 1)
        self.assertEqual(self.driver.counts['request_failed_unclassified'], 2)
        reduced = json.dumps(dict(self.driver.counts))
        self.assertNotIn('FICTIONAL_PRIVATE', reduced)
        self.assertNotIn('https://', reduced)


if __name__ == '__main__':
    unittest.main()
