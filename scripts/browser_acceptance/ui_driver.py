#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Root-only, long-lived aggregate UI driver for an existing guarded browser.

JSON-lines stdin, one fixed action per line. Never launches/closes Chrome, creates
contexts/profiles, exports account state, takes screenshots or prints raw errors.
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit


NETWORKS = ('All chats', 'WhatsApp', 'Messenger', 'Instagram', 'Slack', 'Telegram', 'Matrix')
ACTIONS = {'probe', 'navigate_existing_local', 'wait', 'viewport', 'inbox', 'settings',
           'search', 'search_escape', 'escape', 'back', 'joined_sample', 'network',
           'older', 'details_route', 'header_details', 'offline', 'reload'}
POSITIONS = re.compile(r'(?:main\.dart\.js|native_executor\.js):(\d+):(\d+)')
ASSET_POSITIONS = re.compile(r'(main\.dart\.js|native_executor\.js):(\d+):(\d+)')
FLUTTER_DIAGNOSTICS = {
    'flutter_renderflex_overflow': re.compile(r'\bRenderFlex overflowed\b', re.I),
    'flutter_exception_caught': re.compile(r'\bEXCEPTION CAUGHT\b', re.I),
    'flutter_exception_thrown': re.compile(r'\bAnother exception was thrown\b', re.I),
    'flutter_assertion': re.compile(r'\b(?:AssertionError|Assertion failed|Failed assertion)\b', re.I),
    'flutter_semantics': re.compile(r'\bsemantics\b|\bSemantics(?:Node|Owner|Handle)\b', re.I),
}
BROWSER_DIAGNOSTICS = {
    'resource_load_failed': re.compile(r'^Failed to load resource\b', re.I),
    'browser_cors': re.compile(r'\bCORS policy\b|\bCross-Origin Request Blocked\b', re.I),
    'browser_coep': re.compile(r'\bCross-Origin-Embedder-Policy\b|\bNotSameOriginAfterDefaultedToSameOriginByCoep(?:AndDip)?\b', re.I),
}
NETWORK_ERROR_CODES = frozenset({
    'ERR_FAILED', 'ERR_CONNECTION_REFUSED', 'ERR_BLOCKED_BY_CLIENT', 'ERR_ABORTED',
    'ERR_NAME_NOT_RESOLVED', 'ERR_CONNECTION_RESET', 'ERR_CONNECTION_CLOSED',
    'ERR_CONNECTION_TIMED_OUT', 'ERR_TIMED_OUT', 'ERR_INTERNET_DISCONNECTED',
    'ERR_NETWORK_CHANGED', 'ERR_BLOCKED_BY_RESPONSE', 'ERR_SSL_PROTOCOL_ERROR',
    'ERR_CERT_AUTHORITY_INVALID', 'ERR_CERT_DATE_INVALID', 'ERR_CERT_COMMON_NAME_INVALID',
})
NETWORK_ERROR_PATTERN = re.compile(r'\bnet::(ERR_[A-Z0-9_]+)\b')
RESOURCE_TYPES = frozenset({
    'document', 'stylesheet', 'image', 'media', 'font', 'script', 'texttrack',
    'xhr', 'fetch', 'eventsource', 'websocket', 'manifest', 'other',
})


def known_network_errors(text):
    """Return only allowlisted codes, never arbitrary browser failure text."""
    return set(NETWORK_ERROR_PATTERN.findall(text)) & NETWORK_ERROR_CODES if isinstance(text, str) else set()


def console_source_location(location):
    """Reduce known asset locations to one-based coordinates; never return a URL.

    Playwright console.location supplies zero-based lineNumber/columnNumber.
    Text stack coordinates already use the one-based source_positions format.
    """
    if not isinstance(location, dict) or not isinstance(location.get('url'), str):
        return None
    try:
        source = urlsplit(location['url'])
    except ValueError:
        return None
    if source.scheme not in ('http', 'https') or not source.netloc or source.query or source.fragment:
        return None
    asset = next((name for name in ('main.dart.js', 'native_executor.js')
                  if source.path.endswith('/' + name) and location['url'].endswith('/' + name)), None)
    line, column = location.get('lineNumber'), location.get('columnNumber')
    if asset is None or any(type(value) is not int or not 0 <= value < 2**31
                            for value in (line, column)):
        return None
    return asset, line + 1, column + 1


class Refused(Exception):
    def __init__(self, code):
        self.code = code


def guard_snapshot(path, expected_revision):
    try:
        data = json.loads(path.read_text())
        pid = data['pid']
        if not isinstance(pid, int) or pid <= 0:
            raise ValueError()
        os.kill(pid, 0)
        expiry = datetime.datetime.fromisoformat(data['expires_at'].replace('Z', '+00:00')).timestamp()
        heartbeat = datetime.datetime.fromisoformat(data['heartbeat_at'].replace('Z', '+00:00')).timestamp()
        started = datetime.datetime.fromisoformat(data['started_at'].replace('Z', '+00:00')).timestamp()
        if (data.get('guarded') is not True or expiry <= time.time()
                or not started <= heartbeat < expiry or heartbeat > time.time() + 1
                or data.get('policy_revision') != expected_revision
                or any(data.get(key) != 0 for key in
                       ('harness_errors', 'unsupported_transports', 'unresolved_detaches'))):
            raise ValueError()
        result = {key: data[key] for key in
                  ('blocked_attempts', 'harness_errors', 'unsupported_transports', 'unresolved_detaches')}
        if any(not isinstance(value, int) or value < 0 for value in result.values()):
            raise ValueError()
        result.update(pid=pid, started_at=data['started_at'], heartbeat_at=data['heartbeat_at'])
        return result
    except Exception:
        raise Refused('GUARD_NOT_READY') from None


def fresh_guard_after(read_snapshot, pump, before, completed_at, timeout_ms=2500, monotonic=time.monotonic):
    """Require a published snapshot taken after action completion, same guard.

    Clock/pump injection permits account-free publisher-cadence regressions.
    """
    deadline = monotonic() + timeout_ms / 1000
    while True:
        after = read_snapshot()
        if (after['pid'], after['started_at']) != (before['pid'], before['started_at']):
            raise Refused('GUARD_GENERATION_CHANGED')
        if after['blocked_attempts'] < before['blocked_attempts']:
            raise Refused('GUARD_COUNTER_REGRESSED')
        heartbeat = datetime.datetime.fromisoformat(after['heartbeat_at'].replace('Z', '+00:00')).timestamp()
        if heartbeat > completed_at:
            return after
        if monotonic() >= deadline:
            raise Refused('FRESH_GUARD_TIMEOUT')
        pump(min(100, max(1, (deadline - monotonic()) * 1000)))


class Driver:
    def __init__(self, page, context, args):
        self.page, self.context, self.args = page, context, args
        self.counts = collections.Counter()
        self.positions = set()
        self.source_locations = set()
        self.codes = collections.Counter()
        self.viewport = {'width': 390, 'height': 844}
        if args.viewport_file and args.viewport_file.is_file():
            data = json.loads(args.viewport_file.read_text())
            self.viewport = self.dimensions(data)
        page.set_default_timeout(2500)
        page.on('pageerror', self.page_error)
        page.on('console', self.console)
        page.on('requestfailed', self.request_failed)

    @staticmethod
    def dimensions(data):
        width, height = data.get('width'), data.get('height')
        if type(width) is not int or type(height) is not int or not (280 <= width <= 3000 and 300 <= height <= 3000):
            raise Refused('INVALID_VIEWPORT')
        return {'width': width, 'height': height}

    def page_error(self, error):
        self.counts['page_errors'] += 1
        self.record_positions(error.stack or '')

    def record_positions(self, text):
        self.positions.update(POSITIONS.findall(text)[:8])
        self.source_locations.update((asset, int(line), int(column))
                                     for asset, line, column in ASSET_POSITIONS.findall(text)[:8])

    def console(self, message):
        if message.type in ('warning', 'error'):
            self.counts['console_' + message.type] += 1
        text = message.text
        classified = False
        for code in ('invalid_state', 'missing_value', 'databaseUnavailable', 'mediaUnavailable'):
            if code in text:
                self.codes[code] += 1
                classified = True
        if message.type in ('warning', 'error'):
            for code, pattern in {**FLUTTER_DIAGNOSTICS, **BROWSER_DIAGNOSTICS}.items():
                if pattern.search(text):
                    self.codes[code] += 1
                    classified = True
            for code in known_network_errors(text):
                self.codes['browser_net_' + code] += 1
                classified = True
            if not classified:
                self.counts['console_' + message.type + '_unclassified'] += 1
        self.record_positions(text)
        location = console_source_location(message.location)
        if location is not None:
            self.source_locations.add(location)
            self.positions.add((str(location[1]), str(location[2])))

    def request_failed(self, request):
        # Failure events are distinct from HTTP status errors (for example 404).
        # Never access the request URL, headers, body or response here.
        self.counts['request_failed'] += 1
        resource_type = request.resource_type
        resource_type = resource_type if resource_type in RESOURCE_TYPES else 'other'
        self.counts['request_failed_type_' + resource_type] += 1
        codes = known_network_errors(request.failure)
        if not codes:
            self.counts['request_failed_unclassified'] += 1
        for code in codes:
            self.counts['request_failed_' + code] += 1

    def guarded_wait(self, milliseconds):
        if type(milliseconds) is not int or not 0 <= milliseconds <= 20000:
            raise Refused('INVALID_WAIT')
        deadline = time.monotonic() + milliseconds / 1000
        while time.monotonic() < deadline:
            guard_snapshot(self.args.guard, self.args.policy_revision)
            self.page.wait_for_timeout(min(250, max(1, (deadline - time.monotonic()) * 1000)))

    def incognito(self):
        return self.page.evaluate('''()=>{const v=localStorage.getItem("flutter.pl.personal.incognito");
          return {effective:v===null||v==="true",default:v===null,valid:v===null||v==="true"||v==="false"};}''')

    def one_click(self, locator):
        if locator.count() != 1:
            raise Refused('UNIQUE_CONTROL_UNPROVED')
        locator.dispatch_event('click')

    def search_button(self):
        return self.page.get_by_role('button', name=re.compile(r'^Search(?:\s+Search)?$'))

    def snapshot(self):
        page = self.page
        return {
            'password_present': page.locator('input[type=password]').count() > 0,
            'settings_buttons': page.get_by_role('button', name='Settings', exact=True).count(),
            'back_buttons': page.get_by_role('button', name='Back', exact=True).count(),
            'header_details_buttons': page.get_by_role('button', name=re.compile(r'Chat details for ')).count(),
            'close_search_buttons': page.get_by_role('button', name='Close search', exact=True).count(),
            'textboxes': page.get_by_role('textbox').count(),
            'dialogs': page.get_by_role('dialog').count(),
            'safe_error_dialogs': page.get_by_text('Could not complete this action', exact=True).count(),
            'safe_report_copy_actions': page.get_by_text('Copy safe report', exact=True).count(),
            'menuitems': page.get_by_role('menuitem').count(),
            'semantics_count': page.locator('flt-semantics').count(),
            'composer_empty': page.get_by_role('textbox').evaluate_all('es=>es.every(e=>!e.value)'),
            'cross_origin_isolated': page.evaluate('crossOriginIsolated'),
            'dimensions': page.evaluate('({width:innerWidth,height:innerHeight})'),
            'decrypt_errors': page.get_by_text(re.compile(r'Could not decrypt message:')).count(),
            'route': page.evaluate(r'''()=>{const p=location.hash.slice(1).split('?')[0];return {
              inbox:p==='/rooms',settings:p==='/rooms/settings',details:/\/details$/.test(p),
              conversation:/^\/rooms\/[^/]+$/.test(p)&&p!=='/rooms/settings'};}'''),
            'network_filters': {network: page.get_by_role('button', name=re.compile('Show chats, ' + re.escape(network))).count() > 0 for network in NETWORKS},
            'network_label_counts': {network: page.get_by_text(network, exact=True).count() for network in NETWORKS if network != 'All chats'},
        }

    def run(self, command):
        action = command.get('action')
        if action not in ACTIONS:
            raise Refused('UNSUPPORTED_ACTION')
        before = guard_snapshot(self.args.guard, self.args.policy_revision)
        result = {'action': action, 'guard_before': before}
        try:
            page = self.page
            if action == 'navigate_existing_local':
                if page.url != 'about:blank':
                    raise Refused('BLANK_PAGE_REQUIRED')
                page.goto('http://127.0.0.1:5183/', wait_until='domcontentloaded')
            elif not page.url.startswith('http://127.0.0.1:5183/'):
                raise Refused('LOCAL_PAGE_REQUIRED')
            page.set_viewport_size(self.viewport)
            if action == 'viewport':
                self.viewport = self.dimensions(command)
                page.set_viewport_size(self.viewport)
                if self.args.viewport_file:
                    self.args.viewport_file.write_text(json.dumps(self.viewport))
            elif action == 'wait':
                self.guarded_wait(command.get('milliseconds', 1000))
            elif action in ('inbox', 'settings'):
                page.evaluate('(p)=>location.hash=p', '/rooms/settings' if action == 'settings' else '/rooms')
            elif action in ('search', 'search_escape'):
                self.one_click(self.search_button())
                self.guarded_wait(300)
                result['search_opened'] = page.get_by_role('button', name='Close search', exact=True).count() == 1
                if action == 'search_escape':
                    # No disconnect, route or viewport change between open and Escape.
                    page.keyboard.press('Escape')
                    self.guarded_wait(300)
                    result['search_closed_after_escape'] = page.get_by_role('button', name='Close search', exact=True).count() == 0
            elif action == 'escape':
                page.keyboard.press('Escape')
            elif action == 'back':
                self.one_click(page.get_by_role('button', name='Back', exact=True))
            elif action == 'reload':
                page.reload(wait_until='domcontentloaded')
                page.set_viewport_size(self.viewport)
            elif action == 'network':
                wanted = command.get('network')
                if wanted not in NETWORKS:
                    raise Refused('UNSUPPORTED_NETWORK')
                self.one_click(page.get_by_role('button', name=re.compile(r'^Show chats,')))
                self.guarded_wait(300)
                options = page.get_by_role('button', name=re.compile('^' + re.escape(wanted) + r'(?:\s+' + re.escape(wanted) + ')?$'))
                # Flutter can expose an outer semantic button and a nested leaf.
                leaves = options.evaluate_all('es=>es.map((e,i)=>e.querySelector("[role=button]")?null:i).filter(i=>i!==null)')
                result['network_available'] = len(leaves) > 0
                if len(leaves) == 1:
                    options.nth(leaves[0]).dispatch_event('click')
                    self.guarded_wait(300)
                    result['network_filter_activated'] = page.get_by_role('button', name=re.compile('^Show chats, ' + re.escape(wanted))).count() == 1
                else:
                    page.keyboard.press('Escape')
                    if len(leaves) > 1:
                        raise Refused('UNIQUE_NETWORK_OPTION_UNPROVED')
            elif action in ('joined_sample', 'older', 'details_route', 'header_details', 'offline'):
                state = self.incognito()
                if not state['valid'] or not state['effective']:
                    raise Refused('INCOGNITO_REQUIRED')
                if page.get_by_label('Sending', exact=True).count():
                    raise Refused('PENDING_SEND')
                if not page.get_by_role('textbox').evaluate_all('es=>es.every(e=>!e.value)'):
                    raise Refused('DRAFT_PRESENT')
                if action == 'joined_sample':
                    if hashlib.sha256(self.args.membership_source.read_bytes()).hexdigest() != self.args.membership_source_sha:
                        raise Refused('MEMBERSHIP_SOURCE_CHANGED')
                    close = page.get_by_role('button', name='Close search', exact=True)
                    if close.count():
                        self.one_click(close)
                        self.guarded_wait(250)
                    if page.get_by_role('menuitem').count():
                        page.keyboard.press('Escape')
                        self.guarded_wait(250)
                    if page.get_by_role('menuitem').count():
                        raise Refused('PREVIOUS_MENU_STILL_OPEN')
                    rows = page.locator('[role=button][aria-current]')
                    index = command.get('index', 0)
                    if type(index) is not int or index < 0 or index >= rows.count():
                        raise Refused('CANDIDATE_UNAVAILABLE')
                    identity = rows.nth(index).get_attribute('aria-label')
                    if not identity:
                        raise Refused('ROW_IDENTITY_UNAVAILABLE')
                    candidate = rows.and_(page.get_by_role('button', name=identity, exact=True))
                    if candidate.count() != 1:
                        raise Refused('UNIQUE_ROW_IDENTITY_UNPROVED')
                    candidate.click(button='right')
                    self.guarded_wait(700)
                    labels = ('Mute chat', 'Unmute chat', 'Mark as read', 'Mark as unread')
                    label_patterns = {label: re.compile('^' + re.escape(label) + r'(?:\s+' + re.escape(label) + ')?$') for label in labels}
                    result['context_menu_items_total'] = page.get_by_role('menuitem').count()
                    result['known_menuitem_counts'] = {label: page.get_by_role('menuitem', name=pattern).count() for label, pattern in label_patterns.items()}
                    result['known_menu_label_counts'] = {label: page.get_by_text(pattern).count() for label, pattern in label_patterns.items()}
                    result['known_menu_button_counts'] = {label: page.get_by_role('button', name=pattern).count() for label, pattern in label_patterns.items()}
                    proof = any(result['known_menuitem_counts'].values())
                    result['joined_menu_proof'] = proof
                    page.keyboard.press('Escape')
                    self.guarded_wait(700)
                    current = rows.and_(page.get_by_role('button', name=identity, exact=True))
                    result['same_row_reidentified'] = current.count() == 1
                    if not proof or not result['same_row_reidentified']:
                        raise Refused('JOINED_MEMBERSHIP_UNPROVED')
                    guard_snapshot(self.args.guard, self.args.policy_revision)
                    current.dispatch_event('click')
                    identity = None
                elif action == 'older':
                    page.mouse.move(self.viewport['width'] // 2, self.viewport['height'] // 3)
                    page.mouse.wheel(0, -600)
                elif action == 'header_details':
                    self.one_click(page.get_by_role('button', name=re.compile(r'Chat details for ')))
                elif action == 'details_route':
                    if not page.evaluate(r'''()=>{const p=location.hash.slice(1).split('?')[0];if(!/^\/rooms\/[^/]+$/.test(p)||p==='/rooms/settings')return false;location.hash=p+'/details';return true;}'''):
                        raise Refused('SOURCE_ROUTE_UNPROVED')
                else:
                    try:
                        self.context.set_offline(True)
                        self.guarded_wait(3000)
                        result['offline_observed'] = not page.evaluate('navigator.onLine')
                    finally:
                        self.context.set_offline(False)
                    self.guarded_wait(3000)
                    result['online_restored'] = page.evaluate('navigator.onLine')
                    result['safe_error_dialog_absent'] = page.get_by_text('Could not complete this action', exact=True).count() == 0
                    result['inbox_controls_recovered'] = self.search_button().count() == 1
            self.guarded_wait(500)
            placeholder = page.locator('flt-semantics-placeholder')
            if placeholder.count() == 1:
                placeholder.dispatch_event('click')
                self.guarded_wait(250)
            result['ui'] = self.snapshot()
            result['incognito'] = self.incognito()
            result['status'] = 'OBSERVED'
        except Refused as error:
            result.update(status='REFUSED', code=error.code)
        except Exception:
            result.update(status='HARNESS_ERROR', code='UI_ACTION_FAILED', raw_error_recorded=False)
        completed_at = time.time()
        try:
            after = fresh_guard_after(
                lambda: guard_snapshot(self.args.guard, self.args.policy_revision),
                self.page.wait_for_timeout, before, completed_at)
            result['guard_after'] = after
            result['blocked_delta'] = after['blocked_attempts'] - before['blocked_attempts']
            result['application'] = 'FAIL' if result['blocked_delta'] else 'NO_BLOCKED_ATTEMPT_OBSERVED'
            result['session_application'] = 'FAIL' if after['blocked_attempts'] else 'NO_BLOCKED_ATTEMPT_OBSERVED'
        except Refused as error:
            result.update(status='REFUSED', code=error.code, application='UNVERIFIED')
        result['diagnostic_counts'] = dict(self.counts)
        result['diagnostic_codes'] = dict(self.codes)
        result['source_positions'] = sorted(self.positions)[:20]
        result['source_position_basis'] = 'one_based'
        result['source_locations'] = [dict(asset=asset, line=line, column=column)
                                      for asset, line, column in sorted(self.source_locations)[:20]]
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guard', type=Path, required=True)
    parser.add_argument('--policy-revision', default='2026-10-15-sync-filter-v4',
                        help='Exact expected guard revision; no wildcard matching')
    parser.add_argument('--viewport-file', type=Path)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--membership-source', type=Path, required=True)
    parser.add_argument('--membership-source-sha', required=True)
    args = parser.parse_args()
    playwright = None
    try:
        guard_snapshot(args.guard, args.policy_revision)
        from playwright.sync_api import sync_playwright
        playwright = sync_playwright().start()
        browser = playwright.chromium.connect_over_cdp('http://127.0.0.1:9238')
        candidates = [(context, page) for context in browser.contexts for page in context.pages
                      if page.url.startswith('http://127.0.0.1:5183/')]
        if not candidates:
            candidates = [(context, page) for context in browser.contexts for page in context.pages if page.url == 'about:blank']
        if len(candidates) != 1:
            raise Refused('UNIQUE_EXISTING_PAGE_UNPROVED')
        context, page = candidates[0]
        driver = Driver(page, context, args)
        print(json.dumps({'driver': 'READY', 'connection': 'one_existing', 'raw_account_output': False}), flush=True)
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if not isinstance(command, dict):
                    raise ValueError()
                result = driver.run(command)
            except Refused as error:
                result = {'status': 'REFUSED', 'code': error.code}
            except Exception:
                result = {'status': 'HARNESS_ERROR', 'code': 'INVALID_COMMAND', 'raw_error_recorded': False}
            if args.output_dir:
                args.output_dir.mkdir(parents=True, exist_ok=True)
                with (args.output_dir / ('ui-action-' + str(time.time_ns()) + '.json')).open('x') as output:
                    json.dump(result, output, indent=2)
            print(json.dumps(result), flush=True)
    except Refused as error:
        print(json.dumps({'driver': 'REFUSED', 'code': error.code}), flush=True)
        return 1
    except Exception:
        print(json.dumps({'driver': 'HARNESS_ERROR', 'code': 'DRIVER_CONNECTION_FAILED', 'raw_error_recorded': False}), flush=True)
        return 1
    finally:
        if playwright is not None:
            # Disconnect automation; never call browser.close/context.close.
            try:
                playwright.stop()
            except Exception:
                print(json.dumps({'driver': 'DISCONNECT_ERROR', 'raw_error_recorded': False}), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
