// SPDX-License-Identifier: AGPL-3.0-or-later
// No request URL, header, body, target ID or raw CDP error leaves this module.
import {EventEmitter} from 'node:events';

const CRYPTO_TO_DEVICE = new Set([
  'm.room.encrypted', 'm.room_key_request', 'm.secret.request', 'm.secret.send',
  'm.key.verification.request', 'm.key.verification.ready',
  'm.key.verification.start', 'm.key.verification.accept',
  'm.key.verification.key', 'm.key.verification.mac',
  'm.key.verification.done', 'm.key.verification.cancel',
]);
const TARGET_TYPES = new Set(['page', 'iframe', 'worker', 'service_worker', 'shared_worker']);
const FILTER = [...TARGET_TYPES].map(type => ({type, exclude: false})).concat([{exclude: true}]);
const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);
const KNOWN_METHODS = new Set(['GET', 'HEAD', 'OPTIONS', 'POST', 'PUT', 'PATCH', 'DELETE', 'CONNECT', 'TRACE']);
const CANCELLATION_WINDOW_MS = 500;
const NETWORK_FACT_TTL_MS = 15000;

export function protocolErrorReason(error) {
  // Chromium FindJob emits exactly this when the interception no longer exists.
  // It is not cancellation proof by itself. Never export arbitrary error text.
  return error?.code === -32602 && error?.message === 'Invalid InterceptionId.'
    ? 'interception_missing' : 'other';
}

// These are fixed diagnostic labels, never exported path segments or IDs.
function deniedEndpoint(route) {
  if (route.length === 3 && route[0] === 'user' && route[2] === 'filter') return 'filter_create';
  if (route.length === 2 && route[0] === 'user_directory' && route[1] === 'search') return 'user_search';
  if (route.length === 1 && route[0] === 'search') return 'server_search';
  if (route.length === 1 && route[0] === 'refresh') return 'token_refresh';
  if (route[0] === 'logout') return 'logout';
  if (route[0] === 'login') return 'login';
  if (route[0] === 'register') return 'register';
  if (route.length === 3 && route[0] === 'keys' && route[1] === 'signatures' && route[2] === 'upload') return 'keys_signature';
  if (route.length === 3 && route[0] === 'keys' && route[1] === 'device_signing' && route[2] === 'upload') return 'keys_signing';
  if (route[0] === 'room_keys' && route[1] === 'keys') return 'keys_backup';
  if (route[0] === 'room_keys' && route[1] === 'version') return 'keys_backup_version';
  if (route[0] === 'keys') return 'keys_other';
  if (route[0] === 'sendToDevice') return 'to_device_other';
  if (route[0] === 'user' && (route[2] === 'account_data' || route[2] === 'rooms' && route[4] === 'account_data')) return 'account_data';
  if (route[0] === 'pushers') return 'pusher_set';
  if (route[0] === 'pushrules') return 'push_rules';
  if (route[0] === 'profile') return 'profile';
  if (route[0] === 'devices' || route[0] === 'delete_devices') return 'devices';
  if (['join','knock','createRoom'].includes(route[0]) || route[0] === 'rooms' && ['join','leave','invite','kick','ban','unban','forget'].includes(route[2])) return 'room_membership';
  return 'other';
}

function commandErrorCode(error) {
  if(error?.code === -32000) return 'server_error';
  if(error?.code === -32601) return 'method_missing';
  if(error?.code === -32602) return 'invalid_params';
  if(error?.code === -32600) return 'invalid_request';
  if(error?.code === -32700) return 'parse_error';
  if(error?.message === 'cdp_timeout') return 'timeout';
  if(error?.message === 'cdp_closed') return 'closed';
  return 'other';
}

function exactObject(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value,key));
}

// This validates an SDK encrypted-envelope shape, not its cryptographic value.
// Payloads and identifiers remain local variables and are never included in a
// result, exception, counter or evidence file.
function backupEnvelopeReason(postData) {
  if (typeof postData !== 'string') return 'body_unavailable';
  if (Buffer.byteLength(postData,'utf8') > 1024*1024) return 'body_oversize';
  let body;
  try {body = JSON.parse(postData);} catch {return 'body_invalid_json';}
  // The SDK's jsonEncode emits compact DTO JSON. Require that representation
  // so duplicate/overwritten keys cannot hide raw plaintext before JSON.parse.
  if (JSON.stringify(body) !== postData) return 'body_noncanonical_json';
  if (!exactObject(body,['rooms']) || !body.rooms || typeof body.rooms !== 'object' || Array.isArray(body.rooms)) return 'body_invalid_schema';
  const rooms = Object.entries(body.rooms);
  if (rooms.length > 50) return 'body_session_limit';
  let totalSessions = 0;
  const isMap = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const isCount = value => Number.isSafeInteger(value) && value >= 0;
  const isEncoded = value => typeof value === 'string' && value.length > 0 && /^[A-Za-z0-9+/]+={0,2}$/.test(value);
  for (const [roomId,room] of rooms) {
    if (!roomId || !exactObject(room,['sessions']) || !isMap(room.sessions)) return 'body_invalid_schema';
    const sessions = Object.entries(room.sessions);
    totalSessions += sessions.length;
    if (totalSessions > 50) return 'body_session_limit';
    for (const [sessionId,session] of sessions) {
      if (!sessionId || !exactObject(session,['first_message_index','forwarded_count','is_verified','session_data']) ||
          !isCount(session.first_message_index) || !isCount(session.forwarded_count) || typeof session.is_verified !== 'boolean' ||
          !exactObject(session.session_data,['ephemeral','ciphertext','mac']) ||
          !['ephemeral','ciphertext','mac'].every(key => isEncoded(session.session_data[key]))) return 'body_invalid_schema';
    }
  }
  return null;
}

/** Pure classifier. Inputs stay in memory; result contains fixed codes only. */
export function classify(request) {
  let url, segments;
  try {
    url = new URL(request.url);
    segments = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
  } catch { return {allow: false, code: 'malformed'}; }
  const method = String(request.method || '').toUpperCase();
  if (!['http:', 'https:'].includes(url.protocol)) {
    return {allow: ['data:', 'blob:', 'about:'].includes(url.protocol), code: 'non_http'};
  }
  const start = segments.indexOf('_matrix');
  const matrix = start >= 0;
  const path = matrix ? segments.slice(start + 1) : [];
  if (matrix && path[0] === 'client') {
    // Stable, r0 and unstable namespaces all use a version segment here.
    const route = path.slice(2);
    const op = route[0] === 'rooms' ? route[2] : route[0];
    if (['send', 'redact', 'state', 'receipt', 'read_markers', 'typing'].includes(op) && !SAFE_METHODS.has(method)) {
      return {allow: false, code: op === 'send' ? 'send_or_reaction' : op};
    }
    if (route[0] === 'presence' && !SAFE_METHODS.has(method)) return {allow: false, code: 'presence'};
    if (route.length === 1 && route[0] === 'sync') {
      // A CORS preflight carries no sync operation. The ensuing authenticated
      // GET is intercepted independently and must still request offline presence.
      if (method === 'OPTIONS') return {allow: true, code: 'sync', reason: 'options_preflight'};
      if (method !== 'GET') return {allow: false, code: 'sync', reason: 'bad_method'};
      const presence = url.searchParams.getAll('set_presence');
      const reason = presence.length === 0 ? 'presence_missing'
        : presence.length > 1 ? 'presence_multiple'
        : presence[0] === 'offline' ? 'presence_offline' : 'presence_non_offline';
      return {allow: reason === 'presence_offline', code: 'sync', reason};
    }
    // Diagnosed SDK _checkSyncFilter bootstrap. This creates only a sync-event
    // filter definition; it is not account_data, membership, trust or a send.
    // The SDK uses exactly v3 and an authenticated POST with no query string.
    if (method === 'POST' && start === 0 && segments.length === 6 &&
        url.pathname.split('/').length === 7 && url.search === '' &&
        path[1] === 'v3' && route.length === 3 && route[0] === 'user' &&
        route[1].length > 0 && route[2] === 'filter') {
      return {allow: true, code: 'natural_sync_filter'};
    }
    if (route[0] === 'room_keys' && route[1] === 'keys' && !SAFE_METHODS.has(method)) {
      let reason;
      if (method !== 'PUT') reason = 'method';
      else if (start !== 0 || segments.length !== 5 || url.pathname.split('/').length !== 6 || path[1] !== 'v3' || route.length !== 2) reason = 'route';
      else {
        const query = [...url.searchParams];
        if (query.length !== 1 || query[0][0] !== 'version' || query[0][1].trim().length === 0) reason = 'version_query';
        else reason = backupEnvelopeReason(request.postData);
      }
      if (!reason) return {allow:true,code:'natural_crypto_backup'};
      return {allow:false,code:'account_or_other_matrix_write',endpoint:'keys_backup',reason};
    }
    if (method === 'POST' && route.length === 2 && route[0] === 'keys' && ['query', 'claim', 'upload'].includes(route[1])) {
      return {allow: true, code: 'crypto_keys'};
    }
    if (method === 'PUT' && route.length === 3 && route[0] === 'sendToDevice' && CRYPTO_TO_DEVICE.has(route[1])) {
      return {allow: true, code: 'crypto_to_device'};
    }
    if (SAFE_METHODS.has(method)) return {allow: true, code: 'matrix_read'};
    return {allow: false, code: 'account_or_other_matrix_write', endpoint: deniedEndpoint(route)};
  }
  if (matrix && !SAFE_METHODS.has(method)) return {allow: false, code: 'media_or_other_matrix_write'};
  return {allow: SAFE_METHODS.has(method), code: matrix ? 'matrix_read' : 'non_matrix'};
}

export class SafeCDP extends EventEmitter {
  constructor(socket) {
    super(); this.socket = socket; this.nextId = 0; this.pending = new Map();
    socket.addEventListener('message', event => {
      let message;
      try { message = JSON.parse(event.data); } catch { this.emit('fault', 'cdp_decode'); return; }
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        clearTimeout(pending.timer); this.pending.delete(message.id);
        if (message.error) {
          const error = new Error('cdp_command_failed');
          error.code = message.error.code;
          error.protocolReason = protocolErrorReason(message.error);
          pending.reject(error);
        }
        else pending.resolve(message.result || {});
      } else this.emit('event', message);
    });
    socket.addEventListener('close', () => {
      for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('cdp_closed')); }
      this.pending.clear(); this.emit('fault', 'cdp_closed');
    });
    socket.addEventListener('error', () => this.emit('fault', 'cdp_socket'));
  }
  static async connect(endpoint) {
    const base = new URL(endpoint);
    if (!['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname)) throw new Error('loopback_required');
    const response = await fetch(new URL('/json/version', base));
    if (!response.ok) throw new Error('cdp_discovery_failed');
    const {webSocketDebuggerUrl} = await response.json();
    const wsURL = new URL(webSocketDebuggerUrl);
    if (wsURL.hostname !== base.hostname || wsURL.port !== base.port) throw new Error('cdp_discovery_mismatch');
    const socket = new WebSocket(wsURL);
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, {once: true});
      socket.addEventListener('error', () => reject(new Error('cdp_connect_failed')), {once: true});
    });
    return new SafeCDP(socket);
  }
  send(method, params = {}, sessionId) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {this.pending.delete(id); reject(new Error('cdp_timeout'));}, 15000);
      this.pending.set(id, {resolve, reject, timer});
      this.socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
    });
  }
}

export class TransportGuard {
  constructor(cdp) {
    this.cdp = cdp; this.sessions = new Map(); this.counters = {}; this.errors = 0;
    this.attempts = 0; this.unprotected = 0; this.jobs = new Set(); this.started = false;
    this.detached = new Map(); this.destroyed = new Map();
    this.networkOwners = new Map(); this.canceledNetwork = new Map();
    this.pendingCancellations = new Set(); this.confirmedCancellations = 0;
    cdp.on('event', event => {
      const job = this.handle(event).catch(error => {
        this.errors++;
        const stage = event.method === 'Fetch.requestPaused' ? 'request_paused'
          : event.method === 'Target.attachedToTarget' ? 'target_attach' : 'other';
        this.count(`handler_failed:${stage}:${commandErrorCode(error)}`);
      });
      this.jobs.add(job); job.finally(() => this.jobs.delete(job));
    });
    cdp.on('fault', reason => {
      this.errors++;
      this.count(`cdp_fault:${['cdp_decode','cdp_closed','cdp_socket'].includes(reason) ? reason : 'other'}`);
    });
  }
  count(code) {this.counters[code] = (this.counters[code] || 0) + 1;}
  networkContext(sessionId) {
    let state = this.sessions.get(sessionId);
    if (!state) return null;
    const scopeTargets = [state.targetId];
    const seen = new Set([sessionId]);
    while (state.interception === 'owner_fetch' && state.parentSessionId && !seen.has(state.parentSessionId)) {
      seen.add(state.parentSessionId); state = this.sessions.get(state.parentSessionId);
      if (!state) break;
      scopeTargets.push(state.targetId);
    }
    return {sessionId,targetId:scopeTargets[0],scopeTargets};
  }
  factMatches(record, fact) {
    return fact.networkId === record.networkId &&
      (fact.sessionId === record.sessionId || fact.scopeTargets.includes(record.targetId));
  }
  cancellationProof(record) {
    if (record.targetId && (this.destroyed.get(record.targetId) ?? 0) >= record.pausedAt) return 'target_destroyed';
    if (!record.networkId) return null;
    for (const fact of this.canceledNetwork.values()) {
      if (fact.time >= record.pausedAt && this.factMatches(record,fact)) return 'network_canceled';
    }
    for (const fact of this.networkOwners.values()) {
      if (this.factMatches(record,fact) && (this.destroyed.get(fact.targetId) ?? 0) >= record.pausedAt) return 'target_destroyed';
    }
    return null;
  }
  pruneFacts() {
    const cutoff = Date.now()-NETWORK_FACT_TTL_MS;
    for (const facts of [this.networkOwners,this.canceledNetwork]) {
      for (const [key,fact] of facts) if (fact.time < cutoff) facts.delete(key);
      while (facts.size > 2048) facts.delete(facts.keys().next().value);
    }
  }
  resolveCancellationChecks() {
    for (const pending of [...this.pendingCancellations]) {
      const proof = this.cancellationProof(pending.record);
      if (proof) pending.finish(proof);
    }
  }
  async awaitCancellationProof(record) {
    const immediate = this.cancellationProof(record);
    if (immediate) return immediate;
    return new Promise(resolve => {
      const pending = {record};
      pending.finish = proof => {
        clearTimeout(pending.timer);this.pendingCancellations.delete(pending);resolve(proof);
      };
      pending.timer = setTimeout(()=>pending.finish(null),CANCELLATION_WINDOW_MS);
      this.pendingCancellations.add(pending);
    });
  }
  async install(sessionId, info, parentSessionId) {
    if (!TARGET_TYPES.has(info.type)) return;
    const existing = this.sessions.get(sessionId);
    if (existing) return existing.ready;
    const duplicate = [...this.sessions.values()].find(state => state.targetId === info.targetId);
    if (duplicate) {
      await duplicate.httpReady;
      await this.cdp.send('Runtime.runIfWaitingForDebugger', {}, sessionId);
      return;
    }
    const state = {type: info.type, targetId: info.targetId, guarded: false, parentSessionId};
    state.httpReady = new Promise((resolve, reject) => {state.resolveHttp = resolve;state.rejectHttp = reject;});
    state.httpReady.catch(() => {});
    this.sessions.set(sessionId, state);
    state.ready = (async () => {
      let stage = 'auto_attach'; state.stage = stage;
      try {
      // Every descendant is paused until its own Request-stage Fetch guard exists.
      if (info.type !== 'service_worker') {
        await this.cdp.send('Target.setAutoAttach', {autoAttach: true, waitForDebuggerOnStart: true, flatten: true, filter: FILTER}, sessionId);
      }
      stage = 'fetch_enable'; state.stage = stage;
      try {
        await this.cdp.send('Fetch.enable', {patterns: [{urlPattern: '*', requestStage: 'Request'}]}, sessionId);
        state.interception = 'own_fetch';
      } catch (error) {
        // Chrome exposes dedicated-worker Network but routes its Fetch requests
        // through the owning page. This path is separately proved by the fixture.
        const parent = this.sessions.get(parentSessionId);
        if (info.type !== 'worker' || error.code !== -32601 || !parent || !['page', 'iframe', 'worker'].includes(parent.type)) throw error;
        await parent.ready;
        if (!parent.guarded) throw error;
        state.interception = 'owner_fetch';
      }
      state.resolveHttp();
      if (info.type === 'service_worker') {
        // Chrome's worker Network.enable waits for initialization. Fetch is
        // already active, so install the HTTP barrier before releasing startup.
        stage = 'resume_http_guarded'; state.stage = stage;
        await this.cdp.send('Runtime.runIfWaitingForDebugger', {}, sessionId);
      }
      stage = 'network_enable'; state.stage = stage;
      await this.cdp.send('Network.enable', {}, sessionId);
      stage = 'block_websocket'; state.stage = stage;
      await this.cdp.send('Network.setBlockedURLs', {urls: ['ws://*', 'wss://*']}, sessionId);
      stage = 'bypass_serviceworker'; state.stage = stage;
      if (info.type === 'page' || info.type === 'iframe') {
        await this.cdp.send('Network.setBypassServiceWorker', {bypass: true}, sessionId);
      }
      state.guarded = true;
      stage = 'resume'; state.stage = stage;
      await this.cdp.send('Runtime.runIfWaitingForDebugger', {}, sessionId);
      state.stage = 'guarded';
      } catch {
        state.rejectHttp(new Error('http_barrier_failed'));
        this.count(`install_failed:${info.type}:${stage}`);
        throw new Error('target_guard_install_failed');
      }
    })();
    return state.ready;
  }
  async handle(event) {
    const {method, params = {}, sessionId} = event;
    if (method === 'Target.attachedToTarget') {
      await this.install(params.sessionId, params.targetInfo, sessionId); return;
    }
    if (method === 'Target.detachedFromTarget') {
      const lost = this.sessions.get(params.sessionId);
      if (lost) {
        // Detach is not proof of target death. A still-running parent losing
        // Fetch also invalidates any inherited worker barrier.
        if (!this.destroyed.has(lost.targetId)) this.detached.set(lost.targetId, lost);
        this.count(`target_detached:${lost.type}`);
        for (const state of this.sessions.values()) {
          if (state.parentSessionId === params.sessionId && state.interception === 'owner_fetch') state.guarded = false;
        }
        this.sessions.delete(params.sessionId);
      }
      return;
    }
    if (method === 'Target.targetDestroyed') {
      this.destroyed.set(params.targetId,Date.now()); this.detached.delete(params.targetId);
      for (const [id, state] of this.sessions) if (state.targetId === params.targetId) this.sessions.delete(id);
      this.resolveCancellationChecks();
      return;
    }
    if (method === 'Fetch.requestPaused') {
      const decision = classify(params.request);
      const state = this.sessions.get(sessionId);
      const record = {sessionId,targetId:state?.targetId,networkId:params.networkId,pausedAt:Date.now()};
      this.count(`${state?.type || 'unknown'}:${decision.allow ? 'allow' : 'blocked'}:${decision.code}`);
      const method = String(params.request.method || '').toUpperCase();
      const safeMethod = KNOWN_METHODS.has(method) ? method : 'OTHER';
      this.count(`${state?.type || 'unknown'}:${decision.allow ? 'allow' : 'blocked'}:${decision.code}:${safeMethod}`);
      if (decision.code === 'sync') this.count(`${state?.type || 'unknown'}:sync_reason:${safeMethod}:${decision.reason}`);
      if (decision.endpoint) this.count(`${state?.type || 'unknown'}:denied_endpoint:${safeMethod}:${decision.endpoint}`);
      if (decision.endpoint === 'keys_backup' && decision.reason) this.count(`${state?.type || 'unknown'}:backup_rejected:${safeMethod}:${decision.reason}`);
      if (!decision.allow) this.attempts++;
      try {
        await this.cdp.send(decision.allow ? 'Fetch.continueRequest' : 'Fetch.failRequest', {
          requestId: params.requestId,
          ...(decision.allow ? {} : {errorReason: 'BlockedByClient'}),
        }, sessionId);
      } catch (error) {
        const stage = decision.allow ? 'fetch_continue' : 'fetch_fail';
        this.count(`command_failed:${stage}:${commandErrorCode(error)}`);
        const reason = error.protocolReason === 'interception_missing' ? 'interception_missing' : 'other';
        this.count(`command_reason:${stage}:${reason}`);
        this.count(`command_context:${stage}:${record.networkId ? 'network_id_present' : 'network_id_absent'}`);
        if (decision.allow && error.code === -32602 && reason === 'interception_missing') {
          const proof = await this.awaitCancellationProof(record);
          if (proof) {
            this.confirmedCancellations++;this.count(`command_cancellation_confirmed:${stage}:${proof}`);
            return;
          }
        }
        throw error;
      }
    }
    if (method === 'Network.webSocketCreated' || method === 'Network.webTransportCreated') {
      // Matrix currently uses HTTP. These transports have no Fetch interception.
      this.unprotected++; this.count('unsupported_transport');
    }
    if (method === 'Network.requestWillBeSent') {
      const type = this.sessions.get(sessionId)?.type;
      if (TARGET_TYPES.has(type)) this.count(`${type}:network_observed`);
      const context = this.networkContext(sessionId);
      if (context && params.requestId) this.networkOwners.set(`${sessionId}\0${params.requestId}`,{...context,networkId:params.requestId,time:Date.now()});
      this.pruneFacts();
    }
    if (method === 'Network.loadingFailed') {
      const type=this.sessions.get(sessionId)?.type || 'unknown';
      this.count(`${type}:network_failed:${params.canceled === true ? 'canceled_true' : params.canceled === false ? 'canceled_false' : 'canceled_absent'}`);
    }
    if (method === 'Network.loadingFailed' && params.canceled === true && params.requestId) {
      const key = `${sessionId}\0${params.requestId}`;
      const context = this.networkContext(sessionId) || this.networkOwners.get(key);
      if (context) this.canceledNetwork.set(key,{sessionId,targetId:context.targetId,scopeTargets:context.scopeTargets,networkId:params.requestId,time:Date.now()});
      this.pruneFacts();this.resolveCancellationChecks();
    }
  }
  async settle() {
    while (this.jobs.size) await Promise.all([...this.jobs]);
    await Promise.all([...this.sessions.values()].map(state => state.ready));
  }
  async start() {
    await this.cdp.send('Target.setDiscoverTargets', {discover: true, filter: FILTER});
    await this.cdp.send('Target.setAutoAttach', {autoAttach: true, waitForDebuggerOnStart: true, flatten: true, filter: FILTER});
    await this.settle();
    // Root auto-attach may omit already-running descendants; enumerate and attach
    // every existing worker explicitly before declaring the baseline guarded.
    const {targetInfos} = await this.cdp.send('Target.getTargets');
    for (const info of targetInfos) {
      if (!TARGET_TYPES.has(info.type) || [...this.sessions.values()].some(state => state.targetId === info.targetId)) continue;
      const {sessionId} = await this.cdp.send('Target.attachToTarget', {targetId: info.targetId, flatten: true});
      await this.install(sessionId, info);
    }
    await this.settle(); this.started = true;
    if (!this.isGuarded()) throw new Error('guard_incomplete');
  }
  isGuarded() {
    return this.started && this.errors === 0 && this.unprotected === 0 && this.detached.size === 0 && this.pendingCancellations.size === 0 && this.sessions.size > 0 && [...this.sessions.values()].every(state => state.guarded && (state.interception !== 'owner_fetch' || this.sessions.get(state.parentSessionId)?.guarded));
  }
  snapshot() {
    const targets = {}, stages = {};
    for (const state of this.sessions.values()) {
      targets[state.type] = (targets[state.type] || 0) + 1;
      const key = `${state.type}:${state.stage}`; stages[key] = (stages[key] || 0) + 1;
    }
    return {guarded: this.isGuarded(), application: this.attempts ? 'FAIL' : 'NO_BLOCKED_ATTEMPT_OBSERVED',
      blocked_attempts: this.attempts, harness_errors: this.errors, unsupported_transports: this.unprotected,
      unresolved_detaches: this.detached.size,
      pending_cancellation_checks:this.pendingCancellations.size,confirmed_cancellations:this.confirmedCancellations,
      targets, stages, counts: {...this.counters}, pre_attach_requests: 'NOT_COVERED',
      scope: 'HTTP_ONLY', websocket_prevention: 'UNAVAILABLE',
      existing_websocket_webtransport: 'NOT_COVERED', policy_revision: '2026-10-15-cancellation-proof-v6'};
  }
}
